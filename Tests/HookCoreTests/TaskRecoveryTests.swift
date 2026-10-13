import Foundation
import Testing
@testable import HookCore

struct TaskRecoveryTests {
    private func settle(_ engine: TaskActivityEngine, now: Date, generation: UInt64 = 1) -> TaskEngineSnapshot {
        var result = engine.poll(now: now, generation: generation)
        for _ in 0..<500 where result.hasBacklog { result = engine.poll(now: now, generation: generation) }
        return result
    }

    @Test func coldStartRecoversOnlyACompleteFreshStartChain() throws {
        let f = try Fixture(), a = try f.log("started"), b = try f.log("weak-only")
        try f.append("task_started", to: a)
        try f.append("item_completed", to: b)
        let e = TaskActivityEngine(home: f.home)
        e.begin(now: f.now.addingTimeInterval(1), generation: 1)
        let s = settle(e, now: f.now.addingTimeInterval(1))
        #expect(s.runningIDs == [TaskIdentity(session: "started")])
        #expect(s.records[TaskIdentity(session: "started")]?.executionBasis == .journalRecovered)
        #expect(s.recentCompletions.isEmpty)
    }

    @Test func oldCheckpointMustRebuildStartEvidenceRatherThanTrustLastKnownPhase() throws {
        let f = try Fixture(), a = try f.log("valid"), b = try f.log("unproven")
        let cp = f.home.appendingPathComponent("state/checkpoint.json")
        let first = TaskActivityEngine(home: f.home, checkpointURL: cp)
        first.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: a)
        _ = settle(first, now: f.now)
        var old = try TaskCheckpointStore(url: cp).load()
        for i in old.entries.indices {
            old.entries[i].published.startEvidence = nil
            old.entries[i].candidate.startEvidence = nil
            if old.entries[i].inventory.identity.session == "unproven" {
                old.entries[i].published.lastKnownPhase = .active
                old.entries[i].candidate.lastKnownPhase = .active
            }
        }
        try TaskCheckpointStore(url: cp).save(old)
        try f.append("item_completed", to: b, date: f.now.addingTimeInterval(1))
        let second = TaskActivityEngine(home: f.home, checkpointURL: cp)
        second.begin(now: f.now.addingTimeInterval(2), generation: 2)
        let s = settle(second, now: f.now.addingTimeInterval(2), generation: 2)
        #expect(s.runningIDs == [TaskIdentity(session: "valid")])
        #expect(s.records[TaskIdentity(session: "valid")]?.startEvidence != nil)
        #expect(s.records[TaskIdentity(session: "unproven")]?.startEvidence == nil)
    }

    @Test func halfWrittenTerminalCannotPublishARecoveredRunningTask() throws {
        let f = try Fixture(), log = try f.log()
        try f.append("task_started", to: log)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": formatter.string(from: f.now),
            "payload": ["type": "task_complete", "turn_id": "t1"]])
        try f.appendData(line, to: log)
        let e = TaskActivityEngine(home: f.home)
        e.begin(now: f.now.addingTimeInterval(1), generation: 1)
        let pending = settle(e, now: f.now.addingTimeInterval(1))
        #expect(pending.runningIDs.isEmpty && pending.recentCompletions.isEmpty)
        #expect(!pending.hasBacklog, "Waiting for LF is not a fast-poll byte backlog")
        try f.appendData(Data([10]), to: log)
        let closed = settle(e, now: f.now.addingTimeInterval(2))
        #expect(closed.runningIDs.isEmpty && closed.recentCompletions.isEmpty)
        #expect(closed.records[TaskIdentity(session: "s1")]?.phase == .completed)
    }

    @Test(arguments: [TaskSourceMode.legacy, .hooks])
    func repeatedRestartsRecoverOnlyUnfinishedIdentitiesAndNeverReplayCompletion(mode: TaskSourceMode) throws {
        let f = try Fixture(), a = try f.log("running"), b = try f.log("completed")
        let cp = f.home.appendingPathComponent("state/checkpoint.json")
        var e = TaskActivityEngine(home: f.home, checkpointURL: cp, sourceMode: mode)
        e.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        for log in [a, b] { try f.append("task_started", to: log) }
        #expect(settle(e, now: f.now).runningIDs.count == 2)
        e.stop(now: f.now)
        try f.append("task_complete", to: b, date: f.now.addingTimeInterval(1))
        for generation in 2...21 {
            let now = f.now.addingTimeInterval(Double(generation))
            try f.append("item_completed", to: b, date: now)
            try f.append("task_started", to: b, date: now)
            e = TaskActivityEngine(home: f.home, checkpointURL: cp, sourceMode: mode)
            e.begin(now: now, generation: UInt64(generation))
            let s = settle(e, now: now, generation: UInt64(generation))
            #expect(s.runningIDs == [TaskIdentity(session: "running")])
            #expect(s.records[TaskIdentity(session: "completed")]?.phase == .completed)
            #expect(s.recentCompletions.isEmpty)
            e.stop(now: now)
        }
    }

    @Test func completedTurnRemainsClosedAfterFileRebuild() throws {
        let f = try Fixture(), log = try f.log(), cp = f.home.appendingPathComponent("state/checkpoint.json")
        let first = TaskActivityEngine(home: f.home, checkpointURL: cp)
        first.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: log); try f.append("task_complete", to: log)
        _ = settle(first, now: f.now)
        let header = try Data(contentsOf: log).split(separator: 10).first!
        try HookPaths.atomicWrite(Data(header) + Data([10]), to: log)
        try f.append("task_started", to: log, date: f.now.addingTimeInterval(1))
        let second = TaskActivityEngine(home: f.home, checkpointURL: cp)
        second.begin(now: f.now.addingTimeInterval(2), generation: 2)
        #expect(settle(second, now: f.now.addingTimeInterval(2), generation: 2).runningIDs.isEmpty)
        try f.append("task_started", turn: "new", to: log, date: f.now.addingTimeInterval(3))
        #expect(settle(second, now: f.now.addingTimeInterval(3), generation: 2).runningIDs.count == 1)
    }

    @Test func knownHostLossBlocksOldStartEvenAcrossHUDRestart() throws {
        let f = try Fixture(), log = try f.log(), cp = f.home.appendingPathComponent("state/checkpoint.json")
        let first = TaskActivityEngine(home: f.home, checkpointURL: cp)
        first.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: log)
        #expect(settle(first, now: f.now).runningIDs.count == 1)
        first.reconcile(now: f.now.addingTimeInterval(1), generation: 2, reason: .hostUnavailable)
        first.stop(now: f.now.addingTimeInterval(1))
        try f.append("item_completed", to: log, date: f.now.addingTimeInterval(2))
        let second = TaskActivityEngine(home: f.home, checkpointURL: cp)
        second.begin(now: f.now.addingTimeInterval(3), generation: 3)
        #expect(settle(second, now: f.now.addingTimeInterval(3), generation: 3).runningIDs.isEmpty)
        try f.append("task_started", turn: "after-host-restart", to: log, date: f.now.addingTimeInterval(4))
        #expect(settle(second, now: f.now.addingTimeInterval(4), generation: 3).runningIDs.count == 1)
    }

    @Test func freshActivityCanRevalidateAStaleUnfinishedTurnButCannotHealAMalformedGap() throws {
        let f = try Fixture(), log = try f.log(), e = TaskActivityEngine(home: f.home)
        e.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: log)
        #expect(settle(e, now: f.now).runningIDs.count == 1)
        let now = f.now.addingTimeInterval(HookBudget.staleSeconds + 1)
        #expect(settle(e, now: now).runningIDs.isEmpty)
        try f.append("item_completed", to: log, date: now)
        #expect(settle(e, now: now).runningIDs.count == 1)
        try f.appendData(Data("{broken}\n".utf8), to: log)
        try f.append("item_completed", to: log, date: now.addingTimeInterval(1))
        #expect(settle(e, now: now.addingTimeInterval(1)).runningIDs.isEmpty)
    }
}
