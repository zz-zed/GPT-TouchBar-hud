import AppKit

/// Composition root and AppKit delegate bridge. Domain services remain unchanged.
final class AppDelegate: NSObject, NSApplicationDelegate, RateLimitStoreDelegate {
    private let touchBarHardware = TouchBarHardware.current
    private let store = RateLimitStore(diagnostics: DiagnosticRuntimeRecorder.shared)
    private let appUpdater = AppUpdater()
    private let taskMonitor = TaskMonitoringCoordinator(diagnostics: DiagnosticRuntimeRecorder.shared)
    private let lifecycleMonitor = HostLifecycleMonitor()
    private let persistentTouchBar = PersistentTouchBarController(diagnostics: DiagnosticRuntimeRecorder.shared)
    private let resetNewsMonitor: ResetNewsMonitor
    private let quotaAlerts: QuotaAlertMonitor
    private lazy var menu = StatusMenuController(touchBarHardware: touchBarHardware, appUpdater: appUpdater)
    private lazy var display = AppDisplayCoordinator(menu: menu, persistentTouchBar: persistentTouchBar)
    private lazy var preferences = PreferencesCoordinator(touchBarHardware: touchBarHardware, appUpdater: appUpdater,
        resetNewsMonitor: resetNewsMonitor, quotaAlerts: quotaAlerts)
    private var screenLocked = false
    private var systemSleeping = false
    private var sessionInactive = false
    private var sessionSuspended: Bool { screenLocked || systemSleeping || sessionInactive }
    private var runtimeRunning = false
    private var terminationInProgress = false
    private var terminationReason: DiagnosticExitReason = .system

