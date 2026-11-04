#if HUD_SHARED_CORE_TESTS
@testable import HUDCoreTestSupport
#endif
import AppKit
import SwiftUI

@main enum APICostUITests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message); checks += 1
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func snapshot(_ view: NSView, _ name: String) throws {
        view.wantsLayer = true
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: ".build/api-cost-ui-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
    }
    static func control(_ view: NSView, _ id: String) -> NSControl {
        descendants(view).compactMap { $0 as? NSControl }.first { $0.accessibilityIdentifier() == id }!
    }
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        DispatchQueue.main.async {
            do { try run(); print("PASS: \(checks) API costs native UI checks and light/dark previews"); exit(0) }
            catch { fatalError("Native API cost checks failed: \(error)") }
        }
        NSApp.run()
    }
    static func run() throws {
        let suite = "APICostUITests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        DisplayLanguage.defaults = defaults
        defer { defaults.removePersistentDomain(forName: suite) }
        let date = ISO8601DateFormatter().date(from: "2026-11-03T06:20:00Z")!
        let context = PresentationContext(now: date, language: .chinese)
        var account = RateLimitDisplayState.initial
        account.fiveHour = LimitMeter(title: "5小时", shortTitle: "5h", window: .init(usedPercent: 72,
            windowDurationMins: 300, resetsAt: date.addingTimeInterval(3600).timeIntervalSince1970))
        account.weekly = LimitMeter(title: "周", shortTitle: "7d", window: .init(usedPercent: 36,
            windowDurationMins: 10080, resetsAt: date.addingTimeInterval(3 * 86400).timeIntervalSince1970))
        account.resetCredits = ResetCreditSummary(response: .init(availableCount: 4,
            credits: [.init(status: "available", expiresAt: date.addingTimeInterval(5 * 86400).timeIntervalSince1970)]))
        account.tokenUsage = TokenUsageSummary(yesterdayTokens: 2_400_000, cumulativeTokens: 180_000_000)
        account.lastUpdated = date
        var cost = APICostViewState()
        cost.enabled = true; cost.configured = true; cost.canRefresh = true
        cost.period = .month(containing: date)
        cost.snapshot = APICostSnapshot(period: cost.period, queryEnd: date, fetchedAt: date, amount: Decimal(string: "12.34"))
        do {
            var timedAccount = account
            timedAccount.lastUpdated = date.addingTimeInterval(30)
            timedAccount.tokenUsage?.updatedAt = date.addingTimeInterval(60)
            var timedNews = ResetNewsViewState(enabled: true, status: .success,
                forecastCheckedAt: date.addingTimeInterval(120))
            var timedCosts = cost
            timedCosts.snapshot = APICostSnapshot(period: cost.period, queryEnd: date,
                fetchedAt: date.addingTimeInterval(180), amount: Decimal(string: "12.34"))
            check(HUDDataFreshness.latestDate(account: timedAccount, news: timedNews, costs: timedCosts) == date.addingTimeInterval(180),
                "latest successful update selects the newest valid source")
            timedCosts.enabled = false
            check(HUDDataFreshness.latestDate(account: timedAccount, news: timedNews, costs: timedCosts) == date.addingTimeInterval(120),
                "hidden API data does not determine the visible update timestamp")
            timedCosts.enabled = true; timedCosts.configured = false
            check(HUDDataFreshness.latestDate(account: timedAccount, news: timedNews, costs: timedCosts) == date.addingTimeInterval(120),
                "unconfigured API data does not determine the visible update timestamp")
            timedNews.enabled = false
            check(HUDDataFreshness.latestDate(account: timedAccount, news: timedNews, costs: timedCosts) == date.addingTimeInterval(60),
                "disabled forecasts are excluded while a successful Token timestamp remains eligible")
            timedAccount.tokenUsage?.updatedAt = nil
            check(HUDDataFreshness.latestDate(account: timedAccount, news: timedNews, costs: timedCosts) == date.addingTimeInterval(30),
                "account success remains the timestamp when other visible sources have no newer success")
            timedNews.enabled = true; timedCosts.configured = true
            timedCosts.snapshot = APICostSnapshot(period: .month(containing: cost.period.end), queryEnd: date,
                fetchedAt: date.addingTimeInterval(180), amount: Decimal(string: "12.34"))
            check(HUDDataFreshness.latestDate(account: timedAccount, news: timedNews, costs: timedCosts) == date.addingTimeInterval(120),
                "a snapshot from another API period cannot advance the current timestamp")
            timedCosts.snapshot = cost.snapshot
            let beforeBusy = HUDDataFreshness.latestDate(account: timedAccount, news: timedNews, costs: timedCosts)
            timedAccount.isRefreshing = true; timedNews.status = .checking; timedCosts.refreshing = true
            check(HUDDataFreshness.latestDate(account: timedAccount, news: timedNews, costs: timedCosts) == beforeBusy,
                "busy transitions never invent a later successful update")
            check(HUDDataFreshness.latestDate(account: .initial, news: ResetNewsViewState(), costs: APICostViewState()) == nil,
                "an interface without any successful source has no invented timestamp")
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let prefs = PreferencesWindowController(appearance: .load(), touchBarHardware: .present)
            let window = prefs.window!, content = window.contentView!
            window.appearance = NSAppearance(named: appearance)
            let tabs = descendants(content).compactMap { $0 as? NSTabView }.first!
            check(tabs.tabViewType == .topTabsBezelBorder, "existing top tabs preserved")
            check(tabs.tabViewItems.contains { $0.label == "通用" } && tabs.tabViewItems.contains { $0.label == "API 消费" }, "new tab added alongside old tabs")
            prefs.showAPICostsTab(); content.layoutSubtreeIfNeeded()
            try snapshot(content, "settings-unconfigured-" + appearance.rawValue)
            let panel = prefs.apiCostPanel
            let key = control(panel, "settings.apiCosts.key") as! NSSecureTextField
            check(key.stringValue.isEmpty, "credential entry starts empty")
            prefs.apiCostPanel.update(cost); content.layoutSubtreeIfNeeded()
            try snapshot(content, "settings-connected-" + appearance.rawValue)
            check(!control(panel, "settings.apiCosts.enabled").isHiddenOrHasHiddenAncestor, "enabled visible after connection")
            check(control(panel, "settings.apiCosts.key").isHiddenOrHasHiddenAncestor, "saved key never displayed")
            var toggleResult: Bool?
            panel.onEnabled = { toggleResult = $0 }
            let toggle = control(panel, "settings.apiCosts.enabled") as! NSButton
            toggle.performClick(nil)
            check(toggleResult == false, "turning off forwards new value")
            let replace = control(panel, "settings.apiCosts.replace") as! NSButton
            replace.performClick(nil)
            key.stringValue = "synthetic-ui-fixture"
            panel.clearEditor()
            check(key.stringValue.isEmpty && key.isHiddenOrHasHiddenAncestor, "cancel clears secret draft")
            var failure = cost; failure.error = .permission
            panel.update(failure); content.layoutSubtreeIfNeeded()
            try snapshot(content, "settings-permission-" + appearance.rawValue)
            check((control(panel, "settings.apiCosts.status") as! NSTextField).stringValue.contains("Admin"), "permission failure explains repair")
            for view in descendants(panel) where !view.isHiddenOrHasHiddenAncestor && (view is NSButton || view is NSTextField) {
                let frame = view.convert(view.bounds, to: content)
                check(frame.minX >= 0 && frame.maxX <= content.bounds.width + 1 && frame.minY >= 0 && frame.maxY <= content.bounds.height + 1, "API controls fit existing settings window")
            }
            prefs.close()
        }
        for language in DisplayLanguage.allCases {
            var context = context; context = PresentationContext(now: date, language: language)
            let menu = StatusSummaryView(state: account)
            menu.appearance = NSAppearance(named: .aqua)
            menu.update(account, context: context)
            menu.updateAPICosts(cost, context: context)
            let enabledHeight = menu.frame.height
            check(!control(menu, "menu.apiCosts.amount").isHidden, "configured API summary is visible")
            let timestamp = control(menu, "menu.updated") as! NSTextField
            check(!timestamp.isHidden && timestamp.stringValue == menu.lastSuccessfulUpdateText,
                "one visible timestamp communicates the latest successful update")
            let headerRefresh = control(menu, "menu.refresh")
            check(timestamp.frame.maxX <= headerRefresh.frame.minX && abs(timestamp.frame.midY - headerRefresh.frame.midY) <= 0.5,
                "timestamp and refresh share the same top-right centerline without overlap")
            let timestampTextWidth = (timestamp.stringValue as NSString).size(withAttributes: [.font: timestamp.font!]).width
            check(timestamp.frame.width >= timestampTextWidth + 2, "top-right timestamp reserves its full text width")
            try snapshot(menu, "menu-dual-" + language.rawValue)
            var weekly = account; weekly.fiveHour = nil
            menu.update(weekly, context: context)
            try snapshot(menu, "menu-weekly-" + language.rawValue)
            menu.appearance = NSAppearance(named: .darkAqua)
            try snapshot(menu, "menu-weekly-dark-" + language.rawValue)
            menu.update(account, context: context)
            try snapshot(menu, "menu-dual-dark-" + language.rawValue)
            menu.appearance = NSAppearance(named: .aqua)
            var failure = cost; failure.error = .network
            menu.updateAPICosts(failure, context: context)
            try snapshot(menu, "menu-network-" + language.rawValue)
            let amount = control(menu, "menu.apiCosts.amount") as! NSTextField
            check(amount.stringValue == "US$12.34", "failed refresh retains displayed complete amount")
            check(amount.toolTip?.contains(failure.status(language: language)) == true, "failure details available on hover")
            let recovery = control(menu, "menu.apiCosts.recovery") as! NSButton
            check(!recovery.isHidden && recovery.isEnabled, "network failure exposes an available retry")
            check(menu.bounds.contains(recovery.convert(recovery.bounds, to: menu)) && menu.bounds.contains(amount.convert(amount.bounds, to: menu)), "amount and recovery remain contained in summary")
            check(!recovery.convert(recovery.bounds, to: menu).intersects(amount.convert(amount.bounds, to: menu)), "recovery does not overlap the retained amount")
            var refreshes = 0, settings = 0
            menu.onRefreshAPICosts = { refreshes += 1 }; menu.onAPICostSettings = { settings += 1 }
            recovery.performClick(nil)
            check(refreshes == 1 && settings == 0, "network recovery retries without opening settings")
            for error in [APICostError.authentication, .permission, .credentialStorage] {
                failure.error = error; failure.canRefresh = false
                menu.updateAPICosts(failure, context: context)
                check(recovery.isEnabled, "credential repair remains available when refresh is blocked")
                recovery.performClick(nil)
            }
            check(settings == 3 && refreshes == 1 && amount.stringValue == "US$12.34", "credential failures open settings and retain the previous amount")
            failure.error = .rateLimited(date.addingTimeInterval(60)); failure.canRefresh = false
            menu.updateAPICosts(failure, context: context)
            check(!recovery.isEnabled, "rate-limited recovery observes canRefresh")
            var loading = cost; loading.refreshing = true; loading.canRefresh = false
            menu.updateAPICosts(loading, context: context)
            let globalRefresh = control(menu, "menu.refresh") as! NSButton
            check(!globalRefresh.isEnabled && globalRefresh.title == language.text("刷新中…", "Refreshing…"), "API-only request keeps the combined refresh busy after account completion")
            menu.updateAPICosts(cost, context: context)
            check(globalRefresh.isEnabled, "API-only completion immediately restores the combined refresh")
            menu.updateAPICosts(APICostViewState(), context: context)
            check(menu.frame.height < enabledHeight && amount.isHidden && recovery.isHidden, "disabled removes API presentation and its recovery action")
        }
        let model = NotchPresentationModel(alwaysShowQuota: true)
        model.update(account, tasksEnabled: false, context: context)
        model.updateAPICosts(cost)
        check(model.apiCosts == cost, "notch receives separate API snapshot")
        var loading = cost; loading.refreshing = true; loading.canRefresh = false
        model.updateAPICosts(loading)
        check(model.refreshingAll, "notch combined refresh tracks an API-only request")
        model.updateAPICosts(cost)
        check(!model.refreshingAll, "notch combined refresh clears on API-only completion")
        let geometry = NotchHUDGeometry(screen: CGRect(x: 0, y: 0, width: 1440, height: 900), topInset: 32,
            leftArea: CGRect(x: 0, y: 868, width: 630, height: 32), rightArea: CGRect(x: 810, y: 868, width: 630, height: 32), backingScale: 2)!
        let layout = NotchLayout(geometry: geometry)
        model.setEnvironment(reduceMotion: true, reduceTransparency: false, lowPower: false)
        model.configure(layout); model.setVisible(true); model.click()
        model.selectPage(.usage)
        check(model.page == .usage, "preview opens actual usage page")
        for (page, name) in [(NotchDetailPage.quota, "notch-quota"), (.usage, "notch-usage")] {
            model.selectPage(page)
            check(model.page == page, "notch fixture selects the page before creating its native host")
            let host = NSHostingView(rootView: NotchDetailPages(model: model, layout: layout).background(Color.black))
            host.frame = CGRect(origin: .zero, size: layout.expandedSize)
            host.appearance = NSAppearance(named: .darkAqua)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            host.layoutSubtreeIfNeeded()
            // Let SwiftUI commit this newly mounted page before caching its native display.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            try snapshot(host, name)
            window.close()
        }
    }
}
