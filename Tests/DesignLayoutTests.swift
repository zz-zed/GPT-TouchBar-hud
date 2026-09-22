import AppKit
import SwiftUI
import ResetNewsCore

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
    static func hardwareSettingsChecks(appearance: HUDAppearance, state: RateLimitDisplayState) {
        let supportedModels = ["MacBookPro13,2", "MacBookPro13,3", "MacBookPro14,2", "MacBookPro14,3",
            "MacBookPro15,1", "MacBookPro15,2", "MacBookPro15,3", "MacBookPro15,4",
            "MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,3", "MacBookPro16,4", "MacBookPro17,1", "Mac14,7"]
        for model in supportedModels {
            check(TouchBarHardware.detect(modelIdentifier: model) == .present, "Touch Bar model is recognized: \(model)")
        }
        for model in ["MacBookPro13,1", "MacBookPro14,1", "MacBookPro18,1", "Mac14,5", "MacBookAir10,1", "Macmini9,1", "iMac20,1", "MacPro7,1"] {
            check(TouchBarHardware.detect(modelIdentifier: model) == .absent, "No Touch Bar on model: \(model)")
        }
        let unknownModels: [String?] = [nil, "", " \n", "MacBookPro", "MacBookPro13", "MacBookPro13,x", "Unrecognized1,1"]
        for model in unknownModels {
            check(TouchBarHardware.detect(modelIdentifier: model) == .unknown, "Failed model detection preserves unknown")
        }
        check(TouchBarHardware.detect(modelIdentifier: " Mac14,7\n") == .present, "Whitespace does not invalidate a known model")

        let cases: [(TouchBarHardware, Bool)] = [(.present, true), (.absent, false), (.unknown, true)]
        for (hardware, expectedTouchBar) in cases {
            check(hardware.shouldShowSettings == expectedTouchBar, "Only confirmed absence hides Touch Bar settings")
            for language in DisplayLanguage.allCases {
                DisplayLanguage.current = language
                let prefs = PreferencesWindowController(appearance: appearance, touchBarHardware: hardware)
                let tabs = prefs.window!.contentView!.subviews.compactMap { $0 as? NSTabView }.first!
                let expectedIDs = ["general", "appearance"] + (expectedTouchBar ? ["touchBar"] : []) + ["experiments", "updates", "resetNews"]
                check(tabs.tabViewItems.compactMap { $0.identifier as? String } == expectedIDs, "Hardware controls only Touch Bar tab presence")
                let allControls = tabs.tabViewItems.flatMap { buttons($0.view!) }
                check(allControls.contains { $0.title == "Touch Bar 常驻" } == expectedTouchBar, "Absent hardware does not attach a persistence control")
                prefs.update(appearance: appearance, state: state, taskEnabled: true, persistentEnabled: true, persistentAvailable: false)
                prefs.showResetNewsTab()
                let forecastTab = tabs.selectedTabViewItem!
                check(forecastTab.identifier as? String == "resetNews", "Forecast jump uses stable identity for every hardware state")
                check(forecastTab.label == DisplayLanguage.text("重置预告", "Reset forecasts"), "Forecast tab starts in the selected language")
                prefs.updateResetNews(ResetNewsViewState(enabled: true, status: .success), soundEnabled: true)
                let controls = buttons(forecastTab.view!)
                let enabled = controls.first { $0.accessibilityIdentifier() == "settings.resetNewsEnabled" }!
                let sound = controls.first { $0.accessibilityIdentifier() == "settings.resetNewsSound" }!
                let manualCheck = controls.first { $0.accessibilityIdentifier() == "settings.checkResetNews" }!
                check(enabled.state == .on && sound.state == .on && manualCheck.isEnabled, "Forecast state updates the correct tab after optional Touch Bar removal")
                check(enabled.title == DisplayLanguage.text("启用重置预告", "Enable reset forecasts") && manualCheck.title == DisplayLanguage.text("检查预告", "Check forecasts"), "Forecast controls retain localized labels")
                tabs.selectTabViewItem(withIdentifier: "updates")
                DisplayLanguage.current = language == .chinese ? .english : .chinese
                prefs.updateResetNews(ResetNewsViewState(), soundEnabled: false)
                check(tabs.selectedTabViewItem?.identifier as? String == "updates", "Forecast language and state updates do not select another tab")
                check(tabs.selectedTabViewItem?.label == "更新", "Forecast updates never rename the neighboring update tab")
                check(forecastTab.label == DisplayLanguage.text("重置预告", "Reset forecasts") && enabled.title == DisplayLanguage.text("启用重置预告", "Enable reset forecasts"), "Forecast labels update by identity across language changes")
                check(enabled.state == .off && sound.state == .off && !manualCheck.isEnabled, "Forecast controls update while another tab is selected")
                prefs.showResetNewsTab()
                check(tabs.selectedTabViewItem === forecastTab, "Forecast jump remains stable after language and state changes")
                prefs.window?.orderOut(nil)
            }
        }
        DisplayLanguage.current = .chinese
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
        check(buttons(hud).filter { !$0.isHidden }.count == 1, "Disabled messages keep Quiet at one refresh button")
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
        var openedMessages = 0
        hud.onOpenMessages = { openedMessages += 1 }
        hud.updateMessages(forecastCount: 3, available: true)
        host.layoutSubtreeIfNeeded()
        let hudMessages = buttons(hud).first { $0.accessibilityIdentifier() == "hud.messages" }!
        check(hudMessages.title == "重置预告 3" && hudMessages.toolTip == "重置预告（3 条）", "Quiet counts forecasts upcoming, not reset credits")
        hudMessages.performClick(nil)
        check(openedMessages == 1, "Quiet message button opens local details")
        check(hud.frame.height == 40, "Messages preserve the single-line Quiet height")
        hud.updateMessages(forecastCount: 0, available: false)

        hardwareSettingsChecks(appearance: appearance, state: state)
        let prefs = PreferencesWindowController(appearance: appearance, touchBarHardware: .present)
        let originalSize = prefs.window!.frame.size
        prefs.update(appearance: appearance, state: state, taskEnabled: true, persistentEnabled: true, persistentAvailable: false)
        prefs.window?.contentView?.layoutSubtreeIfNeeded()
        check(prefs.window!.frame.size == originalSize, "Preview must not resize preferences window")
        let tabs = prefs.window!.contentView!.subviews.compactMap { $0 as? NSTabView }.first!
        check(tabs.tabViewItems.map(\.label) == ["通用", "外观", "Touch Bar", "实验", "更新", "重置预告"], "Forecast settings preserve existing tab indices")
        prefs.showResetNewsTab()
        prefs.updateResetNews(ResetNewsViewState(), soundEnabled: false)
        let resetControls = buttons(tabs.selectedTabViewItem!.view!)
        let enableMessages = resetControls.first { $0.accessibilityIdentifier() == "settings.resetNewsEnabled" }!
        let soundMessages = resetControls.first { $0.accessibilityIdentifier() == "settings.resetNewsSound" }!
        let checkMessages = resetControls.first { $0.accessibilityIdentifier() == "settings.checkResetNews" }!
        check(enableMessages.title == "启用重置预告" && soundMessages.title == "预告提示音" && checkMessages.title == "检查预告", "Chinese forecast controls use one feature name")
        check(enableMessages.state == .off && soundMessages.state == .off, "Messages and sounds default off")
        check(!checkMessages.isEnabled, "Disabled messages cannot manually check")
        var enabledValue: Bool?, soundValue: Bool?, manualChecks = 0
        prefs.onResetNewsEnabled = { enabledValue = $0 }
        prefs.onResetNewsSound = { soundValue = $0 }
        prefs.onCheckResetNews = { manualChecks += 1 }
        enableMessages.performClick(nil)
        soundMessages.performClick(nil)
        check(enabledValue == true && soundValue == true, "Message settings send explicit enable and sound callbacks")
        prefs.updateResetNews(ResetNewsViewState(enabled: true, status: .success), soundEnabled: true)
        checkMessages.performClick(nil)
        check(manualChecks == 1 && checkMessages.isEnabled, "Message manual check has its own callback")
        prefs.updateResetNews(ResetNewsViewState(enabled: true, status: .codexNotRunning), soundEnabled: false)
        check(!checkMessages.isEnabled, "Message check remains inactive without Codex")
        DisplayLanguage.current = .english
        prefs.updateResetNews(ResetNewsViewState(), soundEnabled: false)
        check(tabs.selectedTabViewItem?.identifier as? String == "resetNews" && tabs.selectedTabViewItem?.label == "Reset forecasts" && enableMessages.title == "Enable reset forecasts" && checkMessages.title == "Check forecasts", "English forecast controls use one feature name")
        DisplayLanguage.current = .chinese
        prefs.updateResetNews(ResetNewsViewState(), soundEnabled: false)
        tabs.selectTabViewItem(at: 2)
        prefs.window?.contentView?.layoutSubtreeIfNeeded()
        let persistent = buttons(prefs.window!.contentView!).first { $0.title == "Touch Bar 常驻" }
        check(persistent?.isEnabled == false, "Unavailable persistence switch disabled")
        prefs.update(
            appearance: appearance,
            state: state,
            taskEnabled: true,
            persistentEnabled: true,
            persistentAvailable: false,
            appUpdate: AppUpdateViewState(
                automaticChecksEnabled: true,
                automaticChecksAvailable: true,
                availableVersion: "v1.2.3",
                lastSuccess: Date(timeIntervalSince1970: 1_800_000_000),
                isChecking: false,
                isInstalling: false
            )
        )
        tabs.selectTabViewItem(at: 4)
        prefs.window?.contentView?.layoutSubtreeIfNeeded()
        let automaticUpdates = buttons(prefs.window!.contentView!).first {
            $0.accessibilityIdentifier() == "settings.automaticUpdates"
        }
        let checkUpdates = buttons(prefs.window!.contentView!).first {
            $0.accessibilityIdentifier() == "settings.checkForUpdates"
        }
        check(automaticUpdates?.state == .on, "Automatic updates setting reflects persisted state")
        check(checkUpdates?.title == "查看 v1.2.3…", "Available update is visible in settings")
        var viewedUpdate = false
        prefs.onViewUpdate = { viewedUpdate = true }
        checkUpdates?.performClick(nil)
        check(viewedUpdate, "Settings update reminder opens the user-triggered update flow")
        tabs.selectTabViewItem(at: 1)
        prefs.window!.appearance = NSAppearance(named: .aqua)
        prefs.window!.contentView!.wantsLayer = true
        prefs.window!.contentView!.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        prefs.showWindow(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try snapshot(prefs.window!.contentView!, name: "settings")
        prefs.window!.orderOut(nil)

        var messageState = ResetNewsViewState(enabled: true, status: .success, items: (0..<12).map { index in
            ResetNewsItem(id: "message-\(index)", sources: [.feed], originalText: "Reset announcement",
                facts: [.init(kind: .extraResetCredits, scope: "Pro", count: 2, validityText: "7 天")],
                publishedAt: Date(timeIntervalSince1970: 1_790_000_000), firstSeenAt: Date())
        })
        var visibleMessageIDs = Set<String>()
        var visibleMessageCallbacks: [String] = []
        var messagePageVisible = false
        func messageList(visible: Bool) -> ResetNewsListView {
            ResetNewsListView(state: messageState, isVisible: visible, onCheck: {}, onMarkAllRead: {}, onSettings: {},
                onPageVisibility: { messagePageVisible = $0 }, onVisibleItem: {
                    visibleMessageIDs.insert($0)
                    visibleMessageCallbacks.append($0)
                })
        }
        let messageHost = NSHostingView(rootView: messageList(visible: false))
        let messageWindow = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 420, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        messageWindow.appearance = NSAppearance(named: .aqua)
        messageHost.wantsLayer = true
        messageHost.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        messageWindow.contentView = messageHost
        messageWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        check(visibleMessageIDs.isEmpty && !messagePageVisible, "Mounted SwiftUI list does not read cards until its message surface is visible")
        messageHost.rootView = messageList(visible: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        check(messagePageVisible && !visibleMessageIDs.isEmpty, "Visible SwiftUI message cards report IDs through the shared list callback")
        check(visibleMessageIDs.count < messageState.items.count && !visibleMessageIDs.contains("message-11"), "Lazy scroll history outside the viewport stays unread")
        try snapshot(messageHost, name: "reset-messages")
        messageState.readIDs = Set(messageState.items.map(\.id))
        visibleMessageIDs.removeAll()
        visibleMessageCallbacks.removeAll()
        messageHost.rootView = messageList(visible: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        check(visibleMessageCallbacks.isEmpty, "Acknowledging visible cards does not cause a read callback loop")

        // Both edits replace one digit and keep the same card layout. The page
        // remains visible throughout; no remount or scrolling may drive this.
        messageState.items[11].facts[0].count = 3
        messageState.items[11].materialRevision += 1
        messageState.readIDs.remove("message-11")
        messageHost.rootView = messageList(visible: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        check(visibleMessageCallbacks.isEmpty, "An offscreen material revision remains unread")
        messageState.items[0].facts[0].count = 3
        messageState.items[0].materialRevision += 1
        messageState.readIDs.remove("message-0")
        messageHost.rootView = messageList(visible: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        check(visibleMessageCallbacks == ["message-0"], "A same-height revision of a continuously visible card reports its local ID again")
        messageState.readIDs.insert("message-0")
        messageHost.rootView = messageList(visible: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        check(visibleMessageCallbacks == ["message-0"], "Reading the revised card settles without repeated callbacks")
        messageHost.rootView = messageList(visible: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        visibleMessageCallbacks.removeAll()
        messageState.items[0].facts[0].count = 4
        messageState.items[0].materialRevision += 1
        messageState.readIDs.remove("message-0")
        messageHost.rootView = messageList(visible: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        check(visibleMessageCallbacks.isEmpty, "A hidden message page never reads a same-height revision")
        messageWindow.orderOut(nil)
        prefs.updateResetNews(messageState, soundEnabled: false)
        prefs.showResetNewsTab()
        prefs.showWindow(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        try snapshot(prefs.window!.contentView!, name: "settings-reset-messages")
        for control in tabs.selectedTabViewItem!.view!.subviews {
            check(tabs.selectedTabViewItem!.view!.bounds.contains(control.frame), "Message settings content fits inside its existing tab height")
        }
        prefs.window?.orderOut(nil)

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