    init(resetNewsMonitor: ResetNewsMonitor = ResetNewsMonitor(), quotaAlerts: QuotaAlertMonitor = QuotaAlertMonitor()) {
        self.resetNewsMonitor = resetNewsMonitor; self.quotaAlerts = quotaAlerts
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticRecorder.shared.start(enabled: UserDefaults.standard.object(forKey: DiagnosticRecorder.preferenceKey) as? Bool ?? true)
        DiagnosticRuntimeRecorder.shared.recovery.start(arguments: ProcessInfo.processInfo.arguments,
            bundleURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier)
        DiagnosticRuntimeRecorder.shared.record(.lifecycle(.launch))
        DiagnosticRuntimeRecorder.shared.record(.display(surface: .touchBar, action: .capability,
            result: touchBarHardware == .present ? .success : (touchBarHardware == .absent ? .unsupported : .unknown),
            reason: touchBarHardware == .present ? nil : (touchBarHardware == .absent ? .noHardware : .unknownHardware)))
        NSApp.setActivationPolicy(.accessory)
        LegacyAppMigration.terminateLegacyApplications()
        connectCallbacks()
        runtimeRunning = true
        display.start()
        observeSession()
        preferences.configureAutoLaunch()
        HostAutoLauncher.clearManualQuitLock()
        taskMonitor.prepareForHost(displayEnabled: display.taskStatusEnabled)
        lifecycleMonitor.start()
        updateResetNewsGate()
        display.receiveNews(resetNewsMonitor.state)
        if lifecycleMonitor.hostIsRunningNow() { hostDidStart() }
        else {
            DiagnosticRuntimeRecorder.shared.record(.moduleRecovery(module: .host, state: .unknown, observation: .hostNotRunning))
            display.environmentChanged()
        }
        appUpdater.startAutomaticChecks()
        AppUpdateProgressChannel.acknowledgeLaunch(arguments: ProcessInfo.processInfo.arguments,
            bundleURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier, version: AppUpdater.version)
    }
    private func connectCallbacks() {
        store.delegate = self
        display.onRefreshQuota = { [weak self] in self?.refreshQuotaNow() }
        display.onCheckResetNews = { [weak self] in self?.resetNewsMonitor.checkNow() }
        display.onMarkAllRead = { [weak self] in self?.resetNewsMonitor.markAllRead() }
        display.onVisibleMessage = { [weak self] in self?.resetNewsMonitor.markRead([$0]) }
        display.onOpenPreferences = { [weak self] in self?.preferences.openPreferences(nil) }
        display.onOpenResetNewsPreferences = { [weak self] in self?.preferences.openResetNews() }
        display.onTaskStatusChanged = { [weak self] in self?.restartTaskMonitoring() }
        display.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.preferences.update(snapshot: snapshot, appearance: self.display.hudAppearance,
                taskEnabled: self.display.taskStatusEnabled, persistentEnabled: self.persistentTouchBar.isEnabled,
                persistentAvailable: self.persistentTouchBar.isAvailable)
        }
        menu.onQuit = { [weak self] in self?.quitApp() }
        preferences.onAppearance = { [weak self] in self?.display.setAppearance($0) }
        preferences.onQuit = { [weak self] in self?.quitApp() }
        preferences.onDisplayMode = { [weak self] in self?.display.setDisplayMode($0) }
        preferences.onMenuMode = { [weak self] in self?.display.setMenuMode($0) }
        preferences.onAlwaysShowQuota = { [weak self] in self?.display.setAlwaysShowQuota($0) }
        preferences.onVisibility = { [weak self] in self?.display.setVisible($0) }
        preferences.onLanguage = { [weak self] in self?.display.renderDisplayState() }
        preferences.onTaskStatus = { [weak self] in self?.display.setTaskStatusEnabled($0) }
        preferences.onPersistent = { [weak self] in self?.display.setPersistentEnabled($0) }
        preferences.onHookModeChanged = { [weak self] in self?.restartTaskMonitoring() }
        preferences.onNeedsDisplayRefresh = { [weak self] in self?.display.renderDisplayState() }
        quotaAlerts.onStateChange = { [weak self] in self?.preferences.updateQuotaAlertPreferences() }
        quotaAlerts.onOpenSettings = { [weak self] in self?.preferences.openQuotaAlerts() }
        resetNewsMonitor.onStateChange = { [weak self] state in
            guard let self, self.runtimeRunning, !self.terminationInProgress else { return }
            self.display.receiveNews(state)
        }
        resetNewsMonitor.onOpenDetails = { [weak self] ids in self?.display.openResetNews(itemIDs: ids) }
        appUpdater.onInstall = { [weak self] in self?.quitApp(reason: .update) }
        appUpdater.onStateChange = { [weak self] in
            self?.menu.updateMenuState(); self?.display.renderDisplayState(); self?.preferences.updateAppUpdate()
        }
        appUpdater.onProgressChange = { [weak self] in self?.menu.updateUpdateMenuItems(); self?.preferences.updateAppUpdate() }
        taskMonitor.onUpdate = { [weak self] status in
            guard let self, self.runtimeRunning, !self.terminationInProgress else { return }
            self.display.receiveTask(status); self.taskMonitor.recordDisplaySubmission()
        }
        taskMonitor.onDiagnosticSnapshot = { [weak self] reference in
            guard let self, self.runtimeRunning, !self.terminationInProgress else { return }
            self.display.receiveDiagnosticSnapshot(reference)
        }
        lifecycleMonitor.onCodexStarted = { [weak self] in self?.updateResetNewsGate() }
        lifecycleMonitor.onCodexStopped = { [weak self] in self?.updateResetNewsGate() }
        lifecycleMonitor.onHostStarted = { [weak self] in self?.hostDidStart() }
        lifecycleMonitor.onHostStopped = { [weak self] in self?.hostDidStop() }
    }
    private func observeSession() {
        NotificationCenter.default.addObserver(self, selector: #selector(screenConfigurationChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            workspace.addObserver(self, selector: #selector(spaceOrWakeChanged), name: name, object: nil)
        }
        workspace.addObserver(self, selector: #selector(frontApplicationChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(suspendPanels), name: name, object: nil)
        }
        workspace.addObserver(self, selector: #selector(resumePanels), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(suspendPanels), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(resumePanels), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        preferences.openPreferences(nil); return false
    }
    @objc private func screenConfigurationChanged() { display.environmentChanged() }
    @objc private func frontApplicationChanged() { display.frontApplicationChanged() }
    @objc private func spaceOrWakeChanged(_ notification: Notification) {
        if notification.name == NSWorkspace.didWakeNotification {
            DiagnosticRuntimeRecorder.shared.record(.lifecycle(.wake)); systemSleeping = false
            taskMonitor.resume(); appUpdater.didWake(); updateResetNewsGate()
            display.setSessionSuspended(sessionSuspended)
        }
        screenConfigurationChanged()
    }
    @objc private func suspendPanels(_ notification: Notification) {
        if notification.name.rawValue == "com.apple.screenIsLocked" { screenLocked = true; DiagnosticRuntimeRecorder.shared.record(.lifecycle(.screenLocked)) }
        if notification.name == NSWorkspace.willSleepNotification { systemSleeping = true; DiagnosticRuntimeRecorder.shared.record(.lifecycle(.sleep)); taskMonitor.suspend() }
        if notification.name == NSWorkspace.sessionDidResignActiveNotification { sessionInactive = true; DiagnosticRuntimeRecorder.shared.record(.lifecycle(.sessionSuspended)) }
        display.setSessionSuspended(sessionSuspended); updateResetNewsGate()
    }
    @objc private func resumePanels(_ notification: Notification) {
        if notification.name.rawValue == "com.apple.screenIsUnlocked" { screenLocked = false; DiagnosticRuntimeRecorder.shared.record(.lifecycle(.screenUnlocked)) }
        if notification.name == NSWorkspace.sessionDidBecomeActiveNotification { sessionInactive = false; DiagnosticRuntimeRecorder.shared.record(.lifecycle(.sessionResumed)) }
        updateResetNewsGate(); display.setSessionSuspended(sessionSuspended)
    }
    private func updateResetNewsGate() {
        guard runtimeRunning else { return }
        if sessionSuspended || !lifecycleMonitor.hostIsRunningNow() { quotaAlerts.suspend() } else { quotaAlerts.resume() }
        resetNewsMonitor.updateGate(codexRunning: lifecycleMonitor.codexIsRunningNow(), hudRunning: runtimeRunning, suspended: sessionSuspended)
    }
    private func hostDidStart() {
        guard runtimeRunning, !terminationInProgress else { return }
        DiagnosticRuntimeRecorder.shared.record(.moduleRecovery(module: .host, state: .unknown, observation: .hostRunning))
        if !sessionSuspended { quotaAlerts.resume() }
        display.resetCompletionFeedback(); taskMonitor.start(displayEnabled: display.taskStatusEnabled)
        NSApp.setActivationPolicy(.accessory); persistentTouchBar.start(); store.start(); display.hostDidStart()
    }
    private func hostDidStop() {
        guard runtimeRunning, !terminationInProgress else { return }
        terminationReason = .hostExit
        DiagnosticRuntimeRecorder.shared.record(.moduleRecovery(module: .host, state: .unknown, observation: .hostNotRunning))
        quotaAlerts.suspend(); display.resetCompletionFeedback(); resetNewsMonitor.stop()
        taskMonitor.hostUnavailable(); runtimeRunning = false
        display.hidePanels(); taskMonitor.stop(); persistentTouchBar.stop(); store.stop(); NSApp.terminate(nil)
    }
    private func restartTaskMonitoring() {
        guard runtimeRunning, !terminationInProgress else { return }
        display.resetCompletionFeedback()
        if lifecycleMonitor.hostIsRunningNow() { taskMonitor.start(displayEnabled: display.taskStatusEnabled) }
        else { taskMonitor.prepareForHost(displayEnabled: display.taskStatusEnabled) }
    }
    private func refreshQuotaNow() { guard runtimeRunning, !terminationInProgress else { return }; store.start() }
    func rateLimitStore(_ store: RateLimitStore, didUpdate state: RateLimitDisplayState) {
        guard runtimeRunning, !terminationInProgress else { return }
        if state.errorMessage != nil || state.lastUpdated == nil { quotaAlerts.invalidateBaseline() }
        else if !state.isRefreshing { quotaAlerts.update(state: state, accountKey: store.verifiedAccountKey, limitID: store.currentLimitID) }
        display.receiveQuota(state)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard appUpdater.canQuit else { appUpdater.presentInstallationProgress(); return .terminateCancel }
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true; runtimeRunning = false
        let deadline = DispatchTime.now() + .seconds(3)
        let reply = MainRunLoopCompletion(deadline: deadline) { sender.reply(toApplicationShouldTerminate: true) }
        resetNewsMonitor.stop()
        let group = DispatchGroup()
        group.enter(); resetNewsMonitor.flush { group.leave() }
        group.enter(); DiagnosticUpgradeRecovery.prepareTermination(deadline: deadline, reason: terminationReason) { group.leave() }
        group.notify(queue: .global(qos: .utility)) { reply.complete() }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        runtimeRunning = false; quotaAlerts.suspend(); display.resetCompletionFeedback(); resetNewsMonitor.stop()
        display.hidePanels(); taskMonitor.stop(); persistentTouchBar.stop(); lifecycleMonitor.stop(); store.stop(); appUpdater.stop()
    }
    private func quitApp(reason: DiagnosticExitReason = .manual) {
        guard appUpdater.canQuit else { appUpdater.presentInstallationProgress(); return }
        terminationReason = reason; runtimeRunning = false
        quotaAlerts.suspend(); display.resetCompletionFeedback(); resetNewsMonitor.stop(); display.hidePanels()
        HostAutoLauncher.markManualQuit(); persistentTouchBar.stop(); lifecycleMonitor.stop(); store.stop(); appUpdater.stop()
        NSApp.terminate(nil)
    }
}
