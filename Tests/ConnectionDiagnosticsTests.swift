import AppKit

private final class FakeDiagnosticClient: ConnectionDiagnosticsClient {
    var startup: Result<Void, Error> = .success(())
    var accounts: [Result<String?, Error>] = [.success("private-account"), .success("private-account")]
    var quotas: Result<GetAccountRateLimitsResponse, Error> = .success(GetAccountRateLimitsResponse(
        rateLimits: RateLimitSnapshot(limitId: nil, limitName: nil,
            primary: RateLimitWindow(usedPercent: 73.456, windowDurationMins: 300, resetsAt: 1900000000),
            secondary: nil, credits: nil), rateLimitsByLimitId: nil, rateLimitResetCredits: nil))
    var tokens: Result<AccountTokenUsageResponse, Error> = .success(AccountTokenUsageResponse(
        summary: .init(lifetimeTokens: 987654321), dailyUsageBuckets: nil))
    var hold: ConnectionDiagnosticStep?
    var pending: (() -> Void)?
    var starts = 0
    var stops = 0
    var accountReads = 0
    var quotaReads = 0
    var tokenReads = 0

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        starts += 1
        let result = startup
        deliver(.connection) { completion(result) }
    }
    func stop() { stops += 1 }
    func readAccountIdentity(completion: @escaping (Result<String?, Error>) -> Void) {
        let step: ConnectionDiagnosticStep = accountReads == 0 ? .account : .accountConsistency
        let result = accounts[min(accountReads, accounts.count - 1)]
        accountReads += 1
        deliver(step) { completion(result) }
    }
    func readRateLimits(completion: @escaping (Result<GetAccountRateLimitsResponse, Error>) -> Void) {
        quotaReads += 1
        let result = quotas
        deliver(.rateLimits) { completion(result) }
    }
    func readTokenUsage(completion: @escaping (Result<AccountTokenUsageResponse, Error>) -> Void) {
        tokenReads += 1
        let result = tokens
        deliver(.tokenUsage) { completion(result) }
    }
    private func deliver(_ step: ConnectionDiagnosticStep, _ completion: @escaping () -> Void) {
        if hold == step { pending = completion } else { completion() }
    }
}

private final class PrivateError: LocalizedError {
    var descriptionReads = 0
    var errorDescription: String? {
        descriptionReads += 1
        return "secret@example.com /Users/private-person sk-private-token"
    }
}

