import Foundation
import Testing
import SQLite3
@testable import HookCore

private final class ObservationRecorder: TaskObservationSink {
    private let lock = NSLock()
    private var storage: [TaskObservation] = []
    func record(_ event: TaskObservation) { lock.lock(); storage.append(event); lock.unlock() }
    var events: [TaskObservation] { lock.lock(); defer { lock.unlock() }; return storage }
}

struct ReliabilityEngineTests {
    @Test func publishedPendingTransitionsKeepTheirActualCause() throws {
        let f = try Fixture(), log = try f.log(), sink = ObservationRecorder()
        let monitor = engine(f, sink: sink)
        monitor.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: log)
        #expect(settle(monitor, now: f.now).runningIDs.count == 1)
        try f.appendData(Data("{broken}\n".utf8), to: log)
        #expect(settle(monitor, now: f.now.addingTimeInterval(1)).runningIDs.isEmpty)
        #expect(sink.events.contains {
            if case .transition(_, _, _, _, .active, .unknown, .malformedRecord) = $0 { return true }
            return false
        })

        let old = try Fixture(), oldLog = try old.log(), oldSink = ObservationRecorder()
        let stale = engine(old, sink: oldSink)
        stale.begin(now: old.now.addingTimeInterval(-HookBudget.staleSeconds - 2), generation: 1)
        try old.append("task_started", to: oldLog, date: old.now.addingTimeInterval(-HookBudget.staleSeconds - 1))
        #expect(settle(stale, now: old.now).runningIDs.isEmpty)
        #expect(oldSink.events.contains {
            if case .transition(_, _, _, _, _, .unknown, .staleEvidence) = $0 { return true }
            return false
        })
    }

    private func engine(_ fixture: Fixture, checkpoint: URL? = nil, sink: TaskObservationSink? = nil, bytes: Int = 256 * 1024) -> TaskActivityEngine {
        TaskActivityEngine(home: fixture.home, checkpointURL: checkpoint, sink: sink,
            budget: TaskEngineBudget(perFileBytes: bytes, totalBytes: bytes * 8, filesPerPoll: 32, secondsPerPoll: 5))
    }
    private func settle(_ engine: TaskActivityEngine, now: Date, generation: UInt64 = 1, limit: Int = 100) -> TaskEngineSnapshot {
        var value = engine.poll(now: now, generation: generation)
        for _ in 0..<limit where value.hasBacklog { value = engine.poll(now: now, generation: generation) }
        return value
    }

    @Test(arguments: [1, 3, 8, 33, 65])
    func completeIdentityInventory(count: Int) throws {
        let f = try Fixture(), monitor = engine(f)
        monitor.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        let expected = Set((0..<count).map { TaskIdentity(session: String(format: "task-%03d", $0)) })
        for identity in expected { _ = try f.log(identity.session, records: [("task_started", "turn-1")]) }
        _ = try f.log("child", source: "{\"subagent\":{}}", records: [("task_started", "turn-1")])
        let result = settle(monitor, now: f.now)
        #expect(result.runningIDs == expected)
        #expect(result.activity.confirmedRunningCount == expected.count)
        #expect(result.inventoryComplete)
        #expect(result.capability == .continuousLogsOnly)
        #expect(!result.activity.coverage.isComplete)
        // Old active entries survive arbitrarily newer index candidates.
        for i in 0..<65 { _ = try f.log("new-\(i)") }
        let after = settle(monitor, now: f.now.addingTimeInterval(31))
        #expect(after.runningIDs == expected)
    }

    @Test(arguments: [262143, 262145, 489000, 601826, 2097152, 16777216])
    func largeOutputPreservesConfirmedIdentity(bytes: Int) throws {
        let f = try Fixture(), log = try f.log(), monitor = engine(f, bytes: 64 * 1024)
        monitor.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        _ = settle(monitor, now: f.now)
        try f.append("task_started", to: log)
        #expect(settle(monitor, now: f.now).runningIDs == [TaskIdentity(session: "s1")])
        let output = Data(("{\"type\":\"response_item\",\"payload\":{\"output\":\"" + String(repeating: "x", count: bytes) + "\"}}\n").utf8)
        try f.appendData(output, to: log)
        var result = monitor.poll(now: f.now, generation: 1)
        #expect(result.runningIDs == [TaskIdentity(session: "s1")])
        for _ in 0..<400 where result.hasBacklog {
            result = monitor.poll(now: f.now, generation: 1)
            #expect(result.runningIDs == [TaskIdentity(session: "s1")])
        }
        #expect(!result.hasBacklog)
        try f.append("task_complete", to: log)
        let final = settle(monitor, now: f.now)
        #expect(final.runningIDs.isEmpty)
        #expect(final.recentCompletions.count == 1)
        try f.append("item_completed", to: log)
        #expect(settle(monitor, now: f.now).runningIDs.isEmpty)
    }

    @Test func fixedTargetBatchPublishesFinalStateAtomically() throws {
        let f = try Fixture(), log = try f.log(), monitor = engine(f, bytes: 128)
        monitor.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        _ = settle(monitor, now: f.now)
        try f.append("task_started", to: log)
        try f.appendData(Data(("{\"type\":\"response_item\",\"payload\":\"" + String(repeating: "x", count: 8192) + "\"}\n").utf8), to: log)
        try f.append("task_complete", to: log)
        var result = monitor.poll(now: f.now, generation: 1)
        #expect(result.hasBacklog)
        #expect(result.runningIDs.isEmpty)
        for _ in 0..<100 where result.hasBacklog {
            result = monitor.poll(now: f.now, generation: 1)
            #expect(result.runningIDs.isEmpty)
        }
        #expect(!result.hasBacklog)
        #expect(result.records[TaskIdentity(session: "s1")]?.phase == .completed)
    }

    @Test func restartRestoresPendingAndRequiresNewLiveStart() throws {
        let f = try Fixture(), log = try f.log()
        let checkpoint = f.home.appendingPathComponent("hud-state/checkpoint.json")
        let first = engine(f, checkpoint: checkpoint)
        first.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: log)
        #expect(settle(first, now: f.now).runningIDs.count == 1)
        let second = engine(f, checkpoint: checkpoint)
        second.begin(now: f.now.addingTimeInterval(2), generation: 2)
        var result = settle(second, now: f.now.addingTimeInterval(2), generation: 2)
        #expect(result.runningIDs.isEmpty)
        #expect(result.records[TaskIdentity(session: "s1")]?.lastKnownPhase == .active)
        try f.append("token_count", to: log, date: f.now.addingTimeInterval(3))
        result = settle(second, now: f.now.addingTimeInterval(3), generation: 2)
        #expect(result.runningIDs.isEmpty)
        try f.append("task_complete", to: log, date: f.now.addingTimeInterval(4))
        #expect(settle(second, now: f.now.addingTimeInterval(4), generation: 2).recentCompletions.isEmpty)
        try f.append("task_started", turn: "t2", to: log, date: f.now.addingTimeInterval(5))
        #expect(settle(second, now: f.now.addingTimeInterval(5), generation: 2).runningIDs.count == 1)
        try f.append("task_complete", turn: "t1", to: log, date: f.now.addingTimeInterval(6))
        #expect(settle(second, now: f.now.addingTimeInterval(6), generation: 2).runningIDs.count == 1)
    }

    @Test func silentTaskAndBudgetNeverActAsTerminal() throws {
        let f = try Fixture(), log = try f.log(), monitor = engine(f)
        monitor.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: log)
        #expect(settle(monitor, now: f.now).runningIDs.count == 1)
        #expect(settle(monitor, now: f.now.addingTimeInterval(7200)).runningIDs.isEmpty)
        #expect(settle(monitor, now: f.now.addingTimeInterval(7200)).activity.pendingVerificationCount == 1)
        monitor.reconcile(now: f.now.addingTimeInterval(7201), generation: 2, reason: .hostUnavailable)
        let paused = monitor.poll(now: f.now.addingTimeInterval(7201), generation: 2)
        #expect(paused.runningIDs.isEmpty)
        #expect(paused.records[TaskIdentity(session: "s1")]?.lastKnownPhase == .active)
        #expect(paused.bytesRead == 0 && paused.filesRead == 0)
        try f.append("token_count", to: log, date: f.now.addingTimeInterval(7202))
        monitor.reconcile(now: f.now.addingTimeInterval(7203), generation: 3, reason: .resume)
        #expect(settle(monitor, now: f.now.addingTimeInterval(7203), generation: 3).runningIDs.isEmpty)
    }

    @Test func corruptionRebuildAndInterruptedAtomicSave() throws {
        let f = try Fixture(), log = try f.log()
        let checkpoint = f.home.appendingPathComponent("hud-state/checkpoint.json")
        let first = engine(f, checkpoint: checkpoint)
        first.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: log)
        _ = settle(first, now: f.now)
        let original = try Data(contentsOf: checkpoint)
        // A crashed writer's unfinished temp cannot replace the old transaction.
        try Data("partial".utf8).write(to: checkpoint.deletingLastPathComponent().appendingPathComponent(".hook-interrupted.tmp"))
        #expect(try Data(contentsOf: checkpoint) == original)
        try HookPaths.atomicWrite(Data("not-json".utf8), to: checkpoint)
        let rebuilt = engine(f, checkpoint: checkpoint)
        rebuilt.begin(now: f.now.addingTimeInterval(2), generation: 2)
        let result = settle(rebuilt, now: f.now.addingTimeInterval(2), generation: 2)
        #expect(result.runningIDs.isEmpty)
        #expect(result.records[TaskIdentity(session: "s1")]?.lastKnownPhase == .active)
    }

    @Test func productionObservationsJoinReadTransitionAndSnapshot() throws {
        let f = try Fixture(), sink = ObservationRecorder(), monitor = engine(f, sink: sink)
        let log = try f.log()
        monitor.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: log)
        let result = settle(monitor, now: f.now)
        var readAlias: UInt64?, transitionAlias: UInt64?, members: [UInt64] = []
        for event in sink.events {
            switch event {
            case let .read(sequence, generation, _, boundary):
                if sequence == result.sequence && generation == 1 { readAlias = boundary.alias; #expect(boundary.committed > 0) }
            case let .transition(sequence, _, alias, _, _, after, reason):
                if sequence == result.sequence && after == .active { transitionAlias = alias; #expect(reason == .liveStart) }
            case let .members(sequence, _, _, aliases, _, _, _): if sequence == result.sequence { members += aliases }
            default: break
            }
        }
        #expect(readAlias != nil && readAlias == transitionAlias)
        #expect(members == readAlias.map { [$0] })
        #expect(result.activity.snapshotSequence == result.sequence)
    }

    @Test func mutableIndexOrderingCannotHidePage33() throws {
        let f = try Fixture(), inventory = TaskInventory(home: f.home)
        for i in 0..<65 { _ = try f.log(String(format: "s%03d", i)) }
        let first = inventory.discover(now: f.now)
        #expect(!first.completedTraversal)
        try f.sql("UPDATE threads SET updated_at=updated_at+10000 WHERE id>='s032'")
        _ = inventory.discover(now: f.now)
        let last = inventory.discover(now: f.now)
        #expect(last.completedTraversal)
        #expect(Set(inventory.entries.keys) == Set((0..<65).map { TaskIdentity(session: String(format: "s%03d", $0)) }))
    }

    @Test func retiredAndDuplicateStartsCannotReplaceCurrentTurn() throws {
        let f = try Fixture(), log = try f.log(), monitor = engine(f)
        monitor.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", turn: "a", to: log)
        try f.append("task_complete", turn: "a", to: log)
        try f.append("task_started", turn: "a", to: log) // Exact duplicate after terminal.
        let duplicate = settle(monitor, now: f.now)
        #expect(duplicate.runningIDs.isEmpty)
        #expect(duplicate.records[TaskIdentity(session: "s1")]?.phase == .completed)
        try f.append("task_started", turn: "b", to: log, date: f.now.addingTimeInterval(1))
        #expect(settle(monitor, now: f.now.addingTimeInterval(1)).runningIDs.count == 1)
        try f.append("task_started", turn: "a", to: log, date: f.now.addingTimeInterval(2))
        let late = settle(monitor, now: f.now.addingTimeInterval(2))
        #expect(late.records[TaskIdentity(session: "s1")]?.turnID == "b")
        #expect(late.runningIDs.count == 1)
        try f.append("task_complete", turn: "b", to: log, date: f.now.addingTimeInterval(3))
        _ = settle(monitor, now: f.now.addingTimeInterval(3))
        try f.append("task_started", turn: "b", to: log, date: f.now.addingTimeInterval(4))
        #expect(settle(monitor, now: f.now.addingTimeInterval(4)).runningIDs.count == 1)
    }

    @Test func currentMalformedGapHealsAfterCleanEvidence() throws {
        let f = try Fixture(), log = try f.log(), monitor = engine(f)
        monitor.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.appendData(Data("{broken}\n".utf8), to: log)
        #expect(settle(monitor, now: f.now).activity.coverage.gaps.contains(.malformedLog))
        try f.append("task_started", to: log)
        let healed = settle(monitor, now: f.now)
        #expect(healed.runningIDs.count == 1)
        #expect(!healed.activity.coverage.gaps.contains(.malformedLog))
    }

    @Test func inconsistentCheckpointCannotPoisonFutureOffsets() throws {
        let f = try Fixture(), log = try f.log()
        let url = f.home.appendingPathComponent("hud-state/checkpoint.json")
        let first = engine(f, checkpoint: url)
        first.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: log)
        _ = settle(first, now: f.now)
        let store = TaskCheckpointStore(url: url)
        var saved = try store.load()
        saved.entries[0].candidate.lastPosition = UInt64.max
        try store.save(saved)
        let resumed = engine(f, checkpoint: url)
        resumed.begin(now: f.now.addingTimeInterval(1), generation: 2)
        _ = settle(resumed, now: f.now.addingTimeInterval(1), generation: 2)
        try f.append("task_started", turn: "new", to: log, date: f.now.addingTimeInterval(2))
        #expect(settle(resumed, now: f.now.addingTimeInterval(2), generation: 2).runningIDs.count == 1)
    }

    @Test func unchangedPollDoesNotRewriteCheckpoint() throws {
        let f = try Fixture(), log = try f.log()
        let url = f.home.appendingPathComponent("hud-state/checkpoint.json")
        let monitor = engine(f, checkpoint: url)
        monitor.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: log)
        _ = settle(monitor, now: f.now)
        let before = try Data(contentsOf: url)
        _ = settle(monitor, now: f.now.addingTimeInterval(1))
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func inventoryCapacityProtectsPinnedAndAdmitsNewUsingSettledSlot() throws {
        let f = try Fixture(), inventory = TaskInventory(home: f.home, pageSize: 2, capacity: 2)
        _ = try f.log("a"); _ = try f.log("b")
        _ = inventory.discover(now: f.now)
        #expect(inventory.entries.count == 2)
        _ = try f.log("c")
        inventory.hint(TaskIdentity(session: "c"))
        let result = inventory.discover(now: f.now, evictable: [TaskIdentity(session: "b")])
        #expect(result.evicted == [TaskIdentity(session: "b")])
        #expect(Set(inventory.entries.keys) == [TaskIdentity(session: "a"), TaskIdentity(session: "c")])
    }

    @Test func terminalDedupAndRetiredTurnOrderingSurviveRestart() throws {
        let f = try Fixture(), log = try f.log()
        let url = f.home.appendingPathComponent("hud-state/checkpoint.json")
        let first = engine(f, checkpoint: url)
        first.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", turn: "old", to: log)
        try f.append("task_complete", turn: "old", to: log)
        try f.append("task_started", turn: "new", to: log, date: f.now.addingTimeInterval(1))
        _ = settle(first, now: f.now.addingTimeInterval(1))
        let resumed = engine(f, checkpoint: url)
        resumed.begin(now: f.now.addingTimeInterval(2), generation: 2)
        _ = settle(resumed, now: f.now.addingTimeInterval(2), generation: 2)
        try f.append("task_started", turn: "old", to: log, date: f.now.addingTimeInterval(3))
        let result = settle(resumed, now: f.now.addingTimeInterval(3), generation: 2)
        #expect(result.runningIDs.isEmpty)
        #expect(result.records[TaskIdentity(session: "s1")]?.turnID == "new")
        #expect(result.recentCompletions.isEmpty)
    }


    @Test func processAliasesRemainStableAcrossModeAndEngineRecreation() throws {
        let f = try Fixture(), log = try f.log(), firstSink = ObservationRecorder()
        let first = engine(f, sink: firstSink)
        first.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: log)
        _ = settle(first, now: f.now)
        let firstAlias = firstSink.events.compactMap { event -> UInt64? in
            if case let .read(_, _, _, boundary) = event { return boundary.alias }; return nil
        }.first
        first.stop(now: f.now)
        let secondSink = ObservationRecorder()
        let second = TaskActivityEngine(home: f.home, sink: secondSink, sourceMode: .hooks)
        second.begin(now: f.now.addingTimeInterval(1), generation: 2)
        _ = settle(second, now: f.now.addingTimeInterval(1), generation: 2)
        let secondAlias = secondSink.events.compactMap { event -> UInt64? in
            if case let .read(_, _, _, boundary) = event { return boundary.alias }; return nil
        }.first
        #expect(firstAlias != nil && firstAlias == secondAlias)
        let other = try Fixture()
        #expect(TaskObservationAliases.lookup(home: other.home, identity: TaskIdentity(session: "s1")).alias != firstAlias)
    }

    @Test func continuationRevokesOnlyItsOwnCompletionFeedback() throws {
        let f = try Fixture(), monitor = engine(f), a = try f.log("a"), b = try f.log("b")
        monitor.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        for log in [a, b] {
            try f.append("task_started", to: log)
            try f.append("task_complete", to: log)
        }
        #expect(settle(monitor, now: f.now).recentCompletions.count == 2)
        try f.append("task_started", turn: "next", to: a, date: f.now.addingTimeInterval(1))
        let next = settle(monitor, now: f.now.addingTimeInterval(1))
        #expect(next.recentCompletions.count == 1)
        #expect(next.recentCompletions.first?.id.contains(":b:") == true)
    }


    @Test func missingFileBecomesPendingAndVerifiedReturnRestoresContinuity() throws {
        let f = try Fixture(), log = try f.log(), monitor = engine(f)
        monitor.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: log)
        #expect(settle(monitor, now: f.now).runningIDs.count == 1)
        let held = log.appendingPathExtension("held")
        try FileManager.default.moveItem(at: log, to: held)
        let missing = monitor.poll(now: f.now.addingTimeInterval(1), generation: 1)
        #expect(missing.runningIDs.isEmpty)
        #expect(missing.activity.pendingVerificationCount == 1)
        #expect(missing.records[TaskIdentity(session: "s1")]?.lastKnownPhase == .active)
        #expect(missing.recentCompletions.isEmpty)
        try FileManager.default.moveItem(at: held, to: log)
        let returned = settle(monitor, now: f.now.addingTimeInterval(2))
        #expect(returned.runningIDs.count == 1)
        #expect(returned.readFailureCount == 0)
        try FileManager.default.moveItem(at: log, to: held)
        _ = monitor.poll(now: f.now.addingTimeInterval(3), generation: 1)
        try FileManager.default.moveItem(at: held, to: log)
        let delayed = settle(monitor, now: f.now.addingTimeInterval(7200))
        #expect(delayed.runningIDs.isEmpty)
        #expect(delayed.activity.pendingVerificationCount == 1)
    }

}
