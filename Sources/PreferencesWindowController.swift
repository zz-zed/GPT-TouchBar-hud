import AppKit

final class PreferencesWindowController: NSWindowController {
    private enum TabIdentifier: String {
        case general, appearance, touchBar, experiments, updates, resetNews, quotaAlerts
    }

    var onQuit: (() -> Void)?
    var onAppearance: ((HUDAppearance) -> Void)?
    var onLanguage: ((DisplayLanguage) -> Void)?
    var onHookExperiment: (() -> Void)?
    var onTaskStatus: ((Bool) -> Void)?
    var onDisplayMode: ((HUDDisplayMode) -> Void)?
    var onMenuMode: ((MenuBarDisplayMode) -> Void)?
    var onAlwaysShowQuota: ((Bool) -> Void)?
    var onVisibility: ((Bool) -> Void)?
    var onAutomaticUpdates: ((Bool) -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onViewUpdate: (() -> Void)?
    var onViewUpdateProgress: (() -> Void)?
    var onUpdateNotifications: ((Bool) -> Void)?
    var onAuthorizeUpdateNotifications: (() -> Void)?
    var onResetNewsEnabled: ((Bool) -> Void)?
    var onResetNewsSound: ((Bool) -> Void)?
    var onCheckResetNews: (() -> Void)?
    var onQuotaAlerts: ((QuotaAlertConfiguration) -> Void)?
    var onAutoLaunch: ((Bool) -> Void)?
    var onConnectionDiagnostics: (() -> Void)?
    private let autoLaunch = NSButton(checkboxWithTitle: "随 ChatGPT / Codex 启动", target: nil, action: nil)
    private let autoLaunchStatus = NSTextField(wrappingLabelWithString: "关闭后仍可手动打开应用。")
    private let quotaAlertsEnabled = NSButton(checkboxWithTitle: "启用个人低额度提醒", target: nil, action: nil)
    private let quotaAlertsSound = NSButton(checkboxWithTitle: "提醒提示音", target: nil, action: nil)
    private let fiveHourThreshold = NSPopUpButton()
    private let weeklyThreshold = NSPopUpButton()
    private let quotaAlertsPermission = NSTextField(wrappingLabelWithString: "系统通知权限：尚未请求")
    private let quotaThresholds = [10, 20, 30, 50]
    private let touchBarHardware: TouchBarHardware
    private let tabs = NSTabView()
    private let resetNewsEnabled = NSButton(checkboxWithTitle: "启用重置预告", target: nil, action: nil)
    private let resetNewsSound = NSButton(checkboxWithTitle: "预告提示音", target: nil, action: nil)
    private let resetNewsStatus = NSTextField(wrappingLabelWithString: "重置预告已关闭")
    private let resetNewsPermission = NSTextField(wrappingLabelWithString: "系统通知权限：尚未请求")
    private let resetNewsTiming = NSTextField(wrappingLabelWithString: "尚未检查")
    private let resetNewsCheck = NSButton(title: "检查预告", target: nil, action: nil)
    private let menuMode = NSPopUpButton()
    private let visible = NSButton(checkboxWithTitle: "显示状态面板", target: nil, action: nil)
    private let notchRestingState = NSPopUpButton()
    private let displayMode = NSPopUpButton()
    private let modeAvailability = NSTextField(wrappingLabelWithString: "")
    var onPersistent: ((Bool) -> Void)?
    private var appearance: HUDAppearance
    private let language = NSPopUpButton()
    private let material = NSPopUpButton()
    private let color = NSPopUpButton()
    private let tasks = NSButton(checkboxWithTitle: "显示任务状态（实验性）", target: nil, action: nil)
    private let persistent = NSButton(checkboxWithTitle: "Touch Bar 常驻", target: nil, action: nil)
    private let backgroundSlider = NSSlider(value: 94, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let foregroundSlider = NSSlider(value: 100, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let backgroundValue = NSTextField(labelWithString: "")
    private let foregroundValue = NSTextField(labelWithString: "")
    private let availability = NSTextField(wrappingLabelWithString: "")
    private let automaticUpdates = NSButton(checkboxWithTitle: "自动检查更新", target: nil, action: nil)
    private let updateNotifications = NSButton(checkboxWithTitle: "发现新版本时通知我", target: nil, action: nil)
    private let updateNotificationPermission = NSTextField(wrappingLabelWithString: "")
    private let authorizeUpdateNotifications = NSButton(title: "允许系统通知…", target: nil, action: nil)
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private let updateButton = NSButton(title: "检查更新…", target: nil, action: nil)
    private let updateProgressButton = NSButton(title: "查看更新进度…", target: nil, action: nil)
    private var updateAvailableVersion: String?
    private var hasUpdateProgress = false
    private let preview: CompactQuotaHUDView

    init(appearance: HUDAppearance, touchBarHardware: TouchBarHardware = .current) {
        self.appearance = appearance
        self.touchBarHardware = touchBarHardware
        preview = CompactQuotaHUDView(initialAppearance: appearance, onRefresh: {}, onClose: {}, contextMenuProvider: { NSMenu() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "设置 · GPT TouchBar HUD"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        configure()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showResetNewsTab() {
        tabs.selectTabViewItem(withIdentifier: TabIdentifier.resetNews.rawValue)
    }

    func showQuotaAlertsTab() {
        tabs.selectTabViewItem(withIdentifier: TabIdentifier.quotaAlerts.rawValue)
    }

    func updateUpdateNotifications(enabled: Bool, permission: ResetNewsNotificationPermission) {
        updateNotifications.state = enabled ? .on : .off
        let description: String
        switch permission {
        case .notRequested: description = "尚未允许系统通知，可点击下方按钮开启；菜单栏仍会显示更新标记。"
        case .allowed: description = "系统通知已允许；每个版本提醒一次，无提示音。"
        case .denied: description = "系统通知未允许，请前往系统设置 → 通知开启；菜单栏仍会显示更新标记。"
        case .unavailable: description = "系统通知暂不可用；菜单栏仍会显示更新标记。"
        }
        updateNotificationPermission.stringValue = enabled ? description : "已关闭系统提醒；自动检查和菜单栏更新标记仍可使用。"
        authorizeUpdateNotifications.isHidden = !enabled || permission != .notRequested
    }

    func updateAutoLaunch(enabled: Bool, error: String? = nil, busy: Bool = false) {
        autoLaunch.state = enabled ? .on : .off
        autoLaunch.isEnabled = !busy
        autoLaunchStatus.stringValue = busy ? "正在更新启动设置…" : (error ?? "关闭后仍可手动打开应用；重启后保留选择。")
        autoLaunchStatus.toolTip = busy ? nil : error
        autoLaunchStatus.textColor = busy || error == nil ? .secondaryLabelColor : .systemRed
    }

    func updateQuotaAlerts(_ configuration: QuotaAlertConfiguration, permission: ResetNewsNotificationPermission) {
        quotaAlertsEnabled.state = configuration.enabled ? .on : .off
        quotaAlertsSound.state = configuration.soundEnabled ? .on : .off
        fiveHourThreshold.selectItem(at: quotaThresholds.firstIndex(of: configuration.fiveHourThreshold) ?? 1)
        weeklyThreshold.selectItem(at: quotaThresholds.firstIndex(of: configuration.weeklyThreshold) ?? 1)
        for control in [fiveHourThreshold, weeklyThreshold] { control.isEnabled = configuration.enabled }
        quotaAlertsSound.isEnabled = configuration.enabled
        let text: String
        switch permission {
        case .notRequested: text = "尚未请求；开启提醒时请求"
        case .allowed: text = "已允许"
        case .denied: text = "未允许；请在系统设置的通知中允许本应用"
        case .unavailable: text = "暂不可用，请稍后重新打开设置"
        }
        quotaAlertsPermission.stringValue = "系统通知权限：" + text
    }

    func updateResetNews(_ state: ResetNewsViewState, soundEnabled: Bool) {
        resetNewsEnabled.title = DisplayLanguage.text("启用重置预告", "Enable reset forecasts")
        resetNewsSound.title = DisplayLanguage.text("预告提示音", "Forecast sound")
        resetNewsCheck.title = DisplayLanguage.text("检查预告", "Check forecasts")
        tabs.tabViewItems.first { ($0.identifier as? String) == TabIdentifier.resetNews.rawValue }?.label = DisplayLanguage.text("重置预告", "Reset forecasts")
        resetNewsEnabled.state = state.enabled ? .on : .off
        resetNewsSound.state = soundEnabled ? .on : .off
        resetNewsStatus.stringValue = state.statusText
        let permission: String
        switch state.notificationPermission {
        case .notRequested: permission = "尚未请求"
        case .allowed: permission = "已允许"
        case .denied: permission = "未允许；可在系统设置的通知中调整"
        case .unavailable: permission = "暂不可用"
        }
        resetNewsPermission.stringValue = "系统通知权限：" + permission
        func date(_ value: Date?) -> String {
            value.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "无"
        }
        resetNewsTiming.stringValue = "最近检查：\(date(state.lastAttempt))\n最近成功：\(date(state.lastSuccess))\n下次检查：\(date(state.nextCheck))"
        resetNewsCheck.isEnabled = state.enabled && ![.checking, .codexNotRunning, .idle].contains(state.status)
    }

    func update(
        appearance: HUDAppearance,
        state: RateLimitDisplayState,
        taskEnabled: Bool,
        persistentEnabled: Bool,
        persistentAvailable: Bool,
        appUpdate: AppUpdateViewState = AppUpdateViewState(
            automaticChecksEnabled: true,
            automaticChecksAvailable: false,
            availableVersion: nil,
            lastSuccess: nil,
            isChecking: false,
            isInstalling: false
        )
    ) {
        self.appearance = appearance
        displayMode.selectItem(at: HUDDisplayMode.allCases.firstIndex(of: HUDDisplayMode.load()) ?? 0)
        modeAvailability.stringValue = NotchHUDGeometry.current() == nil ? "当前无可用刘海屏，将回退桌面浮窗。" : "悬停查看额度，点击展开详情。"
        selectSavedNotchRestingState()
        menuMode.selectItem(at: MenuBarDisplayMode.allCases.firstIndex(of: MenuBarDisplayMode.load()) ?? 0)
        visible.state = HUDPresentationPreferences().isVisible ? .on : .off
        material.selectItem(at: HUDAppearance.Material.allCases.firstIndex(of: appearance.material) ?? 0)
        color.selectItem(at: HUDAppearance.ColorChoice.allCases.firstIndex(of: appearance.colorChoice) ?? 0)
        language.selectItem(at: DisplayLanguage.current == .chinese ? 0 : 1)
        tasks.state = taskEnabled ? .on : .off
        persistent.state = persistentEnabled ? .on : .off
        persistent.isEnabled = persistentAvailable
        availability.stringValue = persistentAvailable ? "切换 App 后继续显示额度条。隐藏浮窗不影响 Touch Bar 常驻。" : "当前系统常驻接口不可用，保留原有焦点绑定显示。"
        updateAppUpdate(appUpdate)
        backgroundSlider.doubleValue = appearance.backgroundOpacity * 100
        foregroundSlider.doubleValue = appearance.contentOpacity * 100
        updatePreview()
        preview.update(with: state)
    }

    /// Byte updates do not rebuild the quota preview or unrelated preference controls.
    func updateAppUpdate(_ appUpdate: AppUpdateViewState) {
        updateAvailableVersion = appUpdate.availableVersion
        hasUpdateProgress = appUpdate.progress != nil
        automaticUpdates.state = appUpdate.automaticChecksEnabled ? .on : .off
        if let progress = appUpdate.progress {
            updateStatus.stringValue = progress.heading + " · " + progress.detail
        }
        updateProgressButton.isHidden = appUpdate.progress == nil
        if appUpdate.isInstalling {
            updateButton.title = "更新正在进行…"
            updateButton.isEnabled = false
        } else if appUpdate.isChecking {
            if !hasUpdateProgress { updateStatus.stringValue = "正在检查 GitHub 正式版本。" }
            updateButton.title = "正在检查…"
            updateButton.isEnabled = true
        } else if let available = appUpdate.availableVersion {
            if !hasUpdateProgress { updateStatus.stringValue = "新版本 \(available) 可用；查看版本说明后可安装、稍后处理或跳过。" }
            updateButton.title = "查看 \(available)…"
            updateButton.isEnabled = true
        } else {
            let lastSuccess = appUpdate.lastSuccess.map {
                DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short)
            } ?? "尚未成功检查"
            if !hasUpdateProgress { updateStatus.stringValue = appUpdate.automaticChecksAvailable
                ? "最近成功：\(lastSuccess)。后台无更新或失败时不会弹窗。"
                : "自动检查仅在安装到 /Applications 或 ~/Applications 后运行；手动检查始终可用。" }
            updateButton.title = "检查更新…"
            updateButton.isEnabled = true
        }
    }

    private func configure() {
        guard let content = window?.contentView else { return }
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        NSLayoutConstraint.activate([tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), tabs.heightAnchor.constraint(equalToConstant: 420)])
        displayMode.addItems(withTitles: HUDDisplayMode.allCases.map(\.title))
        displayMode.selectItem(at: HUDDisplayMode.allCases.firstIndex(of: HUDDisplayMode.load()) ?? 0)
        displayMode.setAccessibilityLabel("浮窗显示模式")
        notchRestingState.addItems(withTitles: ["静止态 Compact", "额度预览态 Peek（默认）"])
        selectSavedNotchRestingState()
        notchRestingState.setAccessibilityLabel("刘海常驻形态")
        notchRestingState.setAccessibilityIdentifier("settings.notchRestingState")
        menuMode.addItems(withTitles: MenuBarDisplayMode.allCases.map(\.title))
        menuMode.setAccessibilityLabel("菜单栏内容")
        modeAvailability.font = .systemFont(ofSize: 11)
        modeAvailability.textColor = .secondaryLabelColor
        language.addItems(withTitles: ["中文", "English"])
        material.addItems(withTitles: HUDAppearance.Material.allCases.map(\.title))
        material.selectItem(at: HUDAppearance.Material.allCases.firstIndex(of: appearance.material) ?? 0)
        material.setAccessibilityLabel("界面材质")
        material.setAccessibilityIdentifier("settings.material")
        color.addItems(withTitles: HUDAppearance.ColorChoice.allCases.map(\.title))
        for control in [language, material, color, displayMode, notchRestingState, menuMode] { control.target = self; control.action = #selector(changed(_:)) }
        for control in [tasks, persistent, visible, automaticUpdates, updateNotifications, resetNewsEnabled, resetNewsSound, autoLaunch, quotaAlertsEnabled, quotaAlertsSound] { control.target = self; control.action = #selector(changed(_:)) }
        for slider in [backgroundSlider, foregroundSlider] { slider.target = self; slider.action = #selector(changed(_:)); slider.isContinuous = true }
        language.setAccessibilityLabel("信息语言")
        color.setAccessibilityLabel("浮窗颜色")
        backgroundSlider.setAccessibilityLabel("背景不透明度")
        foregroundSlider.setAccessibilityLabel("文字不透明度")
        autoLaunch.setAccessibilityIdentifier("settings.hostAutoLaunch")
        autoLaunchStatus.font = .systemFont(ofSize: 11)
        autoLaunchStatus.maximumNumberOfLines = 2
        autoLaunchStatus.lineBreakMode = .byTruncatingTail
        autoLaunchStatus.textColor = .secondaryLabelColor
        autoLaunch.state = HostAutoLauncher.isEnabled ? .on : .off
        let diagnostics = NSButton(title: "连接检查与诊断…", target: self, action: #selector(openConnectionDiagnostics))
        diagnostics.setAccessibilityIdentifier("settings.connectionDiagnostics")
        let general = column([autoLaunch, autoLaunchStatus, row("显示模式", [displayMode]), modeAvailability, visible, row("刘海常驻形态", [notchRestingState]), note("Compact 悬停展示额度；Peek 常驻展示额度。"), row("菜单栏内容", [menuMode]), row("信息语言", [language]), tasks, diagnostics])
        let appearancePanel = column([row("界面材质", [material]), note("跟随系统在 macOS 26 及以上使用 Liquid Glass；较旧系统使用经典外观。"), row("浮窗颜色", [color]), row("背景不透明度", [backgroundSlider, backgroundValue]), row("文字不透明度", [foregroundSlider, foregroundValue]), note("颜色和透明度仅用于经典浮窗；切换材质会保留这些数值。系统辅助功能设置优先。")])
        updateStatus.font = .systemFont(ofSize: 11)
        updateStatus.textColor = .secondaryLabelColor
        updateButton.target = self
        updateButton.action = #selector(updateClicked)
        automaticUpdates.setAccessibilityIdentifier("settings.automaticUpdates")
        updateButton.setAccessibilityIdentifier("settings.checkForUpdates")
        updateProgressButton.target = self
        updateProgressButton.isHidden = true
        updateProgressButton.action = #selector(viewProgressClicked)
        updateProgressButton.setAccessibilityIdentifier("settings.updateProgress")
        updateNotifications.setAccessibilityIdentifier("settings.updateNotifications")
        updateNotificationPermission.setAccessibilityIdentifier("settings.updateNotificationPermission")
        updateNotificationPermission.font = .systemFont(ofSize: 11)
        updateNotificationPermission.textColor = .secondaryLabelColor
        authorizeUpdateNotifications.target = self
        authorizeUpdateNotifications.action = #selector(authorizeUpdateNotificationsClicked)
        authorizeUpdateNotifications.setAccessibilityIdentifier("settings.authorizeUpdateNotifications")
        let updates = column([automaticUpdates, updateStatus, updateProgressButton, updateButton, updateNotifications, updateNotificationPermission, authorizeUpdateNotifications,
                              note("发现新版本后显示菜单栏更新标记。“稍后”保留入口；“跳过此版本”隐藏该版本提醒。"),
                              note("启动后约 30 秒按需检查；成功后 24 小时内不重复请求。手动检查可找回已跳过版本。")])
        let hookButton = NSButton(title: "配置 Hooks 实验…", target: self, action: #selector(openHookExperiment))
        let experiments = column([note("Hooks 任务监测默认关闭。可审阅配置后启用，随时恢复日志模式。"), hookButton])
        resetNewsEnabled.setAccessibilityIdentifier("settings.resetNewsEnabled")
        resetNewsSound.setAccessibilityIdentifier("settings.resetNewsSound")
        resetNewsCheck.setAccessibilityIdentifier("settings.checkResetNews")
        resetNewsCheck.target = self
        resetNewsCheck.action = #selector(checkResetNewsClicked)
        resetNewsCheck.isEnabled = false
        for label in [resetNewsStatus, resetNewsPermission, resetNewsTiming] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        let resetNews = column([resetNewsEnabled, resetNewsSound,
            note("仅在 Codex 与 HUD App 运行时检查；首次开启会请求系统通知权限。提示音默认关闭。"),
            resetNewsPermission, resetNewsStatus, resetNewsTiming, resetNewsCheck])
        quotaAlertsEnabled.setAccessibilityIdentifier("settings.quotaAlertsEnabled")
        quotaAlertsSound.setAccessibilityIdentifier("settings.quotaAlertsSound")
        for (control, label, identifier) in [(fiveHourThreshold, "5 小时额度提醒阈值", "settings.fiveHourThreshold"),
                                              (weeklyThreshold, "周额度提醒阈值", "settings.weeklyThreshold")] {
            control.addItems(withTitles: quotaThresholds.map { "剩余 \($0)%" })
            control.selectItem(at: 1)
            control.target = self
            control.action = #selector(changed(_:))
            control.setAccessibilityLabel(label)
            control.setAccessibilityIdentifier(identifier)
        }
        quotaAlertsPermission.font = .systemFont(ofSize: 11)
        quotaAlertsPermission.textColor = .secondaryLabelColor
        let alerts = column([quotaAlertsEnabled, row("5 小时额度", [fiveHourThreshold]), row("周额度", [weeklyThreshold]),
                             quotaAlertsSound, quotaAlertsPermission,
                             note("开启后的第一组数据用于建立基线。之后剩余额度从阈值以上降至阈值或以下时提醒；每个账号、每个额度周期最多提醒一次。"),
                             note("关闭、休眠或数据中断后重新建立基线。重置时间或账号无法确认时暂停提醒。公开重置预告可在对应设置页单独管理。")])
        var panels: [(TabIdentifier, String, NSView)] = [(.general, "通用", general), (.appearance, "外观", appearancePanel)]
        if touchBarHardware.shouldShowSettings {
            panels.append((.touchBar, "Touch Bar", column([persistent, availability])))
        }
        panels += [(.experiments, "实验", experiments), (.updates, "更新", updates),
                   (.resetNews, DisplayLanguage.text("重置预告", "Reset forecasts"), resetNews),
                   (.quotaAlerts, "额度提醒", alerts)]
        for (identifier, title, view) in panels {
            let item = NSTabViewItem(identifier: identifier.rawValue)
            item.label = title
            let host = NSView()
            host.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16), view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16), view.topAnchor.constraint(equalTo: host.topAnchor, constant: 18)])
            item.view = host
            tabs.addTabViewItem(item)
        }
        let quit = NSButton(title: "退出 App", target: self, action: #selector(quitClicked))
        quit.translatesAutoresizingMaskIntoConstraints = false
        quit.setAccessibilityIdentifier("settings.quit")
        content.addSubview(quit)
        NSLayoutConstraint.activate([quit.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), quit.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)])
        // A preview view is not a HUD window and must never resize this window.
        preview.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(preview)
        NSLayoutConstraint.activate([preview.centerXAnchor.constraint(equalTo: content.centerXAnchor), preview.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 22)])
        let caption = note("桌面浮窗外观预览 · 刘海主体保持黑色")
        caption.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(caption)
        NSLayoutConstraint.activate([caption.centerXAnchor.constraint(equalTo: content.centerXAnchor), caption.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 10)])
    }
    @objc private func quitClicked() { onQuit?() }
    @objc private func openHookExperiment() { onHookExperiment?() }
    @objc private func checkResetNewsClicked() { onCheckResetNews?() }
    @objc private func openConnectionDiagnostics() { onConnectionDiagnostics?() }
    @objc private func updateClicked() {
        if updateAvailableVersion != nil { onViewUpdate?() }
        else { onCheckForUpdates?() }
    }
    @objc private func viewProgressClicked() { onViewUpdateProgress?() }

    @objc private func authorizeUpdateNotificationsClicked() { onAuthorizeUpdateNotifications?() }

    private func row(_ title: String, _ controls: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let stack = NSStackView(views: [label] + controls)
        stack.orientation = .horizontal
        stack.spacing = 8
        for control in controls where control is NSSlider { control.widthAnchor.constraint(equalToConstant: 170).isActive = true }
        return stack
    }
    private func column(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }
    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }
    private func updatePreview() {
        let classic = appearance.material == .classic || !HUDAppearance.supportsGlass
        color.isEnabled = classic
        backgroundSlider.isEnabled = classic
        foregroundSlider.isEnabled = classic
        backgroundValue.stringValue = "\(Int(backgroundSlider.doubleValue))%"
        foregroundValue.stringValue = "\(Int(foregroundSlider.doubleValue))%"
        preview.updateAppearance(appearance)
    }
    private func selectSavedNotchRestingState() {
        notchRestingState.selectItem(at: NotchPresentationModel.savedAlwaysShowQuota() ? 1 : 0)
    }
    @objc private func changed(_ sender: NSControl) {
        if sender === autoLaunch { onAutoLaunch?(autoLaunch.state == .on); return }
        if sender === quotaAlertsEnabled || sender === quotaAlertsSound || sender === fiveHourThreshold || sender === weeklyThreshold {
            onQuotaAlerts?(QuotaAlertConfiguration(enabled: quotaAlertsEnabled.state == .on,
                fiveHourThreshold: quotaThresholds[max(0, fiveHourThreshold.indexOfSelectedItem)],
                weeklyThreshold: quotaThresholds[max(0, weeklyThreshold.indexOfSelectedItem)],
                soundEnabled: quotaAlertsSound.state == .on))
            return
        }
        if sender === notchRestingState { onAlwaysShowQuota?(notchRestingState.indexOfSelectedItem == 1); return }
        if sender === menuMode { onMenuMode?(MenuBarDisplayMode.allCases[menuMode.indexOfSelectedItem]); return }
        if sender === visible { onVisibility?(visible.state == .on); return }
        if sender === displayMode { onDisplayMode?(HUDDisplayMode.allCases[displayMode.indexOfSelectedItem]); return }
        if sender === language { onLanguage?(language.indexOfSelectedItem == 0 ? .chinese : .english); return }
        if sender === tasks { onTaskStatus?(tasks.state == .on); return }
        if sender === persistent { onPersistent?(persistent.state == .on); return }
        if sender === automaticUpdates { onAutomaticUpdates?(automaticUpdates.state == .on); return }
        if sender === updateNotifications { onUpdateNotifications?(updateNotifications.state == .on); return }
        if sender === resetNewsEnabled { onResetNewsEnabled?(resetNewsEnabled.state == .on); return }
        if sender === resetNewsSound { onResetNewsSound?(resetNewsSound.state == .on); return }
        appearance.material = HUDAppearance.Material.allCases[material.indexOfSelectedItem]
        appearance.colorChoice = HUDAppearance.ColorChoice.allCases[color.indexOfSelectedItem]
        appearance.backgroundOpacity = backgroundSlider.doubleValue / 100
        appearance.contentOpacity = foregroundSlider.doubleValue / 100
        updatePreview()
        onAppearance?(appearance)
    }
}
