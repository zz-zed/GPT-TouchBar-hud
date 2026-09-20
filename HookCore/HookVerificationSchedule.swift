import Foundation

/// Scheduling metadata shares one capacity bound; a rejected reservation leaves no ghost entry.
struct HookVerificationSchedule {
    struct Entry { var due: Date?; var attempt: Int }
    private(set) var entries: [TaskIdentity: Entry] = [:]
    enum Reservation { case enqueue, coalesced, rejected }
    mutating func reserve(_ task: TaskIdentity, due: Date, restart: Bool) -> Reservation {
        guard entries[task] != nil || entries.count < HookBudget.turns else { return .rejected }
        var entry = entries[task] ?? Entry(due: nil, attempt: 0)
        if restart { entry.attempt = 0 }
        if let earlier = entry.due, earlier <= due { entries[task] = entry; return .coalesced }
        entry.due = due; entries[task] = entry; return .enqueue
    }
    mutating func didRun(_ task: TaskIdentity) { entries[task]?.due = nil }
    mutating func nextDelay(_ task: TaskIdentity) -> TimeInterval? {
        let steps: [TimeInterval] = [0.1, 0.4, 1.5, 3.0, 0.15]
        guard var entry = entries[task], entry.attempt < steps.count else { entries.removeValue(forKey: task); return nil }
        let delay = steps[entry.attempt]; entry.attempt += 1; entries[task] = entry; return delay
    }
    mutating func clear() { entries.removeAll() }
}
