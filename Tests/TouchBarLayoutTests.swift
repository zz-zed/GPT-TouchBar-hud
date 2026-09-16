import AppKit

@main
enum TouchBarLayoutTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let view = TouchBarRateLimitsView()
        check(buttons(view).isEmpty, "Quota view has no persistent close/quit button")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 30),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
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
            check(view.frame.width == 600, "\(name): application region width budget")
            check(!view.hasAmbiguousLayout, "\(name): root layout is determined")
            for label in visibleLabels(view) where !label.stringValue.isEmpty {
                let frame = label.convert(label.bounds, to: view)
                check(frame.minX >= -0.5 && frame.maxX <= 600.5, "\(name): \(label.stringValue) stays inside app region (\(frame))")
                let needed = label.cell?.cellSize.width ?? 0
                check(label.bounds.width + 1 >= needed, "\(name): \(label.stringValue) is not clipped: \(label.bounds.width) < \(needed)")
            }
            let yesterday = visibleLabels(view).first { $0.stringValue.hasPrefix("昨日 ") }
            if state.fiveHour != nil || state.resetCredits != nil {
                check(yesterday?.stringValue.contains("2744.3") == true, "\(name): yesterday is visible")
            }
        }
        verify("two quotas")
        state.taskStatus = TaskStatusSummary(runningCount: 12)
        verify("running badge")
        state.taskStatus = TaskStatusSummary(recentlyCompletedCount: 1)
        verify("completed badge")
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
