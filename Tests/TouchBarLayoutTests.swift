import AppKit

@main
enum TouchBarLayoutTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func main() throws {
        let languageSuite = "GPTTouchBarHUD.tests." + UUID().uuidString
        DisplayLanguage.defaults = UserDefaults(suiteName: languageSuite)!
        defer { DisplayLanguage.defaults.removePersistentDomain(forName: languageSuite) }
        DisplayLanguage.current = .english
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        check(TaskStatusAppearance(nil) == .idle, "Disabled task status restores default icon")
        check(TaskStatusAppearance(TaskStatusSummary()) == .idle, "Idle has no task tint")
        check(TaskStatusAppearance(TaskStatusSummary(runningCount: 2, recentlyCompletedCount: 1, unknownCount: 1)) == .running,
              "Running takes priority over completed and unknown")
        check(TaskStatusAppearance(TaskStatusSummary(recentlyCompletedCount: 1, unknownCount: 1)) == .completed,
              "Completed takes priority over unknown")
        check(TaskStatusAppearance(TaskStatusSummary(unknownCount: 1)) == .unknown, "Unknown is separate from idle")
        check(TaskStatusAppearance.running.color == .systemBlue, "Running shares blue")
        check(TaskStatusAppearance.completed.color == .systemGreen, "Completed shares green")
        check(TaskStatusAppearance.unknown.color == .systemGray, "Unknown shares gray")
        check(TaskStatusAppearance.idle.menuIcon()?.isTemplate == true, "Idle uses system template rendering")
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                for phase in [TaskStatusAppearance.running, .completed, .unknown] {
                    let icon = phase.menuIcon()
                    check(icon?.isTemplate == false, "Task icon keeps color in \(name)")
                    check(icon?.tiffRepresentation != nil, "Task icon renders in \(name)")
                }
            }
        }
        let view = TouchBarRateLimitsView()
        check(buttons(view).isEmpty, "Quota view has no persistent close/quit button")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 30),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 30))
        window.contentView = host
        host.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                                     view.topAnchor.constraint(equalTo: host.topAnchor)])
        var state = RateLimitDisplayState.initial
        state.lastUpdated = Date()
        state.fiveHour = LimitMeter(title: "5 小时", shortTitle: "5h", window: RateLimitWindow(
            usedPercent: 0, windowDurationMins: 300, resetsAt: 1799999999))
        state.weekly = LimitMeter(title: "周限额", shortTitle: "7d", window: RateLimitWindow(
            usedPercent: 10, windowDurationMins: 10080, resetsAt: 1799999999))
        state.tokenUsage = TokenUsageSummary(yesterdayTokens: 27443123, cumulativeTokens: 1234567890)

        func verify(_ name: String) {
            view.update(with: state)
            host.layoutSubtreeIfNeeded()
            check(view.frame.width > 0 && view.frame.width <= TouchBarRateLimitsView.contentWidth, "\(name): application region width budget")
            check(!view.hasAmbiguousLayout, "\(name): root layout is determined")
            for label in visibleLabels(view) where !label.stringValue.isEmpty {
                let frame = label.convert(label.bounds, to: view)
                check(frame.minX >= -0.5 && frame.maxX <= view.frame.width + 0.5, "\(name): \(label.stringValue) stays inside app region (\(frame))")
                let needed = label.cell?.cellSize.width ?? 0
                check(label.bounds.width + 1 >= needed, "\(name): \(label.stringValue) is not clipped: \(label.bounds.width) < \(needed)")
            }
            let yesterday = visibleLabels(view).first { $0.stringValue.hasPrefix(DisplayLanguage.text("昨日 ", "Yday ")) }
            if state.fiveHour != nil || state.resetCredits != nil {
                check(yesterday?.stringValue.contains(DisplayLanguage.text("2744.3", "27.4")) == true, "\(name): yesterday is visible")
            }
        }
        verify("two quotas")
        state.taskStatus = TaskStatusSummary(runningCount: 12)
        verify("running badge")
        let badge = visibleLabels(view).first { $0.stringValue == "9+" }!
        check(badge.layer?.animationKeys()?.isEmpty != false, "Hidden window does not animate")
        view.setTouchBarItemVisible(true)
        check((badge.layer?.animation(forKey: "taskBadgeBreathing") != nil) ==
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              "Visible Touch Bar animates even when host window is not visible")
        view.setTouchBarItemVisible(false)
        check(badge.layer?.animation(forKey: "taskBadgeBreathing") == nil,
              "Hidden Touch Bar stops animation")
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.update(with: state)
        view.setTouchBarItemVisible(true)
        let shouldAnimate =
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        check((badge.layer?.animation(forKey: "taskBadgeBreathing") != nil) == shouldAnimate,
              "Running animation respects window visibility and reduced motion")
        view.isHidden = true
        check(badge.layer?.animation(forKey: "taskBadgeBreathing") == nil, "Hiding view stops animation")
        view.isHidden = false
        view.update(with: state)
        state.taskStatus = TaskStatusSummary(recentlyCompletedCount: 1)
        verify("completed badge")
        check(badge.layer?.animation(forKey: "taskBadgeBreathing") == nil, "Completion stops animation")
        window.orderOut(nil)
        state.taskStatus = TaskStatusSummary(unknownCount: 1)
        verify("unknown badge")
        state.taskStatus = nil
        state.tokenUsage?.isStale = true
        verify("stale marker")
        state.creditBalance = CreditBalanceSummary(response: CreditsSnapshot(hasCredits: true, unlimited: false, balance: "9999.99"))
        verify("two quotas and USD balance")
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/touchbar-layout-preview.png"))
        }
        state.fiveHour = nil
        state.resetCredits = ResetCreditSummary(response: RateLimitResetCreditsResponse(availableCount: 9, credits: nil))
        verify("reset credits and USD balance")
        let expiry = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 14, minute: 37))!
        state.resetCredits = ResetCreditSummary(response: RateLimitResetCreditsResponse(
            availableCount: 9,
            credits: [RateLimitResetCreditResponse(status: "available", expiresAt: expiry.timeIntervalSince1970)]))
        check(state.resetCredits?.expirationText == "09/18 14:37", "Expiration preserves local hour and minute")
        verify("reset credits with minute precision and USD balance")
        DisplayLanguage.current = .chinese
        check(state.resetCredits?.expirationText == "09月18日 14:37 到期", "Chinese minute-level expiry")
        verify("switch existing view to Chinese")
        DisplayLanguage.current = .english
        verify("switch existing view back to English")
        state.resetCredits = nil
        verify("weekly and balance")
        state.creditBalance = nil
        verify("weekly only")
        check(SystemTouchBarPresenter.applicationRegionPlacement == 0, "System Control Strip keeps its native region")
        let bar = NSTouchBar()
        let existing = NSCustomTouchBarItem(identifier: .init("test.existingItem"))
        bar.templateItems.insert(existing)
        SystemTouchBarPresenter.configureSystemButton(for: bar)
        check(bar.escapeKeyReplacementItemIdentifier == SystemTouchBarPresenter.systemButtonIdentifier,
              "Our modal explicitly replaces its background close button")
        let systemItem = bar.item(forIdentifier: SystemTouchBarPresenter.systemButtonIdentifier) as! NSCustomTouchBarItem
        check(systemItem.visibilityPriority == .high, "Replacement applies in foreground and background")
        check(systemItem.view.fittingSize.width == 0, "System button replacement has no visible width")
        check(buttons(systemItem.view).isEmpty, "Replacement has no actionable close button")
        SystemTouchBarPresenter.configureSystemButton(for: bar)
        check(bar.templateItems.count == 2 && bar.templateItems.contains(existing), "Idempotent setup preserves other items")
        let nativeBar = NSTouchBar()
        check(nativeBar.escapeKeyReplacementItemIdentifier == nil, "No effect on other/system bars")
        nativeBar.escapeKeyReplacementItemIdentifier = .init("test.existingEscape")
        SystemTouchBarPresenter.configureSystemButton(for: nativeBar)
        check(nativeBar.escapeKeyReplacementItemIdentifier?.rawValue == "test.existingEscape",
              "Do not overwrite an explicitly configured escape item")
        check(!window.isVisible, "Layout validation does not show a floating window")
        print("PASS: \(checks) Touch Bar layout checks")
    }

    private static func visibleLabels(_ view: NSView) -> [NSTextField] {
        guard !view.isHidden else { return [] }
        if let label = view as? NSTextField { return [label] }
        return view.subviews.flatMap { visibleLabels($0) }
    }

    private static func buttons(_ view: NSView) -> [NSButton] {
        if let button = view as? NSButton { return [button] }
        return view.subviews.flatMap { buttons($0) }
    }
}
