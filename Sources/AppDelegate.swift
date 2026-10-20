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
    private lazy var lifecycle = AppLifecycleCoordinator(store: store, appUpdater: appUpdater,
        taskMonitor: taskMonitor, hostMonitor: lifecycleMonitor, resetNewsMonitor: resetNewsMonitor,
        quotaAlerts: quotaAlerts, persistentTouchBar: persistentTouchBar)

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
        observeSession()
        if !AppMigrationRuntime.isCandidate {
            preferences.configureAutoLaunch()
            HostAutoLauncher.clearManualQuitLock()
        }
        lifecycle.start()
        display.receiveNews(resetNewsMonitor.state)
        AppUpdateProgressChannel.acknowledgeLaunch(arguments: ProcessInfo.processInfo.arguments,
            bundleURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier, version: AppUpdater.version)
        AppMigrationRuntime.didFinishCoreStartup()
    }
    private func connectCallbacks() {
        store.delegate = self
        lifecycle.taskStatusEnabled = { [weak self] in self?.display.taskStatusEnabled ?? false }
        lifecycle.onStartPresentation = { [weak self] in self?.preferences.start(); self?.display.start() }
        lifecycle.onResetCompletion = { [weak self] in self?.display.resetCompletionFeedback() }
        lifecycle.onHostStarted = { [weak self] in self?.display.hostDidStart() }
        lifecycle.onHostAbsentAtLaunch = { [weak self] in self?.display.environmentChanged() }
        lifecycle.onSessionSuspended = { [weak self] in self?.display.setSessionSuspended($0) }
        lifecycle.onStopPresentation = { [weak self] in self?.display.stop(); self?.preferences.stop() }
        display.onRefreshQuota = { [weak self] in self?.lifecycle.refreshQuota() }
        display.onCheckResetNews = { [weak self] in self?.resetNewsMonitor.checkNow() }
        display.onMarkAllRead = { [weak self] in self?.resetNewsMonitor.markAllRead() }
        display.onVisibleMessage = { [weak self] in self?.resetNewsMonitor.markRead([$0]) }
        display.onOpenPreferences = { [weak self] in self?.preferences.openPreferences(nil) }
        display.onOpenResetNewsPreferences = { [weak self] in self?.preferences.openResetNews() }
        display.onTaskStatusChanged = { [weak self] in self?.lifecycle.restartTaskMonitoring() }
        display.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.preferences.update(snapshot: snapshot, appearance: self.display.hudAppearance,
                taskEnabled: self.display.taskStatusEnabled, persistentEnabled: self.persistentTouchBar.isEnabled,
                persistentAvailable: self.persistentTouchBar.isAvailable)
        }
        menu.onQuit = { [weak self] in self?.lifecycle.quit() }
        preferences.onAppearance = { [weak self] in self?.display.setAppearance($0) }
        preferences.onQuit = { [weak self] in self?.lifecycle.quit() }
        preferences.onDisplayMode = { [weak self] in self?.display.setDisplayMode($0) }
        preferences.onMenuMode = { [weak self] in self?.display.setMenuMode($0) }
        preferences.onAlwaysShowQuota = { [weak self] in self?.display.setAlwaysShowQuota($0) }
        preferences.onVisibility = { [weak self] in self?.display.setVisible($0) }
        preferences.onLanguage = { [weak self] in self?.display.renderDisplayState() }
        preferences.onTaskStatus = { [weak self] in self?.display.setTaskStatusEnabled($0) }
        preferences.onPersistent = { [weak self] in self?.display.setPersistentEnabled($0) }
        preferences.onHookModeChanged = { [weak self] in self?.lifecycle.restartTaskMonitoring() }
        preferences.onNeedsDisplayRefresh = { [weak self] in self?.display.renderDisplayState() }
        quotaAlerts.onStateChange = { [weak self] in self?.preferences.updateQuotaAlertPreferences() }
        quotaAlerts.onOpenSettings = { [weak self] in self?.preferences.openQuotaAlerts() }
        resetNewsMonitor.onStateChange = { [weak self] state in
            guard let self, self.lifecycle.acceptsCallbacks else { return }
            self.display.receiveNews(state)
        }
        resetNewsMonitor.onOpenDetails = { [weak self] ids in self?.display.openResetNews(itemIDs: ids) }
        appUpdater.onInstall = { [weak self] in self?.lifecycle.quit(reason: .update) }
        appUpdater.onStateChange = { [weak self] in
            guard let self, self.lifecycle.acceptsCallbacks else { return }
            self.menu.updateMenuState(); self.display.renderDisplayState(); self.preferences.updateAppUpdate()
        }
        appUpdater.onProgressChange = { [weak self] in
            guard let self, self.lifecycle.acceptsCallbacks else { return }
            self.menu.updateUpdateMenuItems(); self.preferences.updateAppUpdate()
        }
        taskMonitor.onUpdate = { [weak self] status in
            guard let self, self.lifecycle.acceptsCallbacks else { return }
            self.display.receiveTask(status); self.taskMonitor.recordDisplaySubmission()
        }
        taskMonitor.onDiagnosticSnapshot = { [weak self] reference in
            guard let self, self.lifecycle.acceptsCallbacks else { return }
            self.display.receiveDiagnosticSnapshot(reference)
        }
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
        if notification.name == NSWorkspace.didWakeNotification { lifecycle.didWake() }
        display.environmentChanged()
    }
    @objc private func suspendPanels(_ notification: Notification) {
        if notification.name.rawValue == "com.apple.screenIsLocked" { lifecycle.screenLocked(true) }
        if notification.name == NSWorkspace.willSleepNotification { lifecycle.didSleep() }
        if notification.name == NSWorkspace.sessionDidResignActiveNotification { lifecycle.sessionInactive(true) }
    }
    @objc private func resumePanels(_ notification: Notification) {
        if notification.name.rawValue == "com.apple.screenIsUnlocked" { lifecycle.screenLocked(false) }
        if notification.name == NSWorkspace.sessionDidBecomeActiveNotification { lifecycle.sessionInactive(false) }
    }
    func rateLimitStore(_ store: RateLimitStore, didUpdate state: RateLimitDisplayState) {
        guard lifecycle.acceptsCallbacks else { return }
        if state.errorMessage != nil || state.lastUpdated == nil { quotaAlerts.invalidateBaseline() }
        else if !state.isRefreshing { quotaAlerts.update(state: state, accountKey: store.verifiedAccountKey, limitID: store.currentLimitID) }
        display.receiveQuota(state)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        lifecycle.applicationShouldTerminate(sender)
    }
    func applicationWillTerminate(_ notification: Notification) { lifecycle.stop() }
}
