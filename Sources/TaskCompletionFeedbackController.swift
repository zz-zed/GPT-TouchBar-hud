import Foundation
import HookCore

/// Main-thread presentation lifetime, independent of window visibility and quota refresh.
/// The tracker decides event eligibility; this controller only bounds the decoration lifetime.
final class TaskCompletionFeedbackController {
    private enum Source: Equatable { case hooks, legacy }
    static let duration: TimeInterval = 4
    private static let legacySeenRetention: TimeInterval = 60 * 60
    private static let legacySeenLimit = 1_024
    var onExpiration: (() -> Void)?
    private let now: () -> Date
    private var tracker = HookCompletionFeedbackTracker()
    private var expiration: Timer?
    private var source: Source?
    private var legacyBaselineEstablished = false
    private var legacySeenAt: [String: Date] = [:]
    private(set) var activeCompletionIDs: Set<String> = []
    private(set) var deadline: Date?
    var isActive: Bool { !activeCompletionIDs.isEmpty && (deadline.map { now() < $0 } ?? false) }

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func receive(_ summary: TaskStatusSummary?, enabled: Bool) {
        guard enabled, let summary else {
            reset()
            return
        }
        if let snapshot = summary.activity {
            if source != .hooks { reset(); source = .hooks }
            receiveHook(snapshot)
        } else {
            if source != .legacy { reset(); source = .legacy }
            receiveLegacy(summary)
        }
    }

    private func receiveHook(_ snapshot: TaskActivitySnapshot) {
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

    private func receiveLegacy(_ summary: TaskStatusSummary) {
        let instant = now()
        legacySeenAt = legacySeenAt.filter { instant.timeIntervalSince($0.value) < Self.legacySeenRetention }
        let identities = summary.legacyCompletionIDs
        if !legacyBaselineEstablished {
            legacyBaselineEstablished = true
            rememberLegacy(identities, at: instant)
            clear()
            return
        }

        activeCompletionIDs.formIntersection(identities)
        let newIdentities = identities.filter { legacySeenAt[$0] == nil }
        rememberLegacy(identities, at: instant)
        guard !summary.legacyHasOverallFailure else {
            clear()
            return
        }
        if !newIdentities.isEmpty {
            activeCompletionIDs.formUnion(newIdentities)
            expiration?.invalidate()
            deadline = instant.addingTimeInterval(Self.duration)
            armExpiration()
        } else if !isActive {
            clear()
        }
    }

    private func rememberLegacy(_ identities: Set<String>, at instant: Date) {
        identities.forEach { legacySeenAt[$0] = legacySeenAt[$0] ?? instant }
        guard legacySeenAt.count > Self.legacySeenLimit else { return }
        let overflow = legacySeenAt.count - Self.legacySeenLimit
        for key in legacySeenAt.sorted(by: { $0.value < $1.value }).prefix(overflow).map(\.key) {
            legacySeenAt.removeValue(forKey: key)
        }
    }

    func reset() {
        clear()
        tracker = HookCompletionFeedbackTracker()
        source = nil
        legacyBaselineEstablished = false
        legacySeenAt.removeAll()
    }

    func applying(to source: TaskStatusSummary?) -> TaskStatusSummary? {
        guard var summary = source else { return nil }
        summary.completionFeedbackVisible = isActive && !summary.legacyHasOverallFailure
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
