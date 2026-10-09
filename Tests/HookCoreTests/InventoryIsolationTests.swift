import Foundation
import Testing
@testable import HookCore

struct InventoryIsolationTests {
    @Test func malformedRowBetweenGoodRowsDoesNotPoisonDiscoveryAndHeals() throws {
        let f = try Fixture(), inventory = TaskInventory(home: f.home, pageSize: 2)
        _ = try f.log("a-good"); _ = try f.log("c-good")
        try f.sql("INSERT INTO threads(id,rollout_path,source,updated_at) VALUES('b/bad','/invalid','vscode',\(Int(f.now.timeIntervalSince1970)))")
        // Put candidates outside the recent window so full pagination alone is proved.
        try f.sql("UPDATE threads SET updated_at=0")
        let first = inventory.discover(now: f.now)
        #expect(!first.failed)
        #expect(!first.completedTraversal)
        #expect(Set(inventory.entries.keys) == [TaskIdentity(session: "a-good")])
        let second = inventory.discover(now: f.now)
        #expect(second.completedTraversal)
        #expect(second.coverage == .malformedRows)
        #expect(second.malformedRowCount == 1)
        #expect(Set(inventory.entries.keys) == [TaskIdentity(session: "a-good"), TaskIdentity(session: "c-good")])
        try f.sql("DELETE FROM threads WHERE id='b/bad'")
        _ = try f.log("b-fixed")
        inventory.requestFullReconciliation()
        _ = inventory.discover(now: f.now)
        let healed = inventory.discover(now: f.now)
        #expect(healed.coverage == .complete)
        #expect(healed.malformedRowCount == 0)
        #expect(inventory.entries[TaskIdentity(session: "b-fixed")] != nil)
    }

    @Test func wholeMalformedPageAndMalformedUpperBoundaryStillAdvance() throws {
        let f = try Fixture(), inventory = TaskInventory(home: f.home, pageSize: 2)
        _ = try f.log("c-good")
        for id in ["a/bad", "b/bad", "z/bad"] {
            try f.sql("INSERT INTO threads(id,rollout_path,source,updated_at) VALUES('\(id)','/bad','vscode',0)")
        }
        try f.sql("UPDATE threads SET updated_at=0")
        let first = inventory.discover(now: f.now)
        #expect(first.entries.isEmpty)
        #expect(!first.completedTraversal)
        let second = inventory.discover(now: f.now)
        #expect(second.completedTraversal)
        #expect(second.coverage == .malformedRows)
        #expect(second.malformedRowCount == 3)
        #expect(inventory.entries[TaskIdentity(session: "c-good")] != nil)
    }

    @Test func nullOversizedAndInvalidUTF8RowsAreIsolatedAndKnownTaskRetained() throws {
        let f = try Fixture(), inventory = TaskInventory(home: f.home, pageSize: 2)
        let valid = try f.log("known")
        _ = try f.log("z-good")
        _ = inventory.discover(now: f.now)
        #expect(inventory.entries[TaskIdentity(session: "known")]?.path == valid)
        try f.sql("UPDATE threads SET source=NULL WHERE id='known'")
        try f.sql("INSERT INTO threads(id,rollout_path,source,updated_at) VALUES(NULL,'/null','vscode',0)")
        try f.sql("INSERT INTO threads(id,rollout_path,source,updated_at) VALUES('\(String(repeating: "b", count: 10000))','/huge','vscode',0)")
        try f.sql("INSERT INTO threads(id,rollout_path,source,updated_at) VALUES('invalid-text',CAST(X'FF' AS TEXT),'vscode',0)")
        inventory.requestFullReconciliation()
        var last = inventory.discover(now: f.now)
        for _ in 0..<6 where !last.completedTraversal { last = inventory.discover(now: f.now) }
        #expect(last.completedTraversal)
        #expect(last.coverage == .malformedRows)
        #expect(last.malformedRowCount == 4)
        #expect(inventory.entries[TaskIdentity(session: "known")]?.path == valid)
        #expect(inventory.entries[TaskIdentity(session: "z-good")] != nil)
        try f.sql("UPDATE threads SET source='vscode' WHERE id='known'")
        try f.sql("DELETE FROM threads WHERE id IS NULL OR id NOT IN ('known','z-good')")
        inventory.requestFullReconciliation()
        let fixed = inventory.discover(now: f.now)
        #expect(fixed.coverage == .complete)
    }

