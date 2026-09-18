import AppKit

@main
enum NotchHUDTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        precondition(condition(), name)
        checks += 1
    }
    static func descendants(_ view: NSView) -> [NSView] {
        guard !view.isHidden else { return [] }
        return [view] + view.subviews.flatMap(descendants)
    }
    static func snapshot(_ view: NSView, _ name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            preconditionFailure("snapshot unavailable")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/\(name).png"))
    }
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "NotchHUDTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let oldDefaults = DisplayLanguage.defaults
        DisplayLanguage.defaults = defaults
        defer { DisplayLanguage.defaults = oldDefaults; defaults.removePersistentDomain(forName: suite) }
        defaults.set("purple", forKey: "hud.color")
        var preferences = HUDPresentationPreferences(defaults: defaults)
        check(preferences.mode == .floating && !preferences.isVisible, "existing default stays hidden desktop")
        for mode in HUDDisplayMode.allCases {
            preferences.mode = mode
            preferences.save(to: defaults)
            let restored = HUDPresentationPreferences(defaults: defaults)
            check(restored.mode == mode && !restored.isVisible, "mode cannot unhide after restart")
            check(!restored.usesNotch(hasGeometry: false), "all modes fallback without geometry")
            check(restored.usesNotch(hasGeometry: true) == (mode != .floating), "selected form")
        }
        preferences.isVisible = true
        preferences.save(to: defaults)
        check(HUDPresentationPreferences(defaults: defaults).isVisible, "visible intent restored")
        check(defaults.string(forKey: "hud.color") == "purple", "appearance preserved")
        defaults.set("future", forKey: HUDDisplayMode.defaultsKey)
        check(HUDDisplayMode.load(from: defaults) == .floating, "unknown mode fallback")

        var sample: NotchHUDGeometry!
        for origin in [NSPoint.zero, NSPoint(x: -1512, y: 280), NSPoint(x: 1920, y: -982)] {
            for inset: CGFloat in [24, 32, 38] {
                let frame = NSRect(origin: origin, size: NSSize(width: 1512, height: 982))
                let left = NSRect(x: origin.x, y: frame.maxY - inset, width: 666, height: inset)
                let right = NSRect(x: origin.x + 846, y: frame.maxY - inset, width: 666, height: inset)
                let geometry = NotchHUDGeometry(screen: frame, topInset: inset, leftArea: left, rightArea: right)!
                for (width, height): (CGFloat, CGFloat) in [(180, 30), (260, 30), (380, 310)] {
                    let panel = geometry.frame(width: width, height: height)
                    check(panel.maxY == frame.maxY - inset, "top anchor below camera")
                    check(panel.midX == origin.x + 756, "stable horizontal center")
                    check(frame.contains(panel), "entire panel contained")
                    check(!panel.intersects(left) && !panel.intersects(right), "no menu bar wings")
                }
                check(NotchHUDGeometry(screen: frame, topInset: 0, leftArea: left, rightArea: right) == nil, "no notch safe fallback")
                check(NotchHUDGeometry(screen: frame, topInset: inset, leftArea: right, rightArea: left) == nil, "invalid geometry rejected")
                if origin == .zero && inset == 32 { sample = geometry }
            }
        }
        let usable = NSRect(x: -1504, y: 8, width: 1496, height: 920)
        let clamped = CompactHUDPanel.clampedOrigin(frame: NSRect(x: -30, y: 920, width: 300, height: 40), usable: usable)
        check(usable.contains(NSRect(origin: clamped, size: NSSize(width: 300, height: 40))), "desktop growth clamped inside secondary screen")

        let controller = NotchHUDController()
        check(controller.show(in: sample), "show notch")
        let panel = controller.panel
        check(!panel.canBecomeKey && !panel.canBecomeMain, "nonactivating")
        let top = panel.frame.maxY, center = panel.frame.midX
        let five = LimitMeter(title: "5 小时", shortTitle: "5h", window: RateLimitWindow(usedPercent: 28, windowDurationMins: 300, resetsAt: 1800000000))
        let week = LimitMeter(title: "周", shortTitle: "W", window: RateLimitWindow(usedPercent: 57, windowDurationMins: 10080, resetsAt: 1800000000))
        var full = RateLimitDisplayState.initial
        full.fiveHour = five
        full.weekly = week
        full.taskStatus = TaskStatusSummary(runningCount: 2)
        full.tokenUsage = TokenUsageSummary(yesterdayTokens: 128400, cumulativeTokens: 8620000)
        full.creditBalance = CreditBalanceSummary(response: CreditsSnapshot(hasCredits: true, unlimited: false, balance: "128.40"))
        full.lastUpdated = Date()
        var variants: [RateLimitDisplayState] = [full]
        var reset = full
        reset.fiveHour = nil
        reset.resetCredits = ResetCreditSummary(response: RateLimitResetCreditsResponse(availableCount: 3, credits: [RateLimitResetCreditResponse(status: "available", expiresAt: 1800000000)]))
        variants.append(reset)
        var weekly = full
        weekly.fiveHour = nil
        weekly.tokenUsage = nil
        weekly.creditBalance = nil
        variants.append(weekly)
        var missing = RateLimitDisplayState.initial
        missing.resetCredits = ResetCreditSummary(response: RateLimitResetCreditsResponse(availableCount: 0, credits: nil))
        variants.append(missing)
        var error = full
        error.errorMessage = "Test connection error"
        variants.append(error)

        for language in DisplayLanguage.allCases {
            DisplayLanguage.current = language
            for (index, state) in variants.enumerated() {
                controller.collapse()
                controller.update(state)
                let summary = descendants(controller.view).compactMap { $0 as? NSButton }.first!
                if state.weekly != nil { check(summary.title.contains("43%"), "weekly visible while collapsed") }
                if state.fiveHour != nil { check(summary.title.contains("72%"), "5h visible while collapsed") }
                if index == 1 { check(summary.title.contains("3"), "reset credits visible") }
                if index == 3 { check(summary.title.contains("--") && !summary.title.contains("0%"), "unknown not zero") }
                if index == 4 { check(summary.title.contains("!"), "stale marker") }
                check(summary.frame.width + 1 >= summary.fittingSize.width, "compact text fits")
                summary.performClick(nil)
                check(controller.isExpanded && controller.isVisible, "click expands")
                check(panel.frame.maxY == top && panel.frame.midX == center, "expanded anchor stable")
                check(!controller.view.surfacePath().contains(NSPoint(x: 0.1, y: controller.view.bounds.height - 0.1)), "transparent bottom corner")
                check(controller.view.surfacePath().contains(NSPoint(x: 1, y: 1)), "solid upper attachment")
                for view in descendants(controller.view) where view is NSTextField || view is NSButton {
                    let rect = view.convert(view.bounds, to: controller.view)
                    check(controller.view.bounds.insetBy(dx: -1, dy: -1).contains(rect), "controls inside panel")
                    if let label = view as? NSTextField {
                        check(label.frame.width + 1 >= label.fittingSize.width, "text fits: \(label.stringValue)")
                    }
                }
                let menuAuto = MenuBarPresentation(state: state, mode: .automatic, panelVisible: true)
                check(menuAuto.title.isEmpty, "automatic menu only icon while visible")
                check(!MenuBarPresentation(state: state, mode: .automatic, panelVisible: false).title.isEmpty, "hidden panel restores menu quota")
                check(MenuBarPresentation(state: state, mode: .icon, panelVisible: false).title.isEmpty, "explicit icon respected")
                if state.weekly != nil {
                    check(MenuBarPresentation(state: state, mode: .full, panelVisible: true).title.contains("43%"), "explicit full survives visible panel")
                }
                if index == 0 || index == 1 { try snapshot(controller.view, "notch-ledger-\(language.rawValue)-\(index)") }
            }
        }
        DisplayLanguage.current = .chinese
        let firstTitle = MenuBarPresentation(state: full, mode: .full, panelVisible: false).reservedTitle
        var hundred = full
        hundred.fiveHour = LimitMeter(title: "5h", shortTitle: "5h", window: RateLimitWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: nil))
        check(MenuBarPresentation(state: hundred, mode: .full, panelVisible: false).reservedTitle == firstTitle, "menu width budget stable at 100%")
        check(!MenuBarPresentation(state: full, mode: .single, panelVisible: false).title.contains("43%"), "single prioritizes actual 5h")

        controller.update(full)
        var refreshed = 0, settingsOpened = 0, desktopSelected = 0
        controller.onRefresh = { refreshed += 1 }
        controller.onSettings = { settingsOpened += 1 }
        controller.onDesktop = { desktopSelected += 1 }
        func button(_ title: String) -> NSButton {
            descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == title }!
        }
        button("刷新").performClick(nil)
        check(refreshed == 1, "refresh connected")
        var refreshing = full
        refreshing.isRefreshing = true
        controller.update(refreshing)
        check(!button("…").isEnabled, "refresh disabled while in flight")
        controller.update(full)
        button("设置").performClick(nil)
        check(settingsOpened == 1 && !controller.isExpanded, "settings collapses detail")
        controller.toggleExpanded()
        button("桌面").performClick(nil)
        check(desktopSelected == 1 && !controller.isExpanded, "desktop action connected")
        controller.toggleExpanded()
        button("收起").performClick(nil)
        check(!controller.isExpanded && controller.isVisible, "collapse keeps compact")
        check(!controller.show(in: nil) && !panel.isVisible && !controller.isVisible, "screen loss no orphan panel")
        check(controller.show(in: sample) && !controller.isExpanded, "return collapsed")
        controller.hide()

        let prefs = PreferencesWindowController(appearance: HUDAppearance.load())
        prefs.update(appearance: HUDAppearance.load(), state: full, taskEnabled: true, persistentEnabled: false, persistentAvailable: false)
        prefs.showWindow(nil)
        prefs.window!.appearance = NSAppearance(named: .aqua)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let content = prefs.window!.contentView!
        content.layoutSubtreeIfNeeded()
        try snapshot(content, "notch-settings")
        let tabs = content.subviews.compactMap { $0 as? NSTabView }.first!
        let general = tabs.selectedTabViewItem!.view!
        for view in descendants(general) where view is NSControl {
            let rect = view.convert(view.bounds, to: general)
            check(general.bounds.insetBy(dx: -1, dy: -1).contains(rect), "general settings controls inside tab")
        }
        general.wantsLayer = true
        general.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        try snapshot(general, "notch-settings-general")
        prefs.window!.orderOut(nil)
        print("PASS: \(checks) notch Ledger checks")
    }
}
