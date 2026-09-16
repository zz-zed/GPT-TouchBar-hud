import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, RateLimitStoreDelegate {
    private enum OpacitySetting {
        case background
        case content
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: 118)
    private let store = RateLimitStore()
    private let lifecycleMonitor = CodexLifecycleMonitor()
    private var hudAppearance = HUDAppearance.load()
    private var hudVisibilityMenuItem: NSMenuItem?
    private var persistentTouchBarMenuItem: NSMenuItem?
    private lazy var persistentTouchBar = PersistentTouchBarController()
    private var colorMenuItems: [HUDAppearance.ColorChoice: NSMenuItem] = [:]
    private var backgroundOpacityMenuItems: [Double: NSMenuItem] = [:]
    private var contentOpacityMenuItems: [Double: NSMenuItem] = [:]
    private lazy var hudController = CompactHUDViewController(
        initialAppearance: hudAppearance,
        onRefresh: { [weak self] in
            self?.refreshQuotaNow()
        },
        onQuit: { [weak self] in
            self?.quitFromHUD()
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

        store.delegate = self
        configureStatusItem()
        configureLifecycleMonitor()
        CodexAutoLauncher.installOrUpdate()
        CodexAutoLauncher.clearManualQuitLock()

        lifecycleMonitor.start()

        if lifecycleMonitor.codexIsRunningNow() {
            codexDidStart()
        } else {
            updateStatusTitle(with: .initial)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistentTouchBar.stop()
        lifecycleMonitor.stop()
        store.stop()
    }

    func rateLimitStore(_ store: RateLimitStore, didUpdate state: RateLimitDisplayState) {
        updateStatusTitle(with: state)
        hudController.update(with: state)
        persistentTouchBar.update(with: state)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.image = NSImage(systemSymbolName: "bolt.horizontal.circle.fill", accessibilityDescription: "Codex")
        button.imagePosition = .imageLeft
        button.title = " --"
        button.toolTip = "Codex 额度"

        statusItem.menu = makeStatusMenu()
        updateMenuState()
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let visibilityItem = NSMenuItem(
            title: "隐藏浮窗",
            action: #selector(toggleHUDWindow(_:)),
            keyEquivalent: ""
        )
        visibilityItem.target = self
        menu.addItem(visibilityItem)
        hudVisibilityMenuItem = visibilityItem

        let refreshItem = NSMenuItem(
            title: "刷新额度",
            action: #selector(refreshQuotaFromMenu(_:)),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        menu.setSubmenu(makeAppearanceSettingsMenu(registerItems: true), for: settingsItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quitFromMenu(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func makeHUDContextMenu() -> NSMenu {
        let menu = NSMenu()

        let hideItem = NSMenuItem(
            title: "隐藏浮窗",
            action: #selector(hideHUDFromContextMenu(_:)),
            keyEquivalent: ""
        )
        hideItem.target = self
        menu.addItem(hideItem)

        let refreshItem = NSMenuItem(
            title: "刷新额度",
            action: #selector(refreshQuotaFromMenu(_:)),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        menu.setSubmenu(makeAppearanceSettingsMenu(registerItems: false), for: settingsItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quitFromMenu(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
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
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePersistentTouchBar(_:)) {
            menuItem.state = persistentTouchBar.usesSystemPresentation ? .on : .off
            return persistentTouchBar.isAvailable
        }
        return true
    }

    private func makeAppearanceSettingsMenu(registerItems: Bool) -> NSMenu {
        let settingsMenu = NSMenu(title: "设置")

        let persistentItem = makePersistentTouchBarMenuItem()
        settingsMenu.addItem(persistentItem)
        if registerItems { persistentTouchBarMenuItem = persistentItem }
        settingsMenu.addItem(.separator())

        let colorHeader = NSMenuItem(title: "浮窗颜色", action: nil, keyEquivalent: "")
        colorHeader.isEnabled = false
        settingsMenu.addItem(colorHeader)

        for colorChoice in HUDAppearance.ColorChoice.allCases {
            let item = NSMenuItem(
                title: colorChoice.title,
                action: #selector(selectHUDColor(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = colorChoice.rawValue
            item.state = colorChoice == hudAppearance.colorChoice ? .on : .off
            settingsMenu.addItem(item)
            if registerItems {
                colorMenuItems[colorChoice] = item
            }
        }

        settingsMenu.addItem(.separator())

        let backgroundOpacityItem = NSMenuItem(title: "背景透明度", action: nil, keyEquivalent: "")
        settingsMenu.setSubmenu(
            makeOpacityMenu(for: .background, registerItems: registerItems),
            for: backgroundOpacityItem
        )
        settingsMenu.addItem(backgroundOpacityItem)

        let contentOpacityItem = NSMenuItem(title: "文字透明度", action: nil, keyEquivalent: "")
        settingsMenu.setSubmenu(
            makeOpacityMenu(for: .content, registerItems: registerItems),
            for: contentOpacityItem
        )
        settingsMenu.addItem(contentOpacityItem)

        return settingsMenu
    }

    private func makeOpacityMenu(for setting: OpacitySetting, registerItems: Bool) -> NSMenu {
        let menu = NSMenu(title: setting == .background ? "背景透明度" : "文字透明度")
        let currentOpacity: Double
        let action: Selector

        switch setting {
        case .background:
            currentOpacity = hudAppearance.backgroundOpacity
            action = #selector(selectHUDBackgroundOpacity(_:))
        case .content:
            currentOpacity = hudAppearance.contentOpacity
            action = #selector(selectHUDContentOpacity(_:))
        }

        for opacity in HUDAppearance.opacityChoices {
            let item = NSMenuItem(
                title: "\(Int((opacity * 100).rounded()))%",
                action: action,
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: opacity)
            item.state = abs(opacity - currentOpacity) < 0.001 ? .on : .off
            menu.addItem(item)
            if registerItems {
                switch setting {
                case .background:
                    backgroundOpacityMenuItems[opacity] = item
                case .content:
                    contentOpacityMenuItems[opacity] = item
                }
            }
        }

        return menu
    }

    private func configureLifecycleMonitor() {
        lifecycleMonitor.onCodexStarted = { [weak self] in
            self?.codexDidStart()
        }

        lifecycleMonitor.onCodexStopped = { [weak self] in
            self?.codexDidStop()
        }
    }

    private func updateStatusTitle(with state: RateLimitDisplayState) {
        guard let button = statusItem.button else {
            return
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
            button.toolTip = "Codex 额度：\(tooltipParts.joined(separator: "，"))"
        } else if state.isRefreshing {
            button.title = " ..."
            button.toolTip = "Codex 额度：正在刷新"
        } else {
            button.title = " --"
            button.toolTip = state.errorMessage ?? "Codex 额度"
        }
        if let usage = state.tokenUsage {
            button.toolTip = (button.toolTip ?? "Codex 额度") + "\n\(usage.yesterdayText)；\(usage.cumulativeText)\n\(usage.toolTip)"
        }
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

    private func codexDidStart() {
        NSApp.setActivationPolicy(.accessory)
        persistentTouchBar.start()
        store.start()
        // Startup is menu/Touch Bar only; showing the HUD is an explicit menu action.
        hudWindow.orderOut(nil)
        updateMenuState()
    }

    private func codexDidStop() {
        persistentTouchBar.stop()
        hudWindow.orderOut(nil)
        store.stop()
        NSApp.terminate(nil)
    }

    private func refreshQuotaNow() {
        store.start()
    }

    private func quitFromHUD() {
        quitApp()
    }

    @objc private func refreshQuotaFromMenu(_ sender: AnyObject?) {
        refreshQuotaNow()
    }

    @objc private func hideHUDFromContextMenu(_ sender: AnyObject?) {
        hudWindow.orderOut(sender)
        updateMenuState()
    }

    @objc private func quitFromMenu(_ sender: AnyObject?) {
        quitApp()
    }

    @objc private func selectHUDColor(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let colorChoice = HUDAppearance.ColorChoice(rawValue: rawValue) else {
            return
        }

        hudAppearance.colorChoice = colorChoice
        applyHUDAppearance()
    }

    @objc private func selectHUDBackgroundOpacity(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else {
            return
        }

        hudAppearance.backgroundOpacity = number.doubleValue
        applyHUDAppearance()
    }

    @objc private func selectHUDContentOpacity(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else {
            return
        }

        hudAppearance.contentOpacity = number.doubleValue
        applyHUDAppearance()
    }

    private func applyHUDAppearance() {
        hudAppearance.save()
        hudController.updateAppearance(hudAppearance)
        updateMenuState()
    }

    private func updateMenuState() {
        persistentTouchBarMenuItem?.state = persistentTouchBar.usesSystemPresentation ? .on : .off
        hudVisibilityMenuItem?.title = hudWindow.isVisible ? "隐藏浮窗" : "显示浮窗"

        for (colorChoice, item) in colorMenuItems {
            item.state = colorChoice == hudAppearance.colorChoice ? .on : .off
        }

        for (opacity, item) in backgroundOpacityMenuItems {
            item.state = abs(opacity - hudAppearance.backgroundOpacity) < 0.001 ? .on : .off
        }

        for (opacity, item) in contentOpacityMenuItems {
            item.state = abs(opacity - hudAppearance.contentOpacity) < 0.001 ? .on : .off
        }
    }

    private func quitApp() {
        CodexAutoLauncher.markManualQuit()
        persistentTouchBar.stop()
        hudWindow.orderOut(nil)
        lifecycleMonitor.stop()
        store.stop()
        NSApp.terminate(nil)
    }
}
