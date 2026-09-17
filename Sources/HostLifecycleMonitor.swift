import AppKit

final class HostLifecycleMonitor {
    var onHostStarted: (() -> Void)?
    var onHostStopped: (() -> Void)?

    private var timer: Timer?
    private var isHostRunning = false

    func start() {
        isHostRunning = Self.detectHostRunning()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func hostIsRunningNow() -> Bool {
        Self.detectHostRunning()
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        if Self.isSupportedHost(app) {
            transition(to: true)
        }
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        if Self.isSupportedHost(app) {
            transition(to: Self.detectHostRunning())
        }
    }

    private func poll() {
        transition(to: Self.detectHostRunning())
    }

    private func transition(to running: Bool) {
        guard running != isHostRunning else {
            return
        }

        isHostRunning = running
        if running {
            onHostStarted?()
        } else {
            onHostStopped?()
        }
    }

    private static func detectHostRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            isSupportedHost(app)
        }
    }

    private static func isSupportedHost(_ app: NSRunningApplication) -> Bool {
        if app.bundleIdentifier == "com.openai.codex" {
            return true
        }

        let supportedPaths = [
            "/Applications/Codex.app",
            "/Applications/ChatGPT.app",
            "/Applications/GPT.app"
        ]
        if let path = app.bundleURL?.path, supportedPaths.contains(path) {
            return true
        }

        let supportedNames = ["Codex", "ChatGPT", "GPT"]
        return app.localizedName.map(supportedNames.contains) ?? false
    }
}