    @Test func deletedPageBoundaryRestartsWithoutFalseComplete() throws {
        let f = try Fixture(), inventory = TaskInventory(home: f.home, pageSize: 2)
        for id in ["a", "b", "c", "d"] { _ = try f.log(id) }
        try f.sql("UPDATE threads SET updated_at=0")
        #expect(!inventory.discover(now: f.now).completedTraversal)
        try f.sql("DELETE FROM threads WHERE id='b'")
        let interrupted = inventory.discover(now: f.now)
        #expect(interrupted.failed)
        #expect(!interrupted.completedTraversal)
        #expect(interrupted.coverage != .complete)
        _ = inventory.discover(now: f.now)
        let finished = inventory.discover(now: f.now)
        #expect(finished.completedTraversal)
        #expect(finished.coverage == .complete)
        #expect(inventory.entries[TaskIdentity(session: "d")] != nil)
    }

    @Test(arguments: ["missing", "unknownObject", "unknownString", "cli", "exec", "vscode", "subagent"])
    func sessionSourceMustBeAdmittedIndependentlyOfIndex(source: String) throws {
        let f = try Fixture(), log = try f.log()
        var payload: [String: Any] = ["id": "s1"]
        switch source {
        case "missing": break
        case "unknownObject": payload["source"] = ["other": true]
        case "unknownString": payload["source"] = "new-host-source"
        case "subagent": payload["source"] = ["subagent": ["id": "child"]]
        default: payload["source"] = source
        }
        let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": payload]) + Data([10])
        try HookPaths.atomicWrite(header, to: log)
        try f.append("task_started", to: log)
        let engine = TaskActivityEngine(home: f.home)
        engine.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        var result = engine.poll(now: f.now, generation: 1)
        for _ in 0..<10 where result.hasBacklog { result = engine.poll(now: f.now, generation: 1) }
        let supported = ["cli", "exec", "vscode"].contains(source)
        #expect(result.runningIDs == (supported ? [TaskIdentity(session: "s1")] : []))
        if !supported && source != "subagent" { #expect(result.activity.coverage.gaps.contains(.protocolError)) }
    }

    @Test func checkpointCapacityIsCheckedBeforeEncodingAndPreservesPreviousFile() throws {
        let f = try Fixture(), log = try f.log(records: [("task_started", "turn")])
        let url = f.home.appendingPathComponent("state/checkpoint.json")
        let reader = TaskJournalReader(home: f.home, path: log, expectedSessionID: "s1")
        _ = try reader.read()
        let savedJournal = try reader.checkpoint()
        let journal = try #require(savedJournal)
        let identity = TaskIdentity(session: "s1")
        let row = TaskInventoryEntry(identity: identity, path: log, updatedAt: 0, source: "vscode")
        let record = TaskEngineRecord(identity: identity)
        var entry = TaskCheckpointEntry(inventory: row, journal: journal, published: record, candidate: record, targetEOF: nil)
        let store = TaskCheckpointStore(url: url)
        let small = TaskEngineCheckpoint(savedAt: f.now, entries: [entry], completionIDs: [:])
        let estimate = try TaskCheckpointStore.validateEncodingBudget(small)
        #expect(try JSONEncoder().encode(small).count <= estimate)
        try store.save(small)
        let original = try Data(contentsOf: url)
        // Shared value storage makes this small to construct, but eager JSON encoding
        // would expand it past a gigabyte. Preflight must stop before that allocation.
        let turns = Set((0..<512).map { String(format: "%04d", $0) + String(repeating: "x", count: 156) })
        entry.published.retiredTurnIDs = turns; entry.candidate.retiredTurnIDs = turns
        let huge = TaskEngineCheckpoint(savedAt: f.now, entries: Array(repeating: entry, count: 8192), completionIDs: [:])
        var rejected = false
        do { try store.save(huge) } catch HookFailure.budget { rejected = true }
        #expect(rejected)
        #expect(try Data(contentsOf: url) == original)
    }


    @Test func correctingRawCursorIDInPlaceRestartsTraversal() throws {
        let f = try Fixture(), inventory = TaskInventory(home: f.home, pageSize: 2)
        _ = try f.log("a-good"); _ = try f.log("c-good")
        try f.sql("INSERT INTO threads(id,rollout_path,source,updated_at) VALUES('b/bad','/bad','vscode',0)")
        try f.sql("UPDATE threads SET updated_at=0")
        #expect(!inventory.discover(now: f.now).completedTraversal)
        // Keep the same rowid while changing the raw boundary's sort position.
        try f.sql("UPDATE threads SET id='z-fixed' WHERE id='b/bad'")
        let changed = inventory.discover(now: f.now)
        #expect(changed.failed)
        #expect(!changed.completedTraversal)
        #expect(changed.coverage != .complete)
        _ = inventory.discover(now: f.now)
        let final = inventory.discover(now: f.now)
        #expect(final.completedTraversal)
        #expect(inventory.entries[TaskIdentity(session: "c-good")] != nil)
    }

    @Test func partialReplacementHeaderCheckpointPreservesKnownInventory() throws {
        let f = try Fixture(), log = try f.log()
        let checkpoint = f.home.appendingPathComponent("state/checkpoint.json")
        let first = TaskActivityEngine(home: f.home, checkpointURL: checkpoint)
        first.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: log)
        #expect(first.poll(now: f.now, generation: 1).runningIDs.count == 1)
        try HookPaths.atomicWrite(Data("{\"type\":\"session_meta\",\"payload\":{".utf8), to: log)
        let rotated = first.poll(now: f.now.addingTimeInterval(1), generation: 1)
        #expect(rotated.runningIDs.isEmpty)
        let saved = try TaskCheckpointStore(url: checkpoint).load()
        #expect(saved.entries.count == 1)
        #expect(saved.entries.first?.journal == nil)
        #expect(saved.entries.first?.published.lastKnownPhase == .active)
        try f.sql("DELETE FROM threads") // Checkpoint inventory must stand on its own.
        let resumed = TaskActivityEngine(home: f.home, checkpointURL: checkpoint)
        resumed.begin(now: f.now.addingTimeInterval(2), generation: 2)
        let pending = resumed.poll(now: f.now.addingTimeInterval(2), generation: 2)
        #expect(pending.records[TaskIdentity(session: "s1")]?.lastKnownPhase == .active)
        #expect(pending.activity.pendingVerificationCount == 1)
        try f.appendData(Data("\"id\":\"s1\",\"source\":\"vscode\"}}\n".utf8), to: log)
        try f.append("item_completed", to: log, date: f.now.addingTimeInterval(3))
        #expect(resumed.poll(now: f.now.addingTimeInterval(3), generation: 2).runningIDs.isEmpty)
        try f.append("task_started", turn: "new", to: log, date: f.now.addingTimeInterval(4))
        #expect(resumed.poll(now: f.now.addingTimeInterval(4), generation: 2).runningIDs == [TaskIdentity(session: "s1")])
    }

