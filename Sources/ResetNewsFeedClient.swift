import Foundation
import ResetNewsCore

protocol ResetNewsCancellable: AnyObject { func cancel() }

final class ResetNewsCancellation: ResetNewsCancellable {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void = {}) { self.action = action }
    func cancel() { let pending = action; action = nil; pending?() }
}

protocol ResetNewsHTTPTransport: AnyObject {
    @discardableResult
    func send(_ request: URLRequest, completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> ResetNewsCancellable
}

final class ResetNewsURLSessionTransport: ResetNewsHTTPTransport {
    private let session: URLSession
    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: configuration)
    }
    func send(_ request: URLRequest, completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> ResetNewsCancellable {
        let task = session.dataTask(with: request, completionHandler: completion)
        task.resume()
        return ResetNewsCancellation { task.cancel() }
    }
}

enum ResetNewsFetchError: Error, Equatable {
    case network(String)
    case response
    case http(Int)
    case json(String)
    case identity(String)

    var description: String {
        switch self {
        case let .network(message): return "网络错误：\(message)"
        case .response: return "响应来源或格式无效"
        case let .http(status): return "HTTP \(status)"
        case let .json(message): return "消息格式错误：\(message)"
        case let .identity(message): return "来源身份校验失败：\(message)"
        }
    }
}

struct ResetNewsHTTPMetadata: Equatable {
    var cacheControl: String?
    var maxAge: TimeInterval?
    var publishedCheckedAt: Date?
    var publishedExpiresAt: Date?
    var retryAfter: Date?
    var stale = false
    var rejectedIdentityCount = 0

    func isStale(at now: Date) -> Bool {
        stale || publishedExpiresAt.map { $0 <= now } == true
    }

    static func parse(_ response: HTTPURLResponse, now: Date) -> ResetNewsHTTPMetadata {
        let cacheControl = response.value(forHTTPHeaderField: "cache-control")
        let maxAge = cacheControl?.split(separator: ",").compactMap { part -> TimeInterval? in
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].lowercased() == "max-age" else { return nil }
            return TimeInterval(pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))
        }.first
        let retry = response.value(forHTTPHeaderField: "retry-after").flatMap { value -> Date? in
            if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(seconds) }
            return date(value)
        }
        return ResetNewsHTTPMetadata(cacheControl: cacheControl, maxAge: maxAge,
                                     publishedCheckedAt: response.value(forHTTPHeaderField: "x-published-checked-at").flatMap(date),
                                     publishedExpiresAt: response.value(forHTTPHeaderField: "x-published-expires-at").flatMap(date),
                                     retryAfter: retry)
    }

    static func date(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: text)
    }
}

struct ResetNewsEndpointResult: Equatable {
    let source: ResetNewsSource
    let items: [ResetNewsSourceItem]
    var metadata: ResetNewsHTTPMetadata
    let error: ResetNewsFetchError?

    var succeeded: Bool { error == nil }
}

struct ResetNewsFetchResult: Equatable {
    let endpoints: [ResetNewsEndpointResult]
    var successful: [ResetNewsEndpointResult] { endpoints.filter(\.succeeded) }
    var failures: [ResetNewsEndpointResult] { endpoints.filter { !$0.succeeded } }
    var retryAfter: Date? { endpoints.compactMap(\.metadata.retryAfter).max() }
}

protocol ResetNewsFetching: AnyObject {
    @discardableResult
    func fetch(completion: @escaping (ResetNewsFetchResult) -> Void) -> ResetNewsCancellable
}

final class ResetNewsFeedClient: ResetNewsFetching {
    private let transport: ResetNewsHTTPTransport
    private let now: () -> Date
    private let bundleVersion: String

    init(transport: ResetNewsHTTPTransport = ResetNewsURLSessionTransport(),
         bundleVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
         now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.bundleVersion = bundleVersion
        self.now = now
    }

    func fetch(completion: @escaping (ResetNewsFetchResult) -> Void) -> ResetNewsCancellable {
        precondition(Thread.isMainThread)
        var tasks: [ResetNewsCancellable] = []
        var results: [ResetNewsEndpointResult] = []
        var cancelled = false
        for source in [ResetNewsSource.feed, .timeline] {
            // These fixed URLs contain no credentials or user-specific data.
            let url = URL(string: "https://codex-reset.com/api/\(source.rawValue)?locale=zh")!
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("GPT-TouchBar-HUD/\(bundleVersion) (+https://github.com/zz-zed/GPT-TouchBar-hud)", forHTTPHeaderField: "User-Agent")
            tasks.append(transport.send(request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    guard !cancelled, let self else { return }
                    results.append(self.decode(data: data, response: response, error: error, source: source))
                    if results.count == 2 {
                        completion(ResetNewsFetchResult(endpoints: results.sorted { $0.source.rawValue < $1.source.rawValue }))
                    }
                }
            })
        }
        return ResetNewsCancellation { cancelled = true; tasks.forEach { $0.cancel() } }
    }

    private func decode(data: Data?, response: URLResponse?, error: Error?, source: ResetNewsSource) -> ResetNewsEndpointResult {
        var metadata = (response as? HTTPURLResponse).map { ResetNewsHTTPMetadata.parse($0, now: now()) } ?? .init()
        func failure(_ error: ResetNewsFetchError) -> ResetNewsEndpointResult {
            .init(source: source, items: [], metadata: metadata, error: error)
        }
        if let error { return failure(.network(error.localizedDescription)) }
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https", http.url?.host == "codex-reset.com" else {
            return failure(.response)
        }
        guard (200..<300).contains(http.statusCode) else { return failure(.http(http.statusCode)) }
        guard let data else { return failure(.json("空响应")) }
        do {
            let batch = try ResetNewsSourceDecoder().decodeBatch(data, source: source)
            guard batch.identityValidated, batch.rejectedIdentityCount == 0 || !batch.items.isEmpty else {
                return failure(.identity("来源或 \(batch.rejectedIdentityCount) 条消息身份不匹配"))
            }
            metadata.stale = batch.stale
            metadata.rejectedIdentityCount = batch.rejectedIdentityCount
            return .init(source: source, items: batch.items, metadata: metadata, error: nil)
        } catch let error as ResetNewsDecodingError {
            return failure(.json(String(describing: error)))
        } catch {
            return failure(.json(error.localizedDescription))
        }
    }
}
