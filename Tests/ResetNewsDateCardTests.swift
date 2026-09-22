import AppKit
import SwiftUI
import ResetNewsCore

/// Native fixture windows only: no AppDelegate, monitor, network, notification
/// channel, persistent defaults, or live cache is constructed.
@main
enum ResetNewsDateCardTests {
    private static var checks = 0
    private static let output = URL(fileURLWithPath: "Design/reset-news-preview/date-emphasis", isDirectory: true)
    private static let publishedAt = ISO8601DateFormatter().date(from: "2026-09-22T12:31:00+08:00")!

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }
    private static func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }

    private static func fixture(_ id: String, fact: ResetNewsFact) -> ResetNewsItem {
        ResetNewsItem(id: id, sources: [.feed], originalText: "Native date presentation fixture",
            facts: [fact], publishedAt: publishedAt, firstSeenAt: publishedAt)
    }

    private static func window(_ content: NSView, appearance: NSAppearance) -> NSWindow {
        let screen = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }!
        let frame = CGRect(x: screen.visibleFrame.midX - content.frame.width / 2,
            y: screen.visibleFrame.midY - content.frame.height / 2,
            width: content.frame.width, height: content.frame.height)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = content
        window.orderFrontRegardless()
        pump()
        return window
    }

    private static func save(_ view: NSView, name: String) throws {
        view.wantsLayer = true
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        check(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "Native snapshot has nonzero dimensions")
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        print("\(name): \(view.bounds.size) pt / \(bitmap.pixelsWide)×\(bitmap.pixelsHigh) px")
    }

    private static func listSnapshot(item: ResetNewsItem, appearance: NSAppearance, dark: Bool, name: String) throws {
        let state = ResetNewsViewState(enabled: true, status: .success, items: [item], readIDs: [item.id])
        let view = NSHostingView(rootView: ResetNewsListView(state: state, isVisible: true,
            onCheck: {}, onMarkAllRead: {}, onSettings: {}, onPageVisibility: { _ in }, onVisibleItem: { _ in })
            .padding(12).frame(width: 340, height: 340).environment(\.colorScheme, dark ? .dark : .light))
        view.frame = CGRect(x: 0, y: 0, width: 340, height: 340)
        let window = window(view, appearance: appearance)
        check(view.fittingSize.width <= 340.5, "Shared list fits the narrow 340-point host")
        try save(view, name: name)
        window.orderOut(nil)
    }

    private static func cardSnapshot(item: ResetNewsItem, appearance: NSAppearance, dark: Bool, name: String) throws {
        let view = NSHostingView(rootView: ResetNewsCard(item: item, unread: false)
            .padding(12).frame(width: 340).environment(\.colorScheme, dark ? .dark : .light))
        view.frame = CGRect(x: 0, y: 0, width: 340, height: 400)
        view.layoutSubtreeIfNeeded()
        let height = ceil(view.fittingSize.height)
        check(height > 100 && height < 400, "Long-date card has a finite natural height without a clipping frame")
        view.setFrameSize(CGSize(width: 340, height: height))
        let window = window(view, appearance: appearance)
        check(view.fittingSize.width <= 340.5 && view.fittingSize.height <= view.bounds.height + 0.5,
            "Long-date native card fits in both dimensions")
        try save(view, name: name)
        window.orderOut(nil)
    }

    private static func popoverSnapshot(item: ResetNewsItem, appearance: NSAppearance, name: String) throws {
        let anchor = NSButton(title: "重置预告", target: nil, action: nil)
        anchor.frame = CGRect(x: 0, y: 0, width: 110, height: 24)
        let anchorWindow = window(anchor, appearance: appearance)
        // Place the fixture high enough to retain the real 420×480 content size.
        let screen = anchorWindow.screen!
        anchorWindow.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX,
            y: screen.visibleFrame.maxY - 40))
        let controller = ResetNewsPopoverController()
        controller.update(ResetNewsViewState(enabled: true, status: .success, items: [item], readIDs: [item.id]))
        controller.show(relativeTo: anchor)
        pump()
        let popup = controller.presentedWindow!
        check(controller.model.contentSize == CGSize(width: 420, height: 480), "Actual popup retains its production content dimensions")
        check(screen.visibleFrame.contains(popup.frame), "Actual date popup remains within its source display")
        try save(popup.contentView!, name: name)
        controller.close()
        anchorWindow.orderOut(nil)
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let dateOnly = fixture("date-only", fact: .init(kind: .upcomingReset, timingText: "Tuesday", confidence: .tentative))
        let exact = fixture("exact", fact: .init(kind: .upcomingReset, scope: "Pro",
            effectiveAt: ISO8601DateFormatter().date(from: "2026-09-25T15:30:00+08:00")!, effectiveAtPrecision: .exact))
        let longDate = fixture("long-date", fact: .init(kind: .upcomingReset, scope: "Pro / Plus / Team",
            effectiveAt: ISO8601DateFormatter().date(from: "2027-12-31T00:00:00+08:00")!, effectiveAtPrecision: .windowBoundary))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let day = ResetForecastDatePresentation(fact: dateOnly.facts[0], publishedAt: publishedAt, now: publishedAt, calendar: calendar)
        check(day.dateText == "9月22日（周二）", "Weekday presentation resolves to a concrete month and day")
        check(!day.isExactTime && day.timeText == "具体时刻未公布", "Date-only presentation never invents midnight precision")
        check(day.basisText != nil, "Inferred date includes a secondary explanation")
        let time = ResetForecastDatePresentation(fact: exact.facts[0], publishedAt: publishedAt, now: publishedAt, calendar: calendar)
        check(time.isExactTime && time.timeText.contains("15:30") && time.timeText.contains("UTC+08:00"),
            "Source-exact timestamp retains its explicit local time zone")
        let boundary = ResetForecastDatePresentation(fact: longDate.facts[0], publishedAt: publishedAt, now: publishedAt, calendar: calendar)
        check(boundary.dateText.contains("2027") && !boundary.isExactTime && !boundary.timeText.contains("00:00"),
            "Cross-year boundary includes the year without pretending to be an exact midnight reset")
        let textWidth = (boundary.dateText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .semibold)]).width
        check(textWidth <= 296, "The long Chinese date is readable at full size inside the narrow card")
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            NSApp.appearance = appearance
            let mode = dark ? "dark" : "light"
            try popoverSnapshot(item: dateOnly, appearance: appearance, name: "date-only-popup-\(mode)")
            try popoverSnapshot(item: exact, appearance: appearance, name: "exact-popup-\(mode)")
            try listSnapshot(item: dateOnly, appearance: appearance, dark: dark, name: "notch-width-date-only-\(mode)")
            try cardSnapshot(item: longDate, appearance: appearance, dark: dark, name: "long-date-340-\(mode)")
        }
        print("PASS: \(checks) native forecast date-card, precision, size and appearance checks")
    }
}