@main
enum ConnectionDiagnosticsTests {
    private static var checks = 0
    private static let fixedTime = Date(timeIntervalSince1970: 1800000000)
    private static let runtime = URL(fileURLWithPath: "/private/test-user/ChatGPT.app/Contents/Resources/codex")

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
        checks += 1
    }

    private static func environment(_ runtime: URL?) -> ConnectionDiagnosticsEnvironment {
        ConnectionDiagnosticsEnvironment(appVersion: "0.1.35", operatingSystem:
            OperatingSystemVersion(majorVersion: 11, minorVersion: 7, patchVersion: 10),
            architecture: .arm64, host: runtime == nil ? .unknown : .chatGPT, hostVersion: "1.2026.100")
    }

    private static func runner(_ client: FakeDiagnosticClient) -> ConnectionDiagnosticsRunner {
        ConnectionDiagnosticsRunner(locateRuntime: { runtime }, makeClient: { _ in client },
                                    environment: environment, now: { fixedTime })
    }

    static func main() throws {
        let success = FakeDiagnosticClient()
        let successRunner = runner(success)
        check(success.starts == 0 && successRunner.report == nil, "Initialization performs no diagnostics")
        var published: [String] = []
        successRunner.onUpdate = { published.append($0.text) }
        successRunner.startCheck()
        let report = successRunner.report!
        check(!report.isRunning && report.finishedAt == fixedTime, "Complete report has check time")
        check(report.findings[.runtime] == .passed && report.findings[.account] == .signedIn,
              "Discovery and account status are visible")
        check(report.findings[.rateLimits] == .passed && report.findings[.tokenUsage] == .passed,
              "Available account endpoints pass independently")
        check(success.accountReads == 2 && report.findings[.accountConsistency] == .passed,
              "Identity is verified before and after endpoint requests")
        check(success.starts == 1 && success.stops == 1, "Independent client stops after success")
        for value in ["private-account", "private/test-user", "73.456", "987654321", "1900000000"] {
            check(!published.contains(where: { $0.contains(value) }), "No private field in any intermediate report")
        }
        check(report.text.contains("macOS 11.7.10") && report.text.contains("ChatGPT 1.2026.100"),
              "Report includes safe environment metadata")

        var madeClients = 0
        let missing = ConnectionDiagnosticsRunner(locateRuntime: { nil }, makeClient: { _ in
            madeClients += 1
            return FakeDiagnosticClient()
        }, environment: environment, now: { fixedTime })
        missing.startCheck()
        check(madeClients == 0 && missing.report?.findings[.runtime] == .runtimeMissing,
              "Missing runtime has actionable result without creating a client")
        check(missing.report?.findings[.connection] == .prerequisiteFailed && missing.report?.isRunning == false,
              "Missing runtime completes skipped steps")

        let unavailable = FakeDiagnosticClient()
        unavailable.startup = .failure(CodexAppServerError.processUnavailable)
        let unavailableRunner = runner(unavailable)
        unavailableRunner.startCheck()
        check(unavailable.stops == 1 && unavailable.accountReads == 0, "Startup failure closes connection")
        check(unavailableRunner.report?.findings[.runtime] == .passed &&
              unavailableRunner.report?.findings[.connection] == .unavailable, "Keep successful discovery on startup failure")

        let loggedOut = FakeDiagnosticClient()
        loggedOut.accounts = [.success(nil)]
        let loggedOutRunner = runner(loggedOut)
        loggedOutRunner.startCheck()
        check(loggedOutRunner.report?.findings[.account] == .signedOut && loggedOut.quotaReads == 0 &&
              loggedOut.tokenReads == 0 && loggedOut.stops == 1, "Logged-out user gets login guidance without account-data requests")

        let partial = FakeDiagnosticClient()
        partial.quotas = .failure(CodexAppServerError.serverError("secret@example.com /Users/private-person sk-private-token"))
        let partialRunner = runner(partial)
        var partialReports: [String] = []
        partialRunner.onUpdate = { partialReports.append($0.text) }
        partialRunner.startCheck()
        check(partialRunner.report?.findings[.rateLimits] == .serviceRejected &&
              partialRunner.report?.findings[.tokenUsage] == .passed, "Quota failure preserves successful token check")
        check(partial.tokenReads == 1 && partial.accountReads == 2 && partial.stops == 1,
              "Partial failure still rechecks identity and closes client")
        for value in ["secret@example.com", "/Users/", "sk-private-token"] {
            check(!partialReports.contains(where: { $0.contains(value) }), "Server error payload never appears in reports")
        }
        let privateError = PrivateError()
        let failedToken = FakeDiagnosticClient()
        failedToken.tokens = .failure(privateError)
        let failedTokenRunner = runner(failedToken)
        failedTokenRunner.startCheck()
        check(failedTokenRunner.report?.findings[.tokenUsage] == .unexpectedFailure &&
              failedTokenRunner.report?.findings[.rateLimits] == .passed, "Token failure preserves successful quota check")
        check(privateError.descriptionReads == 0, "Diagnostics never evaluate raw error descriptions")

        for accounts: [Result<String?, Error>] in [
            [.success("private-a"), .success("private-b")],
            [.success("private-a"), .success(nil)],
            [.success("private-a"), .failure(CodexAppServerError.requestTimedOut)]
        ] {
            let changed = FakeDiagnosticClient()
            changed.accounts = accounts
            let changedRunner = runner(changed)
            changedRunner.startCheck()
            check(changedRunner.report?.findings[.rateLimits] != .passed &&
                  changedRunner.report?.findings[.tokenUsage] != .passed,
                  "Changed or unverifiable identity invalidates account endpoint results")
            check(!changedRunner.report!.text.contains("private-"), "Account change report does not reveal identity")
        }

        for stage in [ConnectionDiagnosticStep.connection, .account, .rateLimits, .tokenUsage, .accountConsistency] {
            let deferred = FakeDiagnosticClient()
            deferred.hold = stage
            let deferredRunner = runner(deferred)
            var updates = 0
            deferredRunner.onUpdate = { _ in updates += 1 }
            deferredRunner.startCheck()
            check(deferredRunner.report?.isRunning == true && deferred.pending != nil, "Fake client pauses at \(stage)")
            deferredRunner.cancel()
            let afterCancel = deferredRunner.report!.text
            let updatesAtCancel = updates
            deferred.pending?()
            check(deferredRunner.report?.text == afterCancel && updates == updatesAtCancel,
                  "Closing/cancelling ignores pending callback at \(stage)")
            check(deferred.stops == 1 && deferredRunner.report?.isRunning == false,
                  "Cancellation closes connection once at \(stage)")
        }

        let previous = FakeDiagnosticClient()
        previous.hold = .tokenUsage
        let fresh = FakeDiagnosticClient()
        var factoryCalls = 0
        let restarting = ConnectionDiagnosticsRunner(locateRuntime: { runtime }, makeClient: { _ in
            factoryCalls += 1
            return factoryCalls == 1 ? previous : fresh
        }, environment: environment, now: { fixedTime })
        restarting.startCheck()
        restarting.startCheck()
        let freshReport = restarting.report!.text
        previous.pending?()
        check(restarting.report?.text == freshReport && previous.accountReads == 1,
              "Restart makes old callbacks inert before a new connection starts")
        check(previous.stops == 1 && fresh.stops == 1, "Both replaced and completed clients stop")

        let reentrant = FakeDiagnosticClient()
        let reentrantRunner = runner(reentrant)
        reentrantRunner.onUpdate = { report in
            if report.findings[.connection] == .checking { reentrantRunner.cancel() }
        }
        reentrantRunner.startCheck()
        check(reentrant.starts == 0 && reentrant.stops == 1, "Cancellation from presentation does not launch a late process")
        reentrantRunner.onUpdate = nil

        let empty = FakeDiagnosticClient()
        empty.quotas = .success(GetAccountRateLimitsResponse(rateLimits:
            RateLimitSnapshot(limitId: nil, limitName: nil, primary: nil, secondary: nil, credits: nil),
            rateLimitsByLimitId: nil, rateLimitResetCredits: nil))
        empty.tokens = .success(AccountTokenUsageResponse(summary: .init(lifetimeTokens: nil), dailyUsageBuckets: []))
        let emptyRunner = runner(empty)
        emptyRunner.startCheck()
        check(emptyRunner.report?.findings[.rateLimits] == .noData && emptyRunner.report?.findings[.tokenUsage] == .noData,
              "Valid empty responses are distinct from healthy data and connection failure")

        for maliciousVersion in ["1.0\n/Users/private-person", "secret@example.com", "1.2 sk-token", String(repeating: "1", count: 41)] {
            let sanitized = ConnectionDiagnosticsEnvironment(appVersion: maliciousVersion,
                operatingSystem: OperatingSystemVersion(majorVersion: 11, minorVersion: 0, patchVersion: 0),
                architecture: .arm64, host: .chatGPT, hostVersion: maliciousVersion)
            check(sanitized.appVersion == "未知" && sanitized.hostVersion == "未知", "Version metadata uses a restricted format")
        }
        check(ConnectionDiagnosticFinding.classify(CodexAppServerError.requestTimedOut) == .timedOut,
              "Timeout has a stable actionable category")
        check(ConnectionDiagnosticFinding.classify(CodexAppServerError.responseTooLarge) == .invalidResponse,
              "Oversized response is categorized without exposing contents")

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let windowClient = FakeDiagnosticClient()
        windowClient.hold = .tokenUsage
        let windowRunner = runner(windowClient)
        let controller = ConnectionDiagnosticsWindowController(runner: windowRunner)
        controller.startCheck()
        let content = controller.window!.contentView!
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let review = descendants(content).compactMap { $0 as? NSTextView }.first!
        let copyButton = descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "复制诊断信息" }!
        check(review.string == windowRunner.report?.text && !copyButton.isEnabled,
              "Window previews the complete report and disables copying while checking")
        windowClient.pending?()
        content.layoutSubtreeIfNeeded()
        check(review.string == windowRunner.report?.text && copyButton.isEnabled,
              "Completed preview is the exact copyable report")
        check(review.frame.width > 500 && review.frame.height > 200, "Report receives a readable scrollable area")
        let scroll = descendants(content).compactMap { $0 as? NSScrollView }.first!
        check(scroll.hasVerticalScroller && !review.isEditable && review.isSelectable,
              "Full report remains readable and selectable without edits")
        try snapshot(content, name: "connection-diagnostics")
        controller.window?.setContentSize(NSSize(width: 600, height: 440))
        content.layoutSubtreeIfNeeded()
        check(scroll.frame.width > 500 && scroll.frame.height >= 230, "Report fits the minimum window size")

        let closeClient = FakeDiagnosticClient()
        closeClient.hold = .connection
        let closeRunner = runner(closeClient)
        let closeController = ConnectionDiagnosticsWindowController(runner: closeRunner)
        closeController.startCheck()
        closeController.window?.close()
        let closed = closeRunner.report!.text
        closeClient.pending?()
        check(closeClient.stops == 1 && closeRunner.report?.text == closed && closeRunner.report?.isRunning == false,
              "Closing the window cancels its client and ignores completion")
        print("PASS: \(checks) connection diagnostics checks")
    }

    private static func snapshot(_ view: NSView, name: String) throws {
        view.wantsLayer = true
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: ".build/connection-diagnostics-tests", isDirectory: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
