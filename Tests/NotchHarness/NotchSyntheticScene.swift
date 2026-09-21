import AppKit

/// Harness-only desktop context. Production hosting, model, path and layout are shared.
final class NotchSyntheticBackdrop: NSView {
    override var isFlipped: Bool { true }
    let layout: NotchLayout
    var clicks = 0
    var onClick: ((Int) -> Void)?
    init(layout: NotchLayout) { self.layout = layout; super.init(frame: CGRect(origin: .zero, size: layout.windowFrame.size)) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { clicks += 1; onClick?(clicks); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.17, green: 0.22, blue: 0.30, alpha: 1).setFill(); bounds.fill()
        NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: layout.visualBarHeight).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black]
        ("Synthetic desktop" as NSString).draw(at: CGPoint(x: 12, y: 8), withAttributes: attrs)
        if bounds.width > 600 { ("File   Edit   View" as NSString).draw(at: CGPoint(x: 130, y: 8), withAttributes: attrs) }
        ("Wi-Fi   10:00" as NSString).draw(at: CGPoint(x: bounds.width - 98, y: 8), withAttributes: attrs)
        let note: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white]
        ("SYNTHETIC · shared native renderer · camera is simulated" as NSString).draw(at: CGPoint(x: 12, y: bounds.height - 28), withAttributes: note)
    }
}

final class NotchSyntheticCamera: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        if let context = NSGraphicsContext.current?.cgContext {
            context.addPath(NotchSurfaceShape.path(bounds))
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
        }
        NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.18, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: bounds.midX - 3, y: bounds.midY - 3, width: 6, height: 6)).fill()
    }
}

final class NotchRegionOverlay: NSView {
    let bridge: NotchGeometryBridge
    init(frame: CGRect, bridge: NotchGeometryBridge) { self.bridge = bridge; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let g = bridge.snapshot, let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(g.path); context.setStrokeColor(NSColor.systemGreen.cgColor); context.setLineWidth(1); context.strokePath()
        context.setStrokeColor(NSColor.systemOrange.cgColor); context.stroke(g.rect.insetBy(dx: -2, dy: -2))
        context.setStrokeColor(NSColor.systemRed.cgColor); context.stroke(g.exclusion)
    }
}

