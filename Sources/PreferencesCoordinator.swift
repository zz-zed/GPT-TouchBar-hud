import AppKit

final class PreferencesCoordinator {
    private let touchBarHardware: TouchBarHardware
    private let appUpdater: AppUpdater
    private let resetNewsMonitor: ResetNewsMonitor
    private let quotaAlerts: QuotaAlertMonitor
    private var isStopped = false
    private var preferences: PreferencesWindowController?
    private var hookPreferences: HookExperimentPreferencesController?
    private var connectionDiagnostics: ConnectionDiagnosticsWindowController?
    private var autoLaunchError: String?
    private var autoLaunchBusy = false
    private var hudAppearance = HUDAppearance.load()
    private var latestResetNewsState = ResetNewsViewState()
    var onAppearance: ((HUDAppearance) -> Void)?
    var onQuit: (() -> Void)?
    var onDisplayMode: ((HUDDisplayMode) -> Void)?
    var onMenuMode: ((MenuBarDisplayMode) -> Void)?
    var onAlwaysShowQuota: ((Bool) -> Void)?
    var onVisibility: ((Bool) -> Void)?
    var onLanguage: (() -> Void)?
    var onTaskStatus: ((Bool) -> Void)?
    var onPersistent: ((Bool) -> Void)?
    var onHookModeChanged: (() -> Void)?
    var onNeedsDisplayRefresh: (() -> Void)?

    init(touchBarHardware: TouchBarHardware, appUpdater: AppUpdater,
         resetNewsMonitor: ResetNewsMonitor, quotaAlerts: QuotaAlertMonitor) {
        self.touchBarHardware = touchBarHardware; self.appUpdater = appUpdater
        self.resetNewsMonitor = resetNewsMonitor; self.quotaAlerts = quotaAlerts
    }
    func start() { isStopped = false }
    func stop() {
        isStopped = true
        preferences?.close(); hookPreferences?.close(); connectionDiagnostics?.close()
    }
    func update(snapshot: AppDisplaySnapshot, appearance: HUDAppearance, taskEnabled: Bool,
                persistentEnabled: Bool, persistentAvailable: Bool) {
        hudAppearance = appearance; latestResetNewsState = snapshot.news
        preferences?.update(appearance: appearance, state: snapshot.state, taskEnabled: taskEnabled,
            persistentEnabled: persistentEnabled, persistentAvailable: persistentAvailable, appUpdate: appUpdater.viewState)
        preferences?.updateAutoLaunch(enabled: HostAutoLauncher.isEnabled, error: autoLaunchError, busy: autoLaunchBusy)
        preferences?.updateResetNews(snapshot.news, soundEnabled: resetNewsMonitor.soundEnabled)
        updateQuotaAlertPreferences()
    }
    func updateAppUpdate() { preferences?.updateAppUpdate(appUpdater.viewState); updateUpdateNotificationPreferences() }
    func openResetNews() { guard !isStopped else { return }; openPreferences(nil); preferences?.showResetNewsTab() }
    func openQuotaAlerts() { guard !isStopped else { return }; openPreferences(nil); preferences?.showQuotaAlertsTab() }
    func openPreferences(_ sender: AnyObject?) {
        guard !isStopped else { return }
        if preferences == nil {
            let controller = PreferencesWindowController(appearance: hudAppearance, touchBarHardware: touchBarHardware)
            controller.onAppearance = { [weak self] appearance in guard self?.isStopped == false else { return };
                self?.onAppearance?(appearance)
            }
            controller.onQuit = { [weak self] in guard self?.isStopped == false else { return }; self?.onQuit?() }
            controller.onDisplayMode = { [weak self] mode in guard self?.isStopped == false else { return }; self?.onDisplayMode?(mode) }
            controller.onMenuMode = { [weak self] mode in guard self?.isStopped == false else { return }; self?.onMenuMode?(mode) }
            controller.onAlwaysShowQuota = { [weak self] enabled in guard self?.isStopped == false else { return };
                UserDefaults.standard.set(enabled, forKey: NotchPresentationModel.alwaysShowKey)
                self?.onAlwaysShowQuota?(enabled)
            }
            controller.onVisibility = { [weak self] visible in guard self?.isStopped == false else { return };
                self?.onVisibility?(visible)
            }
            controller.onLanguage = { [weak self] language in guard self?.isStopped == false else { return };
                DisplayLanguage.current = language
                self?.onLanguage?()
            }
            controller.onHookExperiment = { [weak self] in guard self?.isStopped == false else { return }; self?.openHookPreferences() }
            controller.onTaskStatus = { [weak self] enabled in guard self?.isStopped == false else { return }; self?.onTaskStatus?(enabled) }
            controller.onPersistent = { [weak self] enabled in guard self?.isStopped == false else { return };
                self?.onPersistent?(enabled)
            }
            controller.onAutomaticUpdates = { [weak self] enabled in guard self?.isStopped == false else { return };
                self?.appUpdater.setAutomaticChecksEnabled(enabled)
            }
            controller.onUpdateNotifications = { [weak self] enabled in guard self?.isStopped == false else { return };
                self?.appUpdater.setNotificationsEnabled(enabled, userInitiated: true)
            }
            controller.onAuthorizeUpdateNotifications = { [weak self] in guard self?.isStopped == false else { return };
                self?.appUpdater.setNotificationsEnabled(true, userInitiated: true)
            }
            controller.onCheckForUpdates = { [weak self] in guard self?.isStopped == false else { return }; self?.appUpdater.check() }
            controller.onViewUpdate = { [weak self] in guard self?.isStopped == false else { return }; self?.appUpdater.presentAvailableUpdate() }
            controller.onViewUpdateProgress = { [weak self] in guard self?.isStopped == false else { return }; self?.appUpdater.presentInstallationProgress() }
            controller.onResetNewsEnabled = { [weak self] enabled in guard self?.isStopped == false else { return }; self?.resetNewsMonitor.setEnabled(enabled) }
            controller.onResetNewsSound = { [weak self] enabled in guard self?.isStopped == false else { return };
                self?.resetNewsMonitor.setSoundEnabled(enabled)
                self?.onNeedsDisplayRefresh?()
            }
            controller.onCheckResetNews = { [weak self] in guard self?.isStopped == false else { return }; self?.resetNewsMonitor.checkNow() }
            controller.onQuotaAlerts = { [weak self] configuration in guard self?.isStopped == false else { return };
                self?.quotaAlerts.configure(configuration)
                self?.updateQuotaAlertPreferences()
            }
            controller.onAutoLaunch = { [weak self] enabled in guard self?.isStopped == false else { return };
                self?.configureAutoLaunch(enabled: enabled)
            }
            controller.onConnectionDiagnostics = { [weak self] in guard self?.isStopped == false else { return };
                guard let self else { return }
                if self.connectionDiagnostics == nil { self.connectionDiagnostics = ConnectionDiagnosticsWindowController() }
                self.connectionDiagnostics?.showAndCheck()
            }
            preferences = controller
        }
        onNeedsDisplayRefresh?()
        quotaAlerts.refreshPermission()
        appUpdater.refreshNotificationPermission()
        updateUpdateNotificationPreferences()
        preferences?.updateResetNews(latestResetNewsState, soundEnabled: resetNewsMonitor.soundEnabled)
        NSApp.activate(ignoringOtherApps: true)
        preferences?.showWindow(sender)
        preferences?.window?.makeKeyAndOrderFront(sender)
    }

