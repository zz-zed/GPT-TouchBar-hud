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
    static func text(_ view: NSView) -> String {
        guard !view.isHidden else { return "" }
        return ([((view as? NSTextField)?.stringValue ?? "")] + view.subviews.map(text))
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func checkSharedPresentation() {
        let now = ISO8601DateFormatter().date(from: "2026-12-31T04:00:00Z")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let context = PresentationContext(now: now, language: .english, calendar: calendar)
        let item = ResetNewsItem(id: "semantic", sources: [.feed], originalText: "tomorrow",
            facts: [.init(kind: .upcomingReset, timingText: "tomorrow")], publishedAt: now, firstSeenAt: now)
        var state = ResetNewsViewState(enabled: true, status: .success, items: [item], forecastAvailability: .current)
        let first = AppDisplaySnapshot(state: .initial, news: state, context: context)
        let duplicate = AppDisplaySnapshot(state: .initial, news: state, context: context)
        check(first.forecast == duplicate.forecast, "Same domain input and context have identical shared presentation")
        check(first.forecast.headline == first.forecast.cards[item.id]?.first, "Shoulder and card consume one shared forecast interpretation")
        check(first.forecast.canShowList && first.forecast.hasForecastDetails && !first.forecast.canRetry,
            "List access, specific details and retry have distinct capabilities")
        let model = NotchPresentationModel()
        model.updateResetNews(state, forecast: first.forecast, context: context)
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        let sameOutputContext = PresentationContext(now: now.addingTimeInterval(1), language: .english, calendar: calendar)
        model.updateResetNews(state, context: sameOutputContext)
        check(publications == 0, "A newer instant with equal visible forecast content does not publish")
        let popover = ResetNewsPopoverController()
        popover.update(state, forecast: first.forecast, context: context)
        var popupPublications = 0
        let popupObservation = popover.model.objectWillChange.sink { popupPublications += 1 }
        popover.update(state, forecast: first.forecast, context: sameOutputContext)
        check(popupPublications == 0, "Popover retains latest time context without publishing equal presentation")
        withExtendedLifetime((observation, popupObservation)) {}
        let nextContext = PresentationContext(now: now.addingTimeInterval(86400), language: .english, calendar: calendar)
        let next = ForecastPresentation(state, context: nextContext)
        model.updateResetNews(state, forecast: next, context: nextContext)
        check(model.forecast.headline?.day == .today && model.forecast.compactValue == "Today",
            "Unchanged domain state refreshes notch on day-context changes")
        check(model.page == .quota, "Forecast context refresh preserves the selected page")
        let chinese = ForecastPresentation(state, context: PresentationContext(now: now, language: .chinese, calendar: calendar))
        model.updateResetNews(state, forecast: chinese, context: context)
        check(model.forecast.compactValue == "明天", "Unchanged domain state refreshes localized forecast presentation")
        state.items = []
        let empty = ForecastPresentation(state, context: context)
        check(empty.canShowList && !empty.hasForecastDetails && empty.indicator.count == 0,
            "Successful empty can open its list without pretending to have forecast details")
        state.forecastAvailability = .cached; state.status = .failure
        let cachedEmpty = ForecastPresentation(state, context: context)
        check(cachedEmpty.indicator.count == nil && cachedEmpty.canRetry && !cachedEmpty.hasForecastDetails,
            "Cached empty is unknown and retryable rather than a confirmed zero")
    }

    static func checkDisplayDispatch() {
        var now = ISO8601DateFormatter().date(from: "2026-10-15T04:00:00Z")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let menu = StatusMenuController(touchBarHardware: .absent, appUpdater: AppUpdater())
        let touchBar = PersistentTouchBarController()
        let preferencesSuite = "StoppedPreferences." + UUID().uuidString
        let preferencesDefaults = UserDefaults(suiteName: preferencesSuite)!
        preferencesDefaults.set(false, forKey: ResetNewsMonitor.enabledPreferenceKey)
        preferencesDefaults.set(false, forKey: QuotaAlertMonitor.enabledPreferenceKey)
        defer { preferencesDefaults.removePersistentDomain(forName: preferencesSuite) }
        let preferences = PreferencesCoordinator(touchBarHardware: .absent, appUpdater: AppUpdater(),
            resetNewsMonitor: ResetNewsMonitor(repository: ResetNewsRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent(preferencesSuite)),
                defaults: preferencesDefaults), quotaAlerts: QuotaAlertMonitor(defaults: preferencesDefaults))
        var preferenceRefreshes = 0
        preferences.onNeedsDisplayRefresh = { preferenceRefreshes += 1 }
        preferences.stop(); preferences.openPreferences(nil)
        check(preferenceRefreshes == 0, "Stopped preferences reject late window-open requests")
        let display = AppDisplayCoordinator(menu: menu, persistentTouchBar: touchBar,
            contextProvider: { PresentationContext(now: now, language: .chinese, calendar: calendar) })
        menu.configureStatusItem()
        let summary = menu.statusItem.menu!.items[0].view as! StatusSummaryView
        let closedLayouts = summary.layoutUpdateCount
        let item = ResetNewsItem(id: "dispatch", sources: [.feed], originalText: "tomorrow",
            facts: [.init(kind: .upcomingReset, timingText: "tomorrow")], publishedAt: now, firstSeenAt: now)
        let news = ResetNewsViewState(enabled: true, status: .success, items: [item], forecastAvailability: .current)
        var submissions = 0
        display.onSnapshot = { _ in submissions += 1 }
        display.receiveNews(news)
        check(summary.layoutUpdateCount == closedLayouts, "Closed menu retains its summary geometry during news dispatch")
        var quota = RateLimitDisplayState.initial
        quota.fiveHour = LimitMeter(title: "5h", shortTitle: "5h", window: .init(usedPercent: 30,
            windowDurationMins: 300, resetsAt: now.timeIntervalSince1970))
        display.receiveQuota(quota)
        let identifier = NSTouchBarItem.Identifier("io.github.zz-zed.GPTTouchBarHUD.persistent.limits")
        let retainedItem = touchBar.touchBar(NSTouchBar(), makeItemForIdentifier: identifier) as! NSCustomTouchBarItem
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        display.receiveNews(news)
        check(text(retainedItem.view).contains("10月15日 04:00") && summary.layoutUpdateCount == closedLayouts,
            "News-only timezone changes reach quota surfaces without laying out the closed menu")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        display.receiveTask(TaskStatusSummary(runningCount: 1))
        let previousSubmissions = submissions
        let reference = DiagnosticTaskSnapshotReference(domain: UUID(), monitoringGeneration: 2, batch: 17,
            snapshotID: UUID(), runningCount: 1, unknownCount: 0, memberCount: 1, memberPageCount: 1, membershipComplete: true)
        display.receiveDiagnosticSnapshot(reference)
        check(submissions == previousSubmissions, "Diagnostic-only references do not trigger display dispatch")
        now = now.addingTimeInterval(86400)
        menu.menuWillOpen(menu.statusItem.menu!)
        check(display.displaySnapshot.forecast.compactValue == "今天", "Opening the menu refreshes the shared day context")
        check(display.displaySnapshot.state.taskStatus?.diagnosticSnapshot == reference,
            "The next actual refresh retains the newest diagnostic snapshot")
        check(display.displaySnapshot.forecast.headline == display.displaySnapshot.forecast.cards[item.id]?.first,
            "One dispatch supplies consistent headline and card dates")
        let oldMenu = menu.statusItem.menu!
        let settings = oldMenu.items.compactMap(\.submenu).flatMap(\.items).first { $0.action == NSSelectorFromString("openPreferences:") }!
        var preferencesOpens = 0
        display.onOpenPreferences = { preferencesOpens += 1 }
        menu.menuDidClose(oldMenu)
        display.stop()
        NSApp.sendAction(settings.action!, to: settings.target, from: settings)
        menu.menuWillOpen(oldMenu)
        check(preferencesOpens == 0 && menu.statusItem.menu == nil && !menu.validateMenuItem(settings),
            "Stopped display rejects queued menu settings actions and closes menu tracking")
        let stoppedSubmissions = submissions
        display.receiveNews(news); display.receiveTask(nil); display.renderDisplayState()
        check(submissions == stoppedSubmissions, "A stopped display ignores late domain and timer refreshes")
        NSStatusBar.system.removeStatusItem(menu.statusItem)
    }

    static func checkCapturedContext() {
        let previousLanguage = DisplayLanguage.current
        let previousZone = NSTimeZone.default
        DisplayLanguage.current = .english
        NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
        defer { DisplayLanguage.current = previousLanguage; NSTimeZone.default = previousZone }
        let now = ISO8601DateFormatter().date(from: "2026-10-15T04:00:00Z")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let context = PresentationContext(now: now, language: .chinese, calendar: calendar)
        var state = RateLimitDisplayState.initial
        state.fiveHour = LimitMeter(title: "5h", shortTitle: "5h", window: .init(usedPercent: 30,
            windowDurationMins: 300, resetsAt: now.timeIntervalSince1970))
        state.weekly = LimitMeter(title: "7d", shortTitle: "7d", window: .init(usedPercent: 10,
            windowDurationMins: 10080, resetsAt: now.timeIntervalSince1970))
        state.taskStatus = TaskStatusSummary(runningCount: 1)
        state.tokenUsage = TokenUsageSummary(yesterdayTokens: 12000, cumulativeTokens: 30000)
        state.lastUpdated = now
        let item = ResetNewsItem(id: "context", sources: [.feed], originalText: "tomorrow",
            facts: [.init(kind: .upcomingReset, timingText: "tomorrow")], publishedAt: now, firstSeenAt: now)
        let news = ResetNewsViewState(enabled: true, status: .success, items: [item], forecastAvailability: .current)
        let snapshot = AppDisplaySnapshot(state: state, news: news, context: context)
        check(snapshot.metrics[0].date == "10月15日 12:00 重置" && snapshot.metrics[0].title == "5 小时剩余",
            "Quota builder uses the captured language and timezone rather than English/UTC globals")
        let summary = StatusSummaryView(state: state)
        summary.update(state, news: news, forecast: snapshot.forecast, context: context)
        check(text(summary).contains("5小时额度剩余") && text(summary).contains("10/15 12:00") && text(summary).contains("明天"),
            "Native menu quota and forecast use one captured context")
        let touch = TouchBarRateLimitsView()
        touch.update(with: state, context: context); touch.updateMessages(snapshot.forecast.indicator)
        check(text(touch).contains("10月15日 12:00") && text(touch).contains("昨日 1.20 万"),
            "Touch Bar date and token labels ignore mismatched process globals: " + text(touch))
        check(touch.toolTip == "上次更新 12:00:00", "Touch Bar refresh metadata uses the captured timezone")
        let content = NotchContentAdapter(state, tasksEnabled: true, metrics: snapshot.metrics, context: context)
        check(content.metrics == snapshot.metrics && content.peek(left: false).detail == "10/15 12:00"
            && content.taskTitle == "执行中 1", "Notch reuses captured quota rows and task language")
        let sameOutput = NotchContentAdapter(state, tasksEnabled: true, context:
            PresentationContext(now: now.addingTimeInterval(1), language: .chinese, calendar: calendar))
        check(content.hasSamePresentation(as: sameOutput), "New time context with unchanged visible values preserves notch suppression")
        let persistent = PersistentTouchBarController()
        persistent.update(with: state, context: context); persistent.updateMessages(snapshot.forecast.indicator)
        let identifier = NSTouchBarItem.Identifier("io.github.zz-zed.GPTTouchBarHUD.persistent.limits")
        let itemView = persistent.touchBar(NSTouchBar(), makeItemForIdentifier: identifier) as! NSCustomTouchBarItem
        check(text(itemView.view).contains("10月15日 12:00") && text(itemView.view).contains("昨日 1.20 万"),
            "Lazily created persistent Touch Bar keeps the original context")
        let floating = CompactHUDViewController(initialAppearance: .load(), onRefresh: {}, onClose: {},
            onPresentTouchBar: { false }, contextMenuProvider: { NSMenu() })
        floating.update(with: state, context: context); floating.updateMessages(snapshot.forecast.indicator)
        check(text(floating.view).contains("执行中 1"), "Deferred floating HUD keeps captured task language")
        let bar = floating.makeQuotaTouchBar()
        let focused = floating.touchBar(bar, makeItemForIdentifier: bar.defaultItemIdentifiers[0]) as! NSCustomTouchBarItem
        check(text(focused.view).contains("10月15日 12:00") && text(focused.view).contains("昨日 1.20 万"),
            "Deferred responder Touch Bar keeps its parent's original context")
        let legacy = NotchHUDView(frame: NSRect(x: 0, y: 0, width: 460, height: 360))
        legacy.update(state, expanded: true, context: context)
        check(text(legacy).contains("上次 12:00") && descendants(legacy).contains { $0.toolTip == state.taskStatus?.detail(language: .chinese) },
            "Legacy notch tooltip and update time use captured language and timezone")
        let model = NotchPresentationModel()
        model.update(state, tasksEnabled: true, metrics: snapshot.metrics, context: context)
        model.updateResetNews(news, forecast: snapshot.forecast, context: context)
        check(model.content.context == context && model.forecast.compactValue == "明天",
            "Notch content and forecast retain the same captured context")
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "StatusMenuTests." + UUID().uuidString
        DisplayLanguage.defaults = UserDefaults(suiteName: suite)!
        defer { DisplayLanguage.defaults.removePersistentDomain(forName: suite) }
        checkSharedPresentation()
        checkDisplayDispatch()
        checkCapturedContext()
        AppLifecycleCoordinatorChecks.run { check($0, $1) }
        let now = Date()
        let quotaStart = RateLimitDisplayState.initial
        var base = quotaStart
        base.fiveHour = LimitMeter(title: "5小时", shortTitle: "5h", window: .init(usedPercent: 38, windowDurationMins: 300,
            resetsAt: now.addingTimeInterval(3600).timeIntervalSince1970))
        base.weekly = LimitMeter(title: "周", shortTitle: "7d", window: .init(usedPercent: 2, windowDurationMins: 10080,
            resetsAt: now.addingTimeInterval(7 * 86400).timeIntervalSince1970))
        base.resetCredits = ResetCreditSummary(response: .init(availableCount: 3,
            credits: [.init(status: "available", expiresAt: now.addingTimeInterval(8 * 86400).timeIntervalSince1970)]))
        base.tokenUsage = TokenUsageSummary(yesterdayTokens: 144_000_000, cumulativeTokens: 5_570_000_000)
        base.lastUpdated = now
        func item(_ id: String, _ fact: ResetNewsFact) -> ResetNewsItem {
            ResetNewsItem(id: id, sources: [.feed], originalText: "测试预告",
                facts: [fact], publishedAt: now, firstSeenAt: now)
        }
        let announced = item("exact", .init(kind: .upcomingReset, effectiveAt: now.addingTimeInterval(7200),
            effectiveAtPrecision: .deadline))
        let dateOnly = item("date", .init(kind: .upcomingReset, timingText: "tomorrow"))
        let pending = item("pending", .init(kind: .upcomingReset))
        var calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let start = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: now)!
        let end = calendar.date(bySettingHour: 1, minute: 0, second: 0, of: tomorrow)!
        let crossing = item("window", .init(kind: .upcomingReset, effectiveAt: end,
            effectiveAtPrecision: .windowBoundary, officialWindow: .init(startAt: start, endAt: end)))
        let active = ResetNewsViewState(enabled: true, status: .success, items: [announced],
            forecastAvailability: .current, forecastCheckedAt: now)
        var empty = active; empty.items = []
        var disabled = ResetNewsViewState()
        disabled.enabled = false
        let loading = ResetNewsViewState(enabled: true, status: .checking)
        let failed = ResetNewsViewState(enabled: true, status: .failure)
        var cached = active; cached.status = .failure; cached.forecastAvailability = .cached
        cached.forecastCheckedAt = now.addingTimeInterval(-3600)
        var cachedEmpty = cached; cachedEmpty.items = []
        let paused = ResetNewsViewState(enabled: true, status: .idle)
        var weeklyOnly = base; weeklyOnly.fiveHour = nil
        var fiveOnly = base; fiveOnly.weekly = nil
        var noCredit = base; noCredit.resetCredits = ResetCreditSummary(response: .init(availableCount: 0, credits: []))
        var unknownCredit = base; unknownCredit.resetCredits = nil
        var firstLoad = quotaStart; firstLoad.isRefreshing = true
        var firstFail = quotaStart; firstFail.errorMessage = "无法连接 Codex"
        var staleQuota = base; staleQuota.errorMessage = "无法连接 Codex"
        var exhausted = noCredit; exhausted.fiveHour = LimitMeter(title: "5小时", shortTitle: "5h",
            window: .init(usedPercent: 100, windowDurationMins: 300, resetsAt: now.addingTimeInterval(3600).timeIntervalSince1970))
        var tokenUnknown = base; tokenUnknown.tokenUsage = nil
        var extras = base; extras.taskStatus = TaskStatusSummary(runningCount: 2)
        extras.creditBalance = CreditBalanceSummary(response: .init(hasCredits: true, unlimited: false, balance: "12.34"))
        extras.tokenUsage?.isStale = true; extras.tokenUsage?.updatedAt = now.addingTimeInterval(-3600)
        var refreshing = base; refreshing.isRefreshing = true
        var withPending = active; withPending.items = [pending]
        var withDate = active; withDate.items = [dateOnly]
        var withWindow = active; withWindow.items = [crossing]
        let summary = StatusSummaryView(state: base)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        host.contentView?.addSubview(summary)
        func scene(_ number: Int, _ q: RateLimitDisplayState, _ n: ResetNewsViewState) throws {
            summary.update(q, news: n)
            try snapshot(summary, name: String(format: "scene-%02d", number))
            check(summary.frame.width == 344 && summary.frame.height < 500, "Scene \(number) stays within menu width and height")
        }
        try scene(1, base, active)
        let initialForecast = find("menu.forecast", in: summary)!
        let initialReset = find("menu.reset", in: summary)!
        check(initialForecast.frame.minY == initialReset.frame.minY && initialForecast.frame.minX > initialReset.frame.minX,
            "Active forecast and reset credits share a row")
        check(find("menu.forecast.open", in: summary) != nil, "A valid forecast is actionable")
        var opens = 0, retries = 0, refreshes = 0, quotaRetries = 0
        summary.onForecast = { opens += 1 }; summary.onForecastRetry = { retries += 1 }
        summary.onRefresh = { refreshes += 1 }; summary.onQuotaRetry = { quotaRetries += 1 }
        (find("menu.forecast.open", in: summary) as! NSButton).performClick(nil)
        check(opens == 1, "Forecast opens details")
        try scene(2, weeklyOnly, active)
        check(find("menu.forecast", in: summary)!.frame.minY == find("menu.reset", in: summary)!.frame.minY,
            "Weekly-only does not change reset/forecast arrangement")
        try scene(3, fiveOnly, active)
        check(find("menu.forecast", in: summary)!.frame.minY == find("menu.reset", in: summary)!.frame.minY,
            "Five-hour-only does not change reset/forecast arrangement")
        try scene(4, base, empty)
        check(find("menu.forecast.open", in: summary) == nil && text(summary).contains("预告 · 暂无"),
            "Confirmed empty is quiet and read-only")
        let emptyHeight = summary.frame.height
        try scene(5, weeklyOnly, empty)
        check(summary.frame.height == emptyHeight, "One quota does not expand a quiet reset row")
        try scene(6, noCredit, empty)
        check(find("menu.reset", in: summary)!.frame.height < 40 && text(summary).contains("可用重置 0次"),
            "No credits and no forecast collapse to one labeled line")
        try scene(7, unknownCredit, empty)
        check(text(summary).contains("次数待获取") && !text(summary).contains("最早到期 —"),
            "Unknown count never invents a unit or expiry")
        try scene(8, base, disabled)
        check(find("menu.forecast", in: summary) == nil, "Disabled forecast has no menu area")
        try scene(9, weeklyOnly, disabled)
        check(find("menu.forecast", in: summary) == nil, "Disabled weekly-only remains hidden")
        try scene(10, base, loading)
        check(text(summary).contains("正在获取预告") && find("menu.forecast.open", in: summary) == nil,
            "Loading has a short nonactionable status")
        try scene(11, base, paused)
        check(text(summary).contains("预告检查已暂停") && find("menu.forecast.retry", in: summary) == nil,
            "A gated pause has no misleading retry button")
        try scene(12, base, failed)
        check(find("menu.forecast.retry", in: summary) != nil && find("menu.forecast.open", in: summary) == nil,
            "Failure with no cache offers retry but not details")
        (find("menu.forecast.retry", in: summary) as! NSButton).performClick(nil)
        check(retries == 1 && opens == 1, "Retry and details are distinct actions")
        try scene(13, base, cached)
        check(find("menu.forecast.open", in: summary) != nil && find("menu.forecast.retry", in: summary) != nil,
            "Cached forecast keeps details and retry")
        (find("menu.forecast.retry", in: summary) as! NSButton).performClick(nil)
        check(retries == 2 && opens == 1, "Cached retry does not open the details")
        try scene(14, base, cachedEmpty)
        check(!text(summary).contains("预告 · 暂无"), "Old empty cache is not confirmed current empty")
        try scene(15, firstLoad, loading)
        check(find("menu.weekly", in: summary) == nil && text(summary).contains("正在读取账号额度")
            && !(find("menu.reset", in: summary) != nil) && !text(summary).contains("Token 用量待获取"),
            "First load does not invent a weekly window or duplicate unknown placeholders")
        try scene(16, firstFail, failed)
        check(find("menu.quota.retry", in: summary) != nil && find("menu.forecast.retry", in: summary) != nil,
            "Independent account and forecast errors have independent retry routes")
        (find("menu.quota.retry", in: summary) as! NSButton).performClick(nil)
        check(quotaRetries == 1, "Account retry callback is routed")
        try scene(17, staleQuota, active)
        check(text(summary).contains("上次数据") && text(summary).contains("额度暂无法更新"),
            "Stale account quota is labeled beside quotas")
        try scene(18, exhausted, active)
        check(text(summary).contains("已耗尽") && find("menu.forecast.open", in: summary) != nil,
            "Zero quota and public forecast remain independent")
        try scene(19, base, withPending)
        check(text(summary).contains("时间待定") && find("menu.forecast.open", in: summary) != nil,
            "Unknown forecast time keeps detail access without inventing a clock")
        try scene(20, base, withDate)
        check(text(summary).contains("明天") && text(summary).contains("时刻未公布"),
            "Known date leads, unknown clock supports it")
        try scene(21, base, withWindow)
        let windowFrame = find("menu.forecast", in: summary)!.frame
        check(windowFrame.width > 300 && text(summary).contains("今天") && text(summary).contains("明天"),
            "Cross-day window spans full width with both day boundaries")
        try scene(22, extras, active)
        check(text(summary).contains("执行中 2") && text(summary).contains("12.34") && text(summary).contains("Token 暂无法更新"),
            "Task, balance and stale token retain distinct messages")
        try scene(23, refreshing, empty)
        check((find("menu.refresh", in: summary) as! NSButton).isEnabled == false,
            "Menu refresh prevents duplicate quota requests")
        try scene(24, base, active) // app-update items are native menu rows, outside this custom summary.
        try scene(25, base, active)
        try scene(26, noCredit, active)
        check(find("menu.forecast.open", in: summary) != nil, "No reset credits do not hide a valid forecast")
        try scene(27, tokenUnknown, empty)
        check(text(summary).contains("Token 用量待获取") && !text(summary).contains("昨日 —"),
            "Unknown token usage occupies only one line")
        try scene(28, noCredit, disabled)
        check(find("menu.forecast", in: summary) == nil && find("menu.reset", in: summary)!.frame.height < 40
            && text(summary).contains("可用重置 0次"),
            "Disabled forecast and zero credits remain compact")
        summary.appearance = NSAppearance(named: .darkAqua)
        try snapshot(summary, name: "scene-28-dark")
        summary.update(base, news: active)
        try snapshot(summary, name: "scene-01-dark")
        summary.update(base, news: withWindow)
        try snapshot(summary, name: "scene-21-dark")
        summary.appearance = NSAppearance(named: .aqua)
        summary.update(base, news: active)
        let baseline = summary.layoutUpdateCount
        var withDiagnostics = base
        withDiagnostics.taskStatus = TaskStatusSummary(runningCount: 1)
        summary.update(withDiagnostics)
        let afterTask = summary.layoutUpdateCount
        withDiagnostics.taskStatus?.legacyDiagnostics = LegacyTaskDiagnostics(lastSuccessfulCheck: now)
        summary.update(withDiagnostics)
        check(summary.layoutUpdateCount == afterTask && afterTask > baseline,
            "Invisible diagnostics do not rebuild the menu")
        (find("menu.refresh", in: summary) as! NSButton).performClick(nil)
        check(refreshes == 1, "Combined refresh callback is wired")
        let publication = ISO8601DateFormatter().date(from: "2026-10-15T04:56:07Z")!
        let signal = ResetForecastSignal(sourceID: "2110595554036400151",
            sourceURL: URL(string: "https://x.com/thsottiaux/status/2110595554036400151")!,
            originalText: "Landing within the next 2 hours", publishedAt: publication)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let relative = ResetNewsViewState(enabled: true, status: .success,
            items: [signal.evidenceItem(calendar: calendar)], forecastAvailability: .current)
        let presentation = MenuForecastPresentation(relative, now: publication, calendar: calendar)
        check(presentation.value == "预计今天 14:56 前" && presentation.compactValue == "14:56 前",
            "Publication-relative deadline keeps its qualified time")
        DisplayLanguage.current = .english
        func englishScene(_ name: String, _ q: RateLimitDisplayState, _ n: ResetNewsViewState) throws {
            summary.update(q, news: n)
            try snapshot(summary, name: "scene-en-" + name)
            for field in descendants(summary).compactMap({ $0 as? NSTextField })
                where !field.isHidden && !field.stringValue.isEmpty {
                check(field.attributedStringValue.size().width <= field.frame.width + 1,
                    "English \(name) label fits: \(field.stringValue)")
            }
        }
        try englishScene("active", base, active)
        check(text(summary).contains("5-hour remaining") && text(summary).contains("Public reset forecast"),
            "English information preference updates quota and forecast labels")
        try englishScene("crossday", base, withWindow)
        check(text(summary).contains("Today") && text(summary).contains("Tomorrow"),
            "English cross-day forecast keeps both date boundaries")
        try englishScene("date", base, withDate)
        check(text(summary).contains("Tomorrow") && text(summary).contains("Time not announced"),
            "English date-only forecast does not invent a clock")
        try englishScene("pending", base, withPending)
        check(text(summary).contains("Time TBD"), "English unknown time remains explicit")
        try englishScene("weekly", weeklyOnly, active)
        try englishScene("empty", noCredit, empty)
        check(text(summary).contains("No forecast") && text(summary).contains("0 left"),
            "English zero-credit empty state is concise")
        try englishScene("failed", firstFail, failed)
        check(text(summary).contains("Account data unavailable") && text(summary).contains("Forecast unavailable"),
            "English independent failures remain distinguishable")
        try englishScene("cached", base, cached)
        check(text(summary).contains("Cached") && find("menu.forecast.retry", in: summary) != nil,
            "English cached forecast keeps provenance and retry")
        try englishScene("stale", staleQuota, active)
        check(text(summary).contains("Quota unavailable"), "English stale account quota is labeled")
        try englishScene("token-unknown", tokenUnknown, empty)
        check(text(summary).contains("Token usage pending"), "English unknown token usage is labeled")
        DisplayLanguage.current = .chinese
        summary.update(base, news: active)
        check(text(summary).contains("5小时额度剩余"), "Information language switch restores Chinese")
        print("PASS: \(checks) status menu checks; 28 Chinese and 10 English native scene snapshots")
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
