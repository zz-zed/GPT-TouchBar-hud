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
        let item = controller.touchBar(bar, makeItemForIdentifier: bar.defaultItemIdentifiers[0]) as! NSCustomTouchBarItem
        check(labels(in: item.view).contains("剩余 77%"), "Latest data reaches a lazily created system bar")
        state.weekly = LimitMeter(title: "周限额", shortTitle: "7d", window: RateLimitWindow(
            usedPercent: 50, windowDurationMins: 10080, resetsAt: nil
        ))
        controller.update(with: state)
        check(labels(in: item.view).contains("剩余 50%"), "Quota updates do not depend on HUD visibility")

        let hud = CompactHUDViewController(
            initialAppearance: HUDAppearance(colorChoice: .black, backgroundOpacity: 0.86, contentOpacity: 1),
            onRefresh: {}, onQuit: {}, onPresentTouchBar: { controller.presentNow() }, contextMenuProvider: { NSMenu() }
        )
        hud.activateTouchBar(bringAppForward: true)
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID, "Persistent HUD activation preserves the frontmost app")

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
}
