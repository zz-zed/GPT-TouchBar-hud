import AppKit

/// Owns service lifetime and pause facts. Presentation reactions are explicit callbacks.
final class AppLifecycleCoordinator {
    /// Platform exit actions are injectable so update refusal can be tested without quitting the fixture app.
    struct QuitControl {
        let canQuit: () -> Bool
        let presentProgress: () -> Void
        let terminate: () -> Void
        let markManualQuit: () -> Void
    }
    private let quitControl: QuitControl
    private let store: RateLimitStore
    private let appUpdater: AppUpdater
    private let taskMonitor: TaskMonitoringCoordinator
    private let hostMonitor: HostLifecycleMonitor
    private let resetNewsMonitor: ResetNewsMonitor
    private let quotaAlerts: QuotaAlertMonitor
    private let persistentTouchBar: PersistentTouchBarController
    private(set) var state = AppLifecycleState()
    private var terminationInProgress = false
    private var terminationReason: DiagnosticExitReason = .system
    var taskStatusEnabled: () -> Bool = { UserDefaults.standard.object(forKey: "taskStatusEnabled") as? Bool ?? true }
    var onStartPresentation: (() -> Void)?
    var onHostStarted: (() -> Void)?
    var onHostAbsentAtLaunch: (() -> Void)?
    var onResetCompletion: (() -> Void)?
    var onSessionSuspended: ((Bool) -> Void)?
    var onStopPresentation: (() -> Void)?
    var acceptsCallbacks: Bool { state.runtimeRunning && !terminationInProgress }

