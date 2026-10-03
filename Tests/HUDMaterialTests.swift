import AppKit
import SwiftUI

@main
enum HUDMaterialTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static var sample: RateLimitDisplayState {
        var state = RateLimitDisplayState.initial
        state.fiveHour = LimitMeter(title: "5h", shortTitle: "5h", window: RateLimitWindow(usedPercent: 28, windowDurationMins: 300, resetsAt: 1_800_000_000))
        state.weekly = LimitMeter(title: "7d", shortTitle: "7d", window: RateLimitWindow(usedPercent: 57, windowDurationMins: 10080, resetsAt: 1_800_000_000))
        state.taskStatus = TaskStatusSummary(runningCount: 2)
        state.tokenUsage = TokenUsageSummary(yesterdayTokens: 128400, cumulativeTokens: 8620000)
        state.lastUpdated = Date(timeIntervalSince1970: 1_800_000_000)
        return state
    }
    static func geometry(width: CGFloat = 800) -> NotchHUDGeometry {
        let rect = CGRect(x: 0, y: 0, width: width, height: 600)
        return NotchHUDGeometry(screen: rect, topInset: 32,
            leftArea: CGRect(x: 0, y: 568, width: width / 2 - 90, height: 32),
            rightArea: CGRect(x: width / 2 + 90, y: 568, width: width / 2 - 90, height: 32))!
    }
    static func notchMarkerChecks() {
        let model = NotchPresentationModel()
        model.animationsEnabled = false
        let host = NotchHostingView(model: model, bridge: NotchGeometryBridge())
        let panel = NotchIslandPanel()
        panel.contentView = host
        defer { panel.orderOut(nil) }
        for width: CGFloat in [800, 460] {
            let layout = NotchLayout(geometry: geometry(width: width))
            panel.setFrame(CGRect(x: 100, y: 100, width: width, height: 360), display: false)
            model.configure(layout)
            model.setVisible(true)
            model.update(sample, tasksEnabled: true)
            model.click()
            for material in HUDAppearance.Material.allCases {
                model.setMaterial(material)
                panel.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / width
                for left in [true, false] {
                    let x = Int(layout.markX(left: left) * scale)
                    var visiblePixels = 0
                    for px in (x - Int(18 * scale))..<(x + Int(18 * scale)) {
                        for py in 0..<Int(layout.visualBarHeight * scale) {
                            if let color = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB),
                               color.alphaComponent > 0.5, min(color.redComponent, color.greenComponent, color.blueComponent) > 0.35 {
                                visiblePixels += 1
                            }
                        }
                    }
                    check(visiblePixels > 10, "Top icon remains visible after material/width changes: \(material), \(width), left=\(left), pixels=\(visiblePixels)")
                }
            }
        }
    }
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "HUDMaterialTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        DisplayLanguage.defaults = defaults
        defer { DisplayLanguage.defaults = .standard; defaults.removePersistentDomain(forName: suite) }
        if CommandLine.arguments.contains("--preview") || Bundle.main.bundleIdentifier == "local.gpt-touchbar-hud.liquid-glass-preview" {
            let preview = HUDMaterialPreview()
            preview.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.run()
            withExtendedLifetime(preview) {}
            return
        }
        check(HUDAppearance.load(from: defaults).material == .system, "Fresh preferences follow system")
        for key in ["hud.color", "hud.backgroundOpacity", "hud.contentOpacity", "hud.opacity"] {
            defaults.set(key == "hud.color" ? "blue" : 0.45, forKey: key)
            check(HUDAppearance.load(from: defaults).material == .classic, "Legacy explicit setting survives: \(key)")
            defaults.removeObject(forKey: key)
        }
        var appearance = HUDAppearance(material: .system, colorChoice: .purple, backgroundOpacity: 0.45, contentOpacity: 0.6)
        appearance.save(to: defaults)
        check(HUDAppearance.load(from: defaults) == appearance, "Explicit system choice wins over retained legacy values")
        appearance.material = .classic
        appearance.save(to: defaults)
        check(HUDAppearance.load(from: defaults) == appearance, "Switch back restores classic color and both opacity values")
        for supported in [false, true] {
            for reduceTransparency in [false, true] {
                for contrast in [false, true] {
                    check(HUDAppearance.surface(for: .classic, supportsGlass: supported, reduceTransparency: reduceTransparency, increaseContrast: contrast) == .classic, "Classic remains compatible")
                    let expected: HUDAppearance.Surface = !supported ? .classic : (reduceTransparency || contrast ? .solidSystem : .glass)
                    check(HUDAppearance.surface(for: .system, supportsGlass: supported, reduceTransparency: reduceTransparency, increaseContrast: contrast) == expected, "Availability and accessibility choose an explicit surface")
                }
            }
        }
        let hud = CompactQuotaHUDView(initialAppearance: appearance, onRefresh: {}, onClose: {}, contextMenuProvider: { NSMenu() })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 620, height: 80))
        window.contentView = container
        container.addSubview(hud)
        hud.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([hud.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hud.topAnchor.constraint(equalTo: container.topAnchor)])
        hud.update(with: sample)
        hud.updateMessages(forecastCount: 2, available: true)
        container.layoutSubtreeIfNeeded()
        let controls = descendants(hud).compactMap { $0 as? NSButton }
        let refresh = controls.first { $0.accessibilityIdentifier() == "hud.refresh" }!
        let messages = controls.first { $0.accessibilityIdentifier() == "hud.messages" }!
        let classicWidth = hud.frame.width
        let classicCount = hud.layoutUpdateCount
        appearance.material = .system
        hud.updateAppearance(appearance)
        container.layoutSubtreeIfNeeded()
        let solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !solid {
            let glass = descendants(hud).compactMap { $0 as? NSGlassEffectView }
            check(glass.count == 1, "Exactly one native glass shell")
            check(glass[0].contentView.map { refresh.isDescendant(of: $0) && messages.isDescendant(of: $0) } == true, "Existing controls belong to native contentView")
            check(descendants(hud).compactMap { $0 as? NSStackView }.allSatisfy { $0.alphaValue == 1 }, "Glass foreground stays opaque")
            let labels = descendants(hud).compactMap { $0 as? NSTextField }.filter { $0.stringValue.contains("%") }
            check(labels.count == 2 && labels.allSatisfy { $0.textColor == .labelColor }, "Both quota labels use semantic colors")
            check(messages.contentTintColor == .labelColor, "Forecast actions retain readable semantic contrast")
            check(glass[0].frame == hud.bounds, "Native shell covers exactly the HUD bounds")
            let glassID = ObjectIdentifier(glass[0])
            hud.update(with: sample)
            hud.updateAppearance(appearance)
            check(descendants(hud).compactMap { $0 as? NSGlassEffectView }.map(ObjectIdentifier.init) == [glassID], "Repeated data does not recreate glass")
        }
        #endif
        check(hud.frame.width == classicWidth && hud.frame.height == 40, "Material changes preserve HUD geometry: \(classicWidth) -> \(hud.frame)")
        check(hud.layoutUpdateCount == classicCount, "Material does not relayout unchanged data")
        var clicks = 0
        hud.onOpenMessages = { clicks += 1 }
        messages.performClick(nil)
        check(clicks == 1, "Forecast control remains connected after reparenting")
        appearance.material = .classic
        hud.updateAppearance(appearance)
        container.layoutSubtreeIfNeeded()
        let refreshRect = refresh.superview!.convert(refresh.alignmentRect(forFrame: refresh.frame), to: hud)
        check(abs(refreshRect.midY - hud.bounds.midY) < 0.5, "Classic content remains vertically centered: \(refreshRect) in \(hud.bounds)")
        check(descendants(hud).contains { $0 === refresh } && descendants(hud).contains { $0 === messages }, "Switching back preserves control identity")
        check(descendants(hud).compactMap { $0 as? NSStackView }.first?.alphaValue == (solid ? 1 : 0.6), "Classic opacity restored")

        let model = NotchPresentationModel()
        model.animationsEnabled = false
        model.configure(NotchLayout(geometry: geometry()))
        model.setVisible(true)
        model.click()
        model.selectPage(.usage)
        let size = model.size
        model.animationsEnabled = true
        model.hover(true)
        check(model.sweepActive, "Classic controls still have bounded feedback")
        model.setMaterial(.system)
        check(model.state == .expanded && model.page == .usage && model.size == size, "Material changes preserve notch state, page and geometry")
        check(model.sweepActive == !HUDAppearance.supportsGlass, "Glass stops existing decorative feedback")
        var refreshing = sample
        refreshing.isRefreshing = true
        model.update(refreshing, tasksEnabled: true)
        check(model.sweepActive == !HUDAppearance.supportsGlass, "Refresh does not start a glass decoration clock")
        model.setEnvironment(reduceMotion: true, reduceTransparency: true, lowPower: false, increaseContrast: true)
        check(model.controlSurface == (HUDAppearance.supportsGlass ? .solidSystem : .classic), "Notch accessibility fallback")
        check(model.size == size && model.detailsVisible, "Accessibility keeps details usable")

        notchMarkerChecks()
        let prefs = PreferencesWindowController(appearance: appearance, touchBarHardware: .absent)
        prefs.update(appearance: appearance, state: sample, taskEnabled: true, persistentEnabled: false, persistentAvailable: false)
        let tabs = descendants(prefs.window!.contentView!).compactMap { $0 as? NSTabView }.first!
        tabs.selectTabViewItem(withIdentifier: "appearance")
        prefs.window!.contentView!.layoutSubtreeIfNeeded()
        let material = descendants(tabs.selectedTabViewItem!.view!).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "settings.material" }!
        var saved: HUDAppearance?
        prefs.onAppearance = { saved = $0 }
        material.selectItem(at: 0)
        _ = material.sendAction(material.action, to: material.target)
        check(saved?.material == .system && saved?.colorChoice == .purple && saved?.backgroundOpacity == 0.45 && saved?.contentOpacity == 0.6, "Settings sends material while preserving classic settings")
        let sliders = descendants(tabs.selectedTabViewItem!.view!).compactMap { $0 as? NSSlider }
        check(sliders.count == 2 && sliders.allSatisfy { $0.isEnabled == !HUDAppearance.supportsGlass }, "Sliders explain scope through enabled state")
        prefs.window?.orderOut(nil)
        print("HUD material tests passed: \(checks) checks; native glass supported: \(HUDAppearance.supportsGlass)")
    }
}

