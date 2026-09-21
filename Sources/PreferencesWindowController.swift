import AppKit

final class PreferencesWindowController: NSWindowController {
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
    private let menuMode = NSPopUpButton()
    private let visible = NSButton(checkboxWithTitle: "显示状态面板", target: nil, action: nil)
    private let notchRestingState = NSPopUpButton()
    private let displayMode = NSPopUpButton()
    private let modeAvailability = NSTextField(wrappingLabelWithString: "")
    var onPersistent: ((Bool) -> Void)?
    private var appearance: HUDAppearance
    private let language = NSPopUpButton()
    private let color = NSPopUpButton()
    private let tasks = NSButton(checkboxWithTitle: "显示任务状态（实验性）", target: nil, action: nil)
    private let persistent = NSButton(checkboxWithTitle: "Touch Bar 常驻", target: nil, action: nil)
    private let backgroundSlider = NSSlider(value: 94, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let foregroundSlider = NSSlider(value: 100, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let backgroundValue = NSTextField(labelWithString: "")
    private let foregroundValue = NSTextField(labelWithString: "")
    private let availability = NSTextField(wrappingLabelWithString: "")
    private let automaticUpdates = NSButton(checkboxWithTitle: "自动检查更新", target: nil, action: nil)
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private let updateButton = NSButton(title: "检查更新…", target: nil, action: nil)
    private var updateAvailableVersion: String?
    private let preview: CompactQuotaHUDView

    init(appearance: HUDAppearance) {
        self.appearance = appearance
        preview = CompactQuotaHUDView(initialAppearance: appearance, onRefresh: {}, onClose: {}, contextMenuProvider: { NSMenu() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "设置 · GPT TouchBar HUD"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        configure()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        color.selectItem(at: HUDAppearance.ColorChoice.allCases.firstIndex(of: appearance.colorChoice) ?? 0)
        language.selectItem(at: DisplayLanguage.current == .chinese ? 0 : 1)
        tasks.state = taskEnabled ? .on : .off
        persistent.state = persistentEnabled ? .on : .off
        persistent.isEnabled = persistentAvailable
        availability.stringValue = persistentAvailable ? "切换 App 后继续显示额度条。隐藏浮窗不影响 Touch Bar 常驻。" : "当前系统常驻接口不可用，保留原有焦点绑定显示。"
        updateAvailableVersion = appUpdate.availableVersion
        automaticUpdates.state = appUpdate.automaticChecksEnabled ? .on : .off
        if appUpdate.isInstalling {
            updateStatus.stringValue = "正在下载、校验或准备安装更新。"
            updateButton.title = "正在安装…"
            updateButton.isEnabled = false
        } else if appUpdate.isChecking {
            updateStatus.stringValue = "正在检查 GitHub 正式版本。"
            updateButton.title = "正在检查…"
            updateButton.isEnabled = true
        } else if let available = appUpdate.availableVersion {
            updateStatus.stringValue = "新版本 \(available) 可用；查看版本说明后可安装、稍后处理或跳过。"
            updateButton.title = "查看 \(available)…"
            updateButton.isEnabled = true
        } else {
            let lastSuccess = appUpdate.lastSuccess.map {
                DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short)
            } ?? "尚未成功检查"
            updateStatus.stringValue = appUpdate.automaticChecksAvailable
                ? "最近成功：\(lastSuccess)。后台无更新或失败时不会弹窗。"
                : "自动检查仅在安装到 /Applications 或 ~/Applications 后运行；手动检查始终可用。"
            updateButton.title = "检查更新…"
            updateButton.isEnabled = true
        }
        backgroundSlider.doubleValue = appearance.backgroundOpacity * 100
        foregroundSlider.doubleValue = appearance.contentOpacity * 100
        updatePreview()
        preview.update(with: state)
    }

    private func configure() {
        guard let content = window?.contentView else { return }
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        NSLayoutConstraint.activate([tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), tabs.heightAnchor.constraint(equalToConstant: 340)])
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
        color.addItems(withTitles: HUDAppearance.ColorChoice.allCases.map(\.title))
        for control in [language, color, displayMode, notchRestingState, menuMode] { control.target = self; control.action = #selector(changed(_:)) }
        for control in [tasks, persistent, visible, automaticUpdates] { control.target = self; control.action = #selector(changed(_:)) }
        for slider in [backgroundSlider, foregroundSlider] { slider.target = self; slider.action = #selector(changed(_:)); slider.isContinuous = true }
        language.setAccessibilityLabel("信息语言")
        color.setAccessibilityLabel("浮窗颜色")
        backgroundSlider.setAccessibilityLabel("背景不透明度")
        foregroundSlider.setAccessibilityLabel("文字不透明度")
        let general = column([row("显示模式", [displayMode]), modeAvailability, visible, row("刘海常驻形态", [notchRestingState]), note("Compact 悬停展示额度；Peek 常驻展示额度。"), row("菜单栏内容", [menuMode]), row("信息语言", [language]), tasks, note("隐藏状态独立保存；自动菜单栏在面板显示时仅保留图标。")])
        let appearancePanel = column([row("浮窗颜色", [color]), row("背景不透明度", [backgroundSlider, backgroundValue]), row("文字不透明度", [foregroundSlider, foregroundValue]), note("数值越高越不透明；修改即时保存，保留已有偏好。")])
        let touch = column([persistent, availability])
        updateStatus.font = .systemFont(ofSize: 11)
        updateStatus.textColor = .secondaryLabelColor
        updateButton.target = self
        updateButton.action = #selector(updateClicked)
        automaticUpdates.setAccessibilityIdentifier("settings.automaticUpdates")
        updateButton.setAccessibilityIdentifier("settings.checkForUpdates")
        let updates = column([automaticUpdates, updateStatus, updateButton, note("启动后约 30 秒按需检查；成功后 24 小时内不重复请求。手动检查可找回已跳过版本。")])
        let hookButton = NSButton(title: "配置 Hooks 实验…", target: self, action: #selector(openHookExperiment))
        let experiments = column([note("Hooks 任务监测默认关闭。可审阅配置后启用，随时恢复日志模式。"), hookButton])
        for (title, view) in [("通用", general), ("外观", appearancePanel), ("Touch Bar", touch), ("实验", experiments), ("更新", updates)] {
            let item = NSTabViewItem(identifier: title)
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
        let caption = note("桌面浮窗外观预览 · 刘海面板始终使用黑色")
        caption.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(caption)
        NSLayoutConstraint.activate([caption.centerXAnchor.constraint(equalTo: content.centerXAnchor), caption.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 10)])
    }
    @objc private func quitClicked() { onQuit?() }
    @objc private func openHookExperiment() { onHookExperiment?() }
    @objc private func updateClicked() {
        if updateAvailableVersion != nil { onViewUpdate?() }
        else { onCheckForUpdates?() }
    }

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
        backgroundValue.stringValue = "\(Int(backgroundSlider.doubleValue))%"
        foregroundValue.stringValue = "\(Int(foregroundSlider.doubleValue))%"
        preview.updateAppearance(appearance)
    }
    private func selectSavedNotchRestingState() {
        notchRestingState.selectItem(at: NotchPresentationModel.savedAlwaysShowQuota() ? 1 : 0)
    }
    @objc private func changed(_ sender: NSControl) {
        if sender === notchRestingState { onAlwaysShowQuota?(notchRestingState.indexOfSelectedItem == 1); return }
        if sender === menuMode { onMenuMode?(MenuBarDisplayMode.allCases[menuMode.indexOfSelectedItem]); return }
        if sender === visible { onVisibility?(visible.state == .on); return }
        if sender === displayMode { onDisplayMode?(HUDDisplayMode.allCases[displayMode.indexOfSelectedItem]); return }
        if sender === language { onLanguage?(language.indexOfSelectedItem == 0 ? .chinese : .english); return }
        if sender === tasks { onTaskStatus?(tasks.state == .on); return }
        if sender === persistent { onPersistent?(persistent.state == .on); return }
        if sender === automaticUpdates { onAutomaticUpdates?(automaticUpdates.state == .on); return }
        appearance.colorChoice = HUDAppearance.ColorChoice.allCases[color.indexOfSelectedItem]
        appearance.backgroundOpacity = backgroundSlider.doubleValue / 100
        appearance.contentOpacity = foregroundSlider.doubleValue / 100
        updatePreview()
        onAppearance?(appearance)
    }
}
