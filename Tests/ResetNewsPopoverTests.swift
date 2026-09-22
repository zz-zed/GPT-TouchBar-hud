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
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
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
                }
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