    @Test(arguments: ["{broken}\n", "{\"type\":\"event_msg\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"payload\":{\"type\":\"task_complete\"}}\n"])
    func malformedLifecycleStaysPendingUntilTrustedLifecycle(invalid: String) throws {
        let f = try Fixture(), a = try f.log("a"), b = try f.log("b")
        let checkpoint = f.home.appendingPathComponent("state/checkpoint.json")
        let monitor = TaskActivityEngine(home: f.home, checkpointURL: checkpoint)
        monitor.begin(now: f.now.addingTimeInterval(-1), generation: 1)
        try f.append("task_started", to: a); try f.append("task_started", to: b)
        #expect(monitor.poll(now: f.now, generation: 1).runningIDs.count == 2)
        try f.appendData(Data(invalid.utf8), to: a)
        let damaged = monitor.poll(now: f.now.addingTimeInterval(1), generation: 1)
        #expect(damaged.runningIDs == [TaskIdentity(session: "b")])
        #expect(damaged.records[TaskIdentity(session: "a")]?.lastKnownPhase == .active)
        #expect(damaged.activity.coverage.gaps.contains(.malformedLog))
        try f.appendData(Data("{}\n".utf8), to: a)
        try f.append("item_completed", to: a, date: f.now.addingTimeInterval(2))
        let weak = monitor.poll(now: f.now.addingTimeInterval(2), generation: 1)
        #expect(weak.runningIDs == [TaskIdentity(session: "b")])
        #expect(weak.activity.coverage.gaps.contains(.malformedLog))
        let restored = TaskActivityEngine(home: f.home, checkpointURL: checkpoint)
        restored.begin(now: f.now.addingTimeInterval(3), generation: 2)
        let stillPending = restored.poll(now: f.now.addingTimeInterval(3), generation: 2)
        #expect(stillPending.activity.coverage.gaps.contains(.malformedLog))
        #expect(stillPending.runningIDs.isEmpty)
        try f.append("task_complete", to: a, date: f.now.addingTimeInterval(4))
        let settled = restored.poll(now: f.now.addingTimeInterval(4), generation: 2)
        #expect(!settled.activity.coverage.gaps.contains(.malformedLog))
        #expect(settled.records[TaskIdentity(session: "a")]?.phase == .completed)
        #expect(settled.recentCompletions.isEmpty)
    }

}
