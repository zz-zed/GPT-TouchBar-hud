import AppKit

private final class LifecycleQuotaClient: RateLimitClient {
    var onRateLimitsUpdated: (() -> Void)?
    var onAccountUpdated: (() -> Void)?
    var onConnectionClosed: ((Error) -> Void)?
    var starts = 0
    var stops = 0
    func start(completion: @escaping (Result<Void, Error>) -> Void) { starts += 1; completion(.success(())) }
    func stop() { stops += 1 }
    func readAccountIdentity(completion: @escaping (Result<String?, Error>) -> Void) { completion(.success(nil)) }
    func readRateLimits(completion: @escaping (Result<GetAccountRateLimitsResponse, Error>) -> Void) {
        completion(.success(GetAccountRateLimitsResponse(rateLimits: RateLimitSnapshot(limitId: "codex", limitName: nil,
            primary: nil, secondary: nil, credits: nil), rateLimitsByLimitId: nil, rateLimitResetCredits: nil)))
    }
    func readTokenUsage(completion: @escaping (Result<AccountTokenUsageResponse, Error>) -> Void) {
        completion(.failure(CodexAppServerError.missingResult))
    }
}
private final class LifecycleTouchPresenter: SystemTouchBarPresenting {
    var isAvailable = true
    func present(_ touchBar: NSTouchBar) {}
    func dismiss(_ touchBar: NSTouchBar) {}
}

/// Uses production coordinator and display dispatch with injected local clients and platform exit actions.
enum AppLifecycleCoordinatorChecks {
    static func run(_ check: (Bool, String) -> Void) {
        let suite = "LifecycleCoordinator." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: ResetNewsMonitor.enabledPreferenceKey)
        defaults.set(false, forKey: QuotaAlertMonitor.enabledPreferenceKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let news = ResetNewsMonitor(repository: ResetNewsRepository(directory: directory), defaults: defaults)
        let updater = AppUpdater(session: URLSession(configuration: .ephemeral), preferences: AppUpdatePreferences(defaults: defaults),
            policy: .standard, now: Date.init, automaticChecksAvailable: false,
            notifications: AppUpdateNotificationController(defaults: defaults))
        var host = HostLifecycleSnapshot(hostIsRunning: true, codexIsRunning: true)
        var poll: (() -> Void)?
        let hostMonitor = HostLifecycleMonitor(notificationCenter: NotificationCenter(), runningStateProvider: { host },
            pollTimerFactory: { action in poll = action; return Timer(timeInterval: 3600, repeats: true) { _ in } })
        let client = LifecycleQuotaClient()
        let persistent = PersistentTouchBarController(presenter: LifecycleTouchPresenter(), defaults: defaults, notifications: NotificationCenter())
        let menu = StatusMenuController(touchBarHardware: .absent, appUpdater: updater)
        defer { NSStatusBar.system.removeStatusItem(menu.statusItem) }
        let display = AppDisplayCoordinator(menu: menu, persistentTouchBar: persistent)
        var canQuit = false, progressRequests = 0, terminations = 0, manualLocks = 0, displayStops = 0, submissions = 0
        display.onSnapshot = { _ in submissions += 1 }
        let lifecycle = AppLifecycleCoordinator(store: RateLimitStore(client: client), appUpdater: updater,
            taskMonitor: TaskMonitoringCoordinator(), hostMonitor: hostMonitor, resetNewsMonitor: news,
            quotaAlerts: QuotaAlertMonitor(defaults: defaults), persistentTouchBar: persistent,
            quitControl: .init(canQuit: { canQuit }, presentProgress: { progressRequests += 1 },
                terminate: { terminations += 1 }, markManualQuit: { manualLocks += 1 }))
        lifecycle.taskStatusEnabled = { false }
        lifecycle.onStopPresentation = { displayStops += 1; display.stop() }
        lifecycle.start(); lifecycle.start()
        check(client.starts == 1 && lifecycle.acceptsCallbacks, "Lifecycle starts host services once")
        lifecycle.quit()
        check(lifecycle.state.runtimeRunning && displayStops == 0 && terminations == 0 && manualLocks == 0,
            "Denied manual quit leaves runtime and display active without a manual-quit lock")
        check(lifecycle.applicationShouldTerminate(NSApp) == .terminateCancel && progressRequests == 2,
            "Denied AppKit termination presents update progress and cancels before stopping")
        host = HostLifecycleSnapshot(hostIsRunning: false, codexIsRunning: false)
        poll?()
        check(lifecycle.state.runtimeRunning && displayStops == 0 && client.stops == 0 && terminations == 0,
            "Denied host-exit quit retains the runtime and display during installation")
        check(!lifecycle.state.hostRunning && !lifecycle.state.codexRunning
            && !lifecycle.state.quotaAlertsAllowed && !lifecycle.state.resetNewsWorkEnabled,
            "Host and Codex facts still update and close their independent gates when exit is denied")
        display.renderDisplayState()
        check(submissions == 1 && progressRequests == 3, "Display remains usable while installation defers host exit")
        canQuit = true
        lifecycle.quit(reason: .update)
        check(!lifecycle.acceptsCallbacks && lifecycle.state.runtime == .stopped && displayStops == 1
            && client.stops == 1 && terminations == 1 && manualLocks == 1,
            "A later permitted update exit stops the runtime and display exactly once")
        lifecycle.stop(); lifecycle.didWake(); lifecycle.screenLocked(true); lifecycle.sessionInactive(true)
        host = HostLifecycleSnapshot(hostIsRunning: true, codexIsRunning: true)
        poll?(); display.renderDisplayState()
        check(client.starts == 1 && displayStops == 1 && submissions == 1 && !lifecycle.acceptsCallbacks,
            "Late host, wake, session and display callbacks cannot restart a stopped runtime")
    }
}
