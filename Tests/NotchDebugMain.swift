import AppKit

/// Standalone executable. No AppDelegate, Hook installer, usage fetcher or updater is created.
@main
enum NotchDebugMain {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let suite = "NotchFusionDebug." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let previous = DisplayLanguage.defaults
        DisplayLanguage.defaults = defaults
        defer { DisplayLanguage.defaults = previous; defaults.removePersistentDomain(forName: suite) }
        DisplayLanguage.current = .chinese
        let debug = NotchDebugWindow()
        let args = CommandLine.arguments
        if args.contains("--snapshots") {
            try debug.snapshots()
            return
        }
        debug.window.makeKeyAndOrderFront(nil)
        if args.contains("--desktop") { debug.toggleDesktop() }
        var exitTimer: Timer?
        if let flag = args.firstIndex(of: "--seconds"), args.indices.contains(flag + 1), let seconds = Double(args[flag + 1]) {
            exitTimer = Timer.scheduledTimer(withTimeInterval: max(1, seconds), repeats: false) { _ in app.stop(nil) }
        }
        app.run()
        exitTimer?.invalidate()
        debug.close()
        print("Synthetic debug stopped; its HUD and camera windows are closed.")
    }
}

private final class NotchDebugWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let scene = NotchSimulationScene(frame: NSRect(x: 0, y: 0, width: 760, height: 340))
    private let progress = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let language = NSSegmentedControl(labels: ["中文", "English"], trackingMode: .selectOne, target: nil, action: nil)
    private let data = NSSegmentedControl(labels: ["双额度", "单额度", "长数字"], trackingMode: .selectOne, target: nil, action: nil)
    private let width = NSSegmentedControl(labels: ["自然宽", "220 pt", "340 pt"], trackingMode: .selectOne, target: nil, action: nil)
    private let screen = NSSegmentedControl(labels: ["180 × 32 @2x", "140 × 24 @1x", "220 × 38 @2x"], trackingMode: .selectOne, target: nil, action: nil)
    private let background = NSSegmentedControl(labels: ["蓝底", "浅底", "深底"], trackingMode: .selectOne, target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let desktop = LegacyNotchHUDController()
    private var cameraPanel: NSPanel?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "SYNTHETIC · 刘海融合原生调试（假数据，未校准）"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = root
        scene.frame.origin = NSPoint(x: 20, y: 240)
        root.addSubview(scene)
        for (index, control) in [language, data, width, screen, background].enumerated() {
            control.selectedSegment = 0
            control.target = self
            control.action = #selector(changed)
            control.frame = NSRect(x: 20, y: 200 - CGFloat(index) * 32, width: 420, height: 26)
            root.addSubview(control)
        }
        let label = NSTextField(labelWithString: "展开进度（使用正式 180 ms 曲线）")
        label.frame = NSRect(x: 460, y: 201, width: 320, height: 24)
        root.addSubview(label)
        progress.frame = NSRect(x: 460, y: 163, width: 310, height: 26)
        progress.target = self
        progress.action = #selector(changed)
        progress.isContinuous = true
        root.addSubview(progress)
        for (title, action, x) in [("收起 / 展开", #selector(toggle), CGFloat(460)), ("桌面顶部模拟", #selector(toggleDesktop), CGFloat(600))] {
            let button = NSButton(title: title, target: self, action: action)
            button.frame = NSRect(x: x, y: 117, width: 140, height: 28)
            root.addSubview(button)
        }
        status.frame = NSRect(x: 20, y: 12, width: 760, height: 48)
        status.maximumNumberOfLines = 3
        status.font = .systemFont(ofSize: 11)
        root.addSubview(status)
        scene.hud.onToggle = { [weak self] in self?.toggle() }
        scene.hud.onCollapse = { [weak self] in self?.progress.doubleValue = 0; self?.changed() }
        scene.hud.onRefresh = { [weak self] in self?.changed() }
        desktop.onHide = { [weak self] in self?.stopDesktop() }
        changed()
    }
    private var fixture: (CGFloat, CGFloat, CGFloat) {
        switch screen.selectedSegment {
        case 1: return (140, 24, 1)
        case 2: return (220, 38, 2)
        default: return (180, 32, 2)
        }
    }
    private var state: RateLimitDisplayState { NotchSimulation.state(single: data.selectedSegment == 1, long: data.selectedSegment == 2) }
    @objc private func changed() {
        DisplayLanguage.current = language.selectedSegment == 0 ? .chinese : .english
        let (neck, inset, scale) = fixture
        let geometry = NotchSimulation.geometry(inset: inset, neck: neck, scale: scale)
        let requested: CGFloat? = width.selectedSegment == 0 ? nil : (width.selectedSegment == 1 ? 220 : 340)
        scene.background = background.selectedSegment == 0 ? NotchSimulation.blue : (background.selectedSegment == 1 ? .white : NSColor(calibratedWhite: 0.18, alpha: 1))
        scene.configure(geometry: geometry, state: state, width: requested, progress: progress.doubleValue)
        status.stringValue = "SYNTHETIC · 未校准 · HUD \(Int(scene.hud.bounds.width)) × \(Int(scene.hud.bounds.height)) pt，内容起点 \(Int(inset)) pt\n顶部假刘海独立绘制；顶部模拟点击不抢焦点。关闭此窗口仅结束本模拟。"
        if cameraPanel != nil { stopDesktop(); startDesktop() }
    }
    @objc private func toggle() { progress.doubleValue = progress.doubleValue < 1 ? 1 : 0; changed() }
    @objc func toggleDesktop() { cameraPanel == nil ? startDesktop() : stopDesktop() }
    private func startDesktop() {
        guard let display = NSScreen.main ?? NSScreen.screens.first else { return }
        let (neck, inset, _) = fixture
        let geometry = NotchSimulation.geometry(screen: display.frame, inset: inset, neck: neck, scale: display.backingScaleFactor)
        let fake = NSPanel(contentRect: geometry.cameraEnclosure, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        fake.backgroundColor = .clear
        fake.isOpaque = false
        fake.hasShadow = false
        fake.ignoresMouseEvents = true
        fake.level = .statusBar
        fake.collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary, .stationary]
        fake.isReleasedWhenClosed = false
        fake.title = "SYNTHETIC · 假刘海"
        fake.contentView = SyntheticCameraView(frame: NSRect(origin: .zero, size: geometry.cameraEnclosure.size))
        fake.orderFrontRegardless()
        cameraPanel = fake
        desktop.update(state)
        _ = desktop.show(in: geometry)
        if progress.doubleValue == 1 { desktop.toggleExpanded() }
    }
    private func stopDesktop() { desktop.hide(); cameraPanel?.orderOut(nil); cameraPanel = nil }
    func close() { stopDesktop(); window.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { close(); NSApp.stop(nil) }
    func snapshots() throws {
        let geometry = NotchSimulation.geometry()
        scene.configure(geometry: geometry, state: state, width: 180, legacyBelowCamera: true)
        try scene.save("notch-debug-before")
        for progress in [0.0, 0.15, 0.5, 1] {
            scene.configure(geometry: geometry, state: state, progress: progress)
            try scene.save("notch-debug-after-\(progress)")
        }
        changed()
        // Native segmented controls acquire their rendering state after window display.
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let root = window.contentView!
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.layoutSubtreeIfNeeded()
        if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/notch-debug-window.png"))
        }
        print("Native synthetic snapshots: build/notch-debug-{before,after-*}.png")
    }
}
