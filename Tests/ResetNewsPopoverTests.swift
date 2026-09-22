import AppKit
import ResetNewsCore

@main
enum ResetNewsPopoverTests {
    static var checks = 0
    static let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RESET_NEWS_POPOVER_OUTPUT_DIR"]
        ?? "Design/reset-news-preview/popover-fixed", isDirectory: true)
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); checks += 1
    }
    static func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func image(_ view: NSView) -> NSBitmapImageRep {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    static func save(_ bitmap: NSBitmapImageRep, _ name: String) throws {
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
    static func headerPixels(_ bitmap: NSBitmapImageRep) -> [UInt8] {
        let height = min(bitmap.pixelsHigh, Int(100 * CGFloat(bitmap.pixelsHigh) / bitmap.size.height))
        return Array(UnsafeBufferPointer(start: bitmap.bitmapData!, count: height * bitmap.bytesPerRow))
    }
    static func crossEntryChecks() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button!.title = "预告测试"
        defer { NSStatusBar.system.removeStatusItem(status) }
        let floating = NSPanel(contentRect: CGRect(x: 300, y: 300, width: 100, height: 30),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        floating.isReleasedWhenClosed = false
        floating.level = .floating
        let button = NSButton(title: "预告", target: nil, action: nil)
        floating.contentView = button
        floating.orderFrontRegardless(); pump()
        defer { floating.orderOut(nil) }
        let controller = ResetNewsPopoverController()
        var windows: [NSWindow] = []
        for iteration in 0..<3 {
            controller.show(relativeTo: button); pump()
            check(controller.presentedWindow?.isVisible == true, "Floating entry opens details")
            windows.append(controller.presentedWindow!)
            // Match the menu action's deferred opening with the real status-item anchor.
            DispatchQueue.main.async { controller.show(relativeTo: status.button!) }
            pump()
            let current = controller.presentedWindow!
            windows.append(current)
            check(current.isVisible, "Menu entry replaces floating details")
            check(windows.filter { $0 !== current }.allSatisfy { !$0.isVisible }, "Switching entry leaves no orphan popup")
            if iteration == 0 {
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: current)
            } else if iteration == 1 {
                let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: floating.windowNumber, context: nil, eventNumber: 9, clickCount: 1, pressure: 1)!
                NSApp.sendEvent(event)
            } else {
                controller.close()
            }
            pump()
            check(windows.allSatisfy { !$0.isVisible }, "Cross-entry popup closes after focus loss, outside click or explicit close")
            check(!controller.model.isVisible && !controller.model.pageVisible, "Cross-entry close clears reading visibility")
        }
        controller.show(relativeTo: status.button!)
        if let window = controller.presentedWindow { windows.append(window) }
        controller.show(relativeTo: button)
        if let window = controller.presentedWindow { windows.append(window) }
        controller.show(relativeTo: status.button!)
        pump()
        let latest = controller.presentedWindow!
        check(latest.isVisible, "Rapid menu-floating-menu switching keeps the latest presentation")
        check(windows.filter { $0 !== latest }.allSatisfy { !$0.isVisible }, "Rapid replacement retires every older window")
        controller.close(); pump()
        check(!latest.isVisible && windows.allSatisfy { !$0.isVisible }, "Rapid cross-entry presentation remains closable")
        controller.close()
    }
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        crossEntryChecks()
        for visible in [CGRect(x: 0, y: 0, width: 1680, height: 1020), CGRect(x: -1920, y: -30, width: 1920, height: 1050),
                        CGRect(x: -400, y: 200, width: 360, height: 300)] {
            for anchor in [CGRect(x: visible.maxX - 30, y: visible.maxY, width: 24, height: 24),
                           CGRect(x: visible.minX, y: visible.minY, width: 24, height: 24),
                           CGRect(x: visible.midX, y: visible.midY, width: 24, height: 24)] {
                let placement = ResetNewsPopoverPlacement(anchor: anchor, visibleFrame: visible)
                let frame = CGRect(x: anchor.midX, y: anchor.maxY, width: placement.contentSize.width + 26, height: placement.contentSize.height + 26)
                check(placement.usableFrame.contains(placement.containedFrame(frame)), "All top/right/negative/small-screen native-frame budgets stay contained")
                check(placement.contentSize.height >= 180 && placement.contentSize.width >= 300, "Small-screen layout retains header and list space")
            }
        }
        let now = Date()
        let items = (0..<30).map { index in
            ResetNewsItem(id: "popover-test-\(index)", sources: [.feed], originalText: "Fixture",
                facts: [.init(kind: .upcomingReset, scope: "all", effectiveAt: now.addingTimeInterval(Double(index + 1) * 3_600))],
                publishedAt: now, firstSeenAt: now)
        }
        for (screenIndex, screen) in NSScreen.screens.enumerated() {
            let visible = screen.visibleFrame
            for (name, origin) in [("top-right", CGPoint(x: visible.maxX - 120, y: visible.maxY - 30)),
                                   ("bottom-right", CGPoint(x: visible.maxX - 120, y: visible.minY + 20)),
                                   ("floating", CGPoint(x: visible.midX, y: visible.midY))] {
                let anchorWindow = NSWindow(contentRect: CGRect(origin: origin, size: CGSize(width: 110, height: 24)),
                    styleMask: .borderless, backing: .buffered, defer: false)
                anchorWindow.isReleasedWhenClosed = false
                let button = NSButton(title: "重置预告", target: nil, action: nil)
                button.frame = CGRect(x: 0, y: 0, width: 110, height: 24)
                anchorWindow.contentView = button
                var anchor: NSView = button
                if name == "floating" {
                    let hud = CompactQuotaHUDView(initialAppearance: HUDAppearance(colorChoice: .graphite, backgroundOpacity: 0.94, contentOpacity: 1),
                        onRefresh: {}, onClose: {}, contextMenuProvider: { NSMenu() })
                    let container = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 40))
                    hud.translatesAutoresizingMaskIntoConstraints = false
                    container.addSubview(hud)
                    NSLayoutConstraint.activate([hud.leadingAnchor.constraint(equalTo: container.leadingAnchor), hud.topAnchor.constraint(equalTo: container.topAnchor)])
                    hud.update(with: .initial)
                    hud.updateMessages(forecastCount: 3, available: true)
                    anchorWindow.setContentSize(container.frame.size)
                    anchorWindow.contentView = container
                    container.layoutSubtreeIfNeeded()
                    anchor = hud.messageAnchorView
                }
                anchorWindow.orderFrontRegardless(); pump()
                let controller = ResetNewsPopoverController()
                let sampleItems = name == "floating" ? Array(items.prefix(3)) : items
                var state = ResetNewsViewState(enabled: true, status: .success, items: sampleItems)
                state.readIDs = Set(sampleItems.map(\.id))
                controller.update(state)
                controller.show(relativeTo: anchor); pump()
                guard let popover = controller.presentedWindow else {
                    preconditionFailure("Missing \(screenIndex)-\(name) popover; anchor=\(anchor.frame), window=\(String(describing: anchor.window?.frame))")
                }
                let content = popover.contentView!
                check(visible.insetBy(dx: 7, dy: 7).contains(popover.frame), "Actual \(name) popover, including native chrome, remains on the anchor screen")
                check(state.unreadCount == 0 && state.forecastCount == sampleItems.count, "Reading does not reduce today's/upcoming forecast count")
                check(content.bounds.size == controller.model.contentSize, "Native content stays fixed instead of growing with its long list")
                let controls = descendants(content).compactMap { $0 as? NSButton }.filter { !$0.isHidden }
                for control in controls {
                    check(content.bounds.contains(control.convert(control.bounds, to: content)), "Visible action lies within the actual content frame")
                }
                let anchorRect = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                print("\(screenIndex)-\(name): anchor=\(anchorRect), popup=\(popover.frame), usable=\(visible), content=\(content.bounds), actions=\(controls.map(\.title))")
                fflush(stdout)
                let before = image(content)
                try save(before, "\(screenIndex)-\(name)")
                if name == "top-right" {
                    guard let scroll = descendants(content).compactMap({ $0 as? NSScrollView }).first,
                          let document = scroll.documentView else { preconditionFailure("Native scroll viewport unavailable: scroll/header check cannot be skipped") }
                    check(document.bounds.height > scroll.contentView.bounds.height, "Long list uses a scrollable viewport")
                    let previousOffset = scroll.contentView.bounds.minY
                    scroll.contentView.scroll(to: CGPoint(x: 0, y: min(400, document.bounds.height - scroll.contentView.bounds.height)))
                    scroll.reflectScrolledClipView(scroll.contentView); pump()
                    check(scroll.contentView.bounds.minY > previousOffset, "The native card viewport actually scrolled")
                    let after = image(content)
                    check(headerPixels(before) == headerPixels(after), "Title and actions remain pixel-identical while only the card list scrolls")
                    try save(after, "\(screenIndex)-\(name)-scrolled")
                    check(popover.isVisible, "Scrolling inside details does not dismiss the popup")
                }
                // Exercise the real notification wiring, including reopen/cleanup,
                // without switching the user's foreground application in this fixture.
                let unrelatedWindow = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
                unrelatedWindow.isReleasedWhenClosed = false
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: unrelatedWindow)
                check(popover.isVisible, "Another window losing focus does not close details")
                controller.model.pageVisibilityChanged(true)
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: popover)
                pump()
                check(!popover.isVisible && !controller.model.isVisible && !controller.model.pageVisible,
                    "Details losing key focus closes the popup and clears reading visibility")
                controller.show(relativeTo: anchor); pump()
                check(controller.presentedWindow?.isVisible == true, "Details can reopen after losing focus")
                NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
                pump()
                check(controller.presentedWindow?.isVisible != true && !controller.model.isVisible,
                    "Application deactivation closes reopened details")
                controller.show(relativeTo: anchor); pump()
                check(controller.presentedWindow?.isVisible == true, "Details can reopen after app deactivation")
                let reopened = controller.presentedWindow!
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
                    object: NSWorkspace.shared, userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
                check(reopened.isVisible, "Activating the popup's own app does not dismiss it")
                let reopenedContent = reopened.contentView!
                // Window (4,4) can fall in the native popover's rounded chrome,
                // not inside its content. Click the content's top padding instead.
                let contentPoint = CGPoint(x: reopenedContent.bounds.midX,
                    y: reopenedContent.isFlipped ? reopenedContent.bounds.minY + 8 : reopenedContent.bounds.maxY - 8)
                let windowPoint = reopenedContent.convert(contentPoint, to: nil)
                let hitPoint = reopenedContent.convert(contentPoint, to: reopenedContent.superview)
                let hit = reopenedContent.hitTest(hitPoint)
                check(reopenedContent.bounds.contains(contentPoint), "Internal click is inside the actual content bounds")
                check(hit != nil && (hit === reopenedContent || hit!.isDescendant(of: reopenedContent)),
                    "Internal click hit-tests to the actual content subtree")
                check(!(hit is NSControl), "Internal click targets noninteractive header padding")
                let oldPoint = reopenedContent.convert(CGPoint(x: 4, y: 4), from: nil)
                print("\(screenIndex)-\(name) internal click: legacyWindowPoint=(4,4), legacyContentPoint=\(oldPoint), legacyInsideContent=\(reopenedContent.bounds.contains(oldPoint)), contentPoint=\(contentPoint), windowPoint=\(windowPoint), hit=\(String(describing: hit.map { type(of: $0) }))")
                fflush(stdout)
                for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(with: type, location: windowPoint,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: reopened.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                    check(event.window === reopened, "Internal click event targets the current native popup window")
                    NSApp.sendEvent(event)
                }
                pump()
                check(reopened.isVisible, "A click within details keeps the popup open")
                let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: anchorWindow.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
                NSApp.sendEvent(outside); pump()
                check(!reopened.isVisible && !controller.model.isVisible, "A click in another app window closes details")
                controller.close(); anchorWindow.orderOut(nil)
            }
        }
        let hudController = CompactHUDViewController(initialAppearance: HUDAppearance(colorChoice: .graphite, backgroundOpacity: 0.94, contentOpacity: 1),
            onRefresh: {}, onClose: {}, onPresentTouchBar: { false }, contextMenuProvider: { NSMenu() })
        var floatingOpens = 0, touchBarOpens = 0
        hudController.onOpenMessages = { floatingOpens += 1 }
        hudController.onOpenTouchBarMessages = { touchBarOpens += 1 }
        _ = hudController.view
        hudController.updateMessages(forecastCount: 3, available: true)
        (hudController.messageAnchorView as! NSButton).performClick(nil)
        let touchBar = hudController.makeQuotaTouchBar()
        let item = touchBar.item(forIdentifier: touchBar.defaultItemIdentifiers[0]) as! NSCustomTouchBarItem
        let touchButton = descendants(item.view).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "touchbar.messages" }!
        touchButton.performClick(nil)
        check(floatingOpens == 1 && touchBarOpens == 1, "Floating and ordinary Touch Bar have separate source-routing callbacks")
        print("PASS: \(checks) forecast popup containment, count and native-scroll checks")
    }
}
