import AppKit

private final class IntegrationUpdateFetcher: AppReleaseFetching {
    private(set) var requests = 0
    private var pending: ((Result<AppRelease, AppUpdateFetchFailure>) -> Void)?

    func fetchLatest(completion: @escaping (Result<AppRelease, AppUpdateFetchFailure>) -> Void) {
        precondition(pending == nil, "Integration test must not overlap release requests")
        requests += 1
        pending = completion
    }

    func complete(_ result: Result<AppRelease, AppUpdateFetchFailure>) {
        let completion = pending
        pending = nil
        precondition(completion != nil, "Integration fixture requires an active request")
        completion?(result)
    }
}

private final class IntegrationUpdateChannel: AppUpdateNotificationChannel {
    var onOpen: ((String) -> Void)?
    private(set) var authorizationRequests = 0
    private(set) var permissionReads = 0
    private(set) var delivered: [AppUpdateNotificationPayload] = []
    private(set) var removed: [String] = []
    var permission: ResetNewsNotificationPermission = .allowed

    func requestAuthorization(completion: @escaping (ResetNewsNotificationPermission) -> Void) {
        authorizationRequests += 1
        completion(permission)
    }
    func readPermission(completion: @escaping (ResetNewsNotificationPermission) -> Void) {
        permissionReads += 1
        completion(permission)
    }
    func add(_ payload: AppUpdateNotificationPayload, completion: @escaping (Error?) -> Void) {
        delivered.append(payload)
        completion(nil)
    }
    func remove(identifiers: [String]) { removed.append(contentsOf: identifiers) }
    func removeAll(prefix: String, keeping identifier: String?) {}
}

private final class IntegrationUpdateNoNetworkProtocol: URLProtocol {
    private(set) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// Uses the real updater and notification coordinator with isolated preferences and no network,
/// notification center, authorization prompt, or manual-result modal.
enum AppUpdateIntegrationChecks {
    static func run() throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            NotchHUDTests.check(value(), message)
        }
        func release(_ tag: String) -> AppRelease {
            AppRelease(tag_name: tag, draft: false, prerelease: false, assets: [])
        }
        let suite = "GPTTouchBarHUD.AppUpdateIntegration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntegrationUpdateNoNetworkProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        let preferences = AppUpdatePreferences(defaults: defaults)
        let fetcher = IntegrationUpdateFetcher()
        let channel = IntegrationUpdateChannel()
        let notifications = AppUpdateNotificationController(defaults: defaults, channel: channel)
        let updater = AppUpdater(session: session, preferences: preferences, policy: .standard,
            now: { date }, automaticChecksAvailable: true, fetcher: fetcher, notifications: notifications)
        defer { updater.stop() }
        var stateChanges = 0
        updater.onStateChange = { stateChanges += 1 }
        check(updater.viewState.availableVersion == nil && channel.delivered.isEmpty,
              "Updater starts with no invented release or notification")
        updater.startAutomaticChecks()
        check(fetcher.requests == 0 && channel.authorizationRequests == 0,
              "Automatic startup neither checks immediately nor requests notification permission")
        check(channel.permissionReads == 1 && updater.notificationPermission == .allowed,
              "Updater reads permission through the injected notification channel")
        updater.didWake()
        check(fetcher.requests == 0, "Wake respects initial automatic-check delay")
        date.addTimeInterval(31)
        updater.didWake()
        check(fetcher.requests == 1 && updater.isChecking, "Due wake starts the real updater check engine")
        fetcher.complete(.success(release("v9.0")))
        check(!updater.isChecking && updater.viewState.availableVersion == "v9.0",
              "Automatic result persists availability for menu and settings")
        check(channel.delivered.count == 1 && channel.delivered[0].version == "v9.0",
              "Real automatic updater result reaches the notification coordinator once")
        check(preferences.state.lastSuccess == date && stateChanges > 0,
              "Success records its check time and publishes presentation changes")
        check(MenuBarPresentation(state: .initial, mode: .icon, panelVisible: false,
                                  hasUpdate: updater.viewState.availableVersion != nil).title.contains("↑"),
              "Persisted updater availability drives the menu-bar update marker")
        updater.didWake()
        check(fetcher.requests == 1 && channel.delivered.count == 1, "Success interval suppresses repeated wake checks")

