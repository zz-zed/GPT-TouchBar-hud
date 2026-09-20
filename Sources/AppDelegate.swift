import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate, RateLimitStoreDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = RateLimitStore()
    private let appUpdater = AppUpdater()
    private let taskMonitor = TaskStatusMonitor()
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
    private var screenLocked = false
    private var systemSleeping = false
    private var sessionInactive = false
    private var sessionSuspended: Bool { screenLocked || systemSleeping || sessionInactive }
    private lazy var notchHUD: NotchHUDController = {
        let controller = NotchHUDController()
        controller.onRefresh = { [weak self] in self?.refreshQuotaNow() }
        controller.onSettings = { [weak self] in self?.openPreferences(nil) }
        controller.onDesktop = { [weak self] in self?.setDisplayMode(.floating) }
        return controller
    }()
    private var hudAppearance = HUDAppearance.load()
    private var hudVisibilityMenuItem: NSMenuItem?
    private var persistentTouchBarMenuItem: NSMenuItem?
    private var menuTaskAppearance: TaskStatusAppearance = .idle
    private lazy var persistentTouchBar = PersistentTouchBarController()
    private var summaryMenuItem: NSMenuItem?
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

        store.delegate = self
        appUpdater.onInstall = { [weak self] in self?.quitApp() }
        taskMonitor.onUpdate = { [weak self] status in
            guard let self else { return }
            self.latestTaskStatus = status
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
        HostAutoLauncher.installOrUpdate()
        HostAutoLauncher.clearManualQuitLock()

        lifecycleMonitor.start()

        if lifecycleMonitor.hostIsRunningNow() {
            hostDidStart()
        } else {
            updateStatusTitle(with: .initial)
            if hudRequestedVisible { presentSelectedHUD() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPreferences(nil)
        return false
    }

    @objc private func screenConfigurationChanged() {
        notchHUD.collapse()
        if hudRequestedVisible && !sessionSuspended { presentSelectedHUD() }
        renderDisplayState()
    }

    @objc private func frontApplicationChanged() { notchHUD.collapse() }
    @objc private func spaceOrWakeChanged(_ notification: Notification) {
        if notification.name == NSWorkspace.didWakeNotification { systemSleeping = false }
        screenConfigurationChanged()
    }
    @objc private func suspendPanels(_ notification: Notification) {
        if notification.name.rawValue == "com.apple.screenIsLocked" { screenLocked = true }
        if notification.name == NSWorkspace.willSleepNotification { systemSleeping = true }
        if notification.name == NSWorkspace.sessionDidResignActiveNotification { sessionInactive = true }
        notchHUD.hide()
        hudWindow.orderOut(nil)
        renderDisplayState()
    }
    @objc private func resumePanels(_ notification: Notification) {
        if notification.name.rawValue == "com.apple.screenIsUnlocked" { screenLocked = false }
        if notification.name == NSWorkspace.sessionDidBecomeActiveNotification { sessionInactive = false }
        screenConfigurationChanged()
    }
    func menuWillOpen(_ menu: NSMenu) { notchHUD.collapse() }

    func applicationWillTerminate(_ notification: Notification) {
        notchHUD.hide()
        taskMonitor.stop()
        persistentTouchBar.stop()
        lifecycleMonitor.stop()
        store.stop()
    }

    func rateLimitStore(_ store: RateLimitStore, didUpdate state: RateLimitDisplayState) {
        latestQuotaState = state
        renderDisplayState()
    }

    private func renderDisplayState() {
        var state = latestQuotaState
        state.taskStatus = taskStatusEnabled ? latestTaskStatus : nil
        updateStatusTitle(with: state)
        hudController.update(with: state)
        notchHUD.update(state)
        persistentTouchBar.update(with: state)
        summaryMenuItem?.view = StatusSummaryView(state: state)
        preferences?.update(appearance: hudAppearance, state: state, taskEnabled: taskStatusEnabled, persistentEnabled: persistentTouchBar.isEnabled, persistentAvailable: persistentTouchBar.isAvailable)
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
        state.taskStatus = taskStatusEnabled ? latestTaskStatus : nil
        summary.view = StatusSummaryView(state: state)
        summaryMenuItem = summary
        menu.addItem(summary)
        menu.addItem(.separator())
        menu.addItem(menuAction("刷新额度", #selector(refreshQuotaFromMenu(_:)), key: "r"))
        let visibility = menuAction("显示浮窗", #selector(toggleHUDWindow(_:)))
        hudVisibilityMenuItem = visibility
        menu.addItem(visibility)
        menu.addItem(menuAction("收起详情", #selector(collapseNotch(_:))))
        let forms = NSMenuItem(title: "显示形式", action: nil, keyEquivalent: "")
        forms.submenu = NSMenu()
        for (index, mode) in HUDDisplayMode.allCases.enumerated() {
            let item = menuAction(mode.title, #selector(selectDisplayMode(_:)))
            item.tag = index
            forms.submenu?.addItem(item)
        }
        menu.addItem(forms)
        let menuModes = NSMenuItem(title: "菜单栏内容", action: nil, keyEquivalent: "")
        menuModes.submenu = NSMenu()
        for (index, mode) in MenuBarDisplayMode.allCases.enumerated() {
            let item = menuAction(mode.title, #selector(selectMenuMode(_:)))
            item.tag = index
            menuModes.submenu?.addItem(item)
        }
        menu.addItem(menuModes)
        let persistent = makePersistentTouchBarMenuItem()
        persistentTouchBarMenuItem = persistent
        menu.addItem(persistent)
        menu.addItem(.separator())
        menu.addItem(menuAction("设置…", #selector(openPreferences(_:)), key: ","))
        menu.addItem(.separator())
        addUpdateMenuItems(to: menu)
        menu.addItem(menuAction("退出", #selector(quitFromMenu(_:)), key: "q"))
        return menu
    }

    private func makeHUDContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuAction("刷新额度", #selector(refreshQuotaFromMenu(_:)), key: "r"))
        menu.addItem(menuAction("隐藏浮窗", #selector(hideHUDFromContextMenu(_:))))
        menu.addItem(.separator())
        menu.addItem(menuAction("设置…", #selector(openPreferences(_:)), key: ","))
        return menu
    }

    @objc private func openPreferences(_ sender: AnyObject?) {
        if preferences == nil {
            let controller = PreferencesWindowController(appearance: hudAppearance)
            controller.onAppearance = { [weak self] appearance in
                self?.hudAppearance = appearance
                self?.applyHUDAppearance()
            }
            controller.onDisplayMode = { [weak self] mode in self?.setDisplayMode(mode) }
            controller.onMenuMode = { [weak self] mode in self?.setMenuMode(mode) }
            controller.onVisibility = { [weak self] visible in
                if visible { self?.showHUDWindow() } else { self?.closeHUD() }
            }
            controller.onLanguage = { [weak self] language in
                DisplayLanguage.current = language
                self?.renderDisplayState()
            }
            controller.onTaskStatus = { [weak self] enabled in self?.setTaskStatusEnabled(enabled) }
            controller.onPersistent = { [weak self] enabled in
                self?.persistentTouchBar.setEnabled(enabled)
                self?.updateMenuState()
                self?.renderDisplayState()
            }
            preferences = controller
        }
        renderDisplayState()
        NSApp.activate(ignoringOtherApps: true)
        preferences?.showWindow(sender)
        preferences?.window?.makeKeyAndOrderFront(sender)
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
        if menuItem.action == #selector(selectDisplayMode(_:)) {
            menuItem.state = HUDDisplayMode.allCases[menuItem.tag] == hudDisplayMode ? .on : .off
        }
        if menuItem.action == #selector(selectMenuMode(_:)) {
            menuItem.state = MenuBarDisplayMode.allCases[menuItem.tag] == menuDisplayMode ? .on : .off
        }
        if menuItem.action == #selector(collapseNotch(_:)) { return notchHUD.isExpanded }
        if menuItem.action == #selector(refreshQuotaFromMenu(_:)) {
            menuItem.title = latestQuotaState.isRefreshing ? "正在刷新…" : "刷新额度"
            return !latestQuotaState.isRefreshing
        }
        if menuItem.action == #selector(checkForAppUpdates(_:)) {
            menuItem.title = appUpdater.canCheck ? "检查更新…" : "正在检查或下载更新…"
            return appUpdater.canCheck
        }
        if menuItem.action == #selector(togglePersistentTouchBar(_:)) {
            menuItem.state = persistentTouchBar.usesSystemPresentation ? .on : .off
            return persistentTouchBar.isAvailable
        }
        return true
    }

    private func addUpdateMenuItems(to menu: NSMenu) {
        let version = NSMenuItem(title: AppUpdater.versionLabel, action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        let check = NSMenuItem(title: "检查更新…", action: #selector(checkForAppUpdates(_:)), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        menu.addItem(.separator())
    }

    @objc private func checkForAppUpdates(_ sender: AnyObject?) { appUpdater.check() }

    private func configureLifecycleMonitor() {
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
        button.toolTip = tooltip
        button.setAccessibilityLabel(AppIdentity.productName + (task.map { " · " + $0.label } ?? ""))

        let presentation = MenuBarPresentation(state: state, mode: menuDisplayMode, panelVisible: notchHUD.isVisible || hudWindow.isVisible)
        presentation.apply(to: statusItem)
    }

    private func setDisplayMode(_ mode: HUDDisplayMode) {
        hudDisplayMode = mode
        notchHUD.collapse()
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
        let geometry = NotchHUDGeometry.current()
        if hudPreferences.usesNotch(hasGeometry: geometry != nil) && notchHUD.show(in: geometry) {
            hudWindow.orderOut(nil)
        } else {
            notchHUD.hide()
            hudWindow.orderFrontPinned()
            hudWindow.recoverPositionIfOffscreen()
        }
        updateMenuState()
    }

    private func hostDidStart() {
        if taskStatusEnabled { taskMonitor.start() }
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

    private func setTaskStatusEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "taskStatusEnabled")
        latestTaskStatus = nil
        if enabled { taskMonitor.start() } else { taskMonitor.stop() }
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

    }

    private func quitApp() {
        notchHUD.hide()
        HostAutoLauncher.markManualQuit()
        persistentTouchBar.stop()
        hudWindow.orderOut(nil)
        lifecycleMonitor.stop()
        store.stop()
        NSApp.terminate(nil)
    }
}
