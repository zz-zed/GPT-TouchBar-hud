import AppKit
import HookCore

/// A deliberately hostile clock can deliver cancelled work to prove generation guards.
final class NotchManualClock: NotchClock {
    final class Item: NotchScheduledAction {
        let due: Double
        let action: () -> Void
        var cancelled = false
        init(due: Double, action: @escaping () -> Void) { self.due = due; self.action = action }
        func cancel() { cancelled = true }
    }
    var time: Double = 0
    var items: [Item] = []
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> NotchScheduledAction {
        let item = Item(due: time + delay, action: action)
        items.append(item)
        return item
    }
    func advance(_ interval: Double, deliverCancelled: Bool = true) {
        let end = time + interval
        while let item = items.filter({ $0.due <= end }).min(by: { $0.due < $1.due }) {
            items.removeAll { $0 === item }; time = item.due
            if deliverCancelled || !item.cancelled { item.action() }
        }
        time = end
    }
}

extension NotchHarness {
    static func modelChecks() {
        let geometry = fixture(CGRect(x: -1512, y: 240, width: 1512, height: 982))
        let layout = NotchLayout(geometry: geometry)
        let clock = NotchManualClock()
        let model = NotchPresentationModel(clock: clock)
        model.configure(layout); model.setVisible(true)
        check(model.state == .compact && !model.pillsVisible, "new preference defaults to Compact")
        model.hover(true)
        check(model.state == .peek && !model.pillsVisible, "hover starts shell before pills")
        clock.advance(0.059)
        check(!model.pillsVisible, "pills do not enter before 60ms")
        clock.advance(0.002)
        check(model.pillsVisible, "pills enter at 60ms")
        model.click()
        check(model.detailsMounted && !model.detailsVisible && model.size == layout.expandedSize, "click starts shell immediately and mounts hidden content")
        clock.advance(0.219)
        check(!model.detailsVisible && model.pillsVisible, "details wait until 220ms")
        clock.advance(0.002)
        check(model.detailsVisible && model.pillsVisible, "220ms content overlaps preview")
        clock.advance(0.031)
        check(!model.pillsVisible, "250ms preview exits")
        model.click()
        check(model.state == .expanded, "expanded blank click does not toggle")
        let generation = model.scheduler.generation
        model.update(sample, tasksEnabled: true)
        check(model.scheduler.generation == generation && model.state == .expanded, "data refresh preserves animation generation and intent")
        model.selectPage(.activity)
        check(model.size == layout.expandedSize, "pagination preserves shell size")
        model.beginMenu(); model.hover(false)
        check(model.state == .expanded, "own menu holds Expanded after pointer leaves")
        model.beginMenu(); model.endMenu()
        check(model.state == .expanded, "nested menu hold is reference counted")
        model.endMenu()
        check(model.state == .compact && model.detailsMounted && !model.detailsVisible, "exit retains fading detail layer")
        check(model.size == layout.expandedSize, "shell waits only 20ms")
        clock.advance(0.021)
        check(model.size == layout.size(for: .compact) && model.detailsMounted, "shell overlaps content fade")
        clock.advance(0.081)
        check(!model.detailsMounted, "detail unmounts after 100ms")
        // A -> B -> A -> B must reject callbacks from the first visit to B.
        model.hover(true); clock.advance(0.01); model.hover(false); model.hover(true)
        clock.advance(0.051)
        check(!model.pillsVisible, "cancelled first Peek generation cannot reveal pills in second Peek")
        clock.advance(0.011)
        check(model.pillsVisible, "current Peek callback remains valid")
        model.click(); clock.advance(0.05); model.hover(false); model.hover(true); model.click()
        clock.advance(0.171)
        check(!model.detailsVisible, "cancelled first Expanded generation cannot reveal second visit early")
        clock.advance(0.05)
        check(model.detailsVisible, "current Expanded reveals normally")
        model.setAlwaysShowQuota(true)
        check(model.state == .expanded, "always-show preference preserves current Expanded intent")
        model.hover(false); clock.advance(0.12)
        check(model.state == .peek && model.pillsVisible, "always-show resting state is Peek")
        model.setAlwaysShowQuota(false); clock.advance(0.12)
        check(model.state == .compact, "disabling always-show returns rest to Compact")
        model.hover(true); model.click(); model.reset(visible: false); clock.advance(1)
        check(!model.visible && !model.detailsMounted && model.scheduler.pendingCount == 0, "hide cancels even hostile late callbacks")
        model.setVisible(true); model.hover(true); model.click()
        model.configure(NotchLayout(geometry: fixture(CGRect(x: 2000, y: -982, width: 1024, height: 768))))
        clock.advance(1)
        check(model.state == .compact && !model.detailsMounted, "screen change cancels old expansion")
        model.setEnvironment(reduceMotion: true, reduceTransparency: true, lowPower: true)
        model.hover(true); model.click()
        check(model.detailsVisible && model.scheduler.pendingCount == 0 && !model.sweepActive, "Reduce Motion removes staged movement and perpetual sweep")
        check(model.reduceTransparency, "Reduce Transparency is delivered to renderer")
        model.setEnvironment(reduceMotion: false, reduceTransparency: false, lowPower: true)
        model.reset(visible: true)
        check(!model.sweepActive, "low-power rest has no dynamic decoration")
        model.hover(true)
        check(model.sweepActive, "low-power hover permits active decoration")
        model.setVisible(false)
        check(!model.sweepActive, "invisible state stops sweep")
        model.setVisible(true); model.hover(true); model.click(); model.setCaptured(true); model.hover(false)
        check(model.state == .expanded, "drag capture holds Expanded")
        model.setCaptured(false)
        check(model.state == .compact, "capture release outside collapses")
        weak var destroyed: NotchPresentationModel?
        do {
            let temporary = NotchPresentationModel(clock: clock)
            temporary.configure(layout); temporary.setVisible(true); temporary.click()
            destroyed = temporary
        }
        check(destroyed == nil, "pending callbacks do not retain destroyed model")
        clock.advance(1)
    }

