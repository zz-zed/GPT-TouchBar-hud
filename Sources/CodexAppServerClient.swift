import Foundation

enum CodexAppServerError: LocalizedError {
    case processUnavailable
    case malformedResponse
    case serverError(String)
    case missingResult
    case requestTimedOut

    var errorDescription: String? {
        switch self {
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
        }
    }
}

protocol AccountUsageClient: AnyObject {
    func readAccountIdentity(completion: @escaping (Result<String?, Error>) -> Void)
    func readTokenUsage(completion: @escaping (Result<AccountTokenUsageResponse, Error>) -> Void)
}

final class CodexAppServerClient: AccountUsageClient {
    typealias JSONDictionary = [String: Any]

    private let codexCandidates = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/Applications/GPT.app/Contents/Resources/codex"
    ].map(URL.init(fileURLWithPath:))
    private let queue = DispatchQueue(label: "GPTTouchBarHUD.CodexAppServerClient")

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var nextRequestId = 1
    private var pendingResponses: [Int: (Result<Any, Error>) -> Void] = [:]

    var onRateLimitsUpdated: (() -> Void)?
    var onAccountUpdated: (() -> Void)?

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
        queue.async {
            self.outputPipe?.fileHandleForReading.readabilityHandler = nil
            self.errorPipe?.fileHandleForReading.readabilityHandler = nil
            self.inputPipe?.fileHandleForWriting.closeFile()
            if self.process?.isRunning == true {
                self.process?.terminate()
            }
            self.process = nil
            self.failPendingResponses(CodexAppServerError.processUnavailable)
        }
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
        guard let codexURL = codexCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw CodexAppServerError.processUnavailable
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

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            self?.queue.async {
                self?.consumeOutput(data)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                self?.failPendingResponses(CodexAppServerError.processUnavailable)
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
        outputBuffer.append(data)

        while let newlineRange = outputBuffer.firstRange(of: Data([0x0A])) {
            let line = outputBuffer.subdata(in: outputBuffer.startIndex..<newlineRange.lowerBound)
            outputBuffer.removeSubrange(outputBuffer.startIndex..<newlineRange.upperBound)

            guard !line.isEmpty else {
                continue
            }
            consumeLine(line)
        }
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
