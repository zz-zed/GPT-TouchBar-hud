import AppKit
import ResetNewsCore

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
    static func accessibilityElement(in root: Any, identifier: String) -> (any NSAccessibilityProtocol)? {
        var visited = Set<ObjectIdentifier>()
        func find(_ value: Any) -> (any NSAccessibilityProtocol)? {
            guard let object = value as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if let element = object as? any NSAccessibilityProtocol {
                if element.accessibilityIdentifier() == identifier { return element }
                for child in element.accessibilityChildren() ?? [] {
                    if let match = find(child) { return match }
                }
            }
            if let view = object as? NSView {
                for child in view.subviews { if let match = find(child) { return match } }
            }
            return nil
        }
        return find(root)
    }
    static func pressShoulder(in window: NSWindow, host: NSView, layout: NotchLayout) {
        let point = host.convert(NSPoint(x: layout.markX(left: false), y: layout.visualBarHeight / 2), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Queue release before down in case AppKit starts a synchronous tracking loop.
        // These are process-local events targeting this fixture window only.
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.sendEvent(event(.leftMouseDown))
        while let pending = NSApp.nextEvent(matching: [.leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(pending)
        }
    }
    static func snapshot(_ view: NSView, _ name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            preconditionFailure("snapshot unavailable")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/\(name).png"))
    }
    static func peekDateChecks() {
        let originalLanguage = DisplayLanguage.current
        defer { DisplayLanguage.current = originalLanguage }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 10, minute: 0))!
        for language in DisplayLanguage.allCases {
            DisplayLanguage.current = language
            var state = RateLimitDisplayState.initial
            state.fiveHour = LimitMeter(title: "5h", shortTitle: "5h", window: RateLimitWindow(
                usedPercent: 28, windowDurationMins: 300, resetsAt: date.addingTimeInterval(-3_600).timeIntervalSince1970))
            state.weekly = LimitMeter(title: "Weekly", shortTitle: "7d", window: RateLimitWindow(
                usedPercent: 57, windowDurationMins: 10_080, resetsAt: date.timeIntervalSince1970))
            let adapter = NotchContentAdapter(state, tasksEnabled: true)
            let weekly = adapter.peek(left: false)
            check(weekly.value == DisplayLanguage.text("周 43%", "7d 43%"), "Peek preserves the actual weekly remaining quota")
            check(weekly.detail == "09/25 10:00", "Only right Peek uses the fixed short month/day 24-hour format")
            check(weekly.help.contains("2026") && weekly.help.contains("10:00") && weekly.help.contains("43%")
                && weekly.help.contains(DisplayLanguage.text("周限额剩余", "Weekly remaining"))
                && weekly.help.contains(DisplayLanguage.text("重置", "Resets")), "Weekly help and accessibility retain year, remaining quota and reset meaning")
            check(adapter.peek(left: true).detail == adapter.metrics.first?.date, "Left 5h Peek retains the original date wording")
            check(adapter.peek(left: true).help == adapter.metrics.first!.compact + " · " + adapter.metrics.first!.date,
                "Left 5h help remains unchanged")
            check(adapter.metrics.last?.date == HUDMetric.rows(for: state).last?.date, "Shared detail rows retain their original full reset wording")
            let next = calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 23, minute: 45))!
            state.weekly = LimitMeter(title: "Weekly", shortTitle: "7d", window: RateLimitWindow(
                usedPercent: 57, windowDurationMins: 10_080, resetsAt: next.timeIntervalSince1970 * 1_000))
            let changed = NotchContentAdapter(state, tasksEnabled: true).peek(left: false)
            check(changed.detail == "01/02 23:45" && changed.help.contains("2027"), "Short date follows the real meter across years and millisecond epochs")
            for invalid: Double? in [nil, .nan, .infinity, -.infinity] {
                state.weekly = LimitMeter(title: "Weekly", shortTitle: "7d", window: RateLimitWindow(
                    usedPercent: 57, windowDurationMins: 10_080, resetsAt: invalid))
                let unknown = NotchContentAdapter(state, tasksEnabled: true).peek(left: false)
                check(unknown.value == weekly.value && unknown.detail == DisplayLanguage.text("重置 --", "Resets —"),
                    "Missing and nonfinite reset dates keep real quota and an unknown-time placeholder")
                check(unknown.help.contains(DisplayLanguage.text("重置时间未知", "Reset time unknown")), "Unknown reset time stays explicit in help and accessibility")
            }
            state.weekly = nil
            check(NotchContentAdapter(state, tasksEnabled: true).peek(left: false).value == "7d —",
                "Absent weekly meter never falls back to the 5h meter")
            state.fiveHour = nil
            state.resetCredits = ResetCreditSummary(response: RateLimitResetCreditsResponse(availableCount: 3,
                credits: [RateLimitResetCreditResponse(status: "available", expiresAt: date.timeIntervalSince1970)]))
            let credits = NotchContentAdapter(state, tasksEnabled: true)
            check(credits.peek(left: false).value == "7d —" && credits.peek(left: false).detail == DisplayLanguage.text("暂无数据", "No data"),
                "Absent weekly data cannot borrow reset credits or their expiration")
            check(credits.peek(left: true).value == credits.metrics.first?.compact && credits.peek(left: true).detail == credits.metrics.first?.date,
                "Left reset-credit fallback stays unchanged")
        }
    }
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "NotchHUDTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let oldDefaults = DisplayLanguage.defaults
        DisplayLanguage.defaults = defaults
        defer { DisplayLanguage.defaults = oldDefaults; defaults.removePersistentDomain(forName: suite) }
        peekDateChecks()
        defaults.set("purple", forKey: "hud.color")
        var preferences = HUDPresentationPreferences(defaults: defaults)
        check(preferences.mode == .automatic && !preferences.isVisible, "unconfigured mode defaults to automatic")
        check(preferences.usesNotch(hasGeometry: true), "first launch selects notch when available")
        check(!preferences.usesNotch(hasGeometry: false), "first launch falls back to desktop without notch")
        preferences.applyStartupVisibility(hasGeometry: false, defaults: defaults)
        check(!preferences.isVisible, "first launch without notch keeps desktop hidden")
        check(defaults.object(forKey: HUDPresentationPreferences.visibilityKey) == nil, "no notch does not record a manual hide")
        preferences = HUDPresentationPreferences(defaults: defaults)
        preferences.applyStartupVisibility(hasGeometry: true, defaults: defaults)
        check(preferences.isVisible && preferences.usesNotch(hasGeometry: true), "first notch launch displays the detected form")
        check(HUDPresentationPreferences(defaults: defaults).isVisible, "automatic first display survives restart")
        check(defaults.object(forKey: HUDDisplayMode.defaultsKey) == nil, "detection does not save a manual choice")
        for mode in HUDDisplayMode.allCases {
            preferences.mode = mode
            preferences.isVisible = false
            preferences.save(to: defaults)
            var restored = HUDPresentationPreferences(defaults: defaults)
            restored.applyStartupVisibility(hasGeometry: true, defaults: defaults)
            check(restored.mode == mode && !restored.isVisible, "mode cannot unhide after restart")
            check(!restored.usesNotch(hasGeometry: false), "all modes fallback without geometry")
            check(restored.usesNotch(hasGeometry: true) == (mode != .floating), "selected form")
            check(HUDDisplayMode.load(from: defaults) == mode, "screen detection never overwrites saved mode")
        }
        preferences.isVisible = true
        preferences.save(to: defaults)
        check(HUDPresentationPreferences(defaults: defaults).isVisible, "visible intent restored")
        preferences.mode = .floating
        preferences.save(to: defaults)
        var manual = HUDPresentationPreferences(defaults: defaults)
        for hasGeometry in [true, false, true] {
            manual.applyStartupVisibility(hasGeometry: hasGeometry, defaults: defaults)
            check(manual.isVisible && !manual.usesNotch(hasGeometry: hasGeometry), "manual desktop survives restart and screen changes")
        }
        manual.mode = .automatic
        manual.save(to: defaults)
        let automatic = HUDPresentationPreferences(defaults: defaults)
        check(automatic.usesNotch(hasGeometry: true) && !automatic.usesNotch(hasGeometry: false), "choosing automatic restores screen detection")
        defaults.removeObject(forKey: HUDPresentationPreferences.visibilityKey)
        defaults.set(HUDDisplayMode.floating.rawValue, forKey: HUDDisplayMode.defaultsKey)
        var legacyManual = HUDPresentationPreferences(defaults: defaults)
        legacyManual.applyStartupVisibility(hasGeometry: true, defaults: defaults)
        check(legacyManual.mode == .floating && !legacyManual.isVisible, "saved desktop mode is preserved without a visibility key")
        defaults.removeObject(forKey: HUDDisplayMode.defaultsKey)
        defaults.set(false, forKey: HUDPresentationPreferences.visibilityKey)
        var hiddenAutomatic = HUDPresentationPreferences(defaults: defaults)
        hiddenAutomatic.applyStartupVisibility(hasGeometry: true, defaults: defaults)
        check(hiddenAutomatic.mode == .automatic && !hiddenAutomatic.isVisible, "saved hide wins even without a display mode")
        check(defaults.string(forKey: "hud.color") == "purple", "appearance preserved")
        defaults.set("future", forKey: HUDDisplayMode.defaultsKey)
        check(HUDDisplayMode.load(from: defaults) == .automatic, "unknown mode uses automatic detection")

        var sample: NotchHUDGeometry!
        for origin in [NSPoint.zero, NSPoint(x: -1512, y: 280), NSPoint(x: 1920, y: -982)] {
            for inset: CGFloat in [24, 32, 38] {
                let frame = NSRect(origin: origin, size: NSSize(width: 1512, height: 982))
                let left = NSRect(x: origin.x, y: frame.maxY - inset, width: 666, height: inset)
                let right = NSRect(x: origin.x + 846, y: frame.maxY - inset, width: 666, height: inset)
                let geometry = NotchHUDGeometry(screen: frame, topInset: inset, leftArea: left, rightArea: right)!
                for (width, height): (CGFloat, CGFloat) in [(180, 24), (260, 24), (340, 221)] {
                    let panel = geometry.frame(width: width, height: height)
                    check(panel.maxY == frame.maxY, "shell begins at screen top")
                    check(panel.midX == origin.x + 756, "stable horizontal center")
                    check(frame.contains(panel), "entire panel contained")
                    let enclosure = geometry.cameraEnclosure
                    check(!enclosure.intersects(left) && !enclosure.intersects(right), "decoration avoids menu bar wings")
                    check(geometry.contentTop <= frame.maxY - inset, "content stays below camera")
                    check(panel.height - geometry.topInset == height, "decoration does not move content down")
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
        check(NotchTaskPresentation(TaskStatusSummary(runningCount: 12)).badge == "12", "notch preserves the full task count")
        check(NotchTaskPresentation(TaskStatusSummary(runningCount: 2, recentlyCompletedCount: 1, unknownCount: 1)).badge == "2 ✓", "running and completion stay visible while legacy uncertainty remains internal")
        check(NotchTaskPresentation(TaskStatusSummary(recentlyCompletedCount: 1, unknownCount: 1)).badge == "✓", "legacy uncertainty does not hide confirmed completion")
        check(NotchTaskPresentation(TaskStatusSummary(unknownCount: 1)).badge == "0", "legacy uncertainty presents a neutral state")
        check(NotchTaskPresentation(TaskStatusSummary(completionFeedbackVisible: false, recentlyCompletedCount: 1, unknownCount: 1, legacyHealth: .unavailable(.allCandidatesUnreadable))).badge == "0", "legacy monitoring faults clear completion and remain neutral")
        // The pure geometry cases above deliberately include off-screen coordinates.
        // Native button/occlusion checks must place their panel on the runner's real
        // desktop: the fixed 1512x982 fixture can sit above a smaller CI display.
        guard let testScreen = NSScreen.main ?? NSScreen.screens.first else {
            preconditionFailure("native window checks require a desktop screen")
        }
        let testFrame = testScreen.frame
        let testInset = max(CGFloat(32), testFrame.maxY - testScreen.visibleFrame.maxY)
        let auxiliaryWidth = (testFrame.width - 180) / 2
        sample = NotchHUDGeometry(screen: testFrame, topInset: testInset,
            leftArea: NSRect(x: testFrame.minX, y: testFrame.maxY - testInset, width: auxiliaryWidth, height: testInset),
            rightArea: NSRect(x: testFrame.midX + 90, y: testFrame.maxY - testInset, width: auxiliaryWidth, height: testInset))!
        check(testFrame.contains(sample.frame(width: 340, height: 227)), "native fixture is inside the actual desktop")
        print("Native fixture: screen=\(testFrame), visibleFrame=\(testScreen.visibleFrame), anchor=\(sample.anchor)")
        fflush(stdout)
        let messages = ResetNewsViewState(enabled: true, status: .success, items: [
            ResetNewsItem(id: "visible-message", sources: [.feed], originalText: "Upcoming reset",
                facts: [.init(kind: .upcomingReset, effectiveAt: Date().addingTimeInterval(3_600))], firstSeenAt: Date()),
            ResetNewsItem(id: "offscreen-message", sources: [.feed], originalText: "Another upcoming reset",
                facts: [.init(kind: .upcomingReset, effectiveAt: Date().addingTimeInterval(7_200))], firstSeenAt: Date())
        ])
        check(NotchDetailPage.allCases.map(\.rawValue) == [0, 1, 2, 3], "Messages is the appended fourth page")
        check(NotchDetailPage.messages.title == "重置预告", "Forecast tab uses the dedicated product name")
        let forecastLayout = NotchLayout(geometry: sample)
        for count in [0, 3, 120] {
            var forecastState = messages
            forecastState.items = (0..<count).map { index in
                var item = messages.items[0]
                item.id = "forecast-\(index)"
                return item
            }
            for initialState in NotchPresentationState.allCases {
                let forecastModel = NotchPresentationModel(alwaysShowQuota: false)
                forecastModel.animationsEnabled = false
                forecastModel.configure(forecastLayout)
                forecastModel.setVisible(true)
                var quotaState = RateLimitDisplayState.initial
                quotaState.fiveHour = LimitMeter(title: "5h", shortTitle: "5h", window: RateLimitWindow(usedPercent: 28, windowDurationMins: 300, resetsAt: nil))
                forecastModel.update(quotaState, tasksEnabled: true)
                forecastModel.updateResetNews(forecastState)
                switch initialState {
                case .compact: break
                case .peek: forecastModel.hover(true)
                case .expanded: forecastModel.click(); forecastModel.selectPage(.usage)
                }
                let previousPage = forecastModel.page
                forecastModel.updateResetNews(forecastState)
                check(forecastModel.state == initialState && forecastModel.page == previousPage, "Forecast data preserves \(initialState) and its selected page")
                let nativeHost = NotchHostingView(model: forecastModel, bridge: NotchGeometryBridge())
                let nativeWindow = NSWindow(contentRect: NSRect(x: testFrame.minX, y: testFrame.minY + 80, width: forecastLayout.windowFrame.width,
                    height: forecastLayout.windowFrame.height), styleMask: .borderless, backing: .buffered, defer: false)
                nativeWindow.isReleasedWhenClosed = false
                nativeWindow.contentView = nativeHost
                nativeWindow.orderFrontRegardless()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                var quotaRefreshes = 0, forecastChecks = 0
                forecastModel.onRefresh = { quotaRefreshes += 1 }
                forecastModel.onCheckMessages = { forecastChecks += 1 }
                if let entry = accessibilityElement(in: nativeHost, identifier: "notch.resetForecast") {
                    check(entry.accessibilityLabel() == ResetForecastIndicator.accessibilityLabel(count), "Shoulder announces forecasts to review rather than account reset credits")
                    check(entry.accessibilityFrame().width <= 38.5, "Forecast entry stays inside the unchanged 38 point shoulder")
                    check(entry.accessibilityPerformPress(), "Native forecast shoulder supports press from \(initialState)")
                } else {
                    if count == 0 && initialState == .compact {
                        print("SwiftUI AX tree unavailable; exercising fixture-window local mouse events instead.")
                        fflush(stdout)
                    }
                    pressShoulder(in: nativeWindow, host: nativeHost, layout: forecastLayout)
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                check(forecastModel.state == .expanded && forecastModel.page == .messages, "Native shoulder press opens forecasts directly from \(initialState)")
                check(forecastModel.content.state.fiveHour?.remainingPercent == 72 && quotaRefreshes == 0 && forecastChecks == 0,
                    "Opening forecasts neither changes account quota nor requests a refresh")
                check(forecastModel.layout == forecastLayout && forecastModel.size == forecastLayout.expandedSize, "Forecast entry preserves existing geometry")
                forecastModel.selectPage(.quota)
                forecastModel.updateResetNews(forecastState)
                check(forecastModel.page == .quota, "Later forecast updates cannot steal the quota page")
                forecastModel.setVisible(false)
                forecastModel.openResetForecasts()
                check(forecastModel.state == .compact && forecastModel.page == .quota, "A hidden forecast entry cannot expand or switch pages")
                nativeWindow.orderOut(nil)
            }
        }
        let newsModel = NotchPresentationModel(alwaysShowQuota: false)
        newsModel.animationsEnabled = false
        newsModel.configure(NotchLayout(geometry: sample))
        newsModel.setVisible(true)
        newsModel.updateResetNews(messages)
        var allReviewed = messages
        allReviewed.readIDs = Set(messages.items.map(\.id))
        newsModel.updateResetNews(allReviewed)
        check(newsModel.resetNews.unreadCount == 0 && newsModel.resetNews.forecastCount == messages.items.count,
            "Reviewing every forecast never reduces the notch total")
        newsModel.updateResetNews(messages)
        check(newsModel.state == .compact && newsModel.page == .quota, "Incoming messages do not expand or change the current page")
        newsModel.click()
        newsModel.selectPage(.usage)
        newsModel.updateResetNews(messages)
        check(newsModel.state == .expanded && newsModel.page == .usage, "Incoming messages do not steal an expanded usage page")
        var readMessages: [String] = []
        newsModel.onVisibleMessage = { readMessages.append($0) }
        newsModel.resetNewsPageVisibilityChanged(true)
        newsModel.resetNewsCardVisible("visible-message")
        check(readMessages.isEmpty, "A mounted hidden messages page cannot mark a card read")
        newsModel.selectPage(.messages)
        newsModel.resetNewsPageVisibilityChanged(true)
        let visibleIDs = ResetNewsCardVisibility.visibleIDs(frames: [
            "visible-message": CGRect(x: 0, y: 20, width: 300, height: 100),
            "offscreen-message": CGRect(x: 0, y: 400, width: 300, height: 100)
        ], viewport: CGSize(width: 320, height: 220), pageVisible: newsModel.messagesVisible, state: messages)
        visibleIDs.forEach(newsModel.resetNewsCardVisible)
        check(readMessages == ["visible-message"], "Only the card intersecting the visible message viewport is read")
        newsModel.resetNewsCardVisible("unknown-message")
        check(readMessages.count == 1, "Unknown notification IDs cannot be marked read")
        newsModel.collapse()
        newsModel.resetNewsCardVisible("offscreen-message")
        check(readMessages.count == 1, "A stale row callback after collapse cannot mark a card read")
        newsModel.updateResetNews(messages)
        check(newsModel.state == .compact && newsModel.page == .messages, "Message refresh preserves collapsed state and the last selected page")
        check(ResetNewsCardVisibility.visibleIDs(frames: ["visible-message": CGRect(x: 0, y: 0, width: 100, height: 100)],
            viewport: CGSize(width: 320, height: 220), pageVisible: false, state: messages).isEmpty,
            "Hidden popovers and pages report no visible cards")
        let popoverModel = ResetNewsPopoverModel()
        popoverModel.state = messages
        popoverModel.onVisibleItem = { readMessages.append($0) }
        popoverModel.pageVisibilityChanged(true)
        popoverModel.cardVisible("offscreen-message")
        check(readMessages.count == 1, "Opening or mounting a hidden popover does not read history")
        popoverModel.isVisible = true
        popoverModel.cardVisible("offscreen-message")
        check(readMessages == ["visible-message", "offscreen-message"], "A visible popover reports an individual local card ID")
        popoverModel.isVisible = false
        popoverModel.cardVisible("visible-message")
        check(readMessages.count == 2, "Closing a popover rejects delayed visibility callbacks")
        var revisionState = messages
        revisionState.readIDs = Set(messages.items.map(\.id))
        let unchangedFrames = ["visible-message": CGRect(x: 0, y: 20, width: 300, height: 100),
            "offscreen-message": CGRect(x: 0, y: 400, width: 300, height: 100)]
        var revisionReads: [String] = []
        newsModel.onVisibleMessage = { revisionReads.append($0) }
        newsModel.click()
        newsModel.resetNewsPageVisibilityChanged(true)
        newsModel.updateResetNews(revisionState)
        revisionState.items[0].materialRevision += 1
        revisionState.items[1].materialRevision += 1
        revisionState.readIDs.removeAll()
        newsModel.updateResetNews(revisionState)
        ResetNewsCardVisibility.visibleIDs(frames: unchangedFrames, viewport: CGSize(width: 320, height: 220),
            pageVisible: newsModel.messagesVisible, state: revisionState).forEach(newsModel.resetNewsCardVisible)
        check(revisionReads == ["visible-message"], "An unchanged viewport reports only the visible revised card")
        revisionState.readIDs.insert("visible-message")
        newsModel.updateResetNews(revisionState)
        newsModel.resetNewsCardVisible("visible-message")
        check(revisionReads.count == 1, "Acknowledged revision no longer repeats its visible-card callback")
        newsModel.collapse()
        revisionState.items[0].materialRevision += 1
        revisionState.readIDs.remove("visible-message")
        newsModel.updateResetNews(revisionState)
        newsModel.resetNewsCardVisible("visible-message")
        check(revisionReads.count == 1, "A new revision cannot mark itself read after the page is hidden")
        let controller = LegacyNotchHUDController()
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
                check(controller.isExpanded && controller.isPresented, "click expands (language=\(language.rawValue), variant=\(index), frame=\(panel.frame), visible=\(controller.isVisible), occlusion=\(panel.occlusionState.rawValue))")
                check(panel.frame.maxY == top && panel.frame.midX == center, "expanded anchor stable")
                check(!controller.view.surfacePath().contains(NSPoint(x: 0.1, y: controller.view.bounds.height - 0.1)), "transparent bottom corner")
                check(controller.view.surfacePath().contains(NSPoint(x: controller.view.bounds.midX, y: 1)), "solid camera attachment")
                check(!controller.view.surfacePath().contains(NSPoint(x: 0.1, y: 0.1)), "shoulder outside path")
                for view in descendants(controller.view) where view is NSTextField || view is NSButton {
                    let rect = view.convert(view.bounds, to: controller.view)
                    check(controller.view.bounds.insetBy(dx: -1, dy: -1).contains(rect), "controls inside panel")
                    check(rect.minY >= sample.topInset, "content and controls avoid camera")
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
                    check(controller.panel.frame.height - sample.topInset == 24, "summary is 24 pt")
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
        let expectedTaskTitle = NotchTaskPresentation(full.taskStatus).title
        let titleField = descendants(controller.view).compactMap { $0 as? NSTextField }.first { $0.stringValue == expectedTaskTitle }!
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
        check(controller.panel.frame.height - narrow.topInset > 24, "extreme counts gain natural summary height")
        check(controller.view.summaryText.contains(String(Int.max)), "extreme count never shortened")
        try snapshot(controller.view, "notch-v2-extreme")
        controller.toggleExpanded()
        // Force long task text to exercise native overflow without relying on removed diagnostics.
        let extremeTitle = NotchTaskPresentation(extreme.taskStatus).title
        let noteField = controller.view.detailContent.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == extremeTitle }!
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
            check(panel.frame.height > sample.topInset + 24 && panel.frame.height < sample.topInset + controller.view.preferredHeight, "intermediate geometry is between endpoints")
        }
        print("Intermediate anchor: top=\(panel.frame.maxY), expected=\(sample.anchor.y), center=\(panel.frame.midX), expected=\(sample.anchor.x)")
        fflush(stdout)
        check(abs(panel.frame.maxY - sample.anchor.y) < 0.001 && abs(panel.frame.midX - sample.anchor.x) < 0.001, "intermediate frame keeps anchor")
        let local = NSPoint(x: 0.1, y: 0.1)
        let screenPoint = panel.convertPoint(toScreen: controller.view.convert(local, to: nil))
        check(controller.contains(screenPoint) == controller.view.containsInteraction(local), "intermediate routing matches interaction region")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check(!controller.isAnimating && controller.isExpanded, "transition completes expanded without standing timer")
        controller.collapse()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let reversingFrame = panel.frame
        let reversingContour = controller.view.expansionProgress
        controller.toggleExpanded()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check(panel.frame == reversingFrame && controller.view.expansionProgress == reversingContour, "reversing starts from the current window and contour, without a jump")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check(controller.view.expansionProgress == 1 && !controller.isAnimating, "reversed contour settles expanded")
        button("刷新").performClick(nil)
        check(refreshed == 2, "refresh in expanded nonactivating panel")
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID, "show and expand preserve frontmost PID")
        controller.environmentChanged()
        check(!controller.isExpanded, "Space or app change collapses")
        controller.hide()
        controller.environmentChanged()
        check(!controller.isPresented && !controller.isVisible, "environment cannot unhide user-hidden panel")
        check(panel.collectionBehavior.contains(.fullScreenPrimary) && !panel.collectionBehavior.contains(.fullScreenAuxiliary), "other-app full-screen opt-out")

        try fusionChecks(controller: controller, geometry: sample)
        try HookPresentationIntegrationChecks.run(geometry: sample)

        let prefs = PreferencesWindowController(appearance: HUDAppearance.load(), touchBarHardware: .present)
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
        print("PASS: \(checks) notch fusion and V2 checks")
    }
}