    static func geometryChecks() {
        for width: CGFloat in [400, 640, 900, 1512, 2560] {
            for origin in [CGPoint.zero, CGPoint(x: -1600, y: -900), CGPoint(x: 2400, y: 300)] {
                for scale: CGFloat in [1, 2] {
                    let screen = CGRect(origin: origin, size: CGSize(width: width, height: 900))
                    let notch: CGFloat = 160
                    let g = NotchHUDGeometry(screen: screen, topInset: 38,
                        leftArea: CGRect(x: screen.minX, y: screen.maxY - 38, width: (width - notch) / 2, height: 38),
                        rightArea: CGRect(x: screen.midX + notch / 2, y: screen.maxY - 38, width: (width - notch) / 2, height: 38), backingScale: scale)!
                    let layout = NotchLayout(geometry: g, visibleTopDelta: 25)
                    check(screen.contains(layout.windowFrame), "bounded carrier \(width)/\(origin)/\(scale)")
                    check(layout.visualBarHeight == 24 && layout.physicalTopInset == 38, "visual height independent of hardware")
                    check(layout.windowFrame.maxY == screen.maxY && layout.windowFrame.midX == g.anchor.x, "top and center anchored")
                    let left = layout.markX(left: true), right = layout.markX(left: false)
                    check(right - left == notch + 38, "mark centers independent of state")
                    for state in NotchPresentationState.allCases {
                        let size = layout.size(for: state)
                        check(size.width <= layout.windowFrame.width && size.height <= layout.windowFrame.height, "all states fit carrier")
                    }
                }
            }
        }
        check(NotchLayout.visualHeight(physical: 38, visibleDelta: 0, calibration: 1, scale: 2) == 38, "autohide uses physical fallback")
        check(NotchLayout.visualHeight(physical: 38, visibleDelta: 90, calibration: 1, scale: 2) == 38, "stale visible frame cannot extend height")
    }

    static func contentChecks() {
        for language in DisplayLanguage.allCases {
            DisplayLanguage.current = language
            let unknown = NotchContentAdapter(.initial, tasksEnabled: true)
            check(unknown.metrics.isEmpty && unknown.task.badge == "—", "missing quotas and task count remain unknown")
            let disabled = NotchContentAdapter(sample, tasksEnabled: false)
            check(disabled.task.badge.isEmpty && disabled.taskTitle.contains(language == .chinese ? "关闭" : "off"), "monitoring off does not mean zero")
            for summary in [TaskStatusSummary(), TaskStatusSummary(runningCount: 999999), TaskStatusSummary(unknownCount: 1), TaskStatusSummary(recentlyCompletedCount: 1)] {
                var value = sample; value.taskStatus = summary
                let adapted = NotchContentAdapter(value, tasksEnabled: true)
                check(adapted.task.badge == NotchTaskPresentation(summary).badge, "task badge reuses existing semantics")
                check(adapted.metrics.map(\.value) == ["72%", "43%"], "remaining quotas preserved across task states")
            }
            var reset = sample
            reset.fiveHour = nil
            reset.resetCredits = ResetCreditSummary(response: RateLimitResetCreditsResponse(availableCount: 999999, credits: nil))
            check(NotchContentAdapter(reset, tasksEnabled: true).metrics.first?.percent == nil, "reset card fallback is not a quota percentage")
            var error = sample; error.errorMessage = "Fixture error"
            check(NotchContentAdapter(error, tasksEnabled: true).errorSummary != nil, "stale quota is visibly marked on connection error")
            var activity = sample
            activity.taskStatus = TaskStatusSummary(activity: TaskActivitySnapshot(coverage: TaskCoverage(gaps: [])), runningCount: 999)
            check(NotchContentAdapter(activity, tasksEnabled: true).task.badge == "0", "authoritative Hook zero overrides conflicting legacy count")
        }
        DisplayLanguage.current = .chinese
    }
}
