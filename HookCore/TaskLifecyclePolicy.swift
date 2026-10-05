import Foundation

/// Shared lifecycle rules for log monitoring and Hook reconciliation.
/// Callers establish session/turn identity and file order before applying an event.
public enum TaskLifecyclePolicy {
    public static func kind(for event: String) -> EvidenceKind? {
        switch event {
        case "task_started": return .started
        case "task_complete": return .complete
        case "turn_aborted": return .aborted
        case "item_completed", "token_count": return .execution
        default: return nil
        }
    }

    /// Nil means the event cannot change the lifecycle or refresh its evidence clock.
    public static func nextPhase(
        for kind: EvidenceKind, current: TaskPhase, date: Date, previousDate: Date?,
        live: Bool, terminalPending: Bool = false, countedWhileStopping: Bool = false,
        settled: Bool = true
    ) -> TaskPhase? {
        guard previousDate.map({ date >= $0 }) ?? true else { return nil }
        switch kind {
        case .started:
            return live ? .active : .unknown
        case .execution:
            // A tool result may arrive hours after its turn ended. It cannot create,
            // recover or reopen a turn, nor cancel a logged terminal awaiting EOF.
            guard live, !terminalPending,
                  current == .active || (current == .stopping && countedWhileStopping),
                  let previousDate, date.timeIntervalSince(previousDate) < HookBudget.staleSeconds else { return nil }
            return .active
        case .complete:
            return settled ? .completed : .stopping
        case .aborted:
            return .interrupted
        }
    }
}