    func openHookPreferences() {
        guard !isStopped else { return }
        if hookPreferences == nil {
            let controller = HookExperimentPreferencesController()
            controller.onModeChange = { [weak self] _ in guard self?.isStopped == false else { return };
                guard let self else { return }
                self.onHookModeChanged?()
            }
            hookPreferences = controller
        }
        hookPreferences?.showWindow(nil)
        hookPreferences?.window?.makeKeyAndOrderFront(nil)
    }

    func configureAutoLaunch(enabled: Bool? = nil) {
        guard !autoLaunchBusy else { return }
        autoLaunchBusy = true
        preferences?.updateAutoLaunch(enabled: HostAutoLauncher.isEnabled, error: autoLaunchError, busy: true)
        let completion: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.autoLaunchBusy = false
            switch result {
            case .success: self.autoLaunchError = nil
            case .failure(let error): self.autoLaunchError = error.localizedDescription
            }
            self.preferences?.updateAutoLaunch(enabled: HostAutoLauncher.isEnabled, error: self.autoLaunchError)
        }
        if let enabled { HostAutoLauncher.setEnabled(enabled, completion: completion) }
        else { HostAutoLauncher.installOrUpdate(completion: completion) }
    }

    func updateQuotaAlertPreferences() {
        preferences?.updateQuotaAlerts(quotaAlerts.configuration, permission: quotaAlerts.permission)
    }

    func updateUpdateNotificationPreferences() {
        preferences?.updateUpdateNotifications(enabled: appUpdater.notificationsEnabled, permission: appUpdater.notificationPermission)
    }

}
