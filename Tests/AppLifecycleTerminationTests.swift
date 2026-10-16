import AppKit
import Darwin

private final class LifecycleTerminationTouchPresenter: SystemTouchBarPresenting {
    var isAvailable: Bool { false }
    func present(_ touchBar: NSTouchBar) {}
    func dismiss(_ touchBar: NSTouchBar) {}
}

/// Exercises the production coordinator inside AppKit's actual termination loop.
/// Host services stay inactive; only the fixture's cache and defaults are written.
private final class LifecycleTerminationFixture: NSObject, NSApplicationDelegate {
    private let suiteName: String
    private let defaults: UserDefaults
    private let directory: URL
    private var began = DispatchTime.now()
    private var shouldTerminateCalls = 0
    private var willTerminateCalls = 0
    private var presentationStops = 0
    private var checkedLaterReplies = false
    private var cacheSaveAcknowledged = false
    private var expectedCacheState: ResetNewsStoredState?
    private lazy var repository = ResetNewsRepository(directory: directory)
    private lazy var coordinator = makeCoordinator()

    override init() {
        let suiteName = "AppLifecycleTermination." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            print("FAIL: cannot create isolated lifecycle termination defaults")
            exit(1)
        }
        self.suiteName = suiteName
        self.defaults = defaults
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        super.init()
        defaults.set(false, forKey: ResetNewsMonitor.enabledPreferenceKey)
        defaults.set(false, forKey: QuotaAlertMonitor.enabledPreferenceKey)
        defaults.set(false, forKey: AppUpdateNotificationPreferences.enabledKey)
        defaults.set(false, forKey: "persistentTouchBarEnabled")
    }

    private func makeCoordinator() -> AppLifecycleCoordinator {
        let preferences = AppUpdatePreferences(defaults: defaults)
        preferences.automaticChecksEnabled = false
        let updater = AppUpdater(session: URLSession(configuration: .ephemeral), preferences: preferences,
            policy: .standard, now: Date.init, automaticChecksAvailable: false,
            notifications: AppUpdateNotificationController(defaults: defaults))
        let hostMonitor = HostLifecycleMonitor(notificationCenter: NotificationCenter(),
            runningStateProvider: { HostLifecycleSnapshot(hostIsRunning: false, codexIsRunning: false) },
            pollTimerFactory: { _ in Timer(timeInterval: 3_600, repeats: true) { _ in } })
        let news = ResetNewsMonitor(repository: repository, defaults: defaults, notificationCenter: NotificationCenter())
        let persistent = PersistentTouchBarController(presenter: LifecycleTerminationTouchPresenter(),
            defaults: defaults, notifications: NotificationCenter())
        let lifecycle = AppLifecycleCoordinator(store: RateLimitStore(), appUpdater: updater,
            taskMonitor: TaskMonitoringCoordinator(), hostMonitor: hostMonitor, resetNewsMonitor: news,
            quotaAlerts: QuotaAlertMonitor(defaults: defaults), persistentTouchBar: persistent)
        lifecycle.taskStatusEnabled = { false }
        lifecycle.onStopPresentation = { [weak self] in
            guard let self else { return }
            self.check(Thread.isMainThread, "presentation shutdown must run on the main thread")
            self.presentationStops += 1
            self.check(self.presentationStops == 1, "presentation shutdown must occur exactly once")
        }
        return lifecycle
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(5)) { [self] in
            fail("native lifecycle termination watchdog expired")
        }
        check(Thread.isMainThread, "fixture startup must run on the main thread")
        check(!DiagnosticRecorder.shared.isEnabled, "the shared diagnostic recorder must remain unstarted and disabled")
        coordinator.start()
        check(coordinator.state.runtimeRunning, "the production coordinator must start before termination")
        check(!coordinator.state.hostRunning && !coordinator.state.codexRunning,
              "the fixture must not start services for any host")
        check(!coordinator.state.quotaAlertsAllowed && !coordinator.state.resetNewsWorkEnabled,
              "host absence must keep both work gates closed")
        repository.load { [self] in
            DispatchQueue.main.async { [self] in
                let previous = repository.state
                var snapshot = previous
                snapshot.forecastBaselineEstablished = !(previous.forecastBaselineEstablished ?? false)
                // Queue a real write immediately before terminate. Its acknowledgement
                // must still arrive while AppKit waits inside terminateLater.
                repository.replace(snapshot, now: Date()) { [self] saved in
                    check(Thread.isMainThread, "cache acknowledgement must run on the main run loop")
                    check(saved, "the fixture cache must persist successfully")
                    cacheSaveAcknowledged = true
                }
                expectedCacheState = repository.state
                check(expectedCacheState != previous, "the pending write must change the existing cache payload")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        check(Thread.isMainThread, "AppKit must request termination on the main thread")
        shouldTerminateCalls += 1
        check(shouldTerminateCalls == 1, "AppKit must enter the fixture termination delegate once")
        began = .now()
        let reply = coordinator.applicationShouldTerminate(sender)
        check(reply == .terminateLater, "the real coordinator must defer termination for its shutdown fence")
        check(coordinator.state.runtime == .stopped && presentationStops == 1,
              "the first termination request must finish synchronous service shutdown once")
        check(coordinator.applicationShouldTerminate(sender) == .terminateLater,
              "a repeated request during pending termination must remain deferred")
        check(coordinator.state.runtime == .stopped && presentationStops == 1,
              "a repeated termination request must not repeat synchronous shutdown")
        checkedLaterReplies = true
        // The production coordinator owns MainRunLoopCompletion and sender.reply.
        // Reaching applicationWillTerminate therefore verifies their real wiring.
        return reply
    }

    func applicationWillTerminate(_ notification: Notification) {
        check(Thread.isMainThread, "real termination completion must run on the main thread")
        willTerminateCalls += 1
        check(willTerminateCalls == 1, "AppKit must finish termination once")
        check(shouldTerminateCalls == 1 && checkedLaterReplies,
              "real termination must follow the coordinator's accepted terminateLater replies")
        check(coordinator.state.runtime == .stopped && !coordinator.acceptsCallbacks,
              "the coordinator must remain stopped when AppKit finishes termination")
        check(presentationStops == 1, "accepted completion must not repeat presentation shutdown")
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1_000_000_000
        check(elapsed < 3, "accepted completion must finish before the production three-second deadline")
        check(cacheSaveAcknowledged, "the pending cache write must be acknowledged before AppKit exits")
        check(FileManager.default.fileExists(atPath: repository.fileURL.path),
              "the coordinator's flush fence must leave the temporary cache on disk")
        do {
            let saved = try JSONDecoder().decode(ResetNewsStoredState.self, from: Data(contentsOf: repository.fileURL))
            check(saved == expectedCacheState, "the flushed cache must match the pending fixture snapshot")
        } catch {
            fail("cannot read the flushed fixture cache: \(error)")
        }
        check(!DiagnosticRecorder.shared.isEnabled, "termination must not enable the shared diagnostic recorder")
        cleanUp()
        print("PASS: native lifecycle coordinator termination")
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func check(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    private func fail(_ message: String) -> Never {
        print("FAIL: \(message)")
        cleanUp()
        exit(1)
    }
}

@main
private enum AppLifecycleTerminationTests {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        let delegate = LifecycleTerminationFixture()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        delegate.cleanUp()
        print("FAIL: native lifecycle application run returned without terminating")
        exit(1)
    }
}