extension NotchHarness {
    static func syntheticSnapshot(_ controller: NotchIslandController, _ name: String) throws {
        let layout = controller.model.layout!
        let window = NotchIslandPanel()
        window.level = .floating
        window.setFrame(layout.windowFrame, display: false)
        let background = NotchSyntheticBackdrop(layout: layout)
        let bridge = NotchGeometryBridge()
        let host = NotchHostingView(model: controller.model, bridge: bridge)
        host.frame = background.bounds
        background.addSubview(host)
        let camera = NotchSyntheticCamera(frame: layout.localExclusion)
        background.addSubview(camera)
        window.contentView = background
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        pump(0.06)
        background.layoutSubtreeIfNeeded()
        let bitmap = background.bitmapImageRepForCachingDisplay(in: background.bounds)!
        background.cacheDisplay(in: background.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/notch-island/synthetic-\(name).png"))
    }

    /// A separate NSApplication process receives real WindowServer mouse events.
    /// It has no services, preferences, hooks, network access or install actions.
    static func runClickReceiver(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--click-receiver"), arguments.count > index + 5 else { fatalError("receiver arguments") }
        let output = URL(fileURLWithPath: arguments[index + 1])
        let numbers = arguments[(index + 2)...(index + 5)].map { Double($0)! }
        let frame = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        let panel = NotchIslandPanel()
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.setFrame(frame, display: true)
        let layout = NotchLayout(geometry: fixture(CGRect(x: frame.midX - 756, y: frame.maxY - 982, width: 1512, height: 982)))
        let view = NotchSyntheticBackdrop(layout: layout)
        func receipt(_ count: Int) {
            let payload: [String: Any] = ["clicks": count, "pid": ProcessInfo.processInfo.processIdentifier, "windowNumber": panel.windowNumber]
            try? JSONSerialization.data(withJSONObject: payload).write(to: output, options: .atomic)
        }
        view.onClick = receipt
        panel.contentView = view
        panel.orderFrontRegardless()
        receipt(0)
        NSApp.run()
        withExtendedLifetime(panel) {}
    }

    static func nativeClickChecks(_ controller: NotchIslandController) throws -> String {
        guard CGPreflightPostEventAccess() else {
            return "NOT RUN: macOS does not grant synthetic event posting to this harness; no permission prompt was requested."
        }
        let frame = controller.panel.frame
        let file = URL(fileURLWithPath: "build/notch-island/click-receiver-\(UUID().uuidString).json")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--click-receiver", file.path, String(Double(frame.minX)), String(Double(frame.minY)), String(Double(frame.width)), String(Double(frame.height))]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() }; try? FileManager.default.removeItem(at: file) }
        func receipt() -> [String: Any] {
            guard let data = try? Data(contentsOf: file), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return value
        }
        for _ in 0..<100 { if receipt()["windowNumber"] != nil { break }; pump(0.02) }
        check(receipt()["windowNumber"] != nil, "separate native click receiver ready")
        let oldPointer = NSEvent.mouseLocation
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let mainHeight = NSScreen.screens.first!.frame.maxY
        func post(_ type: CGEventType, _ point: CGPoint) {
            let cgPoint = CGPoint(x: point.x, y: mainHeight - point.y)
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cgPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        defer { post(.mouseMoved, oldPointer) }
        func click(_ point: CGPoint) { post(.leftMouseDown, point); pump(0.03); post(.leftMouseUp, point); pump(0.12) }
        controller.interaction.mouseLocation = { NSEvent.mouseLocation }
        controller.panel.orderFrontRegardless()
        controller.refreshVisibility()
        controller.interaction.start()
        controller.model.animationsEnabled = false
        controller.model.reset(visible: true)
        let wing = CGPoint(x: frame.midX - controller.model.layout!.notchWidth / 2 - 19, y: frame.maxY - 12)
        post(.mouseMoved, wing); pump(0.08)
        let initialClicks = receipt()["clicks"] as? Int ?? -1
        click(wing)
        check(controller.model.state == .expanded && receipt()["clicks"] as? Int == initialClicks, "real first wing click expands without reaching underlying receiver")
        let blank = CGPoint(x: frame.midX, y: frame.maxY - 220)
        post(.mouseMoved, blank); pump(0.03); click(blank)
        check(controller.model.state == .expanded && receipt()["clicks"] as? Int == initialClicks, "real detail blank click preserves Expanded")
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID && !controller.panel.isKeyWindow, "real island clicks do not activate app or steal keyboard focus")
        let exterior = CGPoint(x: frame.minX + 5, y: frame.maxY - 120)
        post(.mouseMoved, exterior); pump(0.08)
        controller.model.click(); pump(0.08)
        check(controller.model.state == .expanded, "outside click begins with expanded island")
        let first = receipt()["clicks"] as? Int ?? -1
        click(exterior)
        check(receipt()["clicks"] as? Int == first + 1, "real outside click reaches separate receiver process")
        check(controller.model.state == .compact, "real outside click collapses island")
        controller.model.click(); pump(0.08)
        let edge = CGPoint(x: frame.midX + controller.model.layout!.expandedSize.width / 2 - 12, y: frame.maxY - 90)
        post(.mouseMoved, edge); pump(0.08)
        controller.model.animationsEnabled = true
        controller.model.collapse(); pump(0.55)
        let second = receipt()["clicks"] as? Int ?? -1
        click(edge) // Deliberately no intervening mouseMoved after shrink.
        check(receipt()["clicks"] as? Int == second + 1, "real stationary-pointer click after shrink reaches separate receiver")
        controller.model.animationsEnabled = false
        for (name, point) in [
            ("camera", CGPoint(x: frame.midX, y: frame.maxY - 10)),
            ("bottom-left rounded corner", CGPoint(x: frame.midX - controller.model.layout!.expandedSize.width / 2 + 0.1, y: frame.maxY - controller.model.layout!.expandedSize.height + 0.1)),
            ("top-left rounded corner", CGPoint(x: frame.midX - controller.model.layout!.expandedSize.width / 2 + 0.1, y: frame.maxY - 0.1)),
            ("top-right rounded corner", CGPoint(x: frame.midX + controller.model.layout!.expandedSize.width / 2 - 0.1, y: frame.maxY - 0.1)),
            ("bottom-right rounded corner", CGPoint(x: frame.midX + controller.model.layout!.expandedSize.width / 2 - 0.1, y: frame.maxY - controller.model.layout!.expandedSize.height + 0.1)),
            ("decoration", CGPoint(x: frame.midX - controller.model.layout!.expandedSize.width / 2 - 3, y: frame.maxY - 70))
        ] {
            controller.model.click(); pump(0.06)
            post(.mouseMoved, point); pump(0.06)
            let count = receipt()["clicks"] as? Int ?? -1
            click(point)
            check(receipt()["clicks"] as? Int == count + 1, "real \(name) click reaches separate receiver")
        }
        controller.interaction.stop()
        return "PASS: real WindowServer events reached a separate native receiver process for outside click, stationary-pointer click after animated shrink, camera, rounded corner and decoration."
    }
}
