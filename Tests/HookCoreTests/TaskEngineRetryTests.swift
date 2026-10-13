import Foundation
import Testing
@testable import HookCore

private final class RetryObservations: TaskObservationSink {
    var failures = 0
    func record(_ event: TaskObservation) {
        if case .readFailure = event { failures += 1 }
    }
}

struct TaskEngineRetryTests {
    private func settle(_ engine: TaskActivityEngine, now: Date, generation: UInt64 = 1) -> TaskEngineSnapshot {
        var result = engine.poll(now: now, generation: generation)
        for _ in 0..<50 where result.hasBacklog { result = engine.poll(now: now, generation: generation) }
        return result
    }

    @Test func missingHistoryDoesNotKeepFastPollingOrRewriteCheckpoint() throws {
        let f = try Fixture(), log = try f.log(), sink = RetryObservations()
        let checkpoint = f.home.appendingPathComponent("state/checkpoint.json")
        let engine = TaskActivityEngine(home: f.home, checkpointURL: checkpoint, sink: sink)
        try FileManager.default.removeItem(at: log)
        engine.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        let missing = settle(engine, now: f.now)
        #expect(!missing.hasBacklog)
        #expect(missing.readFailureCount == 1)
        #expect(missing.activity.pendingVerificationCount == 1)
        #expect(missing.runningIDs.isEmpty)
        #expect(missing.activity.coverage.gaps.contains(.missingLog))
        let data = try Data(contentsOf: checkpoint)
        let attributes = try FileManager.default.attributesOfItem(atPath: checkpoint.path)
        let failures = sink.failures
        for i in 1...19 { _ = engine.poll(now: f.now.addingTimeInterval(Double(i) / 20), generation: 1) }
        #expect(sink.failures == failures, "Unavailable history must wait for its retry deadline")
        _ = engine.poll(now: f.now.addingTimeInterval(1), generation: 1)
        #expect(sink.failures == failures + 1)
        #expect(try Data(contentsOf: checkpoint) == data)
        #expect(try FileManager.default.attributesOfItem(atPath: checkpoint.path)[.modificationDate] as? Date == attributes[.modificationDate] as? Date)
    }

    @Test func missingHistoryRetriesWithBoundedBackoff() throws {
        let f = try Fixture(), log = try f.log(), sink = RetryObservations()
        try FileManager.default.removeItem(at: log)
        let engine = TaskActivityEngine(home: f.home, sink: sink)
        engine.begin(now: f.now, generation: 1)
        for second in [0, 1, 3, 7, 15, 31, 61] {
            _ = engine.poll(now: f.now.addingTimeInterval(Double(second)), generation: 1)
        }
        #expect(sink.failures == 7)
        _ = engine.poll(now: f.now.addingTimeInterval(90), generation: 1)
        #expect(sink.failures == 7)
        _ = engine.poll(now: f.now.addingTimeInterval(91), generation: 1)
        #expect(sink.failures == 8, "A persistent failure must still be retried within 30 seconds")
    }

    @Test func hookHintBypassesHistoricalRetryDelay() throws {
        let f = try Fixture(), log = try f.log()
        let held = log.appendingPathExtension("held")
        try FileManager.default.moveItem(at: log, to: held)
        let engine = TaskActivityEngine(home: f.home)
        engine.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        for second in [0, 1, 3, 7] { _ = settle(engine, now: f.now.addingTimeInterval(Double(second))) }
        try FileManager.default.moveItem(at: held, to: log)
        let now = f.now.addingTimeInterval(8)
        try f.append("task_started", to: log, date: now)
        engine.receiveHint(HookEvent(kind: .submitted, session: "s1", turn: "t1"), now: now, generation: 1)
        #expect(settle(engine, now: now).runningIDs == [TaskIdentity(session: "s1")])
    }

    @Test func changedIndexBypassesRetryAndDoesNotReviveFromWeakEvents() throws {
        let f = try Fixture(), log = try f.log()
        let held = log.appendingPathExtension("held")
        try FileManager.default.moveItem(at: log, to: held)
        let engine = TaskActivityEngine(home: f.home)
        engine.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        for second in [0, 1, 3, 7] { _ = settle(engine, now: f.now.addingTimeInterval(Double(second))) }
        try FileManager.default.moveItem(at: held, to: log)
        let now = f.now.addingTimeInterval(8)
        try f.append("item_completed", to: log, date: now)
        try f.sql("UPDATE threads SET updated_at=\(Int(now.timeIntervalSince1970)) WHERE id='s1'")
        let weak = settle(engine, now: now)
        #expect(weak.readFailureCount == 0)
        #expect(weak.runningIDs.isEmpty)
        try f.append("task_started", turn: "next", to: log, date: now)
        #expect(settle(engine, now: now).runningIDs == [TaskIdentity(session: "s1")])
    }