        updater.setNotificationsEnabled(false, userInitiated: false)
        check(!updater.notificationsEnabled && updater.viewState.automaticChecksEnabled,
              "Turning reminders off leaves automatic update checks enabled")
        check(updater.viewState.availableVersion == "v9.0" && channel.removed.contains("app-update:9.0"),
              "Turning reminders off removes their notification but preserves available-version state")
        date.addTimeInterval(24 * 60 * 60 + 1)
        updater.didWake()
        check(fetcher.requests == 2, "Automatic checks continue while notifications are disabled")
        fetcher.complete(.success(release("v9.1")))
        check(updater.viewState.availableVersion == "v9.1" && channel.delivered.count == 1,
              "A newer disabled reminder still updates the persistent release marker")
        check(MenuBarPresentation(state: .initial, mode: .icon, panelVisible: false,
                                  hasUpdate: updater.viewState.availableVersion != nil).hasUpdate,
              "Disabling reminders does not hide the menu-bar update marker")

        date.addTimeInterval(24 * 60 * 60 + 1)
        updater.didWake()
        fetcher.complete(.failure(AppUpdateFetchFailure("fixture network unavailable")))
        check(updater.viewState.availableVersion == "v9.1" && !updater.isChecking,
              "A failed automatic check preserves the previously known available release")
        check(preferences.state.consecutiveAutomaticFailures == 1 && preferences.state.retryNotBefore != nil,
              "Automatic failure retains scheduling backoff without clearing availability")
        check(channel.delivered.count == 1 && channel.authorizationRequests == 0,
              "Failed and disabled checks do not produce notifications or permission prompts")

        updater.setNotificationsEnabled(true, userInitiated: false)
        check(channel.delivered.count == 1 && channel.authorizationRequests == 0,
              "Re-enabling silently never replays an already discovered version")
        date.addTimeInterval(301)
        updater.didWake()
        fetcher.complete(.success(release("v9.1")))
        check(channel.delivered.count == 1 && preferences.state.consecutiveAutomaticFailures == 0,
              "Successful recovery clears backoff without replaying the disabled version")
        date.addTimeInterval(24 * 60 * 60 + 1)
        updater.didWake()
        fetcher.complete(.success(release("v9.2")))
        check(channel.delivered.map(\.version) == ["v9.0", "v9.2"] && updater.viewState.availableVersion == "v9.2",
              "A genuinely newer release after re-enabling receives one notification")
        updater.stop()

        let relaunchedChannel = IntegrationUpdateChannel()
        let relaunchedFetcher = IntegrationUpdateFetcher()
        let relaunched = AppUpdater(session: session, preferences: AppUpdatePreferences(defaults: defaults), policy: .standard,
            now: { date }, automaticChecksAvailable: true, fetcher: relaunchedFetcher,
            notifications: AppUpdateNotificationController(defaults: defaults, channel: relaunchedChannel))
        defer { relaunched.stop() }
        check(relaunched.viewState.availableVersion == "v9.2" && relaunchedChannel.delivered.isEmpty,
              "Relaunch restores the available-version marker silently")
        relaunched.startAutomaticChecks()
        date.addTimeInterval(24 * 60 * 60 + 1)
        relaunched.didWake()
        relaunchedFetcher.complete(.success(release("v9.2")))
        check(relaunchedChannel.delivered.isEmpty, "Persistent version consumption prevents a notification replay after relaunch")
        relaunched.setAutomaticChecksEnabled(false)
        date.addTimeInterval(24 * 60 * 60 + 1)
        relaunched.didWake()
        check(relaunchedFetcher.requests == 1 && relaunched.notificationsEnabled,
              "Disabling automatic checks is independent from the reminder preference")

        let unavailableChannel = IntegrationUpdateChannel()
        let unavailableFetcher = IntegrationUpdateFetcher()
        let unavailable = AppUpdater(session: session, preferences: AppUpdatePreferences(defaults: defaults), policy: .standard,
            now: { date }, automaticChecksAvailable: false, fetcher: unavailableFetcher,
            notifications: AppUpdateNotificationController(defaults: defaults, channel: unavailableChannel))
        defer { unavailable.stop() }
        unavailable.setAutomaticChecksEnabled(true)
        unavailable.startAutomaticChecks()
        date.addTimeInterval(24 * 60 * 60 + 1)
        unavailable.didWake()
        check(unavailableFetcher.requests == 0 && unavailableChannel.permissionReads == 0,
              "Development runtime does not start automatic checks or read system notification permission")
        check(IntegrationUpdateNoNetworkProtocol.requests == 0 && channel.authorizationRequests == 0
              && relaunchedChannel.authorizationRequests == 0 && unavailableChannel.authorizationRequests == 0,
              "Updater integration uses no network task or real authorization request")
    }
}
