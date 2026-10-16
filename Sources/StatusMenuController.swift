import AppKit

struct StatusMenuConfiguration {
    var hudDisplayMode: HUDDisplayMode = .automatic
    var menuDisplayMode: MenuBarDisplayMode = .load()
    var hudRequestedVisible = false
    var panelVisible = false
    var notchExpanded = false
    var persistentEnabled = false
    var persistentAvailable = false
    var usesSystemPresentation = false
}

final class StatusMenuController: NSObject, NSMenuItemValidation, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let touchBarHardware: TouchBarHardware
    private let appUpdater: AppUpdater
    private let menuTaskTrace = DiagnosticTaskDisplayObserver(DiagnosticRuntimeRecorder.shared, surface: .menuBar, consumer: .menuBar)
    private var menuTaskAppearance: TaskStatusAppearance = .idle
    private var snapshot = AppDisplaySnapshot(state: .initial, news: ResetNewsViewState())
    private var latestQuotaState: RateLimitDisplayState { snapshot.state }
    private var latestResetNewsState: ResetNewsViewState { snapshot.news }
    private var summaryState: RateLimitDisplayState { snapshot.state }
    private var displaySnapshot: AppDisplaySnapshot { snapshot }
    private var configuration: StatusMenuConfiguration { configurationProvider?() ?? StatusMenuConfiguration() }
    private var hudDisplayMode: HUDDisplayMode { configuration.hudDisplayMode }
    private var menuDisplayMode: MenuBarDisplayMode { configuration.menuDisplayMode }
    private var hudRequestedVisible: Bool { configuration.hudRequestedVisible }
    private var statusMenuOpen = false
    private var hudVisibilityMenuItem: NSMenuItem?
    private var persistentTouchBarMenuItem: NSMenuItem?
    private var availableUpdateMenuItem: NSMenuItem?
    private var checkUpdatesMenuItem: NSMenuItem?
    private var updateProgressMenuItem: NSMenuItem?
    private var summaryMenuItem: NSMenuItem?
    private var collapseDetailsMenuItem: NSMenuItem?
    var configurationProvider: (() -> StatusMenuConfiguration)?
    var onWillOpen: (() -> Void)?
    var onRefreshQuota: (() -> Void)?
    var onRefreshAll: (() -> Void)?
    var onForecast: (() -> Void)?
    var onForecastRetry: (() -> Void)?
    var onForecastFromContext: ((NSView?) -> Void)?
    var onToggleHUD: (() -> Void)?
    var onHideHUD: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onSelectDisplayMode: ((HUDDisplayMode) -> Void)?
    var onSelectMenuMode: ((MenuBarDisplayMode) -> Void)?
    var onTogglePersistent: (() -> Void)?
    var onPreferences: (() -> Void)?
    var onQuit: (() -> Void)?
    init(touchBarHardware: TouchBarHardware, appUpdater: AppUpdater) {
        self.touchBarHardware = touchBarHardware; self.appUpdater = appUpdater
        super.init()
    }
    func update(_ snapshot: AppDisplaySnapshot, statusTitle: Bool = true) {
        self.snapshot = snapshot
        if statusTitle { updateStatusTitle(with: snapshot.state) }
        if statusMenuOpen {
            (summaryMenuItem?.view as? StatusSummaryView)?.update(snapshot.state, news: snapshot.news, forecast: snapshot.forecast)
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        statusMenuOpen = true
        onWillOpen?()
        collapseDetailsMenuItem?.isHidden = !configuration.notchExpanded
        (summaryMenuItem?.view as? StatusSummaryView)?.update(snapshot.state, news: snapshot.news, forecast: snapshot.forecast)
    }
    func menuDidClose(_ menu: NSMenu) { statusMenuOpen = false }
    func configureStatusItem() {
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

    func menuAction(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let summary = NSMenuItem()
        let state = snapshot.state
        let summaryView = StatusSummaryView(state: state)
        summaryView.update(state, news: latestResetNewsState, forecast: snapshot.forecast)
        summaryView.onRefresh = { [weak self] in self?.onRefreshAll?() }
        summaryView.onForecast = { [weak self] in self?.onForecast?() }
        summaryView.onForecastRetry = { [weak self] in self?.onForecastRetry?() }
        summaryView.onQuotaRetry = { [weak self] in self?.onRefreshQuota?() }
        summary.view = summaryView
        summaryMenuItem = summary
        menu.addItem(summary)
        menu.addItem(.separator())
        // The visible refresh control lives in the summary; keep the menu shortcut available.
        let refresh = menuAction("刷新数据", #selector(refreshDataFromMenu(_:)), key: "r")
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
        collapse.isHidden = !configuration.notchExpanded
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

    func makeHUDContextMenu(anchor: NSView) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuAction("刷新额度", #selector(refreshQuotaFromMenu(_:)), key: "r"))
        let forecasts = menuAction(snapshot.forecast.indicator.accessibilityLabel, #selector(openResetNewsFromMenu(_:)))
        forecasts.representedObject = anchor
        menu.addItem(forecasts)
        menu.addItem(menuAction("隐藏浮窗", #selector(hideHUDFromContextMenu(_:))))
        menu.addItem(.separator())
        menu.addItem(menuAction("设置…", #selector(openPreferences(_:)), key: ","))
        return menu
    }

    func makePersistentTouchBarMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Touch Bar 常驻", action: #selector(togglePersistentTouchBar(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = configuration.persistentAvailable
        item.state = configuration.usesSystemPresentation ? .on : .off
        item.toolTip = configuration.persistentAvailable
            ? "完整额度条在切换 App 后继续显示；关闭后恢复当前 App 的 Touch Bar。"
            : "当前系统不提供常驻接口，点击浮窗后可使用普通 Touch Bar 显示。"
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(openMenuForecast) { return snapshot.forecast.hasForecastDetails }

        if menuItem.action == #selector(selectDisplayMode(_:)) {
            menuItem.state = HUDDisplayMode.allCases[menuItem.tag] == hudDisplayMode ? .on : .off
        }
        if menuItem.action == #selector(selectMenuMode(_:)) {
            menuItem.state = MenuBarDisplayMode.allCases[menuItem.tag] == menuDisplayMode ? .on : .off
        }
        if menuItem.action == #selector(collapseNotch(_:)) {
            menuItem.isHidden = !configuration.notchExpanded
            return configuration.notchExpanded
        }
        if menuItem.action == #selector(refreshDataFromMenu(_:)) {
            menuItem.title = latestQuotaState.isRefreshing || latestResetNewsState.status == .checking
                ? "正在刷新…" : "刷新数据"
            return !latestQuotaState.isRefreshing && latestResetNewsState.status != .checking
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
            menuItem.state = configuration.usesSystemPresentation ? .on : .off
            return configuration.persistentAvailable
        }
        return true
    }

    func addUpdateMenuItems(to menu: NSMenu) {
        menu.addItem(.separator())
        let available = menuAction("", #selector(viewAvailableAppUpdate(_:)))
        availableUpdateMenuItem = available
        menu.addItem(available)
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

    @objc func checkForAppUpdates(_ sender: AnyObject?) { appUpdater.check() }

    @objc func viewAppUpdateProgress(_ sender: AnyObject?) { appUpdater.presentInstallationProgress() }

    @objc func viewAvailableAppUpdate(_ sender: AnyObject?) { appUpdater.presentAvailableUpdate() }

    func updateStatusTitle(with state: RateLimitDisplayState) {
        guard let button = statusItem.button else {
            menuTaskTrace.record(state, action: .skipped, reason: .unavailable, compact: .hidden)
            TaskPresentationTrace.record(state, surface: .menuBar, action: .unavailable)
            return
        }
        TaskPresentationTrace.record(state, surface: .menuBar, action: .renderRequested)
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

        let presentation = MenuBarPresentation(state: state, mode: menuDisplayMode, panelVisible: configuration.panelVisible, hasUpdate: availableVersion != nil)
        presentation.apply(to: statusItem, taskTrace: menuTaskTrace)
    }

    func updateMenuState() {
        persistentTouchBarMenuItem?.state = configuration.usesSystemPresentation ? .on : .off
        hudVisibilityMenuItem?.title = hudRequestedVisible ? "隐藏状态面板" : "显示状态面板"
        updateUpdateMenuItems()
    }

    func updateUpdateMenuItems() {
        let state = appUpdater.viewState
        availableUpdateMenuItem?.isHidden = state.availableVersion == nil
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

    @objc private func openMenuForecast() { onForecast?() }
    @objc private func openResetNewsFromMenu(_ sender: AnyObject?) {
        let anchor = (sender as? NSMenuItem)?.representedObject as? NSView
        DispatchQueue.main.async { [weak self] in self?.onForecastFromContext?(anchor) }
    }
    @objc private func toggleHUDWindow(_ sender: AnyObject?) { onToggleHUD?() }
    @objc private func hideHUDFromContextMenu(_ sender: AnyObject?) { onHideHUD?() }
    @objc private func collapseNotch(_ sender: AnyObject?) { onCollapse?() }
    @objc private func selectDisplayMode(_ sender: NSMenuItem) {
        guard HUDDisplayMode.allCases.indices.contains(sender.tag) else { return }
        onSelectDisplayMode?(HUDDisplayMode.allCases[sender.tag])
    }
    @objc private func selectMenuMode(_ sender: NSMenuItem) {
        guard MenuBarDisplayMode.allCases.indices.contains(sender.tag) else { return }
        onSelectMenuMode?(MenuBarDisplayMode.allCases[sender.tag])
    }
    @objc private func togglePersistentTouchBar(_ sender: NSMenuItem) { onTogglePersistent?() }
    @objc private func refreshDataFromMenu(_ sender: AnyObject?) { onRefreshAll?() }
    @objc private func refreshQuotaFromMenu(_ sender: AnyObject?) { onRefreshQuota?() }
    @objc private func openPreferences(_ sender: AnyObject?) { onPreferences?() }
    @objc private func quitFromMenu(_ sender: AnyObject?) { onQuit?() }
}