    @Test func knownActiveFailureRetriesEverySecondAndRestoresOnlyVerifiedContinuity() throws {
        let f = try Fixture(), log = try f.log()
        let engine = TaskActivityEngine(home: f.home)
        engine.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: log)
        #expect(settle(engine, now: f.now).runningIDs.count == 1)
        let held = log.appendingPathExtension("held")
        try FileManager.default.moveItem(at: log, to: held)
        for second in 1...5 {
            let missing = settle(engine, now: f.now.addingTimeInterval(Double(second)))
            #expect(missing.runningIDs.isEmpty)
            #expect(missing.activity.pendingVerificationCount == 1)
            #expect(!missing.hasBacklog)
            #expect(missing.recentCompletions.isEmpty)
        }
        try FileManager.default.moveItem(at: held, to: log)
        let restored = settle(engine, now: f.now.addingTimeInterval(6))
        #expect(restored.runningIDs == [TaskIdentity(session: "s1")])
        try f.append("task_complete", to: log, date: f.now.addingTimeInterval(7))
        #expect(settle(engine, now: f.now.addingTimeInterval(7)).records[TaskIdentity(session: "s1")]?.phase == .completed)
    }

    @Test func wakeBypassesRetryButRequiresNewStartInTheNewGeneration() throws {
        let f = try Fixture(), log = try f.log()
        let engine = TaskActivityEngine(home: f.home)
        engine.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: log)
        #expect(settle(engine, now: f.now).runningIDs.count == 1)
        let held = log.appendingPathExtension("held")
        try FileManager.default.moveItem(at: log, to: held)
        _ = settle(engine, now: f.now.addingTimeInterval(1))
        engine.reconcile(now: f.now.addingTimeInterval(1.1), generation: 2, reason: .sleep)
        try FileManager.default.moveItem(at: held, to: log)
        let now = f.now.addingTimeInterval(1.2)
        engine.reconcile(now: now, generation: 3, reason: .wake)
        let restored = settle(engine, now: now, generation: 3)
        #expect(restored.readFailureCount == 0)
        #expect(restored.runningIDs.isEmpty)
        try f.append("item_completed", to: log, date: now)
        #expect(settle(engine, now: now, generation: 3).runningIDs.isEmpty)
        try f.append("task_started", turn: "new", to: log, date: now)
        #expect(settle(engine, now: now, generation: 3).runningIDs == [TaskIdentity(session: "s1")])
    }

    @Test func unreadablePartialBatchKeepsEvidenceWithoutFastRetry() throws {
        let f = try Fixture(), log = try f.log()
        let engine = TaskActivityEngine(home: f.home, budget: TaskEngineBudget(perFileBytes: 128, totalBytes: 128))
        engine.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        _ = settle(engine, now: f.now)
        try f.append("task_started", to: log)
        #expect(settle(engine, now: f.now).runningIDs.count == 1)
        try f.appendData(Data(("{\"type\":\"response_item\",\"payload\":\"" + String(repeating: "x", count: 4096) + "\"}\n").utf8), to: log)
        let partial = engine.poll(now: f.now.addingTimeInterval(1), generation: 1)
        #expect(partial.hasBacklog && partial.backlogBytes > 0)
        let held = log.appendingPathExtension("held")
        try FileManager.default.moveItem(at: log, to: held)
        let missing = engine.poll(now: f.now.addingTimeInterval(2), generation: 1)
        #expect(!missing.hasBacklog && missing.backlogBytes > 0)
        #expect(missing.runningIDs.isEmpty && missing.readFailureCount == 1)
        #expect(missing.recentCompletions.isEmpty)
        try FileManager.default.moveItem(at: held, to: log)
        let restored = settle(engine, now: f.now.addingTimeInterval(3))
        #expect(!restored.hasBacklog)
        #expect(restored.runningIDs == [TaskIdentity(session: "s1")])
    }

    @Test(arguments: [TaskSourceMode.legacy, .hooks])
    func missingHistoryCannotDelayLiveLifecycleOrInventCompletion(mode: TaskSourceMode) throws {
        let f = try Fixture()
        for i in 0..<65 {
            let log = try f.log(String(format: "missing-%03d", i))
            try FileManager.default.removeItem(at: log)
        }
        let engine = TaskActivityEngine(home: f.home, sourceMode: mode)
        engine.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        let history = settle(engine, now: f.now)
        #expect(history.readFailureCount == 65)
        #expect(!history.hasBacklog)
        let log = try f.log("live"), identity = TaskIdentity(session: "live")
        try f.append("task_started", to: log)
        #expect(settle(engine, now: f.now).runningIDs == [identity])
        try f.append("task_complete", to: log, date: f.now.addingTimeInterval(1))
        let completed = settle(engine, now: f.now.addingTimeInterval(1))
        #expect(completed.runningIDs.isEmpty)
        #expect(completed.recentCompletions.count == 1)
        #expect(completed.records[identity]?.phase == .completed)
        try f.append("item_completed", to: log, date: f.now.addingTimeInterval(2))
        #expect(settle(engine, now: f.now.addingTimeInterval(2)).runningIDs.isEmpty)
        try f.append("task_started", turn: "next", to: log, date: f.now.addingTimeInterval(3))
        #expect(settle(engine, now: f.now.addingTimeInterval(3)).runningIDs == [identity])
        try f.append("turn_aborted", turn: "next", to: log, date: f.now.addingTimeInterval(4))
        let interrupted = settle(engine, now: f.now.addingTimeInterval(4))
        #expect(interrupted.records[identity]?.phase == .interrupted)
        #expect(interrupted.runningIDs.isEmpty)
        #expect(interrupted.recentCompletions.isEmpty)
        #expect(interrupted.readFailureCount == 65)
    }
}
