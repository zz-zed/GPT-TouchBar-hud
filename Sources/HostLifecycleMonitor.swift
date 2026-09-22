import AppKit

struct HostLifecycleSnapshot: Equatable {
    let hostIsRunning: Bool
    let codexIsRunning: Bool
}

enum HostLifecycleChange: Equatable {
    case hostStarted
    case hostStopped
    case codexStarted
    case codexStopped
}

struct HostLifecycleStateReducer {
    private(set) var snapshot: HostLifecycleSnapshot?

    mutating func reset(to snapshot: HostLifecycleSnapshot) {
        self.snapshot = snapshot
    }

    mutating func transition(to next: HostLifecycleSnapshot) -> [HostLifecycleChange] {
        guard let previous = snapshot else {
            snapshot = next
            return []
        }

        snapshot = next
        var changes: [HostLifecycleChange] = []
        if previous.hostIsRunning != next.hostIsRunning {
            changes.append(next.hostIsRunning ? .hostStarted : .hostStopped)
        }
        if previous.codexIsRunning != next.codexIsRunning {
            changes.append(next.codexIsRunning ? .codexStarted : .codexStopped)
        }
        return changes
    }
}

struct HostApplicationIdentity {
    let bundleIdentifier: String?
    let bundlePath: String?
    let localizedName: String?
}

final class HostLifecycleMonitor {
    var onHostStarted: (() -> Void)?
    var onHostStopped: (() -> Void)?
    var onCodexStarted: (() -> Void)?
    var onCodexStopped: (() -> Void)?

    private let notificationCenter: NotificationCenter
    private let runningStateProvider: () -> HostLifecycleSnapshot
    private let pollTimerFactory: (@escaping () -> Void) -> Timer
    private var timer: Timer?
    private var reducer = HostLifecycleStateReducer()
    private var isMonitoring = false

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        runningStateProvider: @escaping () -> HostLifecycleSnapshot = HostLifecycleMonitor.detectRunningState,
        pollTimerFactory: @escaping (@escaping () -> Void) -> Timer = HostLifecycleMonitor.makePollTimer
    ) {
        self.notificationCenter = notificationCenter
        self.runningStateProvider = runningStateProvider
        self.pollTimerFactory = pollTimerFactory
    }

    func start() {
        guard !isMonitoring else {
            return
        }

        isMonitoring = true
        reducer.reset(to: runningStateProvider())

        notificationCenter.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        notificationCenter.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        timer = pollTimerFactory { [weak self] in
            self?.poll()
        }
    }

    func stop() {
        guard isMonitoring else {
            return
        }

        isMonitoring = false
        timer?.invalidate()
        timer = nil
        notificationCenter.removeObserver(self)
    }

    func hostIsRunningNow() -> Bool {
        runningStateProvider().hostIsRunning
    }

    func codexIsRunningNow() -> Bool {
        runningStateProvider().codexIsRunning
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        guard isMonitoring, Self.isSupportedHost(app) else {
            return
        }

        let detected = runningStateProvider()
        transition(to: HostLifecycleSnapshot(
            hostIsRunning: true,
            codexIsRunning: detected.codexIsRunning || Self.isCodexHost(app)
        ))
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        if isMonitoring, Self.isSupportedHost(app) {
            transition(to: runningStateProvider())
        }
    }

    private func poll() {
        guard isMonitoring else {
            return
        }

        transition(to: runningStateProvider())
    }

    private func transition(to snapshot: HostLifecycleSnapshot) {
        for change in reducer.transition(to: snapshot) {
            switch change {
            case .hostStarted:
                onHostStarted?()
            case .hostStopped:
                onHostStopped?()
            case .codexStarted:
                onCodexStarted?()
            case .codexStopped:
                onCodexStopped?()
            }
        }
    }

    private static func detectRunningState() -> HostLifecycleSnapshot {
        let applications = NSWorkspace.shared.runningApplications
        return HostLifecycleSnapshot(
            hostIsRunning: applications.contains(where: isSupportedHost),
            codexIsRunning: applications.contains(where: isCodexHost)
        )
    }

    private static func makePollTimer(_ poll: @escaping () -> Void) -> Timer {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            poll()
        }
    }

    static func isSupportedHost(_ app: NSRunningApplication) -> Bool {
        isSupportedHost(HostApplicationIdentity(app))
    }

    static func isCodexHost(_ app: NSRunningApplication) -> Bool {
        isCodexHost(HostApplicationIdentity(app))
    }

    static func isSupportedHost(_ app: HostApplicationIdentity) -> Bool {
        if isCodexHost(app) {
            return true
        }

        let supportedPaths = [
            "/Applications/ChatGPT.app",
            "/Applications/GPT.app"
        ]
        if let path = app.bundlePath, supportedPaths.contains(path) {
            return true
        }

        let supportedNames = ["ChatGPT", "GPT"]
        return app.localizedName.map(supportedNames.contains) ?? false
    }

    static func isCodexHost(_ app: HostApplicationIdentity) -> Bool {
        if app.bundleIdentifier == "com.openai.codex" {
            return true
        }

        if app.bundlePath == "/Applications/Codex.app" {
            return true
        }

        return app.localizedName == "Codex"
    }
}

private extension HostApplicationIdentity {
    init(_ app: NSRunningApplication) {
        bundleIdentifier = app.bundleIdentifier
        bundlePath = app.bundleURL?.path
        localizedName = app.localizedName
    }
}
