import AppKit
import SwiftUI

// Choreography adapted from Codex Island 810b8ac; see ThirdPartyNotices.txt.
enum NotchMotion {
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let close = Animation.spring(response: 0.30, dampingFraction: 0.88)
    static let content = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.28)
    static let page = Animation.timingCurve(0.25, 0.82, 0.25, 1, duration: 0.36)
}

protocol NotchScheduledAction { func cancel() }
protocol NotchClock {
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> NotchScheduledAction
}
private final class NotchTimerAction: NotchScheduledAction {
    let timer: Timer
    init(delay: TimeInterval, action: @escaping () -> Void) {
        timer = Timer(timeInterval: delay, repeats: false) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
    }
    func cancel() { timer.invalidate() }
}
struct NotchSystemClock: NotchClock {
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> NotchScheduledAction {
        NotchTimerAction(delay: delay, action: action)
    }
}

/// Every delayed action, including deferred input, belongs to a cancellable generation.
final class NotchDelayScheduler {
    private let clock: NotchClock
    private var actions: [UUID: NotchScheduledAction] = [:]
    private(set) var generation = 0
    var pendingCount: Int { actions.count }
    init(clock: NotchClock = NotchSystemClock()) { self.clock = clock }
    func cancelAll() {
        generation += 1
        actions.values.forEach { $0.cancel() }
        actions.removeAll()
    }
    func after(_ delay: TimeInterval, _ action: @escaping () -> Void) {
        let expected = generation, id = UUID()
        actions[id] = clock.schedule(after: delay) { [weak self] in
            guard let self, self.generation == expected else { return }
            self.actions[id] = nil
            action()
        }
    }
    deinit { actions.values.forEach { $0.cancel() } }
}
