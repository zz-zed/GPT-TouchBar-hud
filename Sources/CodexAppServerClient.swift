import Foundation

enum CodexAppServerError: LocalizedError {
    case runtimeNotFound
    case processUnavailable
    case malformedResponse
    case serverError(String)
    case missingResult
    case requestTimedOut
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .runtimeNotFound:
            return "未找到客户端内置的 Codex 程序，请确认 ChatGPT / Codex 已安装在 /Applications。"
        case .processUnavailable:
            return "Codex app-server is not running."
        case .malformedResponse:
            return "Codex app-server returned an unexpected response."
        case .serverError(let message):
            return message
        case .missingResult:
            return "Codex app-server response did not include a result."
        case .requestTimedOut:
            return "Codex app-server 请求超时。"
        case .responseTooLarge:
            return "Codex app-server 响应超过大小限制。"
        }
    }
}

/// Bound each newline-delimited frame, not the total size of a batch of frames.
struct AppServerLineBuffer {
    static let maximumFrameBytes = 16 * 1024 * 1024
    let limit: Int
    private(set) var pending = Data()

    init(limit: Int = maximumFrameBytes) {
        precondition(limit > 0)
        self.limit = limit
    }
    mutating func reset() { pending = Data() }
    mutating func append(_ data: Data, onLine: (Data) -> Void) throws {
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 0x0A)
            let end = newline ?? data.endIndex
            guard data.distance(from: start, to: end) <= limit - pending.count else {
                reset()
                throw CodexAppServerError.responseTooLarge
            }
            pending.append(contentsOf: data[start..<end])
            guard let newline else { return }
            let line = pending
            reset()
            if !line.isEmpty { onLine(line) }
            start = data.index(after: newline)
        }
    }
}

protocol AccountUsageClient: AnyObject {
    func readAccountIdentity(completion: @escaping (Result<String?, Error>) -> Void)
    func readTokenUsage(completion: @escaping (Result<AccountTokenUsageResponse, Error>) -> Void)
}

