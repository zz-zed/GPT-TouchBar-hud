import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, RateLimitStoreDelegate {
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
        configureStatusItem()
        configureLifecycleMonitor()
        HostAutoLauncher.installOrUpdate()
        HostAutoLauncher.clearManualQuitLock()

        lifecycleMonitor.start()

        if lifecycleMonitor.hostIsRunningNow() {
            hostDidStart()
        } else {
            updateStatusTitle(with: .initial)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
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

        var titleParts: [String] = []
        var tooltipParts: [String] = []

        if let fiveHour = state.fiveHour {
            titleParts.append("\(fiveHour.shortTitle) \(fiveHour.remainingText)")
            tooltipParts.append("5 小时剩余 \(fiveHour.remainingText)")
        } else if let resetCredits = state.resetCredits, resetCredits.availableCount > 0 {
            titleParts.append("重置\(resetCredits.availableCount)")
            tooltipParts.append("可重置 \(resetCredits.availableCount) 次，\(resetCredits.expirationText)")
        }

        if let weekly = state.weekly {
            titleParts.append("\(weekly.shortTitle) \(weekly.remainingText)")
            tooltipParts.append("周限额剩余 \(weekly.remainingText)")
        }

        if !titleParts.isEmpty {
            button.title = " \(titleParts.joined(separator: "  "))"
            button.toolTip = "\(AppIdentity.productName) 额度：\(tooltipParts.joined(separator: "，"))"
        } else if state.isRefreshing {
            button.title = " ..."
            button.toolTip = "\(AppIdentity.productName) 额度：正在刷新"
        } else {
            button.title = " --"
            button.toolTip = state.errorMessage ?? "\(AppIdentity.productName) 额度"
        }
        if let usage = state.tokenUsage {
            button.toolTip = (button.toolTip ?? "\(AppIdentity.productName) 额度") + "\n\(usage.yesterdayText)；\(usage.cumulativeText)\n\(usage.toolTip)"
        }
        if let task {
            button.toolTip = (button.toolTip ?? AppIdentity.productName) + "\n" + task.label + "\n" + task.detail
        }
        button.setAccessibilityLabel(AppIdentity.productName + (task.map { " · " + $0.label } ?? ""))
    }

    @objc private func toggleHUDWindow(_ sender: AnyObject?) {
        if hudWindow.isVisible {
            hudWindow.orderOut(sender)
        } else {
            showHUDWindow()
        }
        updateMenuState()
    }

    private func showHUDWindow() {
        hudWindow.orderFrontPinned()
        hudController.activateTouchBar()
        updateMenuState()
    }

    private func hostDidStart() {
        if taskStatusEnabled { taskMonitor.start() }
        NSApp.setActivationPolicy(.accessory)
        persistentTouchBar.start()
        store.start()
        // Startup is menu/Touch Bar only; showing the HUD is an explicit menu action.
        hudWindow.orderOut(nil)
        updateMenuState()
    }

    private func hostDidStop() {
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
        hudWindow.orderOut(nil)
        updateMenuState()
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
        hudVisibilityMenuItem?.title = hudWindow.isVisible ? "隐藏浮窗" : "显示浮窗"

    }

    private func quitApp() {
        HostAutoLauncher.markManualQuit()
        persistentTouchBar.stop()
        hudWindow.orderOut(nil)
        lifecycleMonitor.stop()
        store.stop()
        NSApp.terminate(nil)
    }
}