extension NotchHUDTests {
    static func fusionChecks(controller: LegacyNotchHUDController, geometry: NotchHUDGeometry) throws {
        let scene = NotchSimulationScene(frame: NSRect(x: 0, y: 0, width: 760, height: 340))
        let host = NSWindow(contentRect: scene.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        host.contentView = scene
        defer { host.orderOut(nil); controller.hide() }
        func black(_ rep: NSBitmapImageRep, _ point: NSPoint, scale: CGFloat) -> Bool {
            let color = rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))!.usingColorSpace(.deviceRGB)!
            return max(color.redComponent, color.greenComponent, color.blueComponent) < 0.04 && color.alphaComponent > 0.99
        }
        // A negative control recreates the old below-camera start. Both independent
        // camera corner witnesses MUST fail, or this test would miss the user's photo.
        let baseline = NotchSimulation.geometry()
        let witnesses = [NSPoint(x: baseline.cameraEnclosure.minX + 1, y: baseline.topInset - 1),
                         NSPoint(x: baseline.cameraEnclosure.maxX - 1.5, y: baseline.topInset - 1)]
        scene.configure(geometry: baseline, state: NotchSimulation.state(), width: 180, legacyBelowCamera: true)
        let old = scene.bitmap()
        check(witnesses.allSatisfy { !black(old, $0, scale: 2) }, "negative control detects BOTH old blue corner gaps")
        try scene.save("notch-fusion-before-synthetic")
        for scale: CGFloat in [1, 2] {
            for inset: CGFloat in [24, 32, 38] {
                let fixture = NotchSimulation.geometry(inset: inset, scale: scale)
                for background in [NotchSimulation.blue, NSColor.white, NSColor(calibratedWhite: 0.18, alpha: 1)] {
                    scene.background = background
                    for width: CGFloat in [180, 188, 240, 340] {
                        for progress in [0.0, 0.15, 0.5, 0.85, 1] {
                            scene.configure(geometry: fixture, state: NotchSimulation.state(), width: width, progress: progress)
                            let rep = scene.bitmap(scale: scale)
                            // Scan the entire camera bottom band, not just its center.
                            for x in stride(from: fixture.cameraEnclosure.minX + 1, through: fixture.cameraEnclosure.maxX - 2, by: 2) {
                                for y in stride(from: inset - 7, through: inset - 1, by: 2) {
                                    check(black(rep, NSPoint(x: x, y: y), scale: scale), "no background gap across camera bottom band")
                                }
                            }
                            for x in [fixture.cameraEnclosure.minX - 2, fixture.cameraEnclosure.maxX + 1] {
                                check(!black(rep, NSPoint(x: x, y: inset - 2), scale: scale), "menu pixels remain uncovered")
                            }
                            let hud = scene.hud
                            let neckRight = hud.cameraEnclosure!.maxX
                            if hud.bounds.width - neckRight > 0.5 {
                                check(!hud.surfacePath().contains(NSPoint(x: neckRight + 0.25, y: inset + 0.01)), "shoulder starts vertically without a horizontal ledge")
                            }
                            if progress == 1 && hud.bounds.width - neckRight >= 28 {
                                let shoulderMiddle = (neckRight + 10 + hud.bounds.width - 18) / 2
                                check(!hud.surfacePath().contains(NSPoint(x: shoulderMiddle, y: inset + 9.5)), "flat shoulder excludes pixels above its 10 pt level")
                                check(hud.surfacePath().contains(NSPoint(x: shoulderMiddle, y: inset + 10.5)), "flat shoulder includes pixels below its 10 pt level")
                                check(!hud.surfacePath().contains(NSPoint(x: hud.bounds.width - 1, y: inset + 12)), "outer shoulder corner stays transparent")
                                check(hud.surfacePath().contains(NSPoint(x: hud.bounds.width - 1, y: inset + 28)), "outer 18 pt corner joins the side")
                            }
                            let decoration = NSPoint(x: hud.bounds.midX, y: inset - 1)
                            check(hud.surfacePath().contains(decoration) && !hud.containsInteraction(decoration), "visible decoration is noninteractive")
                            check(hud.hitTest(hud.convert(decoration, to: scene)) == nil, "decoration passes view hit test")
                            check(hud.containsInteraction(NSPoint(x: hud.bounds.midX, y: inset + 12)), "summary remains clickable")
                            check(!hud.containsInteraction(NSPoint(x: 0.1, y: hud.bounds.maxY - 0.1)), "transparent corner passes through")
                        }
                    }
                }
            }
        }
        scene.background = NotchSimulation.blue
        for language in DisplayLanguage.allCases {
            DisplayLanguage.current = language
            for single in [true, false] {
                for long in [false, true] {
                    let state = NotchSimulation.state(single: single, long: long)
                    scene.configure(geometry: baseline, state: state)
                    check(scene.hud.compactWidth <= scene.hud.bounds.width, "localized long summary fits")
                    let summary = scene.hud.subviews.compactMap { $0 as? NSButton }.first!
                    let summaryY = summary.frame.minY
                    for progress in [0.0, 0.5, 1] {
                        scene.configure(geometry: baseline, state: state, progress: progress)
                        check(summary.frame.minY == summaryY, "summary text stays anchored while shoulders grow")
                        let rep = scene.bitmap()
                        let hud = scene.hud
                        var inkPixels = 0
                        // Actual glyph pixels (including the attachment), not button frame bounds.
                        for x in stride(from: hud.frame.minX + 1, to: hud.frame.maxX - 1, by: 0.5) {
                            for y in stride(from: baseline.topInset + 1, to: min(hud.bounds.height, baseline.topInset + 44), by: 0.5) {
                                let color = rep.colorAt(x: Int(x * 2), y: Int(y * 2))!.usingColorSpace(.deviceRGB)!
                                // White labels, mint quota values, and the blue active-task badge.
                                let isInk = color.redComponent > 0.35 && color.greenComponent > 0.6 || color.blueComponent > 0.9 && color.greenComponent > 0.5
                                if isInk {
                                    inkPixels += 1
                                    check(hud.surfacePath().contains(NSPoint(x: x - hud.frame.minX + 0.25, y: y + 0.25)), "summary ink remains inside shell across language, width and animation")
                                }
                            }
                        }
                        check(inkPixels > 50, "glyph containment check actually sampled summary ink")
                        try scene.save("notch-fusion-\(language.rawValue)-\(single ? "single" : "dual")-\(long ? "long" : "normal")-\(progress)")
                    }
                }
            }
        }
        // Exercise actual NSPanel routing with the same view-space points at every frame.
        controller.animationsEnabled = false
        controller.update(NotchSimulation.state())
        _ = controller.show(in: geometry)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let start = controller.panel.frame
        controller.toggleExpanded()
        let target = controller.panel.frame
        for progress in [0.0, 0.15, 0.5, 0.85, 1] {
            let frame = geometry.transitionFrame(from: start, to: target, progress: progress)
            controller.panel.setFrame(frame, display: true)
            controller.view.expansionProgress = NotchHUDGeometry.transitionFraction(progress)
            controller.view.cameraEnclosure = geometry.enclosure(in: frame)
            controller.view.layoutSubtreeIfNeeded()
            for point in [NSPoint(x: frame.width / 2, y: 1), NSPoint(x: 1, y: 1),
                          NSPoint(x: frame.width / 2, y: geometry.topInset + 12), NSPoint(x: 0.1, y: frame.height - 0.1)] {
                let screen = controller.panel.convertPoint(toScreen: controller.view.convert(point, to: nil))
                let interactive = controller.view.containsInteraction(point)
                check(controller.contains(screen) == interactive, "panel and view use identical current-frame input")
                controller.updateMouseRouting(at: screen)
                check(controller.panel.ignoresMouseEvents == (!controller.isVisible || !interactive), "window routing matches interaction including top decoration")
            }
            check(frame.maxY == geometry.screen.maxY, "animation remains attached to screen top")
        }
        // Very small side clearance must shrink both radii instead of crossing them.
        let narrowShoulder = NotchHUDView(frame: .zero)
        for width: CGFloat in [180, 181, 188, 208, 235, 340, 380] {
            narrowShoulder.frame = NSRect(x: 0, y: 0, width: width, height: 260)
            narrowShoulder.cameraEnclosure = NSRect(x: (width - 180) / 2, y: 0, width: 180, height: 32)
            narrowShoulder.expansionProgress = 1
            let path = narrowShoulder.surfacePath()
            check(narrowShoulder.bounds.contains(path.bounds), "scaled shoulder cannot extend outside panel")
            for y in stride(from: CGFloat(32.5), through: 62.5, by: 2) {
                var entered = false, exited = false
                for x in stride(from: CGFloat(0.5), to: width, by: 2) {
                    let inside = path.contains(NSPoint(x: x, y: y))
                    check(!(inside && exited), "each shoulder row has a single continuous black interval")
                    if inside { entered = true } else if entered { exited = true }
                }
            }
        }
        // Fractional auxiliary boundaries are rounded INWARD, even off-origin.
        let fractional = NotchSimulation.geometry(screen: NSRect(x: -1512.25, y: 280, width: 1512, height: 982), neck: 179.5)
        check((fractional.cameraEnclosure.minX * 2).rounded() == fractional.cameraEnclosure.minX * 2, "camera edge aligned to backing pixels")
        check(fractional.cameraEnclosure.minX >= -1512.25 + (1512 - 179.5) / 2, "rounded edge cannot cover menu")
    }
}
