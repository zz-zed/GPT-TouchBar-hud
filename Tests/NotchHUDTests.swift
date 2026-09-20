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
                for (width, height): (CGFloat, CGFloat) in [(180, 24), (260, 24), (340, 221)] {
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

        var resolver = DisplayTargetResolver()
        let a = DisplayTargetResolver.Candidate(id: 1, geometry: sample)
        let b = DisplayTargetResolver.Candidate(id: 2, geometry: sample)
        check(resolver.resolve([a, b]) != nil && resolver.selectedID == 1, "select valid notch")
        _ = resolver.resolve([b, a])
        check(resolver.selectedID == 1, "main-screen reorder does not move HUD")
        _ = resolver.resolve([b])
        check(resolver.selectedID == 2, "removed screen reselects")
        check(resolver.resolve([]) == nil && resolver.selectedID == nil, "no valid notch falls back")
        for requested in [false, true] {
            for active in [false, true] {
                for unoccluded in [false, true] {
                    check(NotchVisibility(requested: requested, onActiveSpace: active, unoccluded: unoccluded).isVisible == (requested && active && unoccluded), "actual visibility requires intent, active Space and occlusion")
                }
            }
        }
        check(NotchTaskPresentation(nil, enabled: false).badge.isEmpty, "disabled tasks are omitted")
        check(NotchTaskPresentation(nil).badge == "—", "missing snapshot unknown")
        check(NotchTaskPresentation(TaskStatusSummary()).badge == "0", "explicit legacy local idle distinct from unavailable")
        check(NotchTaskPresentation(TaskStatusSummary(runningCount: 12)).badge == "12", "full task count")
        check(NotchTaskPresentation(TaskStatusSummary(runningCount: 2, recentlyCompletedCount: 1, unknownCount: 1)).badge == "2 ? ✓", "partial completion retains running and unknown")
        check(NotchTaskPresentation(TaskStatusSummary(recentlyCompletedCount: 1, unknownCount: 1)).badge == "?", "uncertainty prevents overall success")
        let controller = NotchHUDController()
        controller.animationsEnabled = false
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
                if index == 3 { check(summary.title.contains("—") && !summary.title.contains("0%"), "unknown not zero") }
                if index == 4 { check(summary.title.contains("!"), "stale marker") }
                check(summary.frame.width + 1 >= summary.fittingSize.width, "compact text fits")
                summary.performClick(nil)
                check(controller.isExpanded && controller.isPresented, "click expands")
                check(panel.frame.maxY == top && panel.frame.midX == center, "expanded anchor stable")
                check(!controller.view.surfacePath().contains(NSPoint(x: 0.1, y: controller.view.bounds.height - 0.1)), "transparent bottom corner")
                check(controller.view.surfacePath().contains(NSPoint(x: controller.view.bounds.midX, y: 1)), "solid camera attachment")
                check(!controller.view.surfacePath().contains(NSPoint(x: 0.1, y: 0.1)), "shoulder outside path")
                for view in descendants(controller.view) where view is NSTextField || view is NSButton {
                    let rect = view.convert(view.bounds, to: controller.view)
                    check(controller.view.bounds.insetBy(dx: -1, dy: -1).contains(rect), "controls inside panel")
                    if let label = view as? NSTextField, (label.superview === controller.view || label.superview === controller.view.detailContent) {
                        let measured = (label.stringValue as NSString).boundingRect(with: NSSize(width: max(1, label.frame.width - 4), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: label.font!])
                        check(label.frame.height + 1 >= ceil(measured.height), "wrapped text height fits: \(label.stringValue)")
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
        check(!MenuBarPresentation(state: full, mode: .single, panelVisible: false).title.contains("43%"), "single prioritizes actual 5h")

        let nativeStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(nativeStatusItem) }
        let nativeButton = nativeStatusItem.button!
        nativeButton.image = NSImage(systemSymbolName: "bolt.horizontal.circle.fill", accessibilityDescription: nil)
        nativeButton.imagePosition = .imageLeft
        nativeButton.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        func applyToNativeStatusItem(_ presentation: MenuBarPresentation) -> CGFloat {
            presentation.apply(to: nativeStatusItem)
            nativeButton.layoutSubtreeIfNeeded()
            check(nativeStatusItem.length == presentation.statusItemLength, "native status item uses presentation length policy")
            check(nativeButton.frame.width + 1 >= nativeButton.fittingSize.width, "native status item content fits")
            return nativeButton.frame.width
        }
        func state(remainingPercent: Double, weekly: Bool = false) -> RateLimitDisplayState {
            var state = RateLimitDisplayState.initial
            state.fiveHour = LimitMeter(
                title: "5 小时",
                shortTitle: "5h",
                window: RateLimitWindow(usedPercent: 100 - remainingPercent, windowDurationMins: 300, resetsAt: nil)
            )
            if weekly {
                state.weekly = LimitMeter(
                    title: "周",
                    shortTitle: "W",
                    window: RateLimitWindow(usedPercent: 43, windowDurationMins: 10080, resetsAt: nil)
                )
            }
            return state
        }

        var percentageWidths: [Int: CGFloat] = [:]
        for percentage in [0, 9, 10, 99, 100] {
            let presentation = MenuBarPresentation(
                state: state(remainingPercent: Double(percentage)),
                mode: .single,
                panelVisible: false
            )
            check(presentation.title == " 5h \(percentage)%", "menu uses actual \(percentage)% content")
            check(presentation.statusItemLength == NSStatusItem.variableLength, "text uses variable status item length")
            percentageWidths[percentage] = applyToNativeStatusItem(presentation)
        }
        check(percentageWidths[9]! < percentageWidths[10]!, "native width grows from one to two digits")
        check(percentageWidths[99]! < percentageWidths[100]!, "native width grows from two to three digits")

        for language in DisplayLanguage.allCases {
            DisplayLanguage.current = language
            var resetOne = RateLimitDisplayState.initial
            resetOne.resetCredits = ResetCreditSummary(response: RateLimitResetCreditsResponse(availableCount: 1, credits: nil))
            var resetMany = RateLimitDisplayState.initial
            resetMany.resetCredits = ResetCreditSummary(response: RateLimitResetCreditsResponse(availableCount: 12, credits: nil))
            let one = MenuBarPresentation(state: resetOne, mode: .single, panelVisible: false)
            let many = MenuBarPresentation(state: resetMany, mode: .single, panelVisible: false)
            check(one.title.contains("1") && many.title.contains("12"), "\(language.rawValue) reset count uses actual digits")
            check(applyToNativeStatusItem(one) < applyToNativeStatusItem(many), "\(language.rawValue) reset count changes native width")
        }

        DisplayLanguage.current = .chinese
        let single = MenuBarPresentation(state: state(remainingPercent: 9, weekly: true), mode: .single, panelVisible: false)
        let dual = MenuBarPresentation(state: state(remainingPercent: 9, weekly: true), mode: .full, panelVisible: false)
        check(!single.title.contains("57%") && dual.title.contains("57%"), "single and full preserve metric selection")
        check(applyToNativeStatusItem(single) < applyToNativeStatusItem(dual), "dual quota changes native width")

        var failed = state(remainingPercent: 9)
        failed.errorMessage = "Test connection error"
        let healthy = MenuBarPresentation(state: state(remainingPercent: 9), mode: .single, panelVisible: false)
        let errorPresentation = MenuBarPresentation(state: failed, mode: .single, panelVisible: false)
        let healthyWidth = applyToNativeStatusItem(healthy)
        let errorWidth = applyToNativeStatusItem(errorPresentation)
        check(!healthy.title.contains("!") && errorPresentation.title.hasSuffix(" !"), "error marker appears only for actual error")
        check(healthyWidth < errorWidth, "error appearance changes native width")
        check(applyToNativeStatusItem(healthy) == healthyWidth, "error recovery restores native width")

        let icon = MenuBarPresentation(state: full, mode: .icon, panelVisible: false)
        check(icon.title.isEmpty && icon.statusItemLength == NSStatusItem.squareLength, "icon mode uses square status item")
        check(applyToNativeStatusItem(icon) < applyToNativeStatusItem(dual), "icon and text modes switch native width")
        check(MenuBarPresentation(state: full, mode: .automatic, panelVisible: true).statusItemLength == NSStatusItem.squareLength, "automatic visible panel uses square status item")
        check(MenuBarPresentation(state: full, mode: .automatic, panelVisible: false).statusItemLength == NSStatusItem.variableLength, "automatic hidden panel uses variable status item")

        for language in DisplayLanguage.allCases {
            DisplayLanguage.current = language
            for count in [0, 2, 12, 100] {
                for percent in [0.0, 9, 10, 99, 100] {
                    var state = full
                    state.taskStatus = TaskStatusSummary(runningCount: count)
                    state.fiveHour = LimitMeter(title: "5h", shortTitle: "5h", window: RateLimitWindow(usedPercent: 100 - percent, windowDurationMins: 300, resetsAt: 1800000000))
                    controller.collapse()
                    controller.update(state)
                    check(controller.panel.frame.height == 24, "summary is 24 pt")
                    check(controller.view.summaryText.hasPrefix(String(count)), "untruncated count")
                    check(controller.view.compactWidth <= controller.panel.frame.width, "current content fully measured")
                    check(!controller.isExpanded, "data never opens detail")
                }
            }
        }
        DisplayLanguage.current = .chinese
        controller.update(full)
        let plainWidth = controller.view.compactWidth
        controller.update(error)
        check(controller.view.compactWidth > plainWidth, "error width exists only when present")
        controller.update(weekly)
        check(controller.view.compactWidth < plainWidth, "absent quota has no reserved column")
        controller.update(full, taskDisplayEnabled: false)
        check(!controller.view.summaryText.contains("2" + "  "), "disabled task group omitted")
        controller.update(full)
        controller.toggleExpanded()
        print("Native regular expanded size: \(controller.panel.frame.size)")
        let regularHeight = controller.view.preferredHeight
        let titleField = descendants(controller.view).compactMap { $0 as? NSTextField }.first { $0.stringValue == "2 个任务执行中" }!
        titleField.stringValue = String(repeating: "长任务状态需要换行。", count: 12)
        check(controller.view.preferredHeight > regularHeight, "long native content grows naturally")
        controller.update(full)
        // Extreme content on a narrow synthetic screen must wrap instead of dropping digits.
        let narrowScreen = NSRect(x: 0, y: 0, width: 400, height: 600)
        let narrow = NotchHUDGeometry(screen: narrowScreen, topInset: 32,
            leftArea: NSRect(x: 0, y: 568, width: 130, height: 32),
            rightArea: NSRect(x: 270, y: 568, width: 130, height: 32))!
        var extreme = reset
        extreme.taskStatus = TaskStatusSummary(runningCount: Int.max, recentlyCompletedCount: 1, unknownCount: 1)
        extreme.resetCredits = ResetCreditSummary(response: RateLimitResetCreditsResponse(availableCount: Int.max, credits: nil))
        controller.collapse()
        controller.update(extreme)
        check(controller.show(in: narrow), "narrow synthetic screen")
        check(controller.panel.frame.height > 24, "extreme counts gain natural summary height")
        check(controller.view.summaryText.contains(String(Int.max)), "extreme count never shortened")
        try snapshot(controller.view, "notch-v2-extreme")
        controller.toggleExpanded()
        // Force a long localized explanatory note to exercise native overflow, not a clipped window.
        let noteField = controller.view.detailContent.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("本地监测覆盖不完整") }!
        noteField.stringValue = String(repeating: "这是一段需要完整阅读的状态说明，不能裁掉底部操作。", count: 70)
        let overflowHeight = controller.view.preferredHeight(width: narrow.screen.width)
        let limitedFrame = narrow.frame(width: narrow.screen.width, height: overflowHeight)
        check(overflowHeight > narrow.anchor.y && limitedFrame.height == narrow.anchor.y, "geometry caps screen-height overflow")
        controller.panel.setFrame(limitedFrame, display: true)
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
        check(controller.view.detailScroll.hasVerticalScroller, "screen-height overflow provides scrolling")
        let hideAction = controller.view.detailContent.subviews.compactMap { $0 as? NSButton }.first { $0.title == "隐藏" }!
        controller.view.detailContent.scrollToVisible(hideAction.frame)
        check(controller.view.detailScroll.documentVisibleRect.intersects(hideAction.frame), "bottom action reachable by scroll")
        controller.collapse()
        check(controller.show(in: sample), "restore sample geometry")
        controller.update(full)
        try snapshot(controller.view, "notch-v2-compact")
        controller.toggleExpanded()
        var refreshed = 0, settingsOpened = 0, hideSelected = 0
        controller.onRefresh = { refreshed += 1 }
        controller.onSettings = { settingsOpened += 1 }
        controller.onHide = { hideSelected += 1; controller.hide() }
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
        button("隐藏").performClick(nil)
        check(hideSelected == 1 && !controller.isPresented, "hide action connected")
        check(controller.show(in: sample), "explicit restore")
        controller.toggleExpanded()
        button("收起").performClick(nil)
        check(!controller.isExpanded && controller.isPresented, "collapse keeps compact")
        check(!controller.show(in: nil) && !panel.isVisible && !controller.isVisible, "screen loss no orphan panel")
        check(controller.show(in: sample) && !controller.isExpanded, "return collapsed")
        controller.hide()
        check(!controller.isAnimating, "hide cancels transition")
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        controller.animationsEnabled = true
        check(controller.show(in: sample), "transition harness show")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        print("Live synthetic panel: requested=\(controller.isPresented), visible=\(controller.isVisible), onSpace=\(panel.isOnActiveSpace), occlusion=\(panel.occlusionState.rawValue)")
        controller.toggleExpanded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.07))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check(controller.isAnimating, "animation is active at intermediate frame")
            check(panel.frame.height > 24 && panel.frame.height < controller.view.preferredHeight, "intermediate geometry is between endpoints")
        }
        print("Intermediate anchor: top=\(panel.frame.maxY), expected=\(sample.anchor.y), center=\(panel.frame.midX), expected=\(sample.anchor.x)")
        fflush(stdout)
        check(abs(panel.frame.maxY - sample.anchor.y) < 0.001 && abs(panel.frame.midX - sample.anchor.x) < 0.001, "intermediate frame keeps anchor")
        let local = NSPoint(x: 0.1, y: 0.1)
        let screenPoint = panel.convertPoint(toScreen: controller.view.convert(local, to: nil))
        check(controller.contains(screenPoint) == controller.view.surfacePath().contains(local), "intermediate routing matches visible path")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check(!controller.isAnimating && controller.isExpanded, "transition completes expanded without standing timer")
        button("刷新").performClick(nil)
        check(refreshed == 2, "refresh in expanded nonactivating panel")
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID, "show and expand preserve frontmost PID")
        controller.environmentChanged()
        check(!controller.isExpanded, "Space or app change collapses")
        controller.hide()
        controller.environmentChanged()
        check(!controller.isPresented && !controller.isVisible, "environment cannot unhide user-hidden panel")
        check(panel.collectionBehavior.contains(.fullScreenPrimary) && !panel.collectionBehavior.contains(.fullScreenAuxiliary), "other-app full-screen opt-out")

        try HookPresentationIntegrationChecks.run(geometry: sample)

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
        let quit = descendants(content).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "settings.quit" }!
        var quitRequested = false
        prefs.onQuit = { quitRequested = true }
        quit.performClick(nil)
        check(quitRequested, "settings provides reachable quit action")
        check(content.bounds.contains(quit.frame), "quit button inside settings")
        check(NSApp.activationPolicy() == .accessory, "settings does not change accessory policy")
        tabs.selectTabViewItem(at: 3)
        content.layoutSubtreeIfNeeded()
        let experiments = tabs.selectedTabViewItem!.view!
        let hookEntry = descendants(experiments).compactMap { $0 as? NSButton }.first { $0.title == "配置 Hooks 实验…" }!
        var experimentRequested = false
        prefs.onHookExperiment = { experimentRequested = true }
        hookEntry.performClick(nil)
        check(experimentRequested, "experiment entry survives Quit integration")
        check(experiments.bounds.contains(hookEntry.convert(hookEntry.bounds, to: experiments)), "experiment entry remains in tab")
        check(content.bounds.contains(quit.frame), "Quit remains reachable with experiment tab")
        experiments.wantsLayer = true
        experiments.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        try snapshot(experiments, "integrated-settings-experiment")
        prefs.window!.orderOut(nil)
        print("PASS: \(checks) notch V2 checks")
    }
}