    init(store: RateLimitStore, appUpdater: AppUpdater, taskMonitor: TaskMonitoringCoordinator,
         hostMonitor: HostLifecycleMonitor, resetNewsMonitor: ResetNewsMonitor,
         quotaAlerts: QuotaAlertMonitor, persistentTouchBar: PersistentTouchBarController,
         quitControl: QuitControl? = nil) {
        self.quitControl = quitControl ?? QuitControl(canQuit: { appUpdater.canQuit },
            presentProgress: { appUpdater.presentInstallationProgress() }, terminate: { NSApp.terminate(nil) },
            markManualQuit: { HostAutoLauncher.markManualQuit() })
        self.store = store; self.appUpdater = appUpdater; self.taskMonitor = taskMonitor
        self.hostMonitor = hostMonitor; self.resetNewsMonitor = resetNewsMonitor
        self.quotaAlerts = quotaAlerts; self.persistentTouchBar = persistentTouchBar
        hostMonitor.onHostStarted = { [weak self] in self?.hostChanged(running: true) }
        hostMonitor.onHostStopped = { [weak self] in self?.hostChanged(running: false) }
        hostMonitor.onCodexStarted = { [weak self] in self?.codexChanged(running: true) }
        hostMonitor.onCodexStopped = { [weak self] in self?.codexChanged(running: false) }
    }
    func start() {
        guard state.runtime == .stopped, !terminationInProgress else { return }
        hostMonitor.start()
        let transition = state.start(hostRunning: hostMonitor.hostIsRunningNow(), codexRunning: hostMonitor.codexIsRunningNow())
        guard transition.runtimeStarted else { return }
        onStartPresentation?()
        if state.sessionSuspended { onSessionSuspended?(true) }
        taskMonitor.prepareForHost(displayEnabled: taskStatusEnabled())
        updateWorkGates()
        if transition.hostStarted { startHostServices() }
        else {
            DiagnosticRuntimeRecorder.shared.record(.moduleRecovery(module: .host, state: .unknown, observation: .hostNotRunning))
            onHostAbsentAtLaunch?()
        }
        appUpdater.startAutomaticChecks()
    }
    private func hostChanged(running: Bool) {
        let transition = state.updateHostRunning(running)
        guard !transition.isEmpty else { return }
        if transition.hostStarted { updateWorkGates(); startHostServices() }
        else if transition.hostStopped {
            terminationReason = .hostExit
            DiagnosticRuntimeRecorder.shared.record(.moduleRecovery(module: .host, state: .unknown, observation: .hostNotRunning))
            taskMonitor.hostUnavailable()
            guard quitControl.canQuit() else {
                updateWorkGates()
                quitControl.presentProgress()
                return
            }
            stop()
            quitControl.terminate()
        }
    }
    private func codexChanged(running: Bool) {
        guard !state.updateCodexRunning(running).isEmpty else { return }
        updateWorkGates()
    }
    private func startHostServices() {
        guard acceptsCallbacks, state.hostRunning else { return }
        DiagnosticRuntimeRecorder.shared.record(.moduleRecovery(module: .host, state: .unknown, observation: .hostRunning))
        onResetCompletion?()
        taskMonitor.start(displayEnabled: taskStatusEnabled())
        if state.sessionSuspended { taskMonitor.suspend() }
        NSApp.setActivationPolicy(.accessory)
        persistentTouchBar.start(); store.start()
        onHostStarted?()
    }
    func restartTaskMonitoring() {
        guard acceptsCallbacks else { return }
        onResetCompletion?()
        if state.hostRunning {
            taskMonitor.start(displayEnabled: taskStatusEnabled())
            if state.sessionSuspended { taskMonitor.suspend() }
        } else { taskMonitor.prepareForHost(displayEnabled: taskStatusEnabled()) }
    }
    func refreshQuota() { guard acceptsCallbacks else { return }; store.start() }
    private func updateWorkGates() {
        if state.quotaWorkEnabled { quotaAlerts.resume() } else { quotaAlerts.suspend() }
        resetNewsMonitor.updateGate(codexRunning: state.codexRunning,
            hudRunning: state.runtimeRunning, suspended: state.sessionSuspended)
    }
    private func setPause(_ reason: AppLifecycleState.PauseReason, active: Bool) {
        let transition = state.setPause(reason, active: active)
        guard !transition.isEmpty else { return }
        if transition.becameSuspended { taskMonitor.suspend() }
        if transition.becameResumed && state.hostRunning { taskMonitor.resume() }
        updateWorkGates()
        if transition.becameSuspended || transition.becameResumed { onSessionSuspended?(state.sessionSuspended) }
    }
    func didSleep() {
        guard acceptsCallbacks else { return }
        DiagnosticRuntimeRecorder.shared.record(.lifecycle(.sleep)); setPause(.systemSleeping, active: true)
    }
    func didWake() {
        guard acceptsCallbacks else { return }
        DiagnosticRuntimeRecorder.shared.record(.lifecycle(.wake)); setPause(.systemSleeping, active: false)
        appUpdater.didWake()
    }
    func screenLocked(_ locked: Bool) {
        guard acceptsCallbacks else { return }
        DiagnosticRuntimeRecorder.shared.record(.lifecycle(locked ? .screenLocked : .screenUnlocked))
        setPause(.screenLocked, active: locked)
    }
    func sessionInactive(_ inactive: Bool) {
        guard acceptsCallbacks else { return }
        DiagnosticRuntimeRecorder.shared.record(.lifecycle(inactive ? .sessionSuspended : .sessionResumed))
        setPause(.sessionInactive, active: inactive)
    }
    /// The reducer closes gates first. Synchronous or queued service callbacks cannot restart work.
    func stop() {
        guard state.stop().runtimeStopped else { return }
        quotaAlerts.suspend(); onStopPresentation?(); resetNewsMonitor.stop()
        taskMonitor.stop(); persistentTouchBar.stop(); hostMonitor.stop(); store.stop(); appUpdater.stop()
        state.finishStop()
    }
    func quit(reason: DiagnosticExitReason = .manual) {
        guard quitControl.canQuit() else { quitControl.presentProgress(); return }
        terminationReason = reason
        quitControl.markManualQuit()
        stop()
        quitControl.terminate()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard quitControl.canQuit() else { quitControl.presentProgress(); return .terminateCancel }
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        let deadline = DispatchTime.now() + .seconds(3)
        let reply = MainRunLoopCompletion(deadline: deadline) { sender.reply(toApplicationShouldTerminate: true) }
        stop()
        resetNewsMonitor.stop()
        let group = DispatchGroup()
        group.enter(); resetNewsMonitor.flush { group.leave() }
        group.enter(); DiagnosticUpgradeRecovery.prepareTermination(deadline: deadline, reason: terminationReason) { group.leave() }
        group.notify(queue: .global(qos: .utility)) { reply.complete() }
        return .terminateLater
    }
}
