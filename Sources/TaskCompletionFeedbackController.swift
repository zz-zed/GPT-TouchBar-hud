import Foundation
import HookCore

/// Main-thread presentation lifetime, independent of window visibility and quota refresh.
/// The tracker decides event eligibility; this controller only bounds the decoration lifetime.
final class TaskCompletionFeedbackController {
    static let duration: TimeInterval = 4
    var onExpiration: (() -> Void)?
    private let now: () -> Date
    private var tracker = HookCompletionFeedbackTracker()
    private var expiration: Timer?
    private(set) var activeCompletionIDs: Set<String> = []
    private(set) var deadline: Date?
    var isActive: Bool { !activeCompletionIDs.isEmpty && (deadline.map { now() < $0 } ?? false) }

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func receive(_ summary: TaskStatusSummary?, enabled: Bool) {
        guard enabled, let snapshot = summary?.activity else {
            reset()
            return
        }
        let instant = now()
        // Continuation/new-turn evidence can withdraw an earlier terminal fact.
        // Retain permission only for identities still supported by this authoritative snapshot.
        activeCompletionIDs.formIntersection(snapshot.recentCompletions.map(\.id))
        let events = tracker.consume(snapshot, now: instant)
        if !events.isEmpty {
            let eligible = activeCompletionIDs.union(events.map(\.id))
            activeCompletionIDs = Set(snapshot.recentCompletions
                .filter { eligible.contains($0.id) }
                .sorted { $0.occurredAt > $1.occurredAt }
                .prefix(32).map(\.id))
            expiration?.invalidate()
            deadline = instant.addingTimeInterval(Self.duration)
            armExpiration()
        } else if !isActive || (snapshot.confirmedRunningCount == 0 && snapshot.hasUncertainty) {
            clear()
        }
    }

    func reset() {
        clear()
        tracker = HookCompletionFeedbackTracker()
    }

    func applying(to source: TaskStatusSummary?) -> TaskStatusSummary? {
        guard var summary = source, summary.activity != nil else { return source }
        summary.completionFeedbackVisible = isActive
        return summary
    }

    private func armExpiration() {
        guard let deadline else { return }
        let timer = Timer(timeInterval: max(0.001, deadline.timeIntervalSince(now())), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.clear()
            self.onExpiration?()
        }
        expiration = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func clear() {
        expiration?.invalidate()
        expiration = nil
        deadline = nil
        activeCompletionIDs.removeAll()
    }
    deinit { expiration?.invalidate() }
}
