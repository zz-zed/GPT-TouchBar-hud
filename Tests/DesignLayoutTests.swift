import AppKit

@main
enum DesignLayoutTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        checks += 1
    }
    static func labels(_ view: NSView) -> [NSTextField] {
        guard !view.isHidden else { return [] }
        return (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(labels)
    }
    static func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    static func snapshot(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "Design/ui-v2/native/\(name).png"))
    }
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "GPTTouchBarHUD.design-tests." + UUID().uuidString
        DisplayLanguage.defaults = UserDefaults(suiteName: suite)!
        defer { DisplayLanguage.defaults.removePersistentDomain(forName: suite) }
        DisplayLanguage.current = .chinese
        let appearance = HUDAppearance(colorChoice: .graphite, backgroundOpacity: 0.94, contentOpacity: 1)
        let hud = CompactQuotaHUDView(initialAppearance: appearance, onRefresh: {}, onClose: {}, contextMenuProvider: { NSMenu() })
        let hostWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 80))
        hostWindow.contentView = host
        host.addSubview(hud)
        hud.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([hud.leadingAnchor.constraint(equalTo: host.leadingAnchor), hud.topAnchor.constraint(equalTo: host.topAnchor)])
        var state = RateLimitDisplayState.initial
        state.lastUpdated = Date()
        state.fiveHour = LimitMeter(title: "5 小时", shortTitle: "5h", window: RateLimitWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: 1800000000))
        state.weekly = LimitMeter(title: "周限额", shortTitle: "7d", window: RateLimitWindow(usedPercent: 38, windowDurationMins: 10080, resetsAt: 1800000000))
        state.taskStatus = TaskStatusSummary(runningCount: 2)
        state.tokenUsage = TokenUsageSummary(yesterdayTokens: 1240000, cumulativeTokens: 38600000)
        hud.update(with: state)
        host.layoutSubtreeIfNeeded()
        let fullWidth = hud.frame.width
        check(buttons(hud).count == 1, "Quiet only has refresh; no close button")
        check(hud.frame.height == 40, "Quiet height")
        for label in labels(hud) { check(label.frame.width + 1 >= label.fittingSize.width, "HUD text fits: \(label.stringValue)") }
        try snapshot(hud, name: "quiet")
        state.fiveHour = nil
        state.taskStatus = nil
        hud.update(with: state)
        host.layoutSubtreeIfNeeded()
        check(hud.frame.width < fullWidth, "Quiet shrinks when quota and task disappear")
        state.isRefreshing = true
        hud.update(with: state)
        check(buttons(hud).first?.isEnabled == false, "Refresh cannot be repeated in flight")
        state.isRefreshing = false
        state.resetCredits = ResetCreditSummary(response: RateLimitResetCreditsResponse(availableCount: 3, credits: nil))
        hud.update(with: state)
        host.layoutSubtreeIfNeeded()
        check(labels(hud).contains { $0.stringValue.contains("3次") }, "Reset count is visible")
        check(hud.frame.width > 0 && !hud.hasAmbiguousLayout, "Reset layout is determined")

        let prefs = PreferencesWindowController(appearance: appearance)
        let originalSize = prefs.window!.frame.size
        prefs.update(appearance: appearance, state: state, taskEnabled: true, persistentEnabled: true, persistentAvailable: false)
        prefs.window?.contentView?.layoutSubtreeIfNeeded()
        check(prefs.window!.frame.size == originalSize, "Preview must not resize preferences window")
        let tabs = prefs.window!.contentView!.subviews.compactMap { $0 as? NSTabView }.first!
        tabs.selectTabViewItem(at: 2)
        prefs.window?.contentView?.layoutSubtreeIfNeeded()
        let persistent = buttons(prefs.window!.contentView!).first { $0.title == "Touch Bar 常驻" }
        check(persistent?.isEnabled == false, "Unavailable persistence switch disabled")
        tabs.selectTabViewItem(at: 1)
        prefs.window!.appearance = NSAppearance(named: .aqua)
        prefs.window!.contentView!.wantsLayer = true
        prefs.window!.contentView!.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        prefs.showWindow(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try snapshot(prefs.window!.contentView!, name: "settings")
        prefs.window!.orderOut(nil)

        let bar = TouchBarRateLimitsView()
        host.addSubview(bar)
        NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: host.leadingAnchor), bar.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
        for language in DisplayLanguage.allCases {
            DisplayLanguage.current = language
            for balance in [false, true] {
                state.creditBalance = balance ? CreditBalanceSummary(response: CreditsSnapshot(hasCredits: true, unlimited: false, balance: "9999.99")) : nil
                for single in [false, true] {
                    state.resetCredits = single ? nil : ResetCreditSummary(response: RateLimitResetCreditsResponse(availableCount: 99, credits: nil))
                    bar.update(with: state)
                    host.layoutSubtreeIfNeeded()
                    check(bar.frame.width <= TouchBarRateLimitsView.contentWidth, "Balanced within language budget")
                    check(bar.frame.height == 30, "Point balance never adds height")
                    for label in labels(bar) where !label.stringValue.isEmpty {
                        let bounds = label.convert(label.bounds, to: bar)
                        check(bounds.minX >= 0 && bounds.maxX <= bar.frame.width + 1, "Balanced within content width")
                        check(label.frame.width + 1 >= label.fittingSize.width, "Balanced label fits")
                    }
                }
            }
        }
        DisplayLanguage.current = .chinese
        bar.update(with: state)
        host.layoutSubtreeIfNeeded()
        try snapshot(bar, name: "balanced-points")
        state.resetCredits = ResetCreditSummary(response: RateLimitResetCreditsResponse(
            availableCount: 3,
            credits: [RateLimitResetCreditResponse(status: "available", expiresAt: 1800000000)]))
        bar.update(with: state)
        host.layoutSubtreeIfNeeded()
        try snapshot(bar, name: "balanced-reset-alignment")
        let summary = StatusSummaryView(state: state)
        summary.appearance = NSAppearance(named: .aqua)
        summary.wantsLayer = true
        summary.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.addSubview(summary)
        try snapshot(summary, name: "status-summary")
        print("PASS: \(checks) design integration checks")
        if CommandLine.arguments.contains("--preview") {
            prefs.showWindow(nil)
            prefs.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            RunLoop.current.run(until: Date().addingTimeInterval(120))
        }
    }
}
