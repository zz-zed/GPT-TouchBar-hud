import Foundation

private final class FaultURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var url: URL?
        var headers: [String: String] = [:]
        var data = Data()
        var error: Error?
    }
    static let lock = NSLock()
    static var handler: ((URLRequest) -> Reply)?
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else { preconditionFailure("Missing failure fixture") }
        let reply = handler(request)
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: reply.url ?? request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.data.isEmpty { client?.urlProtocol(self, didLoad: reply.data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func configure(_ handler: @escaping (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        requests = []; self.handler = handler
    }
    static func recordedRequests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}

@main
enum GitHubReleaseFallbackTests {
    private static var checks = 0
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)
    private static let pageURL = URL(string: "https://github.com/\(AppRelease.repository)/releases/tag/v1.2.3")!

    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message); checks += 1
    }

    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--live-evidence" {
            try verifyLiveDiscovery(outputURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        try successfulAPI()
        try apiFailuresFallBack()
        try invalidAPIReleasesFallBack()
        rejectedPageRedirects()
        retryHeadersAndCooldown()
        assetTrust()
        print("PASS: \(checks) GitHub fallback fault-injection checks")
    }

    private static func fixtureData(tag: String = "v1.2.3", draft: Bool = false, prerelease: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": [],
            "name": "Fixture release", "body": "Release notes"
        ])
    }

    private static func withFetcher(_ operation: (GitHubReleaseFetcher) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FaultURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        operation(GitHubReleaseFetcher(session: session, version: "0.1.35", now: { date }))
    }

    private static func fetch(_ fetcher: GitHubReleaseFetcher, timeout: TimeInterval = 5) -> Result<AppRelease, AppUpdateFetchFailure> {
        var result: Result<AppRelease, AppUpdateFetchFailure>?
        fetcher.fetchLatest {
            check(Thread.isMainThread, "Completion is delivered on the main thread")
            result = $0
        }
        let deadline = Date().addingTimeInterval(timeout)
        while result == nil && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        guard let result else { preconditionFailure("Fixture request timed out") }
        return result
    }

    /// Explicit opt-in only: uses production discovery against public GitHub and
    /// records no cookies, credentials, IP addresses, or signed CDN URLs.
    private static func verifyLiveDiscovery(outputURL: URL) throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let result = fetch(GitHubReleaseFetcher(session: session, version: "0.1.35"), timeout: 65)
        var report: [String: Any] = ["checkedAt": ISO8601DateFormatter().string(from: Date())]
        switch result {
        case .success(let release):
            report["status"] = "success"
            report["tag"] = release.tag_name
            report["page"] = release.releasePageURL.absoluteString
            report["discovery"] = release.assets.allSatisfy { $0.size == 0 } ? "release-page-fallback" : "api"
            report["assets"] = release.assets.map { ["name": $0.name, "size": $0.size] as [String: Any] }
        case .failure(let failure):
            report["status"] = "failure"
            report["message"] = failure.message
            if let date = failure.retryAfter { report["retryAfter"] = ISO8601DateFormatter().string(from: date) }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: outputURL)
        guard case .success(let release) = result else { throw NSError(domain: "LiveDiscovery", code: 1) }
        print("PASS: live production fetcher discovered \(release.tag_name); evidence saved")
    }

    private static func verifyFallback(_ reply: FaultURLProtocol.Reply, label: String) {
        FaultURLProtocol.configure { request in
            request.url?.host == "api.github.com" ? reply : .init(url: pageURL)
        }
        withFetcher { fetcher in
            guard case .success(let release) = fetch(fetcher) else { preconditionFailure("\(label): fallback must succeed") }
            check(release.tag_name == "v1.2.3", "\(label): trusted latest page recovers release")
            check(release.installer(architecture: "arm64")?.size == 0, "\(label): fallback requires subsequent size verification")
            check(release.checksums != nil, "\(label): fallback retains checksum requirement")
            let requests = FaultURLProtocol.recordedRequests()
            check(requests.count == 2 && requests[1].httpMethod == "HEAD", "\(label): uses HEAD on the latest Release page")
        }
    }

    private static func successfulAPI() throws {
        let data = try fixtureData()
        FaultURLProtocol.configure { _ in .init(data: data) }
        withFetcher { fetcher in
            guard case .success(let release) = fetch(fetcher) else { preconditionFailure("Valid API release rejected") }
            check(release.body == "Release notes", "Healthy API preserves release notes")
            let requests = FaultURLProtocol.recordedRequests()
            check(requests.count == 1, "Healthy API does not request page fallback")
            check(requests[0].value(forHTTPHeaderField: "User-Agent") == "GPTTouchBarHUD/0.1.35", "Versioned user agent is retained")
        }
    }

    private static func apiFailuresFallBack() throws {
        let failures: [(String, FaultURLProtocol.Reply)] = [
            ("403 rate limit", .init(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000600"])),
            ("403 non-rate-limit", .init(status: 403)),
            ("429", .init(status: 429, headers: ["Retry-After": "600"])),
            ("500", .init(status: 500)), ("502", .init(status: 502)), ("503", .init(status: 503)),
            ("timeout", .init(error: URLError(.timedOut))),
            ("DNS failure", .init(error: URLError(.cannotFindHost))),
            ("offline", .init(error: URLError(.notConnectedToInternet))),
            ("invalid JSON", .init(data: Data("not-json".utf8))),
            ("empty JSON", .init(data: Data("{}".utf8))),
            ("oversized JSON", .init(data: Data(repeating: 32, count: 2_000_000)))
        ]
        for (label, reply) in failures { verifyFallback(reply, label: label) }
    }

    private static func invalidAPIReleasesFallBack() throws {
        verifyFallback(.init(data: try fixtureData(tag: "invalid/version")), label: "Invalid version")
        verifyFallback(.init(data: try fixtureData(tag: "v1.2.3-beta")), label: "Unstable version")
        verifyFallback(.init(data: try fixtureData(draft: true)), label: "Draft")
        verifyFallback(.init(data: try fixtureData(prerelease: true)), label: "Prerelease")
        for value in [
            "https://evil.example/repos/\(AppRelease.repository)/releases/latest",
            "http://api.github.com/repos/\(AppRelease.repository)/releases/latest",
            "https://api.github.com:8443/repos/\(AppRelease.repository)/releases/latest",
            "https://api.github.com/repos/other/repo/releases/latest"
        ] {
            verifyFallback(.init(url: URL(string: value)!, data: try fixtureData()), label: "Untrusted API final URL")
        }
    }

    private static func rejectedPageRedirects() {
        let urls = [
            "https://evil.example/\(AppRelease.repository)/releases/tag/v1.2.3",
            "http://github.com/\(AppRelease.repository)/releases/tag/v1.2.3",
            "https://user@github.com/\(AppRelease.repository)/releases/tag/v1.2.3",
            "https://github.com:8443/\(AppRelease.repository)/releases/tag/v1.2.3",
            "https://github.com/other/repo/releases/tag/v1.2.3",
            "https://github.com/\(AppRelease.repository)/releases/tag/v1.2.3/extra",
            "https://github.com/\(AppRelease.repository)/releases/tag/v1.2.3?unexpected=1",
            "https://github.com/\(AppRelease.repository)/releases/tag/v1.2.3#unexpected",
            "https://github.com/\(AppRelease.repository)/releases/tag/v1.2.3-beta",
            "https://github.com/\(AppRelease.repository)/releases/latest"
        ]
        for value in urls {
            FaultURLProtocol.configure { request in
                request.url?.host == "api.github.com" ? .init(status: 500) : .init(url: URL(string: value)!)
            }
            withFetcher { fetcher in
                guard case .failure = fetch(fetcher) else { preconditionFailure("Untrusted page accepted: \(value)") }
                check(true, "Untrusted page final URL rejected")
            }
        }
    }

    private static func retryHeadersAndCooldown() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let later = date.addingTimeInterval(1800)
        let scenarios: [(FaultURLProtocol.Reply, FaultURLProtocol.Reply, Date?)] = [
            (.init(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000600"]),
             .init(status: 503, headers: ["Retry-After": "1200"]), date.addingTimeInterval(1200)),
            (.init(status: 429, headers: ["Retry-After": "60", "X-RateLimit-Reset": "1800000900"]),
             .init(status: 500), date.addingTimeInterval(900)),
            (.init(status: 503, headers: ["Retry-After": formatter.string(from: later)]),
             .init(error: URLError(.cannotFindHost)), later),
            (.init(error: URLError(.timedOut)), .init(status: 429, headers: ["Retry-After": "600"]), date.addingTimeInterval(600)),
            (.init(status: 500), .init(error: URLError(.cannotFindHost)), nil),
            (.init(status: 403, headers: ["X-RateLimit-Remaining": "7", "X-RateLimit-Reset": "1800000600"]),
             .init(status: 500), nil),
            (.init(status: 429, headers: ["Retry-After": "inf", "X-RateLimit-Reset": "nan"]), .init(status: 500), nil)
        ]
        for (api, page, expected) in scenarios {
            FaultURLProtocol.configure { request in request.url?.host == "api.github.com" ? api : page }
            withFetcher { fetcher in
                guard case .failure(let failure) = fetch(fetcher) else { preconditionFailure("Both failed sources accepted") }
                check(failure.retryAfter == expected, "Preserve the later valid server retry boundary")
                let state = AppUpdateSchedulePolicy.standard.recordingAutomaticFailure(in: .empty, at: date, serverRetryAfter: failure.retryAfter)
                check(state.retryNotBefore == max(date.addingTimeInterval(300), expected ?? date), "Scheduler preserves server boundary with local fallback")
            }
        }
        FaultURLProtocol.configure { request in
            request.url?.host == "api.github.com"
                ? .init(status: 429, headers: ["Retry-After": "600"])
                : .init(url: pageURL)
        }
        withFetcher { fetcher in
            _ = fetch(fetcher); _ = fetch(fetcher)
            check(FaultURLProtocol.recordedRequests().map { $0.url!.host! } == ["api.github.com", "github.com", "github.com"],
                  "Known API cooldown continues through the page without repeating API")
        }
    }

    private static func assetTrust() {
        let name = "GPT-TouchBar-HUD-1.2.3-arm64.dmg"
        for base in ["http://github.com", "https://evil.example", "https://github.com:8443", "https://user@github.com"] {
            let url = URL(string: "\(base)/\(AppRelease.repository)/releases/download/v1.2.3/\(name)")!
            let release = AppRelease(tag_name: "v1.2.3", draft: false, prerelease: false,
                                     assets: [.init(name: name, browser_download_url: url, size: 100)])
            check(release.installer(architecture: "arm64") == nil, "Untrusted asset origin is rejected")
        }
    }
}
