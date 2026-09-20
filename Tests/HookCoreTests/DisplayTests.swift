import Foundation
import Testing
@testable import HookCore

struct DisplayTests {
    @Test func transientPermissionDoesNotEraseSourceCompletionOrUncertainty() {
        var snapshot = TaskActivitySnapshot(recentlyCompletedCount: 2, coverage: TaskCoverage(gaps: []))
        let expired = HookTaskDisplayAdapter(snapshot, showsCompletionFeedback: false)
        #expect(expired.state == .idle && expired.badge == "0")
        #expect(expired.snapshot.recentlyCompletedCount == 2)
        #expect(expired.detail.contains("最近完成 2"))
        let active = HookTaskDisplayAdapter(snapshot, showsCompletionFeedback: true)
        #expect(active.state == .completed && active.badge == "✓")
        snapshot.coverage.gaps.insert(.initialCoverageUnknown)
        #expect(HookTaskDisplayAdapter(snapshot, showsCompletionFeedback: true).state == .unknown)
        #expect(HookTaskDisplayAdapter(snapshot, showsCompletionFeedback: false).badge == "—")
        snapshot.confirmedRunningCount = 12
        #expect(HookTaskDisplayAdapter(snapshot, showsCompletionFeedback: false).badge == "12 ?")
    }

    @Test func uncertaintyNeverShowsPrimaryCompletionOrHidesRunning() {
        let snapshot = TaskActivitySnapshot(confirmedRunningCount: 2, pendingVerificationCount: 1, recentlyCompletedCount: 3)
        let display = HookTaskDisplayAdapter(snapshot)
        #expect(display.hasRunningTasks)
        #expect(display.state == .running)
        #expect(display.badge == "2 ?")
        #expect(display.detail.contains("启动前"))
        let english = HookTaskDisplayAdapter(snapshot, english: true)
        #expect(!english.detail.contains("initialCoverageUnknown"))
        #expect(english.detail.contains("startup"))
    }
    @Test func secondaryCompletionUnderPartialCoverageDoesNotReplay() {
        let now = Date(); var tracker = HookCompletionFeedbackTracker()
        var snapshot = TaskActivitySnapshot(confirmedRunningCount: 1, updatedAt: now.addingTimeInterval(-1))
        #expect(tracker.consume(snapshot, now: now).isEmpty)
        snapshot.recentCompletions = [TaskCompletion(identity: TurnIdentity(task: TaskIdentity(session: "s"), turn: "t"), occurredAt: now)]
        #expect(tracker.consume(snapshot, now: now).count == 1)
        #expect(tracker.consume(snapshot, now: now).isEmpty)
        #expect(snapshot.compactText == "1 ?")
        var reopened = HookCompletionFeedbackTracker()
        #expect(reopened.consume(snapshot, now: now).isEmpty)
    }
    @Test func moreThan128CompletionIDsDoNotReplayOrOverflow() {
        let now = Date(); var tracker = HookCompletionFeedbackTracker()
        var snapshot = TaskActivitySnapshot(confirmedRunningCount: 1, updatedAt: now.addingTimeInterval(-1))
        _ = tracker.consume(snapshot, now: now)
        snapshot.recentCompletions = (0..<512).map { TaskCompletion(identity: TurnIdentity(task: TaskIdentity(session: "s\($0)"), turn: "t"), occurredAt: now) }
        #expect(tracker.consume(snapshot, now: now).count == 512)
        #expect(tracker.consume(snapshot, now: now).isEmpty)
        snapshot.recentCompletions.append(TaskCompletion(identity: TurnIdentity(task: TaskIdentity(session: "extra"), turn: "t"), occurredAt: now))
        #expect(tracker.consume(snapshot, now: now).isEmpty)
        #expect(tracker.consume(snapshot, now: now).isEmpty)
    }
    @Test func occurrenceIdentityStableAcrossReducerRestore() {
        let now = Date(), key = TurnIdentity(task: TaskIdentity(session: "s"), turn: "t")
        let evidence = TaskEvidence(identity: key, kind: .complete, position: 10, date: now, live: false, settled: true)
        var r = TaskStateReducer(); r.apply(evidence, now: now)
        let before = r.snapshot(now: now).recentCompletions
        var after = TaskStateReducer(); after.restore(Array(r.records.values), now: now.addingTimeInterval(1))
        after.apply(evidence, now: now.addingTimeInterval(2))
        #expect(after.snapshot(now: now.addingTimeInterval(3)).recentCompletions == before)
    }
}

struct ScheduleTests {
    @Test func capacityRejectsAtomicallyAndFreedSlotCanRetry() {
        var schedule = HookVerificationSchedule(); let now = Date()
        for i in 0..<512 { #expect(schedule.reserve(TaskIdentity(session: "s\(i)"), due: now, restart: true) == .enqueue) }
        let extra = TaskIdentity(session: "extra")
        for _ in 0..<600 { #expect(schedule.reserve(extra, due: now, restart: true) == .rejected) }
        #expect(schedule.entries.count == 512)
        #expect(schedule.entries[extra] == nil)
        let first = TaskIdentity(session: "s0")
        for _ in 0..<6 { _ = schedule.nextDelay(first) }
        #expect(schedule.entries.count == 511)
        #expect(schedule.reserve(extra, due: now, restart: true) == .enqueue)
        #expect(schedule.entries.count == 512)
    }
    @Test func fileChangePreemptsLaterRetryWithoutGrowingState() {
        var schedule = HookVerificationSchedule(); let task = TaskIdentity(session: "s"), now = Date()
        #expect(schedule.reserve(task, due: now.addingTimeInterval(3), restart: true) == .enqueue)
        #expect(schedule.reserve(task, due: now.addingTimeInterval(0.1), restart: true) == .enqueue)
        #expect(schedule.reserve(task, due: now.addingTimeInterval(0.2), restart: true) == .coalesced)
        #expect(schedule.entries.count == 1)
        #expect(schedule.entries[task]?.due == now.addingTimeInterval(0.1))
    }
}
