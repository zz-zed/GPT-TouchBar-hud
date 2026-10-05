import Foundation
import Testing
@testable import HookCore

struct LifecycleRegressionTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func key(_ turn: String) -> TurnIdentity { TurnIdentity(task: TaskIdentity(session: "session"), turn: turn) }
    func event(_ kind: EvidenceKind, _ position: UInt64, _ turn: String, seconds: Double = 0, live: Bool = true, settled: Bool = false) -> TaskEvidence {
        TaskEvidence(identity: key(turn), kind: kind, position: position, date: now.addingTimeInterval(seconds), live: live, settled: settled)
    }

    @Test func weakEvidenceNeverCreatesOrReopensATurn() {
        let kind = EvidenceKind.execution
        var r = TaskStateReducer()
        r.apply(event(kind, 1, "unseen"), now: now)
        #expect(r.records.isEmpty)
        r.apply(event(.started, 10, "old"), now: now)
        r.apply(event(.complete, 20, "old", settled: true), now: now)
        r.apply(event(.started, 30, "new"), now: now)
        r.apply(event(.complete, 40, "new", settled: true), now: now)
        r.apply(event(kind, 50, "old", seconds: 10), now: now.addingTimeInterval(10))
        r.apply(event(kind, 60, "unknown-old", seconds: 11), now: now.addingTimeInterval(11))
        #expect(r.snapshot(now: now.addingTimeInterval(11)).confirmedRunningCount == 0)
        #expect(r.records[key("old")]?.phase == .completed)
        #expect(r.records[key("new")]?.phase == .completed)
        #expect(r.records[key("unknown-old")] == nil)
    }

    @Test func lateToolCannotReplaceHeadOrObstructTerminalSettlement() {
        var r = TaskStateReducer()
        r.apply(event(.started, 1, "old"), now: now)
        r.apply(event(.started, 2, "current"), now: now)
        r.apply(event(.execution, 3, "old", seconds: 1), now: now.addingTimeInterval(1))
        #expect(r.snapshot(now: now).confirmedRunningCount == 1)
        #expect(r.records[key("current")]?.firstPosition == 2)
        r.apply(event(.complete, 4, "current", seconds: 2), now: now.addingTimeInterval(2))
        r.apply(event(.execution, 5, "current", seconds: 3), now: now.addingTimeInterval(3))
        #expect(r.records[key("current")]?.phase == .stopping)
        #expect(r.records[key("current")]?.lastPosition == 4)
        r.receive(HookEvent(kind: .interrupt, session: "session", turn: "current"), now: now.addingTimeInterval(3))
        r.receive(HookEvent(kind: .sessionEnd, session: "session", turn: nil), now: now.addingTimeInterval(3))
        #expect(r.records[key("current")]?.phase == .stopping)
        r.apply(event(.complete, 4, "current", seconds: 2, settled: true), now: now.addingTimeInterval(4))
        #expect(r.snapshot(now: now.addingTimeInterval(4)).confirmedRunningCount == 0)
        #expect(r.records[key("current")]?.phase == .completed)
        r.receive(HookEvent(kind: .interrupt, session: "session", turn: "current"), now: now.addingTimeInterval(5))
        #expect(r.records[key("current")]?.phase == .completed)
    }

    @Test func explicitContinuationReordersSameTurnIdentity() {
        var r = TaskStateReducer()
        r.apply(event(.started, 1, "continued"), now: now)
        r.apply(event(.started, 2, "other"), now: now)
        r.apply(event(.complete, 3, "other", settled: true), now: now)
        r.apply(event(.started, 4, "continued", seconds: 1), now: now.addingTimeInterval(1))
        #expect(r.snapshot(now: now.addingTimeInterval(1)).confirmedRunningCount == 1)
        #expect(r.records[key("continued")]?.firstPosition == 4)
    }

    @Test func stopContinuationNeedsNoInventedCompletion() {
        var r = TaskStateReducer()
        r.apply(event(.started, 1, "turn"), now: now)
        r.receive(HookEvent(kind: .stop, session: "session", turn: "turn"), now: now)
        r.apply(event(.execution, 2, "turn", seconds: 1), now: now.addingTimeInterval(1))
        #expect(r.snapshot(now: now.addingTimeInterval(1)).confirmedRunningCount == 1)
        #expect(r.records[key("turn")]?.phase == .active)
        #expect(r.snapshot(now: now).recentlyCompletedCount == 0)
    }

    @Test(arguments: [CoverageGap.restart, .sleep, .disconnected, .staleEvidence])
    func weakEvidenceCannotUndoInvalidation(_ gap: CoverageGap) {
        var r = TaskStateReducer()
        r.apply(event(.started, 1, "turn"), now: now)
        r.invalidate(gap, now: now)
        r.apply(event(.execution, 2, "turn", seconds: 1), now: now.addingTimeInterval(1))
        #expect(r.snapshot(now: now.addingTimeInterval(1)).confirmedRunningCount == 0)
        #expect(r.snapshot(now: now).recentlyCompletedCount == 0)
    }

    @Test func staleAndHistoricalEvidenceCannotReviveBeforeTimerTicks() {
        var r = TaskStateReducer()
        r.apply(event(.started, 1, "turn"), now: now)
        r.apply(event(.execution, 2, "turn", seconds: HookBudget.staleSeconds + 1), now: now.addingTimeInterval(HookBudget.staleSeconds + 1))
        r.tick(now: now.addingTimeInterval(HookBudget.staleSeconds + 1))
        #expect(r.snapshot(now: now).confirmedRunningCount == 0)
        r.apply(event(.started, 3, "recovered", live: false), now: now)
        r.apply(event(.execution, 4, "recovered", seconds: 1), now: now.addingTimeInterval(1))
        #expect(r.snapshot(now: now).confirmedRunningCount == 0)
    }

    @Test func resolverSettlesTerminalDespiteTrailingToolAndTokens() throws {
        let f = try Fixture(); let file = try f.log()
        let resolver = TaskEvidenceResolver(home: f.home)
        var r = TaskStateReducer()
        _ = resolver.recover(tasks: [], now: f.now)
        try f.append("task_started", to: file)
        try f.append("task_complete", to: file)
        try f.append("item_completed", to: file)
        try f.append("token_count", to: file)
        for e in resolver.resolve(task: TaskIdentity(session: "s1"), now: f.now, liveSince: nil).evidence { r.apply(e, now: f.now) }
        let settled = resolver.resolve(task: TaskIdentity(session: "s1"), now: f.now.addingTimeInterval(0.2), liveSince: nil)
        #expect(settled.evidence.count == 1)
        #expect(settled.evidence.first?.settled == true)
        for e in settled.evidence { r.apply(e, now: f.now.addingTimeInterval(0.2)) }
        #expect(r.snapshot(now: f.now.addingTimeInterval(0.2)).confirmedRunningCount == 0)
        #expect(r.snapshot(now: f.now.addingTimeInterval(0.2)).recentlyCompletedCount == 1)
    }
}
