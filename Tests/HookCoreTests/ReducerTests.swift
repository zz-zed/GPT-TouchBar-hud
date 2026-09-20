import Foundation
import Testing
@testable import HookCore

struct ReducerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func key(_ turn: String = "t1", session: String = "s1") -> TurnIdentity { TurnIdentity(task: TaskIdentity(session: session), turn: turn) }
    func evidence(_ kind: EvidenceKind, _ position: UInt64, turn: String = "t1", session: String = "s1", live: Bool = true, settled: Bool = false) -> TaskEvidence {
        TaskEvidence(identity: key(turn, session: session), kind: kind, position: position, date: now, live: live, settled: settled)
    }
    @Test func submittedIsNotRunningAndBlockedSubmissionAgesToUnknown() {
        var r = TaskStateReducer()
        for _ in 0..<3 { r.receive(HookEvent(kind: .submitted, session: "s1", turn: "t1"), now: now) }
        #expect(r.snapshot(now: now).confirmedRunningCount == 0)
        #expect(r.snapshot(now: now).submittedCount == 1)
        #expect(r.snapshot(now: now).compactText == "…")
        r.tick(now: now.addingTimeInterval(6))
        #expect(r.snapshot(now: now).compactText == "—")
        #expect(r.snapshot(now: now).recentlyCompletedCount == 0)
    }
    @Test func duplicateEvidenceAndSessionAggregation() {
        var r = TaskStateReducer()
        r.apply(evidence(.started, 1), now: now); r.apply(evidence(.started, 1), now: now)
        r.apply(evidence(.started, 10, turn: "t2"), now: now)
        #expect(r.snapshot(now: now).confirmedRunningCount == 1)
        r.apply(evidence(.started, 1, session: "s2"), now: now)
        #expect(r.snapshot(now: now).compactText == "2 ?")
    }
    @Test func lateOldStopAndInterruptCannotEndNewTurn() {
        var r = TaskStateReducer()
        r.apply(evidence(.started, 10, turn: "z-old"), now: now)
        r.apply(evidence(.started, 20, turn: "a-new"), now: now)
        r.receive(HookEvent(kind: .stop, session: "s1", turn: "z-old"), now: now)
        r.receive(HookEvent(kind: .interrupt, session: "s1", turn: "z-old"), now: now)
        r.apply(evidence(.aborted, 30, turn: "z-old"), now: now)
        #expect(r.snapshot(now: now).confirmedRunningCount == 1)
        #expect(r.records[key("a-new")]?.phase == .active)
    }
    @Test func terminalOnlyLateOldTurnCannotReplaceKnownRunningHead() {
        var r = TaskStateReducer()
        r.apply(evidence(.started, 100, turn: "current"), now: now)
        r.apply(evidence(.complete, 200, turn: "unseen-old", settled: true), now: now)
        #expect(r.snapshot(now: now).confirmedRunningCount == 1)
        #expect(r.snapshot(now: now).coverage.gaps.contains(.orderingConflict))
        #expect(!r.snapshot(now: now).showsCompletion)
    }
    @Test func blockedUnloggedRoundIsSupersededOnlyByDatedNewStart() {
        var r = TaskStateReducer(coverage: TaskCoverage(gaps: []))
        r.receive(HookEvent(kind: .submitted, session: "s1", turn: "blocked"), now: now)
        r.tick(now: now.addingTimeInterval(6))
        r.apply(TaskEvidence(identity: key("next"), kind: .started, position: 100, date: now.addingTimeInterval(7), live: true), now: now.addingTimeInterval(7))
        r.apply(TaskEvidence(identity: key("next"), kind: .complete, position: 101, date: now.addingTimeInterval(8), live: false, settled: true), now: now.addingTimeInterval(8))
        #expect(r.snapshot(now: now.addingTimeInterval(9)).pendingVerificationCount == 0)
        #expect(r.records[key("blocked")]?.phase == .unknown)
        #expect(r.records[key("blocked")]?.supersededBy == "next")
        #expect(r.snapshot(now: now.addingTimeInterval(9)).compactText == "✓")
        // The reverse chronology remains unresolved: an old log read after a new hint is not proof.
        var ambiguous = TaskStateReducer(coverage: TaskCoverage(gaps: []))
        ambiguous.receive(HookEvent(kind: .submitted, session: "s1", turn: "blocked"), now: now.addingTimeInterval(10))
        ambiguous.apply(TaskEvidence(identity: key("next"), kind: .started, position: 100, date: now, live: false), now: now.addingTimeInterval(11))
        ambiguous.apply(evidence(.complete, 101, turn: "next", settled: true), now: now.addingTimeInterval(11))
        #expect(ambiguous.snapshot(now: now.addingTimeInterval(11)).pendingVerificationCount == 1)
        #expect(!ambiguous.snapshot(now: now.addingTimeInterval(11)).showsCompletion)
    }
    @Test func oldUnknownDoesNotMaskNewCompletedTurn() {
        var r = TaskStateReducer(coverage: TaskCoverage(gaps: []))
        r.apply(evidence(.started, 1), now: now)
        r.invalidate(.restart, now: now)
        r.apply(evidence(.started, 10, turn: "t2"), now: now)
        r.apply(evidence(.complete, 20, turn: "t2", settled: true), now: now)
        #expect(r.snapshot(now: now).pendingVerificationCount == 0)
        #expect(r.snapshot(now: now).recentlyCompletedCount == 1)
        #expect(r.snapshot(now: now).compactText == "—") // Coverage is still incomplete.
    }
    @Test func stopRetainsCountBrieflyAndCannotCompleteByTime() {
        var r = TaskStateReducer()
        r.apply(evidence(.started, 1), now: now)
        r.receive(HookEvent(kind: .stop, session: "s1", turn: "t1"), now: now)
        #expect(r.snapshot(now: now).confirmedRunningCount == 1)
        #expect(r.snapshot(now: now).pendingVerificationCount == 1)
        r.tick(now: now.addingTimeInterval(6))
        #expect(r.snapshot(now: now).confirmedRunningCount == 0)
        #expect(r.records[key()]?.phase == .unknown)
        #expect(r.snapshot(now: now).recentlyCompletedCount == 0)
    }
    @Test func completionNeedsStableReconciliationAndCanReactivate() {
        var r = TaskStateReducer(coverage: TaskCoverage(gaps: []))
        r.apply(evidence(.started, 1), now: now)
        r.apply(evidence(.complete, 2), now: now)
        #expect(r.snapshot(now: now).compactText == "1 ?")
        r.apply(evidence(.complete, 2, settled: true), now: now)
        #expect(r.snapshot(now: now).compactText == "✓")
        let completion = r.snapshot(now: now).recentCompletions
        r.receive(HookEvent(kind: .stop, session: "s1", turn: "t1"), now: now)
        #expect(r.snapshot(now: now).recentCompletions == completion)
        r.receive(HookEvent(kind: .submitted, session: "s1", turn: "t1", continued: true), now: now)
        #expect(r.snapshot(now: now).confirmedRunningCount == 0)
        r.apply(evidence(.started, 3), now: now)
        r.apply(evidence(.complete, 2, settled: true), now: now) // Late earlier evidence.
        #expect(r.snapshot(now: now).compactText == "1")
        #expect(r.snapshot(now: now).recentlyCompletedCount == 0)
    }
    @Test(arguments: [CoverageGap.restart, .sleep, .disconnected, .staleEvidence])
    func lossNeverInventsSuccess(_ gap: CoverageGap) {
        var r = TaskStateReducer(); r.apply(evidence(.started, 1), now: now)
        r.invalidate(gap, now: now)
        #expect(r.snapshot(now: now).compactText == "—")
        #expect(r.snapshot(now: now).recentlyCompletedCount == 0)
    }
    @Test func interruptAndSessionEndAreNotSuccessfulCompletion() {
        var r = TaskStateReducer(); r.apply(evidence(.started, 1), now: now)
        r.receive(HookEvent(kind: .interrupt, session: "s1", turn: "t1"), now: now)
        r.apply(evidence(.aborted, 2), now: now)
        #expect(r.records[key()]?.phase == .interrupted)
        r.receive(HookEvent(kind: .sessionEnd, session: "s1", turn: nil), now: now)
        #expect(r.records[key()]?.phase == .interrupted)
        #expect(r.snapshot(now: now).recentlyCompletedCount == 0)
    }
    @Test func recoveryAndSilenceCannotProveRunning() {
        var r = TaskStateReducer(); r.apply(evidence(.started, 1, live: false), now: now)
        #expect(r.snapshot(now: now).confirmedRunningCount == 0)
        r.apply(evidence(.started, 2), now: now)
        r.tick(now: now.addingTimeInterval(HookBudget.staleSeconds + 1))
        #expect(r.snapshot(now: now).confirmedRunningCount == 0)
        #expect(r.snapshot(now: now).recentlyCompletedCount == 0)
        var restarted = TaskStateReducer(); restarted.restore(Array(r.records.values), now: now)
        #expect(restarted.snapshot(now: now).compactText == "—")
    }
    @Test func subagentExcludedAndCapacityPublic() {
        var r = TaskStateReducer(); r.apply(evidence(.started, 1), now: now)
        r.exclude(key().task)
        #expect(r.snapshot(now: now).confirmedRunningCount == 0)
        for i in 0..<600 { r.receive(HookEvent(kind: .submitted, session: "s\(i + 2)", turn: "t"), now: now.addingTimeInterval(Double(i))) }
        #expect(r.records.count == 512)
        for _ in 0..<200 { r.gap(.capacity, now: now) }
        #expect(r.diagnostics.count == 128)
        #expect(r.snapshot(now: now).coverage.gaps.contains(.capacity))
    }
    @Test func healthDoesNotMakeCoverageCompleteAndCompletionCannotMaskUncertainty() {
        var r = TaskStateReducer(); r.receive(HookEvent(kind: .stop, session: "s1", turn: "t1"), now: now)
        r.apply(evidence(.complete, 1, settled: true), now: now)
        #expect(r.snapshot(now: now).sourceHealth.first?.state == .connected)
        #expect(!r.snapshot(now: now).coverage.isComplete)
        #expect(!r.snapshot(now: now).showsCompletion)
        #expect(r.snapshot(now: now).compactText == "—")
        #expect(TaskActivitySnapshot(coverage: TaskCoverage(gaps: [])).compactText == "0")
    }
}
