import AppKit
import ResetNewsCore

@main
struct StatusMenuTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); checks += 1
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func find(_ id: String, in view: NSView) -> NSView? {
        descendants(view).first { $0.accessibilityIdentifier() == id }
    }
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "StatusMenuTests." + UUID().uuidString
        DisplayLanguage.defaults = UserDefaults(suiteName: suite)!
        defer { DisplayLanguage.defaults.removePersistentDomain(forName: suite) }
        let date = Date(timeIntervalSince1970: 1_790_490_000)
        var quota = RateLimitDisplayState.initial
        quota.fiveHour = LimitMeter(title: "5小时", shortTitle: "5h", window: .init(usedPercent: 38, windowDurationMins: 300, resetsAt: date.timeIntervalSince1970))
        quota.weekly = LimitMeter(title: "周", shortTitle: "7d", window: .init(usedPercent: 3, windowDurationMins: 10080, resetsAt: date.addingTimeInterval(3600).timeIntervalSince1970))
        quota.resetCredits = ResetCreditSummary(response: .init(availableCount: 2, credits: [.init(status: "available", expiresAt: date.timeIntervalSince1970)]))
        quota.tokenUsage = TokenUsageSummary(yesterdayTokens: 1_488_000, cumulativeTokens: 3_470_000_000)
        quota.lastUpdated = date
        var news = ResetNewsViewState(enabled: true, status: .success, forecastAvailability: .current)
        let summary = StatusSummaryView(state: quota)
        summary.update(quota, news: news)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        host.contentView?.addSubview(summary)
        let five = find("menu.fiveHour", in: summary)!
        let weekly = find("menu.weekly", in: summary)!
        let reset = find("menu.reset", in: summary)!
        check(five.frame.minX < weekly.frame.minX && five.frame.minY == weekly.frame.minY, "5-hour quota precedes week")
        check(reset.frame.minY > five.frame.minY, "Complete resets follow both quotas")
        let readable = (summary.accessibilityChildren() ?? []).compactMap { ($0 as? NSView)?.accessibilityIdentifier() }
        check(readable.filter { ["menu.fiveHour", "menu.weekly", "menu.reset", "menu.forecast"].contains($0) }
              == ["menu.fiveHour", "menu.weekly", "menu.reset", "menu.forecast"], "Accessibility follows visual metric order")
        check(find("menu.forecast.open", in: summary) == nil, "Confirmed zero has no button")
        let empty = find("menu.forecast", in: summary)!
        check(empty.accessibilityLabel()?.contains("0条") == true, "Confirmed zero is readable")
        let emptyFrame = empty.frame
        let emptyHeight = summary.frame.height
        try snapshot(summary, name: "zero")
        for status in [ResetNewsCheckStatus.disabled, .idle, .checking, .failure, .partial, .stale, .codexNotRunning] {
            news.status = status; news.forecastAvailability = .unknown; summary.update(quota, news: news)
            check(MenuForecastPresentation(news).value == "—", "Unknown or unavailable never invents zero")
            check(find("menu.forecast.open", in: summary) == nil, "Unavailable empty state is read-only")
        }
        news.status = .success
        check(MenuForecastPresentation(news).value == "—" && MenuForecastPresentation(news).detail == "尚未获取预告",
            "Other source success alone does not confirm an empty forecast")
        news.forecastAvailability = .current
        news.items = [ResetNewsItem(id: "fixture", sources: [.feed], originalText: "仅用于测试的预告",
            facts: [.init(kind: .upcomingReset, scope: "test", effectiveAt: date)], publishedAt: date, firstSeenAt: date)]
        summary.update(quota, news: news)
        check(empty.frame == emptyFrame && summary.frame.height == emptyHeight, "Positive and zero states retain geometry")
        var opens = 0
        summary.onForecast = { opens += 1 }
        let button = find("menu.forecast.open", in: summary) as! NSButton
        button.performClick(nil)
        check(opens == 1, "Positive forecast activates details")
        news.status = .failure; news.forecastAvailability = .cached; news.forecastCheckedAt = date
        summary.update(quota, news: news)
        check(MenuForecastPresentation(news).canOpen && MenuForecastPresentation(news).detail.contains("缓存"), "Cached forecasts remain readable after failure")
        check(MenuForecastPresentation(news).help.contains("预告数据更新于"), "Cached forecast exposes its data timestamp")
        news.status = .success; news.forecastAvailability = .current; summary.update(quota, news: news)
        try snapshot(summary, name: "positive")
        summary.appearance = NSAppearance(named: .darkAqua)
        try snapshot(summary, name: "dark")
        summary.appearance = NSAppearance(named: .aqua)
        news.items = []; summary.update(quota, news: news)
        check(find("menu.forecast.open", in: summary) == nil, "Positive-to-zero removes the action")
        news.forecastAvailability = .cached; summary.update(quota, news: news)
        check(MenuForecastPresentation(news).value == "—" && !MenuForecastPresentation(news).detail.contains("暂无"),
            "A cached empty result is not presented as a fresh no-forecast result")
        try snapshot(summary, name: "cached-empty")
        news.forecastAvailability = .current; summary.update(quota, news: news)
        var refreshes = 0; summary.onRefresh = { refreshes += 1 }
        (find("menu.refresh", in: summary) as! NSButton).performClick(nil)
        check(refreshes == 1, "Refresh activates the callback")
        quota.isRefreshing = true; summary.update(quota)
        check((find("menu.refresh", in: summary) as! NSButton).isEnabled == false, "Duplicate refresh is disabled")
        quota.fiveHour = nil; quota.isRefreshing = false; summary.update(quota)
        check(find("menu.fiveHour", in: summary) == nil, "Weekly-only does not invent a 5-hour window")
        check(find("menu.weekly", in: summary)!.frame.minX < find("menu.reset", in: summary)!.frame.minX, "Weekly-only retains order")
        try snapshot(summary, name: "weekly")
        quota.taskStatus = TaskStatusSummary(runningCount: 2)
        quota.creditBalance = CreditBalanceSummary(response: .init(hasCredits: true, unlimited: false, balance: "12.34"))
        quota.tokenUsage?.isStale = true
        summary.update(quota)
        let text = descendants(summary).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
        check(text.contains("执行中 2") && text.contains("12.34") && text.contains("*"), "Conditional task, balance and stale token are preserved")
        let layouts = summary.layoutUpdateCount
        quota.taskStatus?.legacyDiagnostics = LegacyTaskDiagnostics(lastSuccessfulCheck: date)
        summary.update(quota)
        check(summary.layoutUpdateCount == layouts, "Invisible diagnostics do not rebuild the view")
        summary.update(.initial, news: ResetNewsViewState())
        try snapshot(summary, name: "missing")
        check(summary.frame.width == 344 && summary.frame.height < 360, "Summary keeps a compact width and height")
        print("PASS: \(checks) status menu checks")
    }
    static func snapshot(_ view: NSView, name: String) throws {
        view.wantsLayer = true
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STATUS_MENU_OUTPUT_DIR"]
            ?? "Design/menu-bar-icons/native", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
    }
}
