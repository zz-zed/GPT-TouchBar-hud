import Foundation

final class MockReleaseURLProtocol: URLProtocol {
    static var response: ((URLRequest) -> (status: Int, url: URL, headers: [String: String]))?
    static var requestedHosts: [String] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixture = Self.response?(request) else { preconditionFailure("Missing release fixture") }
        Self.lock.lock()
        Self.requestedHosts.append(request.url!.host!)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: fixture.url, statusCode: fixture.status,
                                       httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class FakeReleaseFetcher: AppReleaseFetching {
    private(set) var requestCount = 0
    private var completion: ((Result<AppRelease, AppUpdateFetchFailure>) -> Void)?

    func fetchLatest(completion: @escaping (Result<AppRelease, AppUpdateFetchFailure>) -> Void) {
        requestCount += 1
        self.completion = completion
    }

    func complete(_ result: Result<AppRelease, AppUpdateFetchFailure>) {
        let pending = completion
        completion = nil
        pending?(result)
    }
}

@main enum AppUpdateTests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message); count += 1
    }
    static func main() throws {
        check(AppVersion("0.1.9")! < AppVersion("0.1.10")!, "Numeric version comparison")
        check(AppVersion("v1.2.0") == AppVersion("1.2"), "Normalize tag and trailing zeros")
        check(AppVersion("0.1.21")! > AppVersion("v0.1.20")!, "Do not downgrade development versions")
        for value in ["", "1", "1..2", "1.2-beta", "1.2/evil", "1.２", "1.-2", "1.9999999999999999999999999"] {
            check(AppVersion(value) == nil, "Reject invalid version \(value)")
        }
        let name = "GPT-TouchBar-HUD-1.2.3-arm64.dmg"
        let root = "https://github.com/\(AppRelease.repository)/releases/download/v1.2.3/"
        let asset = AppRelease.Asset(name: name, browser_download_url: URL(string: root + name)!, size: 123)
        let sums = AppRelease.Asset(name: "SHA256SUMS.txt", browser_download_url: URL(string: root + "SHA256SUMS.txt")!, size: 100)
        let release = AppRelease(tag_name: "v1.2.3", draft: false, prerelease: false, assets: [asset, sums])
        check(release.installer(architecture: "arm64")?.name == name, "Matching architecture")
        check(release.installer(architecture: "x86_64") == nil, "Wrong architecture not selected")
        check(release.checksums != nil, "Checksum asset matched")
        let fallback = AppRelease.fromLatestPageURL(URL(string: "https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v1.2.3")!)
        check(fallback?.installer(architecture: "arm64")?.name == name, "Latest page redirect constructs trusted release assets")
        check(fallback?.installer(architecture: "arm64")?.size == 0, "Fallback defers size verification to asset HEAD")
        for url in [
            "http://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v1.2.3",
            "https://evil.example/zz-zed/GPT-TouchBar-hud/releases/tag/v1.2.3",
            "https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v1.2.3/extra",
            "https://github.com/other/repo/releases/tag/v1.2.3",
            "https://user@github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v1.2.3"
        ] {
            check(AppRelease.fromLatestPageURL(URL(string: url)!) == nil, "Reject untrusted latest-page redirect")
        }
        for url in ["https://example.com/" + name, "http://github.com/" + name, root.replacingOccurrences(of: "v1.2.3", with: "v1.2.4") + name] {
            let bad = AppRelease(tag_name: "v1.2.3", draft: false, prerelease: false, assets: [.init(name: name, browser_download_url: URL(string: url)!, size: 123)])
            check(bad.installer(architecture: "arm64") == nil, "Reject untrusted asset location")
        }
        let hash = String(repeating: "ab", count: 32)
        check(AppRelease.checksum(in: hash + "  " + name + "\n", filename: name) == hash, "Parse shasum format")
        check(AppRelease.checksum(in: hash + " *" + name, filename: name) == hash, "Parse binary checksum format")
        check(AppRelease.checksum(in: "123  " + name, filename: name) == nil, "Reject short checksum")
        check(AppRelease.checksum(in: hash + "  other.dmg", filename: name) == nil, "Reject unrelated checksum")
        check(AppRelease.checksum(in: "\(hash)  \(name)\n\(hash)  \(name)", filename: name) == nil, "Reject duplicate checksum entries")
        testPersistentState()
        testSchedulePolicy()
        testRequestDeduplication(release: release)
        testGitHubRateLimitFallback()
        testSkipping(release: release)
        testRuntimeIsolation()
        testReleaseNotesPresentation()
        print("PASS: \(count) update policy checks")
    }

    static func testReleaseNotesPresentation() {
        let markdown = "## 优化\n\n- 修复**重置预告**的关闭问题。\n- 保留 `Touch Bar` 设置。\n\n## 注意事项\n\n- 请先阅读[安装说明](https://example.com/install)。"
        let text = AppUpdateReleaseNotes.plainText(markdown)
        check(text == "优化\n\n• 修复重置预告的关闭问题。\n• 保留 Touch Bar 设置。\n\n注意事项\n\n• 请先阅读安装说明（https://example.com/install）。", "Release headings, bullets, emphasis and links become readable text")
        check(AppUpdateReleaseNotes.plainText("  \n\t") == "", "Empty release notes preserve fallback behavior")
        check(AppUpdateReleaseNotes.plainText("普通 C#、snake_case 与 2 * 3 不应改变。") == "普通 C#、snake_case 与 2 * 3 不应改变。", "Plain text punctuation and identifiers survive formatting")
        check(AppUpdateReleaseNotes.plainText("1. 安装\n2. 重启") == "1. 安装\n2. 重启", "Ordered instructions retain numbering")
        check(AppUpdateReleaseNotes.plainText("优化\n----\n\n注意事项\n====") == "优化\n\n注意事项", "Setext headings do not leak decoration")
        check(AppUpdateReleaseNotes.plainText("### Changes\n\n* _Important_ and *useful*\n+ **Fixed**") == "Changes\n\n• Important and useful\n• Fixed", "Alternate bullets and emphasis remain readable")
        check(AppUpdateReleaseNotes.plainText("```sh\n# a comment\necho **literal**\n```") == "# a comment\necho **literal**", "Code fence contents are preserved literally")
        check(AppUpdateReleaseNotes.plainText("## 优化\r\n\r\n- 修复") == "优化\n\n• 修复", "CRLF release notes normalize line breaks")
        check(AppUpdateReleaseNotes.plainText("`**literal**` 与 `snake_case`") == "**literal** 与 snake_case", "Inline code remains literal rather than losing meaningful characters")
        check(AppUpdateReleaseNotes.plainText("[指南](https://example.com/a_(b)?key=snake_case)") == "指南（https://example.com/a_(b)?key=snake_case）", "Link addresses retain parentheses and underscores")
        check(AppUpdateReleaseNotes.plainText("https://example.com/snake_case_path") == "https://example.com/snake_case_path", "Bare URLs remain unchanged")
        let unicode = String(repeating: "改进👨‍👩‍👧‍👦", count: 400)
        check(AppUpdateReleaseNotes.plainText(unicode) == unicode, "Formatter preserves long Unicode text before presentation truncation")
    }

    static func testPersistentState() {
        let suite = "GPTTouchBarHUD.update-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppUpdatePreferences(defaults: defaults)
        check(preferences.automaticChecksEnabled, "Automatic checks default on")
        preferences.automaticChecksEnabled = false
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        preferences.state = AppUpdatePersistentState(
            lastAttempt: base,
            lastSuccess: base.addingTimeInterval(-10),
            availableVersion: "v1.2.3",
            skippedVersion: "v1.2.2",
            consecutiveAutomaticFailures: 2,
            retryNotBefore: base.addingTimeInterval(300)
        )
        let relaunched = AppUpdatePreferences(defaults: defaults)
        check(!relaunched.automaticChecksEnabled, "Automatic check choice survives restart")
        check(relaunched.state.lastAttempt == base, "Last attempt survives restart")
        check(relaunched.state.lastSuccess == base.addingTimeInterval(-10), "Last success survives restart")
        check(relaunched.state.availableVersion == "v1.2.3", "Available version survives restart")
        check(relaunched.state.skippedVersion == "v1.2.2", "Skipped version survives restart")
        check(relaunched.state.consecutiveAutomaticFailures == 2, "Retry count survives restart")
        check(relaunched.state.retryNotBefore == base.addingTimeInterval(300), "Retry deadline survives restart")
    }

    static func testSchedulePolicy() {
        let policy = AppUpdateSchedulePolicy.standard
        let launched = Date(timeIntervalSince1970: 1_800_000_000)
        let planner = AppUpdateSchedulePlanner(launchedAt: launched, policy: policy)
        check(planner.nextDate(state: .empty, now: launched) == launched.addingTimeInterval(30),
              "Fresh launch waits 30 seconds")
        check(!planner.shouldCheckAfterWake(state: .empty, now: launched.addingTimeInterval(10)),
              "Wake does not bypass the startup delay")
        check(planner.shouldCheckAfterWake(state: .empty, now: launched.addingTimeInterval(30)),
              "Wake performs one due check after the startup delay")

        var state = AppUpdatePersistentState.empty
        state = policy.recordingSuccess(in: state, at: launched)
        let restarted = launched.addingTimeInterval(60)
        let relaunchedPlanner = AppUpdateSchedulePlanner(launchedAt: restarted, policy: policy)
        check(relaunchedPlanner.nextDate(state: state, now: restarted) == launched.addingTimeInterval(24 * 60 * 60),
              "Restart preserves the 24-hour success interval")
        check(!policy.isDue(state: state, now: launched.addingTimeInterval(23 * 60 * 60)), "Wake before due does not check")
        check(policy.isDue(state: state, now: launched.addingTimeInterval(24 * 60 * 60)), "Wake at due time checks once")

        var failed = AppUpdatePersistentState.empty
        failed = policy.recordingAutomaticFailure(in: failed, at: launched, serverRetryAfter: nil)
        check(failed.retryNotBefore == launched.addingTimeInterval(5 * 60), "First failure uses five-minute backoff")
        failed = policy.recordingAutomaticFailure(in: failed, at: launched.addingTimeInterval(5 * 60), serverRetryAfter: nil)
        check(failed.retryNotBefore == launched.addingTimeInterval(35 * 60), "Second failure uses thirty-minute backoff")
        failed = policy.recordingAutomaticFailure(in: failed, at: launched.addingTimeInterval(35 * 60), serverRetryAfter: nil)
        check(failed.retryNotBefore == launched.addingTimeInterval(155 * 60), "Third failure uses two-hour backoff")
        failed = policy.recordingAutomaticFailure(in: failed, at: launched.addingTimeInterval(155 * 60), serverRetryAfter: nil)
        check(failed.retryNotBefore == launched.addingTimeInterval(155 * 60 + 24 * 60 * 60), "Retries become daily after the finite backoff sequence")
        let serverLimit = launched.addingTimeInterval(3 * 24 * 60 * 60)
        failed = policy.recordingAutomaticFailure(in: .empty, at: launched, serverRetryAfter: serverLimit)
        check(failed.retryNotBefore == serverLimit, "Server rate limit overrides shorter local backoff")
    }

    static func testRequestDeduplication(release: AppRelease) {
        let fetcher = FakeReleaseFetcher()
        let engine = AppUpdateCheckEngine(fetcher: fetcher, currentVersion: "1.0.0")
        var completedOrigins: Set<AppUpdateCheckOrigin> = []
        var foundUpdate = false
        engine.onCompletion = { outcome, origins in
            completedOrigins = origins
            if case .update = outcome { foundUpdate = true }
        }
        check(engine.request(.automatic) == .started, "Background request starts network fetch")
        check(engine.request(.manual) == .joined, "Manual request joins background fetch")
        check(fetcher.requestCount == 1, "Concurrent checks share one network request")
        fetcher.complete(.success(release))
        check(foundUpdate, "Fake network result is classified as update")
        check(completedOrigins == [.automatic, .manual], "Completion retains background and manual origins")
        check(AppUpdatePresentationPolicy.shouldPresentResult(for: completedOrigins), "Joined manual request receives explicit presentation")
        check(!AppUpdatePresentationPolicy.shouldPresentResult(for: [.automatic]), "Background-only result remains silent")

        check(engine.request(.automatic) == .started, "Engine accepts later request after completion")
        fetcher.complete(.failure(AppUpdateFetchFailure("offline")))
        check(fetcher.requestCount == 2, "Failure releases the in-flight request lock")
    }

    static func testGitHubRateLimitFallback() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockReleaseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fetcher = GitHubReleaseFetcher(session: session, version: "0.1.34")
        let reset = Date().addingTimeInterval(1800)
        let page = URL(string: "https://github.com/\(AppRelease.repository)/releases/tag/v0.1.34")!
        MockReleaseURLProtocol.requestedHosts = []
        MockReleaseURLProtocol.response = { request in
            if request.url!.host == "api.github.com" {
                return (403, request.url!, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970))])
            }
            return (200, page, [:])
        }
        let first = awaitFetch(fetcher)
        if case let .success(release) = first {
            check(release.tag_name == "v0.1.34", "API rate limit falls back to the latest Release page")
        } else { check(false, "API rate limit must not end the check when the page works") }
        check(MockReleaseURLProtocol.requestedHosts == ["api.github.com", "github.com"], "Fallback fetches the Release page")

        let second = awaitFetch(fetcher)
        if case .success = second { check(true, "Page fallback remains available") }
        else { check(false, "Cached API limit must still use the page") }
        check(MockReleaseURLProtocol.requestedHosts == ["api.github.com", "github.com", "github.com"],
              "Known API limit avoids another API request")

        MockReleaseURLProtocol.requestedHosts = []
        MockReleaseURLProtocol.response = { request in
            if request.url!.host == "api.github.com" {
                return (403, request.url!, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970))])
            }
            return (503, request.url!, [:])
        }
        let failed = awaitFetch(GitHubReleaseFetcher(session: session, version: "0.1.34"))
        if case let .failure(error) = failed {
            check(error.retryAfter != nil && abs(error.retryAfter!.timeIntervalSince(reset)) < 1,
                  "If both sources fail, preserve the API reset time")
        } else { check(false, "Both failed sources must report an error") }
    }

    static func awaitFetch(_ fetcher: GitHubReleaseFetcher) -> Result<AppRelease, AppUpdateFetchFailure> {
        var result: Result<AppRelease, AppUpdateFetchFailure>?
        fetcher.fetchLatest { result = $0 }
        let deadline = Date().addingTimeInterval(5)
        while result == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard let result else { preconditionFailure("Release fetch timed out") }
        return result
    }

    static func testRuntimeIsolation() {
        let home = URL(fileURLWithPath: "/Users/tester")
        check(AppUpdateRuntime.allowsAutomaticChecks(
            bundleURL: URL(fileURLWithPath: "/Applications/GPT TouchBar HUD.app"),
            bundleIdentifier: "io.github.zz-zed.GPTTouchBarHUD",
            homeDirectory: home
        ), "Installed system application may check automatically")
        check(AppUpdateRuntime.allowsAutomaticChecks(
            bundleURL: home.appendingPathComponent("Applications/GPT TouchBar HUD.app"),
            bundleIdentifier: "io.github.zz-zed.GPTTouchBarHUD",
            homeDirectory: home
        ), "Installed user application may check automatically")
        check(!AppUpdateRuntime.allowsAutomaticChecks(
            bundleURL: home.appendingPathComponent("project/.build/GPTTouchBarHUD"),
            bundleIdentifier: "io.github.zz-zed.GPTTouchBarHUD",
            homeDirectory: home
        ), "SwiftPM and swiftc executables cannot check automatically")
        check(!AppUpdateRuntime.allowsAutomaticChecks(
            bundleURL: URL(fileURLWithPath: "/Applications/GPT TouchBar HUD.app"),
            bundleIdentifier: "io.github.zz-zed.GPTTouchBarHUD.Tests",
            homeDirectory: home
        ), "Test bundles cannot check automatically")
    }

    static func testSkipping(release: AppRelease) {
        var state = AppUpdatePersistentState.empty
        state.availableVersion = release.tag_name
        state = AppUpdateAvailabilityPolicy.skipping(release.tag_name, in: state)
        check(state.skippedVersion == release.tag_name && state.availableVersion == nil, "Skipping hides the offered version")
        check(AppUpdateAvailabilityPolicy.storedVersion(for: release, skippedVersion: state.skippedVersion) == nil,
              "Background checks keep the skipped version hidden")
        let newer = AppRelease(tag_name: "v1.2.4", draft: false, prerelease: false, assets: [])
        check(AppUpdateAvailabilityPolicy.storedVersion(for: newer, skippedVersion: state.skippedVersion) == "v1.2.4",
              "A newer release becomes available after skipping an older version")
        check(AppUpdatePresentationPolicy.shouldPresentResult(for: [.manual]),
              "Manual checks still present a skipped version result")
    }

}