enum CodexRuntimeLocator {
    /// Keep host priority stable while supporting both bundle layouts.
    static func locate(in applicationsDirectory: URL = URL(fileURLWithPath: "/Applications"),
                       fileManager: FileManager = .default) -> URL? {
        let layouts = [
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Contents/Resources/codex"
        ]
        for host in ["ChatGPT.app", "Codex.app", "GPT.app"] {
            for layout in layouts {
                let candidate = applicationsDirectory.appendingPathComponent(host).appendingPathComponent(layout)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                   !isDirectory.boolValue, fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}

final class CodexAppServerClient: AccountUsageClient {
    typealias JSONDictionary = [String: Any]

    private let queue = DispatchQueue(label: "GPTTouchBarHUD.CodexAppServerClient")

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = AppServerLineBuffer()
    private var connectionGeneration = 0
    private let executableURL: URL?
    private var nextRequestId = 1
    private var pendingResponses: [Int: (Result<Any, Error>) -> Void] = [:]

    var onRateLimitsUpdated: (() -> Void)?
    var onAccountUpdated: (() -> Void)?

    init(executableURL: URL? = nil) { self.executableURL = executableURL }

    func readAccountIdentity(completion: @escaping (Result<String?, Error>) -> Void) {
        request(method: "account/read", params: ["refreshToken": false]) { result in
            completion(result.flatMap { value in
                guard let response = value as? JSONDictionary else {
                    return .failure(CodexAppServerError.malformedResponse)
                }
                guard let account = response["account"] as? JSONDictionary else {
                    return .success(nil)
                }
                // Account metadata only; never request, persist or log access tokens.
                guard let data = try? JSONSerialization.data(withJSONObject: account, options: .sortedKeys),
                      let identity = String(data: data, encoding: .utf8) else {
                    return .failure(CodexAppServerError.malformedResponse)
                }
                return .success(identity)
            })
        }
    }

    func readTokenUsage(completion: @escaping (Result<AccountTokenUsageResponse, Error>) -> Void) {
        request(method: "account/usage/read", params: nil) { result in
            completion(result.flatMap { value in
                Result {
                    let data = try JSONSerialization.data(withJSONObject: value)
                    return try JSONDecoder().decode(AccountTokenUsageResponse.self, from: data)
                }
            })
        }
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            if self.process?.isRunning == true {
                DispatchQueue.main.async {
                    completion(.success(()))
                }
                return
            }

            do {
                try self.launchProcess()
                self.initialize(completion: completion)
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func stop() {
        queue.async { self.closeConnection(CodexAppServerError.processUnavailable) }
    }

    /// Queue-confined cleanup also invalidates callbacks already queued by old pipes.
    private func closeConnection(_ error: Error) {
        connectionGeneration += 1
        process?.terminationHandler = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputPipe?.fileHandleForWriting.close()
        // Release read handles with their pipes. An in-flight readability callback
        // retains its handle until it finishes; do not close it underneath the read.
        if process?.isRunning == true { process?.terminate() }
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer.reset()
        failPendingResponses(error)
    }

    func readRateLimits(completion: @escaping (Result<GetAccountRateLimitsResponse, Error>) -> Void) {
        request(method: "account/rateLimits/read", params: nil) { result in
            switch result {
            case .success(let value):
                do {
                    guard JSONSerialization.isValidJSONObject(value) else {
                        throw CodexAppServerError.malformedResponse
                    }
                    let data = try JSONSerialization.data(withJSONObject: value)
                    let response = try JSONDecoder().decode(GetAccountRateLimitsResponse.self, from: data)
                    completion(.success(response))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func launchProcess() throws {
        closeConnection(CodexAppServerError.processUnavailable)
        guard let codexURL = executableURL ?? CodexRuntimeLocator.locate() else {
            throw CodexAppServerError.runtimeNotFound
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = codexURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let generation = connectionGeneration

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            self?.queue.async {
                guard let self, self.connectionGeneration == generation else { return }
                self.consumeOutput(data)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                guard let self, self.connectionGeneration == generation else { return }
                self.closeConnection(CodexAppServerError.processUnavailable)
            }
        }

        try process.run()

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
    }

    private func initialize(completion: @escaping (Result<Void, Error>) -> Void) {
        let capabilities: JSONDictionary = [
            "experimentalApi": true,
            "requestAttestation": false,
            "optOutNotificationMethods": [String]()
        ]

        let params: JSONDictionary = [
            "clientInfo": [
                "name": "gpt-touchbar-hud",
                "title": "GPT TouchBar HUD",
                "version": "0.1.21"
            ],
            "capabilities": capabilities
        ]

        request(method: "initialize", params: params) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    private func request(method: String, params: Any?, completion: @escaping (Result<Any, Error>) -> Void) {
        queue.async { [self] in
            guard let writer = self.inputPipe?.fileHandleForWriting, self.process?.isRunning == true else {
                DispatchQueue.main.async {
                    completion(.failure(CodexAppServerError.processUnavailable))
                }
                return
            }

            let requestId = self.nextRequestId
            self.nextRequestId += 1
            self.pendingResponses[requestId] = { result in
                DispatchQueue.main.async {
                    completion(result)
                }
            }
            self.queue.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.pendingResponses.removeValue(forKey: requestId)?(.failure(CodexAppServerError.requestTimedOut))
            }

            var payload: JSONDictionary = [
                "id": requestId,
                "method": method
            ]
            if let params {
                payload["params"] = params
            }

            do {
                let data = try JSONSerialization.data(withJSONObject: payload)
                var framed = data
                framed.append(0x0A)
                writer.write(framed)
            } catch {
                self.pendingResponses.removeValue(forKey: requestId)
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private func consumeOutput(_ data: Data) {
        do { try outputBuffer.append(data) { self.consumeLine($0) } }
        catch { closeConnection(error) }
    }

    private func consumeLine(_ data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let message = object as? JSONDictionary
        else {
            return
        }

        if let method = message["method"] as? String {
            if method == "account/updated" || method == "account/login/completed" {
                DispatchQueue.main.async { self.onAccountUpdated?() }
            }
            if method == "account/rateLimits/updated" {
                DispatchQueue.main.async {
                    self.onRateLimitsUpdated?()
                }
            }
            return
        }

        guard let id = intRequestId(from: message["id"]) else {
            return
        }

        guard let completion = pendingResponses.removeValue(forKey: id) else {
            return
        }

        if let error = message["error"] as? JSONDictionary {
            let message = error["message"] as? String ?? "Codex app-server returned an error."
            completion(.failure(CodexAppServerError.serverError(message)))
            return
        }

        guard let result = message["result"] else {
            completion(.failure(CodexAppServerError.missingResult))
            return
        }

        completion(.success(result))
    }

    private func intRequestId(from value: Any?) -> Int? {
        if let id = value as? Int {
            return id
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func failPendingResponses(_ error: Error) {
        let completions = pendingResponses.values
        pendingResponses.removeAll()

        completions.forEach { completion in
            completion(.failure(error))
        }
    }
}
