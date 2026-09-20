import Foundation

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
        testSkipping(release: release)
        testRuntimeIsolation()
        try testInstaller()
        print("PASS: \(count) update policy checks")
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

    static func testInstaller() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("update-test-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let original = try String(contentsOfFile: "Resources/install-update.sh", encoding: .utf8)
        let guardLine = "[[ \"$target_app\" == /Applications/'GPT TouchBar HUD.app' || \"$target_app\" == \"$HOME/Applications/GPT TouchBar HUD.app\" ]] || exit 2"
        check(original.contains(guardLine), "Installer target guard is present")
        // Only the temporary test copy permits an isolated target and mocks LaunchServices.
        for scenario in ["success", "move-failure", "launch-failure"] {
            let directory = root.appendingPathComponent(scenario)
            let target = directory.appendingPathComponent("GPT TouchBar HUD.app")
            let staging = directory.appendingPathComponent(".GPTTouchBarHUD-update-fixture")
            let newApp = staging.appendingPathComponent("new.app")
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            try manager.createDirectory(at: newApp, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: target.appendingPathComponent("marker"))
            try Data("new".utf8).write(to: newApp.appendingPathComponent("marker"))
            var script = original.replacingOccurrences(of: guardLine, with: "[[ \"$target_app\" == \"$UPDATE_TEST_TARGET\" ]] || exit 2")
                .replacingOccurrences(of: "/usr/bin/open", with: scenario == "launch-failure" ? "/usr/bin/false" : "/usr/bin/true")
            if scenario == "move-failure" {
                script = script.replacingOccurrences(of: "if ! /bin/mv \"$staging_dir/new.app\" \"$target_app\"; then", with: "if ! /usr/bin/false; then")
            }
            let helper = directory.appendingPathComponent("helper.sh")
            try script.write(to: helper, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [helper.path, "999999", target.path, staging.path]
            var environment = ProcessInfo.processInfo.environment
            environment["UPDATE_TEST_TARGET"] = target.path
            process.environment = environment
            try process.run(); process.waitUntilExit()
            let installed = try String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8)
            check(installed == (scenario == "success" ? "new" : "old"), "\(scenario): correct application retained")
            check((process.terminationStatus == 0) == (scenario == "success"), "\(scenario): correct exit status")
            if scenario == "success" {
                let previous = try String(contentsOf: staging.appendingPathComponent("previous.app/marker"), encoding: .utf8)
                check(previous == "old", "Old app retained for recovery")
            }
        }
    }
}
