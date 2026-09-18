import AppKit

final class PreferencesWindowController: NSWindowController {
    var onAppearance: ((HUDAppearance) -> Void)?
    var onLanguage: ((DisplayLanguage) -> Void)?
    var onTaskStatus: ((Bool) -> Void)?
    var onDisplayMode: ((HUDDisplayMode) -> Void)?
    var onMenuMode: ((MenuBarDisplayMode) -> Void)?
    var onVisibility: ((Bool) -> Void)?
    private let menuMode = NSPopUpButton()
    private let visible = NSButton(checkboxWithTitle: "显示状态面板", target: nil, action: nil)
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
    private let preview: CompactQuotaHUDView

    init(appearance: HUDAppearance) {
        self.appearance = appearance
        preview = CompactQuotaHUDView(initialAppearance: appearance, onRefresh: {}, onClose: {}, contextMenuProvider: { NSMenu() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 445), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "设置 · GPT TouchBar HUD"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        configure()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(appearance: HUDAppearance, state: RateLimitDisplayState, taskEnabled: Bool, persistentEnabled: Bool, persistentAvailable: Bool) {
        self.appearance = appearance
        displayMode.selectItem(at: HUDDisplayMode.allCases.firstIndex(of: HUDDisplayMode.load()) ?? 0)
        modeAvailability.stringValue = NotchHUDGeometry.current() == nil ? "当前主显示屏无可用刘海区域，将回退桌面浮窗。" : "刘海下沿显示双额度；点击展开 Ledger 明细。"
        menuMode.selectItem(at: MenuBarDisplayMode.allCases.firstIndex(of: MenuBarDisplayMode.load()) ?? 0)
        visible.state = HUDPresentationPreferences().isVisible ? .on : .off
        color.selectItem(at: HUDAppearance.ColorChoice.allCases.firstIndex(of: appearance.colorChoice) ?? 0)
        language.selectItem(at: DisplayLanguage.current == .chinese ? 0 : 1)
        tasks.state = taskEnabled ? .on : .off
        persistent.state = persistentEnabled ? .on : .off
        persistent.isEnabled = persistentAvailable
        availability.stringValue = persistentAvailable ? "切换 App 后继续显示额度条。隐藏浮窗不影响 Touch Bar 常驻。" : "当前系统常驻接口不可用，保留原有焦点绑定显示。"
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
        NSLayoutConstraint.activate([tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), tabs.heightAnchor.constraint(equalToConstant: 305)])
        displayMode.addItems(withTitles: HUDDisplayMode.allCases.map(\.title))
        displayMode.selectItem(at: HUDDisplayMode.allCases.firstIndex(of: HUDDisplayMode.load()) ?? 0)
        displayMode.setAccessibilityLabel("浮窗显示模式")
        menuMode.addItems(withTitles: MenuBarDisplayMode.allCases.map(\.title))
        menuMode.setAccessibilityLabel("菜单栏内容")
        modeAvailability.font = .systemFont(ofSize: 11)
        modeAvailability.textColor = .secondaryLabelColor
        language.addItems(withTitles: ["中文", "English"])
        color.addItems(withTitles: HUDAppearance.ColorChoice.allCases.map(\.title))
        for control in [language, color, displayMode, menuMode] { control.target = self; control.action = #selector(changed(_:)) }
        for control in [tasks, persistent, visible] { control.target = self; control.action = #selector(changed(_:)) }
        for slider in [backgroundSlider, foregroundSlider] { slider.target = self; slider.action = #selector(changed(_:)); slider.isContinuous = true }
        language.setAccessibilityLabel("信息语言")
        color.setAccessibilityLabel("浮窗颜色")
        backgroundSlider.setAccessibilityLabel("背景不透明度")
        foregroundSlider.setAccessibilityLabel("文字不透明度")
        let general = column([row("显示模式", [displayMode]), modeAvailability, visible, row("菜单栏内容", [menuMode]), row("信息语言", [language]), tasks, note("隐藏状态独立保存；自动菜单栏在面板显示时仅保留图标。")])
        let appearancePanel = column([row("浮窗颜色", [color]), row("背景不透明度", [backgroundSlider, backgroundValue]), row("文字不透明度", [foregroundSlider, foregroundValue]), note("数值越高越不透明；修改即时保存，保留已有偏好。")])
        let touch = column([persistent, availability])
        for (title, view) in [("通用", general), ("外观", appearancePanel), ("Touch Bar", touch)] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            let host = NSView()
            host.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16), view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16), view.topAnchor.constraint(equalTo: host.topAnchor, constant: 18)])
            item.view = host
            tabs.addTabViewItem(item)
        }
        // A preview view is not a HUD window and must never resize this window.
        preview.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(preview)
        NSLayoutConstraint.activate([preview.centerXAnchor.constraint(equalTo: content.centerXAnchor), preview.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 22)])
        let caption = note("桌面浮窗外观预览 · 刘海面板始终使用黑色")
        caption.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(caption)
        NSLayoutConstraint.activate([caption.centerXAnchor.constraint(equalTo: content.centerXAnchor), caption.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 10)])
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
    @objc private func changed(_ sender: NSControl) {
        if sender === menuMode { onMenuMode?(MenuBarDisplayMode.allCases[menuMode.indexOfSelectedItem]); return }
        if sender === visible { onVisibility?(visible.state == .on); return }
        if sender === displayMode { onDisplayMode?(HUDDisplayMode.allCases[displayMode.indexOfSelectedItem]); return }
        if sender === language { onLanguage?(language.indexOfSelectedItem == 0 ? .chinese : .english); return }
        if sender === tasks { onTaskStatus?(tasks.state == .on); return }
        if sender === persistent { onPersistent?(persistent.state == .on); return }
        appearance.colorChoice = HUDAppearance.ColorChoice.allCases[color.indexOfSelectedItem]
        appearance.backgroundOpacity = backgroundSlider.doubleValue / 100
        appearance.contentOpacity = foregroundSlider.doubleValue / 100
        updatePreview()
        onAppearance?(appearance)
    }
}
