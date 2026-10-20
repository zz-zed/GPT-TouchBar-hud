import AppKit
import ResetNewsCore

/// Fixed demo data only. No application delegate, account access, or network clients.
@main
enum ReadmeMenuCapture {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "ReadmeMenuCapture." + UUID().uuidString
        DisplayLanguage.defaults = UserDefaults(suiteName: suite)!
        defer { DisplayLanguage.defaults.removePersistentDomain(forName: suite) }
        DisplayLanguage.current = .chinese
        let now = ISO8601DateFormatter().date(from: "2026-09-27T06:20:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let context = PresentationContext(now: now, language: .chinese, calendar: calendar)
        var state = RateLimitDisplayState.initial
        state.fiveHour = LimitMeter(title: "5小时", shortTitle: "5h",
            window: .init(usedPercent: 38, windowDurationMins: 300, resetsAt: now.timeIntervalSince1970))
        state.weekly = LimitMeter(title: "周", shortTitle: "7d",
            window: .init(usedPercent: 3, windowDurationMins: 10080, resetsAt: now.addingTimeInterval(3600).timeIntervalSince1970))
        state.resetCredits = ResetCreditSummary(response: .init(availableCount: 2,
            credits: [.init(status: "available", expiresAt: now.timeIntervalSince1970)]))
        state.tokenUsage = TokenUsageSummary(yesterdayTokens: 1_488_000, cumulativeTokens: 3_447_000_000)
        state.lastUpdated = now
        let item = ResetNewsItem(id: "readme-demo", sources: [.feed], originalText: "演示预告，不代表真实公告。",
            facts: [.init(kind: .upcomingReset, effectiveAt: now.addingTimeInterval(7200), effectiveAtPrecision: .deadline)],
            publishedAt: now, firstSeenAt: now)
        let news = ResetNewsViewState(enabled: true, status: .success, items: [item],
            forecastAvailability: .current, forecastCheckedAt: now)
        let view = StatusSummaryView(state: state)
        view.appearance = NSAppearance(named: .aqua)
        view.update(state, news: news, context: context)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 740),
            styleMask: [], backing: .buffered, defer: false)
        host.contentView?.addSubview(view)
        view.wantsLayer = true
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.white.cgColor
        }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(domain: "ReadmeMenuCapture", code: 1)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ReadmeMenuCapture", code: 2)
        }
        try png.write(to: URL(fileURLWithPath: "Marketing/readme-native-menu-summary-v3.png"))
        print("Captured current native menu with fixed demo data; no account or network access.")
    }
}