/// Demo data only: this entry point never constructs AppDelegate or host services.
final class HUDMaterialPreview: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let model = NotchPresentationModel()
    private let bridge = NotchGeometryBridge()
    private let hud: CompactQuotaHUDView
    private let material = NSSegmentedControl(labels: ["系统玻璃", "经典"], trackingMode: .selectOne, target: nil, action: nil)
    private let theme = NSSegmentedControl(labels: ["浅色", "深色"], trackingMode: .selectOne, target: nil, action: nil)
    private let language = NSSegmentedControl(labels: ["中文", "English"], trackingMode: .selectOne, target: nil, action: nil)
    private let contrast = NSButton(checkboxWithTitle: "刘海实色回退", target: nil, action: nil)
    private let narrow = NSButton(checkboxWithTitle: "窄屏布局", target: nil, action: nil)
    private var prefs: PreferencesWindowController?
    private var floating: CompactHUDPanel?
    private var host: NotchHostingView
    override init() {
        hud = CompactQuotaHUDView(initialAppearance: HUDAppearance(material: .system, colorChoice: .black, backgroundOpacity: 0.94, contentOpacity: 1), onRefresh: {}, onClose: {}, contextMenuProvider: { NSMenu() })
        host = NotchHostingView(model: model, bridge: bridge)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 820, height: 590), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Liquid Glass B · 原生预览 · 演示数据 / 模拟刘海"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 820, height: 590))
        root.wantsLayer = true
        window.contentView = root
        for (index, control) in [material, theme, language].enumerated() {
            control.selectedSegment = 0
            control.target = self
            control.action = #selector(update)
            control.frame = CGRect(x: 22 + index * 230, y: 540, width: 210, height: 28)
            root.addSubview(control)
        }
        for (index, button) in [contrast, narrow].enumerated() {
            button.target = self; button.action = #selector(update)
            button.frame = CGRect(x: 22 + index * 190, y: 497, width: 180, height: 26)
            root.addSubview(button)
        }
        let floatingButton = NSButton(title: "真实浮窗", target: self, action: #selector(showFloating))
        floatingButton.frame = CGRect(x: 420, y: 497, width: 160, height: 26)
        root.addSubview(floatingButton)
        let settings = NSButton(title: "外观设置预览", target: self, action: #selector(showSettings))
        settings.frame = CGRect(x: 610, y: 497, width: 180, height: 26)
        root.addSubview(settings)
        root.addSubview(hud)
        hud.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([hud.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            hud.topAnchor.constraint(equalTo: root.topAnchor, constant: 122)])
        host.frame = CGRect(x: 10, y: 40, width: 800, height: 360)
        root.addSubview(host)
        let note = NSTextField(labelWithString: "使用正式 HUD 视图与图标；演示不连接账号、不安装、不写入实际偏好。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.frame = CGRect(x: 24, y: 14, width: 760, height: 20)
        root.addSubview(note)
        model.animationsEnabled = false
        model.onRefresh = { [weak self] in self?.update() }
        model.onSettings = { [weak self] in self?.showSettings() }
        model.onHide = { [weak self] in self?.model.collapse() }
        update()
    }
    @objc func update() {
        DisplayLanguage.current = language.selectedSegment == 0 ? .chinese : .english
        window.appearance = NSAppearance(named: theme.selectedSegment == 0 ? .aqua : .darkAqua)
        let appearance = HUDAppearance(material: material.selectedSegment == 0 ? .system : .classic, colorChoice: .black, backgroundOpacity: 0.94, contentOpacity: 1)
        hud.updateAppearance(appearance)
        hud.update(with: HUDMaterialTests.sample)
        hud.updateMessages(forecastCount: 0, available: true)
        model.setMaterial(appearance.material)
        model.setEnvironment(reduceMotion: true, reduceTransparency: contrast.state == .on, lowPower: false, increaseContrast: contrast.state == .on)
        let layout = NotchLayout(geometry: HUDMaterialTests.geometry(width: narrow.state == .on ? 460 : 800))
        model.configure(layout)
        model.update(HUDMaterialTests.sample, tasksEnabled: true)
        model.setVisible(true)
        model.click()
        // Each scenario gets a host after its synthetic geometry is final.
        // Production resizes its panel and keeps the host at origin zero.
        host.removeFromSuperview()
        host = NotchHostingView(model: model, bridge: bridge)
        host.frame = CGRect(x: (820 - layout.windowFrame.width) / 2, y: 40, width: layout.windowFrame.width, height: 360)
        window.contentView?.addSubview(host)
        window.contentView?.layoutSubtreeIfNeeded()
    }
    @objc func showFloating() {
        floating?.orderOut(nil)
        let appearance = HUDAppearance(material: material.selectedSegment == 0 ? .system : .classic, colorChoice: .black, backgroundOpacity: 0.94, contentOpacity: 1)
        let controller = CompactHUDViewController(initialAppearance: appearance, onRefresh: {}, onClose: {}, onPresentTouchBar: { false }, contextMenuProvider: { [weak self] in
            let menu = NSMenu()
            let item = NSMenuItem(title: "返回原生预览", action: #selector(HUDMaterialPreview.returnToGallery), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return menu
        })
        let panel = CompactHUDPanel(contentViewController: controller)
        panel.title = "Liquid Glass · 真实浮窗 / 演示数据"
        panel.appearance = window.appearance
        controller.update(with: HUDMaterialTests.sample)
        controller.updateMessages(forecastCount: 0, available: true)
        controller.prepareToShow()
        panel.setContentSize(controller.view.fittingSize)
        panel.setFrameOrigin(CGPoint(x: window.frame.maxX - panel.frame.width - 24, y: window.frame.minY + 72))
        panel.orderFrontRegardless()
        floating = panel
        window.orderOut(nil)
    }
    @objc func returnToGallery() {
        floating?.orderOut(nil)
        window.makeKeyAndOrderFront(nil)
    }
    @objc func showSettings() {
        let appearance = HUDAppearance(material: material.selectedSegment == 0 ? .system : .classic, colorChoice: .black, backgroundOpacity: 0.94, contentOpacity: 1)
        let controller = PreferencesWindowController(appearance: appearance, touchBarHardware: .absent)
        controller.update(appearance: appearance, state: HUDMaterialTests.sample, taskEnabled: true, persistentEnabled: false, persistentAvailable: false)
        HUDMaterialTests.descendants(controller.window!.contentView!).compactMap { $0 as? NSTabView }.first?.selectTabViewItem(withIdentifier: "appearance")
        controller.onAppearance = { [weak self] value in
            self?.material.selectedSegment = value.material == .system ? 0 : 1
            self?.hud.updateAppearance(value)
            self?.model.setMaterial(value.material)
        }
        prefs = controller
        controller.showWindow(nil)
    }
    func windowWillClose(_ notification: Notification) { floating?.orderOut(nil); prefs?.window?.orderOut(nil); NSApp.stop(nil) }
}
