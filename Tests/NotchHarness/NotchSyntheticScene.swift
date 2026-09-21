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
        // Keep the HUD's subpixel corner probes away from the receiver's own
        // pixel-rounded window boundary. The tested HUD and points stay unchanged.
        panel.setFrame(frame.insetBy(dx: -2, dy: -2), display: true)
        let layout = NotchLayout(geometry: fixture(CGRect(x: frame.midX - 756, y: frame.maxY - 982, width: 1512, height: 982)))
        let view = NotchSyntheticBackdrop(layout: layout)
        func receipt(_ count: Int) {
            let payload: [String: Any] = ["clicks": count, "pid": ProcessInfo.processInfo.processIdentifier,
                "windowNumber": panel.windowNumber, "eventLoopUptime": ProcessInfo.processInfo.systemUptime,
                "visible": panel.isVisible, "onActiveSpace": panel.isOnActiveSpace]
            try? JSONSerialization.data(withJSONObject: payload).write(to: output, options: .atomic)
        }
        view.onClick = receipt
        panel.contentView = view
        panel.orderFrontRegardless()
        // Readiness and later acknowledgements must come from the running event
        // loop, not merely from allocating an NSWindow before NSApp.run().
        let heartbeat = Timer(timeInterval: 0.02, repeats: true) { _ in receipt(view.clicks) }
        RunLoop.main.add(heartbeat, forMode: .common)
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
        let oldPointer = NSEvent.mouseLocation
        let mainHeight = NSScreen.screens.first!.frame.maxY
        func post(_ type: CGEventType, _ point: CGPoint) {
            let cgPoint = CGPoint(x: point.x, y: mainHeight - point.y)
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cgPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        defer { post(.mouseMoved, oldPointer) }
        var moves = 0, downs = 0, ups = 0
        var lastEvent = "none"
        func observe(_ event: NSEvent) {
            switch event.type {
            case .mouseMoved: moves += 1
            case .leftMouseDown: downs += 1
            case .leftMouseUp: ups += 1
            default: break
            }
            lastEvent = "type=\(event.type.rawValue), window=\(event.windowNumber), timestamp=\(event.timestamp)"
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: observe)
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { event in observe(event); return event }
        defer {
            if let global { NSEvent.removeMonitor(global) }
            if let local { NSEvent.removeMonitor(local) }
        }
        func diagnostic(_ point: CGPoint?, beforeClicks: Int?) -> String {
            let pointer = NSEvent.mouseLocation
            return "target=\(String(describing: point)), pointer=\(pointer), contains=\(controller.interaction.contains(pointer)), "
                + "ignores=\(controller.panel.ignoresMouseEvents), enabled=\(controller.interaction.enabled), "
                + "mouseDownWindow=\(NSWindow.windowNumber(at: point ?? pointer, belowWindowWithWindowNumber: 0)), panelWindow=\(controller.panel.windowNumber), "
                + "visible=\(controller.model.visible)/\(controller.isVisible), state=\(controller.model.state.rawValue), "
                + "panelVisible=\(controller.panel.isVisible), onSpace=\(controller.panel.isOnActiveSpace), occlusion=\(controller.panel.occlusionState.rawValue), "
                + "bridge=\(String(describing: controller.bridge.snapshot?.size)), receiverRunning=\(child.isRunning), "
                + "beforeClicks=\(String(describing: beforeClicks)), receiver=\(receipt()), events=\(moves)/\(downs)/\(ups), lastEvent=\(lastEvent)"
        }
        func waitUntil(_ condition: () -> Bool) -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            repeat {
                if condition() { return true }
                pump(0.01)
            } while ProcessInfo.processInfo.systemUptime < deadline
            return condition()
        }
        func verify(_ success: Bool, _ message: String, point: CGPoint? = nil, beforeClicks: Int? = nil) {
            if !success {
                FileHandle.standardError.write(Data(("Native click failure: " + diagnostic(point, beforeClicks: beforeClicks) + "\n").utf8))
            }
            check(success, message)
        }
        verify(waitUntil {
            let value = receipt()
            return value["eventLoopUptime"] != nil && value["clicks"] as? Int != nil
                && value["visible"] as? Bool == true && value["onActiveSpace"] as? Bool == true
        }, "separate native click receiver ready")
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        func pointerIs(at point: CGPoint) -> Bool {
            let actual = NSEvent.mouseLocation
            return abs(actual.x - point.x) < 1 && abs(actual.y - point.y) < 1
        }
        func move(to point: CGPoint, accepts: Bool) {
            let before = moves
            post(.mouseMoved, point)
            verify(waitUntil {
                let expectedWindow = accepts ? controller.panel.windowNumber : (receipt()["windowNumber"] as? Int ?? -1)
                return moves > before && pointerIs(at: point) && controller.interaction.enabled
                    && controller.model.visible && controller.isVisible
                    && controller.interaction.contains(point) == accepts && controller.panel.ignoresMouseEvents == !accepts
                    && NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == expectedWindow
            }, "real mouse movement establishes expected native routing", point: point)
        }
        func geometryIs(_ state: NotchPresentationState) -> Bool {
            guard let presented = controller.bridge.snapshot?.size, let layout = controller.model.layout else { return false }
            let target = layout.size(for: state)
            return controller.model.state == state && abs(presented.width - target.width) < 0.05 && abs(presented.height - target.height) < 0.05
        }
        func expand() {
            controller.model.click()
            verify(waitUntil { geometryIs(.expanded) }, "native click fixture presents expanded geometry")
        }
        func click(_ point: CGPoint, expectedClicks: Int, state: NotchPresentationState? = nil, _ message: String) {
            let beforeClicks = receipt()["clicks"] as? Int
            let beforeDowns = downs, beforeUps = ups
            let expectedWindow = expectedClicks == beforeClicks ? controller.panel.windowNumber : (receipt()["windowNumber"] as? Int ?? -1)
            // AppKit's property can change before WindowServer applies routing.
            // This public query uses actual mouse-down hit-testing rules.
            verify(waitUntil {
                pointerIs(at: point) && NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == expectedWindow
            }, "WindowServer is ready for the single real click", point: point, beforeClicks: beforeClicks)
            // Send exactly one down/up pair. Polling must never retry the click.
            post(.leftMouseDown, point)
            let downDelivered = waitUntil { downs > beforeDowns }
            post(.leftMouseUp, point) // Release even if the down acknowledgement times out.
            verify(downDelivered, "real mouse down is observed", point: point, beforeClicks: beforeClicks)
            verify(waitUntil { ups > beforeUps }, "real mouse up is observed", point: point, beforeClicks: beforeClicks)
            let released = ProcessInfo.processInfo.systemUptime
            var stableSince: TimeInterval?
            verify(waitUntil {
                let value = receipt()
                let matches = (value["eventLoopUptime"] as? Double ?? 0) > released
                    && value["clicks"] as? Int == expectedClicks && (state == nil || controller.model.state == state)
                guard matches else { stableSince = nil; return false }
                let now = ProcessInfo.processInfo.systemUptime
                guard let since = stableSince else { stableSince = now; return false }
                return now - since >= 0.12
            }, message, point: point, beforeClicks: beforeClicks)
        }
        controller.interaction.mouseLocation = { NSEvent.mouseLocation }
        controller.panel.orderFrontRegardless()
        controller.refreshVisibility()
        controller.interaction.start()
        controller.model.animationsEnabled = false
        controller.model.reset(visible: true)
        let wing = CGPoint(x: frame.midX - controller.model.layout!.notchWidth / 2 - 19, y: frame.maxY - 12)
        move(to: wing, accepts: true)
        let initialClicks = receipt()["clicks"] as? Int ?? -1
        click(wing, expectedClicks: initialClicks, state: .expanded, "real first wing click expands without reaching underlying receiver")
        verify(waitUntil { geometryIs(.expanded) }, "first real click presents expanded geometry")
        let blank = CGPoint(x: frame.midX, y: frame.maxY - 220)
        move(to: blank, accepts: true)
        click(blank, expectedClicks: initialClicks, state: .expanded, "real detail blank click preserves Expanded")
        let finalFrontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        verify(finalFrontPID == frontPID && !controller.panel.isKeyWindow,
               "real island clicks do not activate app or steal keyboard focus (before=\(String(describing: frontPID)), after=\(String(describing: finalFrontPID)), key=\(controller.panel.isKeyWindow))")
        let exterior = CGPoint(x: frame.minX + 5, y: frame.maxY - 120)
        move(to: exterior, accepts: false)
        expand()
        check(controller.model.state == .expanded, "outside click begins with expanded island")
        let first = receipt()["clicks"] as? Int ?? -1
        click(exterior, expectedClicks: first + 1, state: .compact, "real outside click reaches separate receiver process")
        check(controller.model.state == .compact, "real outside click collapses island")
        expand()
        let edge = CGPoint(x: frame.midX + controller.model.layout!.expandedSize.width / 2 - 12, y: frame.maxY - 90)
        move(to: edge, accepts: true)
        controller.model.animationsEnabled = true
        controller.model.collapse()
        verify(waitUntil { geometryIs(.compact) && pointerIs(at: edge) && controller.panel.ignoresMouseEvents },
               "stationary pointer becomes click-through after actual shrink", point: edge)
        let second = receipt()["clicks"] as? Int ?? -1
        // Deliberately no intervening mouseMoved after shrink.
        click(edge, expectedClicks: second + 1, "real stationary-pointer click after shrink reaches separate receiver")
        controller.model.animationsEnabled = false
        for (name, point) in [
            ("camera", CGPoint(x: frame.midX, y: frame.maxY - 10)),
            ("bottom-left rounded corner", CGPoint(x: frame.midX - controller.model.layout!.expandedSize.width / 2 + 0.1, y: frame.maxY - controller.model.layout!.expandedSize.height + 0.1)),
            ("top-left rounded corner", CGPoint(x: frame.midX - controller.model.layout!.expandedSize.width / 2 + 0.1, y: frame.maxY - 0.1)),
            ("top-right rounded corner", CGPoint(x: frame.midX + controller.model.layout!.expandedSize.width / 2 - 0.1, y: frame.maxY - 0.1)),
            ("bottom-right rounded corner", CGPoint(x: frame.midX + controller.model.layout!.expandedSize.width / 2 - 0.1, y: frame.maxY - controller.model.layout!.expandedSize.height + 0.1)),
            ("decoration", CGPoint(x: frame.midX - controller.model.layout!.expandedSize.width / 2 - 3, y: frame.maxY - 70))
        ] {
            expand()
            move(to: point, accepts: false)
            let count = receipt()["clicks"] as? Int ?? -1
            click(point, expectedClicks: count + 1, "real \(name) click reaches separate receiver")
        }
        controller.interaction.stop()
        return "PASS: real WindowServer events reached a separate native receiver process for outside click, stationary-pointer click after animated shrink, camera, rounded corner and decoration."
    }
}
