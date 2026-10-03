import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate, RateLimitStoreDelegate {
    private let touchBarHardware = TouchBarHardware.current
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = RateLimitStore()
    private let appUpdater = AppUpdater()
    private let taskMonitor = TaskMonitoringCoordinator()
    private let resetNewsMonitor = ResetNewsMonitor()
    private let quotaAlerts = QuotaAlertMonitor()
    private var connectionDiagnostics: ConnectionDiagnosticsWindowController?
    private var autoLaunchError: String?
    private var latestResetNewsState = ResetNewsViewState()
    private var resetNewsRuntimeRunning = false
    private lazy var resetNewsPopover: ResetNewsPopoverController = {
        let controller = ResetNewsPopoverController()
        controller.model.onCheck = { [weak self] in self?.resetNewsMonitor.checkNow() }
        controller.model.onMarkAllRead = { [weak self] in self?.resetNewsMonitor.markAllRead() }
        controller.model.onSettings = { [weak self] in self?.openResetNewsPreferences() }
        controller.model.onVisibleItem = { [weak self] id in self?.resetNewsMonitor.markRead([id]) }
        return controller
    }()
    private var hookPreferences: HookExperimentPreferencesController?
    private lazy var completionFeedback: TaskCompletionFeedbackController = {
        let controller = TaskCompletionFeedbackController()
        controller.onExpiration = { [weak self] in self?.renderDisplayState() }
        return controller
    }()
    private var latestQuotaState = RateLimitDisplayState.initial
    private var latestTaskStatus: TaskStatusSummary?
    private var taskStatusEnabled: Bool {
        UserDefaults.standard.object(forKey: "taskStatusEnabled") as? Bool ?? true
    }
    private let lifecycleMonitor = HostLifecycleMonitor()
    private var hudPreferences = HUDPresentationPreferences()
    private var hudDisplayMode: HUDDisplayMode {
        get { hudPreferences.mode }
        set { hudPreferences.mode = newValue; hudPreferences.save() }
    }
    private var hudRequestedVisible: Bool {
        get { hudPreferences.isVisible }
        set { hudPreferences.isVisible = newValue; hudPreferences.save() }
    }
    private var menuDisplayMode = MenuBarDisplayMode.load()
    private var displayTarget = DisplayTargetResolver()
    private var screenLocked = false
    private var systemSleeping = false
    private var sessionInactive = false
    private var sessionSuspended: Bool { screenLocked || systemSleeping || sessionInactive }
    private lazy var notchHUD: NotchHUDController = {
        let controller = NotchHUDController()
        controller.onRefresh = { [weak self] in self?.refreshQuotaNow() }
        controller.onSettings = { [weak self] in self?.openPreferences(nil) }
        controller.onHide = { [weak self] in self?.closeHUD() }
        controller.onVisibilityChanged = { [weak self] in self?.renderDisplayState() }
        controller.onCheckMessages = { [weak self] in self?.resetNewsMonitor.checkNow() }
        controller.onMarkAllMessagesRead = { [weak self] in self?.resetNewsMonitor.markAllRead() }
        controller.onMessageSettings = { [weak self] in self?.openResetNewsPreferences() }
        controller.onVisibleMessage = { [weak self] id in self?.resetNewsMonitor.markRead([id]) }
        return controller
    }()
    private var hudAppearance = HUDAppearance.load()
    private var hudVisibilityMenuItem: NSMenuItem?
    private var persistentTouchBarMenuItem: NSMenuItem?
    private var availableUpdateMenuItem: NSMenuItem?
    private var updateMenuSeparator: NSMenuItem?
    private var checkUpdatesMenuItem: NSMenuItem?
    private var updateProgressMenuItem: NSMenuItem?
    private var menuTaskAppearance: TaskStatusAppearance = .idle
    private lazy var persistentTouchBar = PersistentTouchBarController()
    private var summaryMenuItem: NSMenuItem?
    private var collapseDetailsMenuItem: NSMenuItem?
    private var preferences: PreferencesWindowController?
    private lazy var hudController = CompactHUDViewController(
        initialAppearance: hudAppearance,
        onRefresh: { [weak self] in
            self?.refreshQuotaNow()
        },
        onClose: { [weak self] in
            self?.closeHUD()
        },
        onPresentTouchBar: { [weak self] in
            self?.persistentTouchBar.presentNow() ?? false
        },
        contextMenuProvider: { [weak self] in
            self?.makeHUDContextMenu() ?? NSMenu()
        }
    )
    private lazy var hudWindow = CompactHUDPanel(contentViewController: hudController)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        LegacyAppMigration.terminateLegacyApplications()
        hudPreferences.applyStartupVisibility(hasGeometry: !DisplayTargetResolver.candidates().isEmpty)

        store.delegate = self
        quotaAlerts.onStateChange = { [weak self] in self?.updateQuotaAlertPreferences() }
        quotaAlerts.onOpenSettings = { [weak self] in
            self?.openPreferences(nil)
            self?.preferences?.showQuotaAlertsTab()
        }
        resetNewsRuntimeRunning = true
        resetNewsMonitor.onStateChange = { [weak self] state in
            self?.latestResetNewsState = state
            self?.renderResetNews()
        }
        resetNewsMonitor.onOpenDetails = { [weak self] ids in self?.openResetNews(itemIDs: ids) }
        latestResetNewsState = resetNewsMonitor.state
        hudController.onOpenMessages = { [weak self] in
            guard let self else { return }
            self.openResetNews(relativeTo: self.hudController.messageAnchorView)
        }
        hudController.onOpenTouchBarMessages = { [weak self] in self?.openResetNews() }
        persistentTouchBar.onOpenMessages = { [weak self] in self?.openResetNews() }
        appUpdater.onInstall = { [weak self] in self?.quitApp() }
        appUpdater.onStateChange = { [weak self] in self?.updateUpdatePresentation() }
        appUpdater.onProgressChange = { [weak self] in
            guard let self else { return }
            self.updateUpdateMenuItems()
            self.preferences?.updateAppUpdate(self.appUpdater.viewState)
        }
        taskMonitor.onUpdate = { [weak self] status in
            guard let self else { return }
            self.latestTaskStatus = status
            self.completionFeedback.receive(status, enabled: self.taskStatusEnabled)
            self.renderDisplayState()
        }
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
        configureStatusItem()
        configureLifecycleMonitor()
        if case .failure(let error) = HostAutoLauncher.installOrUpdate() {
            autoLaunchError = error.localizedDescription
        }
        HostAutoLauncher.clearManualQuitLock()

        taskMonitor.prepareForHost(displayEnabled: taskStatusEnabled)
        lifecycleMonitor.start()
        updateResetNewsGate()
        renderResetNews()

        if lifecycleMonitor.hostIsRunningNow() {
            hostDidStart()
        } else {
            if hudRequestedVisible { presentSelectedHUD() }
            renderDisplayState() // Preserve the coordinator's explicit unavailable/disabled state.
        }
        appUpdater.startAutomaticChecks()
        AppUpdateProgressChannel.acknowledgeLaunch(arguments: ProcessInfo.processInfo.arguments,
            bundleURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier,
            version: AppUpdater.version)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPreferences(nil)
        return false
    }

    @objc private func screenConfigurationChanged() {
        notchHUD.environmentChanged()
        if hudRequestedVisible && !sessionSuspended { presentSelectedHUD() }
        renderDisplayState()
    }

    @objc private func frontApplicationChanged() { notchHUD.environmentChanged() }
    @objc private func spaceOrWakeChanged(_ notification: Notification) {
        if notification.name == NSWorkspace.didWakeNotification {
            systemSleeping = false
            taskMonitor.resume()
            appUpdater.didWake()
            updateResetNewsGate()
        }
        screenConfigurationChanged()
    }
    @objc private func suspendPanels(_ notification: Notification) {
        if notification.name.rawValue == "com.apple.screenIsLocked" { screenLocked = true }
        if notification.name == NSWorkspace.willSleepNotification { systemSleeping = true; taskMonitor.suspend() }
        if notification.name == NSWorkspace.sessionDidResignActiveNotification { sessionInactive = true }
        notchHUD.hide()
        hudWindow.orderOut(nil)
        resetNewsPopover.close()
        updateResetNewsGate()
        renderDisplayState()
    }
    @objc private func resumePanels(_ notification: Notification) {
        if notification.name.rawValue == "com.apple.screenIsUnlocked" { screenLocked = false }
        if notification.name == NSWorkspace.sessionDidBecomeActiveNotification { sessionInactive = false }
        updateResetNewsGate()
        screenConfigurationChanged()
    }
    private var summaryState = RateLimitDisplayState.initial
    private var statusMenuOpen = false
    func menuWillOpen(_ menu: NSMenu) {
        notchHUD.collapse()
        statusMenuOpen = true
        collapseDetailsMenuItem?.isHidden = !notchHUD.isExpanded
        let summary = summaryMenuItem?.view as? StatusSummaryView
        summary?.update(summaryState, news: latestResetNewsState)
    }
    func menuDidClose(_ menu: NSMenu) {
        statusMenuOpen = false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard appUpdater.canQuit else { appUpdater.presentInstallationProgress(); return .terminateCancel }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        quotaAlerts.suspend()
        completionFeedback.reset()
        stopResetNews()
        notchHUD.hide()
        taskMonitor.stop()
        persistentTouchBar.stop()
        lifecycleMonitor.stop()
        store.stop()
        appUpdater.stop()
    }

    func rateLimitStore(_ store: RateLimitStore, didUpdate state: RateLimitDisplayState) {
        latestQuotaState = state
        if state.errorMessage != nil || state.lastUpdated == nil {
            quotaAlerts.invalidateBaseline()
        } else if !state.isRefreshing {
            quotaAlerts.update(state: state, accountKey: store.verifiedAccountKey, limitID: store.currentLimitID)
        }
        renderDisplayState()
    }

    private func renderDisplayState() {
        var state = latestQuotaState
        state.taskStatus = taskStatusEnabled ? completionFeedback.applying(to: latestTaskStatus) : nil
        updateStatusTitle(with: state)
        hudController.update(with: state)
        notchHUD.update(state, taskDisplayEnabled: taskStatusEnabled)
        persistentTouchBar.update(with: state)
        summaryState = state
        if statusMenuOpen { (summaryMenuItem?.view as? StatusSummaryView)?.update(state, news: latestResetNewsState) }
        preferences?.update(appearance: hudAppearance, state: state, taskEnabled: taskStatusEnabled, persistentEnabled: persistentTouchBar.isEnabled, persistentAvailable: persistentTouchBar.isAvailable, appUpdate: appUpdater.viewState)
        preferences?.updateAutoLaunch(enabled: HostAutoLauncher.isEnabled, error: autoLaunchError)
        updateQuotaAlertPreferences()
    }

    private func updateQuotaAlertPreferences() {
        preferences?.updateQuotaAlerts(quotaAlerts.configuration, permission: quotaAlerts.permission)
    }

    private func renderResetNews() {
        let state = latestResetNewsState
        let available = state.enabled || !state.items.isEmpty
        if statusMenuOpen {
            (summaryMenuItem?.view as? StatusSummaryView)?.update(summaryState, news: state)
        }
        hudController.updateMessages(forecastCount: state.forecastCount, available: available)
        persistentTouchBar.updateMessages(forecastCount: state.forecastCount, available: available)
        notchHUD.updateResetNews(state)
        resetNewsPopover.update(state)
        preferences?.updateResetNews(state, soundEnabled: resetNewsMonitor.soundEnabled)
    }

    private func updateResetNewsGate() {
        if sessionSuspended || !lifecycleMonitor.hostIsRunningNow() { quotaAlerts.suspend() }
        else { quotaAlerts.resume() }
        resetNewsMonitor.updateGate(codexRunning: lifecycleMonitor.codexIsRunningNow(),
            hudRunning: resetNewsRuntimeRunning, suspended: sessionSuspended)
    }

    private func stopResetNews() {
        resetNewsRuntimeRunning = false
        resetNewsMonitor.stop()
        resetNewsPopover.close()
    }

    private func openResetNews(relativeTo source: NSView? = nil, itemIDs: [String] = []) {
        guard !sessionSuspended, let anchor = source.flatMap({ $0.window?.isVisible == true && $0.window?.isOnActiveSpace == true && !$0.isHidden ? $0 : nil }) ?? statusItem.button else { return }
        resetNewsPopover.update(latestResetNewsState)
        resetNewsPopover.show(relativeTo: anchor, itemIDs: itemIDs)
    }

    @objc private func openResetNewsFromMenu(_ sender: AnyObject?) {
        let anchor = (sender as? NSMenuItem)?.representedObject as? NSView
        DispatchQueue.main.async { [weak self] in self?.openResetNews(relativeTo: anchor) }
    }

    @objc private func openMenuForecast() {
        guard latestResetNewsState.forecastCount > 0, !sessionSuspended else { return }
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self, let anchor = self.statusItem.button, !self.sessionSuspended else { return }
            self.resetNewsPopover.update(self.latestResetNewsState)
            self.resetNewsPopover.show(relativeTo: anchor, onBack: { [weak self] in
                guard let self, !self.sessionSuspended else { return }
                DispatchQueue.main.async { [weak self] in self?.statusItem.button?.performClick(nil) }
            })
        }
    }

    private func openResetNewsPreferences() {
        resetNewsPopover.close()
        notchHUD.collapse(animated: false)
        openPreferences(nil)
        preferences?.showResetNewsTab()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.image = NSImage(systemSymbolName: "bolt.horizontal.circle.fill", accessibilityDescription: AppIdentity.productName)
        button.imagePosition = .imageLeft
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.title = " --"
        button.toolTip = "\(AppIdentity.productName) 额度"

        statusItem.menu = makeStatusMenu()
        updateMenuState()
    }

    private func menuAction(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let summary = NSMenuItem()
        var state = latestQuotaState
        state.taskStatus = taskStatusEnabled ? completionFeedback.applying(to: latestTaskStatus) : nil
        let summaryView = StatusSummaryView(state: state)
        summaryView.update(state, news: latestResetNewsState)
        summaryView.onRefresh = { [weak self] in self?.refreshQuotaNow() }
        summaryView.onForecast = { [weak self] in self?.openMenuForecast() }
        summary.view = summaryView
        summaryState = state
        summaryMenuItem = summary
        menu.addItem(summary)
        menu.addItem(.separator())
        let available = menuAction("", #selector(viewAvailableAppUpdate(_:)))
        availableUpdateMenuItem = available
        menu.addItem(available)
        let updateSeparator = NSMenuItem.separator()
        updateMenuSeparator = updateSeparator
        menu.addItem(updateSeparator)
        // The visible refresh control lives in the summary; keep the menu shortcut available.
        let refresh = menuAction("刷新额度", #selector(refreshQuotaFromMenu(_:)), key: "r")
        refresh.isHidden = true
        refresh.allowsKeyEquivalentWhenHidden = true
        menu.addItem(refresh)
        let forecastShortcut = menuAction("查看重置预告", #selector(openMenuForecast), key: "p")
        forecastShortcut.keyEquivalentModifierMask = [.command, .shift]
        forecastShortcut.isHidden = true
        forecastShortcut.allowsKeyEquivalentWhenHidden = true
        menu.addItem(forecastShortcut)
        let visibility = menuAction("显示浮窗", #selector(toggleHUDWindow(_:)))
        hudVisibilityMenuItem = visibility
        menu.addItem(visibility)
        let collapse = menuAction("收起详情", #selector(collapseNotch(_:)))
        collapse.isHidden = !notchHUD.isExpanded
        collapseDetailsMenuItem = collapse
        menu.addItem(collapse)
        let displayPreferences = NSMenuItem(title: "显示与偏好", action: nil, keyEquivalent: "")
        let preferencesMenu = NSMenu()
        displayPreferences.submenu = preferencesMenu
        let forms = NSMenuItem(title: "显示形式", action: nil, keyEquivalent: "")
        forms.submenu = NSMenu()
        for (index, mode) in HUDDisplayMode.allCases.enumerated() {
            let item = menuAction(mode.title, #selector(selectDisplayMode(_:)))
            item.tag = index
            forms.submenu?.addItem(item)
        }
        preferencesMenu.addItem(forms)
        let menuModes = NSMenuItem(title: "菜单栏内容", action: nil, keyEquivalent: "")
        menuModes.submenu = NSMenu()
        for (index, mode) in MenuBarDisplayMode.allCases.enumerated() {
            let item = menuAction(mode.title, #selector(selectMenuMode(_:)))
            item.tag = index
            menuModes.submenu?.addItem(item)
        }
        preferencesMenu.addItem(menuModes)
        if touchBarHardware.shouldShowSettings {
            let persistent = makePersistentTouchBarMenuItem()
            persistentTouchBarMenuItem = persistent
            preferencesMenu.addItem(persistent)
        }
        preferencesMenu.addItem(.separator())
        preferencesMenu.addItem(menuAction("设置…", #selector(openPreferences(_:)), key: ","))
        menu.addItem(displayPreferences)
        addUpdateMenuItems(to: menu)
        menu.addItem(menuAction("退出", #selector(quitFromMenu(_:)), key: "q"))
        return menu
    }

    private func makeHUDContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuAction("刷新额度", #selector(refreshQuotaFromMenu(_:)), key: "r"))
        let forecasts = menuAction(ResetForecastIndicator.accessibilityLabel(latestResetNewsState.forecastCount), #selector(openResetNewsFromMenu(_:)))
        forecasts.representedObject = hudController.messageAnchorView
        menu.addItem(forecasts)
        menu.addItem(menuAction("隐藏浮窗", #selector(hideHUDFromContextMenu(_:))))
        menu.addItem(.separator())
        menu.addItem(menuAction("设置…", #selector(openPreferences(_:)), key: ","))
        return menu
    }

    @objc private func openPreferences(_ sender: AnyObject?) {
        if preferences == nil {
            let controller = PreferencesWindowController(appearance: hudAppearance, touchBarHardware: touchBarHardware)
            controller.onAppearance = { [weak self] appearance in
                self?.hudAppearance = appearance
                self?.applyHUDAppearance()
            }
            controller.onQuit = { [weak self] in self?.quitApp() }
            controller.onDisplayMode = { [weak self] mode in self?.setDisplayMode(mode) }
            controller.onMenuMode = { [weak self] mode in self?.setMenuMode(mode) }
            controller.onAlwaysShowQuota = { [weak self] enabled in
                UserDefaults.standard.set(enabled, forKey: NotchPresentationModel.alwaysShowKey)
                self?.notchHUD.setAlwaysShowQuota(enabled)
            }
            controller.onVisibility = { [weak self] visible in
                if visible { self?.showHUDWindow() } else { self?.closeHUD() }
            }
            controller.onLanguage = { [weak self] language in
                DisplayLanguage.current = language
                self?.renderDisplayState()
                self?.renderResetNews()
            }
            controller.onHookExperiment = { [weak self] in self?.openHookPreferences() }
            controller.onTaskStatus = { [weak self] enabled in self?.setTaskStatusEnabled(enabled) }
            controller.onPersistent = { [weak self] enabled in
                self?.persistentTouchBar.setEnabled(enabled)
                self?.updateMenuState()
                self?.renderDisplayState()
            }
            controller.onAutomaticUpdates = { [weak self] enabled in
                self?.appUpdater.setAutomaticChecksEnabled(enabled)
            }
            controller.onUpdateNotifications = { [weak self] enabled in
                self?.appUpdater.setNotificationsEnabled(enabled, userInitiated: true)
            }
            controller.onAuthorizeUpdateNotifications = { [weak self] in
                self?.appUpdater.setNotificationsEnabled(true, userInitiated: true)
            }
            controller.onCheckForUpdates = { [weak self] in self?.appUpdater.check() }
            controller.onViewUpdate = { [weak self] in self?.appUpdater.presentAvailableUpdate() }
            controller.onViewUpdateProgress = { [weak self] in self?.appUpdater.presentInstallationProgress() }
            controller.onResetNewsEnabled = { [weak self] enabled in self?.resetNewsMonitor.setEnabled(enabled) }
            controller.onResetNewsSound = { [weak self] enabled in
                self?.resetNewsMonitor.setSoundEnabled(enabled)
                self?.renderResetNews()
            }
            controller.onCheckResetNews = { [weak self] in self?.resetNewsMonitor.checkNow() }
            controller.onQuotaAlerts = { [weak self] configuration in
                self?.quotaAlerts.configure(configuration)
                self?.updateQuotaAlertPreferences()
            }
            controller.onAutoLaunch = { [weak self] enabled in
                guard let self else { return }
                switch HostAutoLauncher.setEnabled(enabled) {
                case .success: self.autoLaunchError = nil
                case .failure(let error): self.autoLaunchError = error.localizedDescription
                }
                self.preferences?.updateAutoLaunch(enabled: HostAutoLauncher.isEnabled, error: self.autoLaunchError)
            }
            controller.onConnectionDiagnostics = { [weak self] in
                guard let self else { return }
                if self.connectionDiagnostics == nil { self.connectionDiagnostics = ConnectionDiagnosticsWindowController() }
                self.connectionDiagnostics?.showAndCheck()
            }
            preferences = controller
        }
        renderDisplayState()
        quotaAlerts.refreshPermission()
        appUpdater.refreshNotificationPermission()
        updateUpdateNotificationPreferences()
        preferences?.updateResetNews(latestResetNewsState, soundEnabled: resetNewsMonitor.soundEnabled)
        NSApp.activate(ignoringOtherApps: true)
        preferences?.showWindow(sender)
        preferences?.window?.makeKeyAndOrderFront(sender)
    }

    private func openHookPreferences() {
        if hookPreferences == nil {
            let controller = HookExperimentPreferencesController()
            controller.onModeChange = { [weak self] _ in
                guard let self else { return }
                self.restartTaskMonitoring()
            }
            hookPreferences = controller
        }
        hookPreferences?.showWindow(nil)
        hookPreferences?.window?.makeKeyAndOrderFront(nil)
    }

    private func makePersistentTouchBarMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Touch Bar 常驻", action: #selector(togglePersistentTouchBar(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = persistentTouchBar.isAvailable
        item.state = persistentTouchBar.usesSystemPresentation ? .on : .off
        item.toolTip = persistentTouchBar.isAvailable
            ? "完整额度条在切换 App 后继续显示；关闭后恢复当前 App 的 Touch Bar。"
            : "当前系统不提供常驻接口，点击浮窗后可使用普通 Touch Bar 显示。"
        return item
    }

    @objc private func togglePersistentTouchBar(_ sender: NSMenuItem) {
        persistentTouchBar.setEnabled(!persistentTouchBar.isEnabled)
        updateMenuState()
        renderDisplayState()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(openMenuForecast) { return latestResetNewsState.forecastCount > 0 }

        if menuItem.action == #selector(selectDisplayMode(_:)) {
            menuItem.state = HUDDisplayMode.allCases[menuItem.tag] == hudDisplayMode ? .on : .off
        }
        if menuItem.action == #selector(selectMenuMode(_:)) {
            menuItem.state = MenuBarDisplayMode.allCases[menuItem.tag] == menuDisplayMode ? .on : .off
        }
        if menuItem.action == #selector(collapseNotch(_:)) {
            menuItem.isHidden = !notchHUD.isExpanded
            return notchHUD.isExpanded
        }
        if menuItem.action == #selector(refreshQuotaFromMenu(_:)) {
            menuItem.title = latestQuotaState.isRefreshing ? "正在刷新…" : "刷新额度"
            return !latestQuotaState.isRefreshing
        }
        if menuItem.action == #selector(checkForAppUpdates(_:)) {
            updateUpdateMenuItems()
            return appUpdater.canCheck
        }
        if menuItem.action == #selector(viewAppUpdateProgress(_:)) { return appUpdater.viewState.progress != nil }
        if menuItem.action == #selector(viewAvailableAppUpdate(_:)) {
            guard let version = appUpdater.viewState.availableVersion else { return false }
            AppUpdateMenuPresentation.apply(to: menuItem, version: version, enabled: appUpdater.canCheck)
            return appUpdater.canCheck
        }
        if menuItem.action == #selector(togglePersistentTouchBar(_:)) {
            menuItem.state = persistentTouchBar.usesSystemPresentation ? .on : .off
            return persistentTouchBar.isAvailable
        }
        return true
    }

    private func addUpdateMenuItems(to menu: NSMenu) {
        let progress = NSMenuItem(title: "查看更新进度…", action: #selector(viewAppUpdateProgress(_:)), keyEquivalent: "")
        progress.target = self
        updateProgressMenuItem = progress
        menu.addItem(progress)
        let check = NSMenuItem(title: "检查更新…", action: #selector(checkForAppUpdates(_:)), keyEquivalent: "")
        check.target = self
        check.toolTip = AppUpdater.versionLabel
        checkUpdatesMenuItem = check
        menu.addItem(check)
        updateUpdateMenuItems()
        menu.addItem(.separator())
    }

    @objc private func checkForAppUpdates(_ sender: AnyObject?) { appUpdater.check() }
    @objc private func viewAppUpdateProgress(_ sender: AnyObject?) { appUpdater.presentInstallationProgress() }
    @objc private func viewAvailableAppUpdate(_ sender: AnyObject?) { appUpdater.presentAvailableUpdate() }

    private func configureLifecycleMonitor() {
        lifecycleMonitor.onCodexStarted = { [weak self] in self?.updateResetNewsGate() }
        lifecycleMonitor.onCodexStopped = { [weak self] in self?.updateResetNewsGate() }
        lifecycleMonitor.onHostStarted = { [weak self] in
            self?.hostDidStart()
        }

        lifecycleMonitor.onHostStopped = { [weak self] in
            self?.hostDidStop()
        }
    }

    private func updateStatusTitle(with state: RateLimitDisplayState) {
        guard let button = statusItem.button else {
            return
        }
        let task = state.displayedTaskStatus
        let appearance = TaskStatusAppearance(task)
        if menuTaskAppearance != appearance {
            button.image = appearance.menuIcon()
            menuTaskAppearance = appearance
        }

        var tooltipParts: [String] = []

        if let fiveHour = state.fiveHour {
            tooltipParts.append("5 小时剩余 \(fiveHour.remainingText)")
        } else if let resetCredits = state.resetCredits, resetCredits.availableCount > 0 {
            tooltipParts.append("可重置 \(resetCredits.availableCount) 次，\(resetCredits.expirationText)")
        }

        if let weekly = state.weekly {
            tooltipParts.append("周限额剩余 \(weekly.remainingText)")
        }

        var tooltip: String
        if !tooltipParts.isEmpty {
            tooltip = "\(AppIdentity.productName) 额度：\(tooltipParts.joined(separator: "，"))"
        } else if state.isRefreshing {
            tooltip = "\(AppIdentity.productName) 额度：正在刷新"
        } else {
            tooltip = state.errorMessage ?? "\(AppIdentity.productName) 额度"
        }
        if let usage = state.tokenUsage {
            tooltip += "\n\(usage.yesterdayText)；\(usage.cumulativeText)\n\(usage.toolTip)"
        }
        if let task {
            tooltip += "\n" + task.label + "\n" + task.detail
        }
        let availableVersion = appUpdater.viewState.availableVersion
        let updateLabel = availableVersion.map { " · 新版本 \($0) 可用" } ?? ""
        button.toolTip = tooltip + updateLabel
        button.setAccessibilityLabel(AppIdentity.productName + (task.map { " · " + $0.label } ?? "") + updateLabel)

        let presentation = MenuBarPresentation(state: state, mode: menuDisplayMode, panelVisible: notchHUD.isVisible || hudWindow.isVisible, hasUpdate: availableVersion != nil)
        presentation.apply(to: statusItem)
    }

    private func setDisplayMode(_ mode: HUDDisplayMode) {
        hudDisplayMode = mode
        notchHUD.environmentChanged()
        if hudRequestedVisible && !sessionSuspended { presentSelectedHUD() }
        renderDisplayState()
    }
    private func setMenuMode(_ mode: MenuBarDisplayMode) {
        menuDisplayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: MenuBarDisplayMode.defaultsKey)
        renderDisplayState()
    }
    @objc private func selectDisplayMode(_ sender: NSMenuItem) { setDisplayMode(HUDDisplayMode.allCases[sender.tag]) }
    @objc private func selectMenuMode(_ sender: NSMenuItem) { setMenuMode(MenuBarDisplayMode.allCases[sender.tag]) }
    @objc private func collapseNotch(_ sender: AnyObject?) { notchHUD.collapse() }

    @objc private func toggleHUDWindow(_ sender: AnyObject?) {
        if hudRequestedVisible {
            closeHUD()
        } else {
            showHUDWindow()
        }
        updateMenuState()
    }

    private func showHUDWindow() {
        hudRequestedVisible = true
        if !sessionSuspended { presentSelectedHUD() }
        renderDisplayState()
    }

    private func presentSelectedHUD() {
        let geometry = displayTarget.resolve(DisplayTargetResolver.candidates())
        if hudPreferences.usesNotch(hasGeometry: geometry != nil) && notchHUD.show(in: geometry) {
            hudWindow.orderOut(nil)
        } else {
            notchHUD.hide()
            hudController.prepareToShow()
            hudWindow.orderFrontPinned()
            hudWindow.recoverPositionIfOffscreen()
        }
        updateMenuState()
    }

    private func hostDidStart() {
        if !sessionSuspended { quotaAlerts.resume() }
        completionFeedback.reset()
        taskMonitor.start(displayEnabled: taskStatusEnabled)
        NSApp.setActivationPolicy(.accessory)
        persistentTouchBar.start()
        store.start()
        if hudRequestedVisible && !sessionSuspended {
            presentSelectedHUD()
        } else {
            hudWindow.orderOut(nil)
        }
        updateMenuState()
        renderDisplayState()
    }

    private func hostDidStop() {
        quotaAlerts.suspend()
        completionFeedback.reset()
        stopResetNews()
        taskMonitor.hostUnavailable()
        notchHUD.hide()
        taskMonitor.stop()
        persistentTouchBar.stop()
        hudWindow.orderOut(nil)
        store.stop()
        NSApp.terminate(nil)
    }

    private func refreshQuotaNow() {
        store.start()
    }

    private func restartTaskMonitoring() {
        completionFeedback.reset()
        if lifecycleMonitor.hostIsRunningNow() { taskMonitor.start(displayEnabled: taskStatusEnabled) }
        else { taskMonitor.prepareForHost(displayEnabled: taskStatusEnabled) }
    }

    private func setTaskStatusEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "taskStatusEnabled")
        restartTaskMonitoring()
        renderDisplayState()
    }

    private func closeHUD() {
        hudRequestedVisible = false
        notchHUD.hide()
        hudWindow.orderOut(nil)
        updateMenuState()
        renderDisplayState()
    }

    @objc private func refreshQuotaFromMenu(_ sender: AnyObject?) {
        refreshQuotaNow()
    }

    @objc private func hideHUDFromContextMenu(_ sender: AnyObject?) {
        closeHUD()
    }

    @objc private func quitFromMenu(_ sender: AnyObject?) {
        quitApp()
    }

    private func applyHUDAppearance() {
        hudAppearance.save()
        hudController.updateAppearance(hudAppearance)
        updateMenuState()
    }

    private func updateMenuState() {
        persistentTouchBarMenuItem?.state = persistentTouchBar.usesSystemPresentation ? .on : .off
        hudVisibilityMenuItem?.title = hudRequestedVisible ? "隐藏状态面板" : "显示状态面板"
        updateUpdateMenuItems()
    }

    private func updateUpdatePresentation() {
        updateUpdateMenuItems()
        var state = latestQuotaState
        state.taskStatus = taskStatusEnabled ? completionFeedback.applying(to: latestTaskStatus) : nil
        updateStatusTitle(with: state)
        updateUpdateNotificationPreferences()
        preferences?.update(appearance: hudAppearance, state: state, taskEnabled: taskStatusEnabled, persistentEnabled: persistentTouchBar.isEnabled, persistentAvailable: persistentTouchBar.isAvailable, appUpdate: appUpdater.viewState)
    }

    private func updateUpdateNotificationPreferences() {
        preferences?.updateUpdateNotifications(enabled: appUpdater.notificationsEnabled, permission: appUpdater.notificationPermission)
    }

    private func updateUpdateMenuItems() {
        let state = appUpdater.viewState
        availableUpdateMenuItem?.isHidden = state.availableVersion == nil
        updateMenuSeparator?.isHidden = state.availableVersion == nil
        if let version = state.availableVersion {
            AppUpdateMenuPresentation.apply(to: availableUpdateMenuItem, version: version, enabled: !state.isInstalling)
        }
        updateProgressMenuItem?.isHidden = state.progress == nil
        updateProgressMenuItem?.title = state.progress?.menuTitle ?? "查看更新进度…"
        updateProgressMenuItem?.isEnabled = state.progress != nil
        let actionTitle = state.isChecking ? "正在检查更新…" : "检查更新…"
        if let check = checkUpdatesMenuItem {
            let title = NSMutableAttributedString(string: actionTitle)
            title.append(NSAttributedString(string: "   \(AppUpdater.version)", attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
            check.title = "\(actionTitle)  \(AppUpdater.version)"
            check.attributedTitle = title
            check.toolTip = AppUpdater.versionLabel
            check.isEnabled = !state.isInstalling
        }
    }

    private func quitApp() {
        guard appUpdater.canQuit else { appUpdater.presentInstallationProgress(); return }
        quotaAlerts.suspend()
        completionFeedback.reset()
        stopResetNews()
        notchHUD.hide()
        HostAutoLauncher.markManualQuit()
        persistentTouchBar.stop()
        hudWindow.orderOut(nil)
        lifecycleMonitor.stop()
        store.stop()
        appUpdater.stop()
        NSApp.terminate(nil)
    }
}
