import AppKit

private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

private final class RecordingPresenter: SystemTouchBarPresenting {
    var isAvailable = true
    var presentations: [NSTouchBar] = []
    var dismissals: [NSTouchBar] = []
    func present(_ touchBar: NSTouchBar) { presentations.append(touchBar) }
    func dismiss(_ touchBar: NSTouchBar) { dismissals.append(touchBar) }
}

@main
enum PersistentTouchBarTests {
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    private static func drainEvents() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
    }

    static func main() {
        let languageSuite = "GPTTouchBarHUD.tests." + UUID().uuidString
        DisplayLanguage.defaults = UserDefaults(suiteName: languageSuite)!
        defer { DisplayLanguage.defaults.removePersistentDomain(forName: languageSuite) }
        DisplayLanguage.current = .english
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let defaults = MemoryDefaults()
        let notifications = NotificationCenter()
        let presenter = RecordingPresenter()
        let controller = PersistentTouchBarController(
            presenter: presenter, defaults: defaults, notifications: notifications
        )
        check(controller.isEnabled, "New installs default to persistent mode")
        check(!controller.presentNow(), "No presentation before the host starts")
        controller.start()
        controller.start()
        check(presenter.presentations.count == 1, "Repeated starts do not duplicate observers or presentation")
        let bar = presenter.presentations[0]
        check(bar.defaultItemIdentifiers.last == .flexibleSpace, "Trailing flexible space left-aligns quota content")
        check(bar.principalItemIdentifier == nil, "No centered principal item")

        // Rapid app switches should restore one retained bar, without a HUD/window.
        for _ in 0..<4 { notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil) }
        drainEvents()
        check(presenter.presentations.count == 2, "App switches are coalesced")
        check(presenter.presentations.last === bar, "Background presentation retains the same bar")

        // Disabling while a restore is queued must not resurrect the bar later.
        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        controller.setEnabled(false)
        drainEvents()
        check(presenter.presentations.count == 2, "Disabling cancels queued presentation")
        check(presenter.dismissals.count == 1 && presenter.dismissals[0] === bar, "Disabling releases the system bar")
        check(!controller.presentNow(), "Disabled mode falls back to focused-window behavior")
        let reloaded = PersistentTouchBarController(
            presenter: presenter, defaults: defaults, notifications: NotificationCenter()
        )
        check(!reloaded.isEnabled, "The setting survives controller recreation")
        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        drainEvents()
        check(presenter.presentations.count == 2, "Disabled mode remains disabled after switching apps")

        controller.setEnabled(true)
        check(presenter.presentations.count == 3, "Re-enabling presents immediately")
        notifications.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        notifications.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        notifications.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        drainEvents()
        check(presenter.presentations.count == 3, "Screen wake does not override an inactive session")
        check(controller.presentNow(), "A suspended persistent request does not trigger focus fallback")
        notifications.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        drainEvents()
        check(presenter.presentations.count == 4, "Returning to the active session restores the bar")

        // The quota view has its own lifecycle: receive data before item creation,
        // then continue updating even when no HUD view is loaded.
        var state = RateLimitDisplayState.initial
        state.weekly = LimitMeter(title: "周限额", shortTitle: "7d", window: RateLimitWindow(
            usedPercent: 23, windowDurationMins: 10080, resetsAt: nil
        ))
        state.lastUpdated = Date()
        controller.update(with: state)
        var openedMessages = 0
        controller.onOpenMessages = { openedMessages += 1 }
        controller.updateMessages(forecastCount: 4, available: true)
        let item = controller.touchBar(bar, makeItemForIdentifier: bar.defaultItemIdentifiers[0]) as! NSCustomTouchBarItem
        check(labels(in: item.view).contains("77%"), "Latest data reaches a lazily created system bar")
        let messagesButton = buttons(in: item.view).first { $0.accessibilityIdentifier() == "touchbar.messages" }!
        check(messagesButton.title == "Reset forecasts 4", "Persistent Touch Bar receives cached forecast count at creation")
        check(messagesButton.image?.isTemplate == true && messagesButton.image?.size == NSSize(width: 18, height: 18),
              "Persistent Touch Bar uses the shared forecast indicator")
        messagesButton.performClick(nil)
        check(openedMessages == 1, "Persistent Touch Bar forwards the local message details callback")
        controller.updateMessages(forecastCount: 2, available: true)
        check(messagesButton.title == "Reset forecasts 2", "Persistent forecast count updates without quota refresh")
        controller.updateMessages(forecastCount: 0, available: true)
        check(messagesButton.title == "Reset forecasts 0" && !messagesButton.isHidden,
              "Available persistent entry keeps an explicit zero")
        controller.updateMessages(forecastCount: 100, available: true)
        check(messagesButton.title == "Reset forecasts 99+", "Persistent visual count compacts above 99")
        check(messagesButton.toolTip == "Reset forecasts (100 upcoming)",
              "Persistent tooltip retains the exact count above 99")
        controller.updateMessages(forecastCount: 0, available: false)
        check(messagesButton.isHidden, "Disabled messages without history hide the Touch Bar entry")
        state.weekly = LimitMeter(title: "周限额", shortTitle: "7d", window: RateLimitWindow(
            usedPercent: 50, windowDurationMins: 10080, resetsAt: nil
        ))
        controller.update(with: state)
        check(labels(in: item.view).contains("50%"), "Quota updates do not depend on HUD visibility")

        var closeRequests = 0
        let hud = CompactHUDViewController(
            initialAppearance: HUDAppearance(colorChoice: .black, backgroundOpacity: 0.86, contentOpacity: 1),
            onRefresh: {}, onClose: { closeRequests += 1 }, onPresentTouchBar: { controller.presentNow() }, contextMenuProvider: { NSMenu() }
        )
        hud.activateTouchBar(bringAppForward: true)
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID, "Persistent HUD activation preserves the frontmost app")

        let hudView = hud.view
        hud.onOpenMessages = { openedMessages += 1 }
        let refreshButton = buttons(in: hudView).first { $0.accessibilityIdentifier() == "hud.refresh" }!
        check(refreshButton.toolTip == "Refresh quotas", "HUD quota refresh remains clearly distinguished from forecasts")
        hud.updateMessages(forecastCount: 0, available: true)
        let hudMessages = buttons(in: hudView).first { $0.accessibilityIdentifier() == "hud.messages" }!
        check(hudMessages.title == "Reset forecasts 0" && !hudMessages.isHidden,
              "HUD displays the available zero-count forecast entry")
        check(hudMessages.image?.isTemplate == true && hudMessages.image?.size == NSSize(width: 18, height: 18),
              "HUD uses the shared 18-point template forecast icon")
        hud.updateMessages(forecastCount: 3, available: true)
        check(hudMessages.title == "Reset forecasts 3", "HUD names forecasts instead of showing an ambiguous count")
        check(hudMessages.toolTip == "Reset forecasts (3 upcoming)", "HUD tooltip describes forecasts upcoming")
        hudMessages.performClick(nil)
        check(openedMessages == 2, "HUD forecast entry forwards its local details callback")
        hud.updateMessages(forecastCount: 100, available: true)
        check(hudMessages.title == "Reset forecasts 99+", "HUD visual count compacts above 99")
        check(hudMessages.toolTip == "Reset forecasts (100 upcoming)", "HUD tooltip retains the exact count above 99")
        hud.updateMessages(forecastCount: 3, available: true)
        let focusedBar = hud.makeQuotaTouchBar()
        let focusedItem = hud.touchBar(focusedBar, makeItemForIdentifier: focusedBar.defaultItemIdentifiers[0]) as! NSCustomTouchBarItem
        let focusedMessages = buttons(in: focusedItem.view).first { $0.accessibilityIdentifier() == "touchbar.messages" }!
        check(focusedMessages.title == "Reset forecasts 3", "Focused and persistent Touch Bars use the same forecast label")
        focusedMessages.performClick(nil)
        check(openedMessages == 3, "Focused Touch Bar forwards its local message details callback")
        hud.updateMessages(forecastCount: 0, available: false)
        func closeButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.toolTip == "隐藏浮窗" { return button }
            return view.subviews.lazy.compactMap { closeButton(in: $0) }.first
        }
        let dismissalsBeforeClose = presenter.dismissals.count
        check(closeButton(in: hudView) == nil, "Quiet has no close button; hiding is a menu action")
        check(closeRequests == 0, "Rendering Quiet does not request hiding")
        check(presenter.dismissals.count == dismissalsBeforeClose, "HUD close does not dismiss persistent Touch Bar")
        hud.update(with: state)
        let plainWidth = hudView.frame.width
        state.taskStatus = TaskStatusSummary(runningCount: 2)
        hud.update(with: state)
        hudView.layoutSubtreeIfNeeded()
        check(labels(in: hudView).contains("Run 2"), "HUD displays task summary")
        check(hudView.frame.width > plainWidth, "Task summary adds width without squeezing metrics")
        check(!hudView.hasAmbiguousLayout, "Task HUD layout is determined")
        check(hudView.window == nil, "Task updates do not create/show a floating window")
        controller.update(with: state)
        check(labels(in: item.view).contains("2"), "Task count reaches persistent Touch Bar")
        state.taskStatus = TaskStatusSummary()
        hud.update(with: state)
        controller.update(with: state)
        check(hudView.frame.width == plainWidth, "Idle restores original HUD width")
        check(!labels(in: item.view).contains("?"), "Idle does not show unknown badge")
        state.taskStatus = nil
        hud.update(with: state)
        check(hudView.frame.width == plainWidth, "Disabling restores original HUD width")

        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        controller.stop()
        let countAfterStop = presenter.presentations.count
        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        drainEvents()
        check(presenter.presentations.count == countAfterStop, "Stopping removes observers and cancels queued restores")
        controller.stop()
        check(presenter.dismissals.count == 3, "Stopping is idempotent")

        let unavailablePresenter = RecordingPresenter()
        unavailablePresenter.isAvailable = false
        let unsupported = PersistentTouchBarController(
            presenter: unavailablePresenter, defaults: MemoryDefaults(), notifications: NotificationCenter()
        )
        unsupported.start()
        check(!unsupported.presentNow(), "Missing private API permits public API fallback")
        check(unavailablePresenter.presentations.isEmpty, "No private call on unsupported systems")
        unsupported.stop()

        let systemPresenter = SystemTouchBarPresenter()
        print("PASS: \(checks) Touch Bar lifecycle, preference, data and focus checks")
        print("System-modal API signatures available: \(systemPresenter.isAvailable)")
        if CommandLine.arguments.contains("--smoke-system") {
            check(systemPresenter.isAvailable, "System-modal APIs must exist for the smoke check")
            let smoke = PersistentTouchBarController(
                presenter: systemPresenter, defaults: MemoryDefaults(), notifications: NotificationCenter()
            )
            smoke.update(with: state)
            smoke.start()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
            smoke.stop()
            check(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID, "Real system-modal calls preserve frontmost app")
            print("PASS: real system-modal present/dismiss calls completed without changing focus; physical visibility requires a Touch Bar")
        }
    }

    private static func labels(in view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { labels(in: $0) }
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
}
