import Foundation
import Testing
@testable import HookCore

struct ResolverTests {
    @Test func startsUnknownThenReadsOnlyIncrementAndSettlesTerminal() throws {
        let f = try Fixture(); let file = try f.log(records: [("task_started", "t1")])
        let resolver = TaskEvidenceResolver(home: f.home)
        let initial = resolver.recover(tasks: [], now: f.now)
        #expect(initial.evidence.count == 1)
        #expect(initial.evidence.first?.live == false)
        let idle = resolver.resolve(task: TaskIdentity(session: "s1"), now: f.now.addingTimeInterval(0.2), liveSince: nil)
        #expect(idle.bytesRead == 0)
        try f.append("task_complete", to: file)
        let read = resolver.resolve(task: TaskIdentity(session: "s1"), now: f.now.addingTimeInterval(0.3), liveSince: nil)
        #expect(read.evidence.first?.kind == .complete)
        #expect(read.evidence.first?.settled == false)
        let settled = resolver.resolve(task: TaskIdentity(session: "s1"), now: f.now.addingTimeInterval(0.5), liveSince: nil)
        #expect(settled.evidence.first?.settled == true)
        #expect(settled.bytesRead == 0)
        try f.append("task_started", to: file, date: f.now.addingTimeInterval(0.6))
        let resumed = resolver.resolve(task: TaskIdentity(session: "s1"), now: f.now.addingTimeInterval(0.7), liveSince: nil)
        #expect(resumed.evidence.first?.kind == .started)
        #expect(resumed.evidence.first?.live == true)
        #expect(resumed.evidence.first!.position > read.evidence.first!.position)
    }
    @Test func submissionCorrelatesOnlyNewExecutionNotOldHistory() throws {
        let f = try Fixture(); _ = try f.log(records: [("task_started", "t1")])
        let resolver = TaskEvidenceResolver(home: f.home)
        let old = resolver.resolve(task: TaskIdentity(session: "s1"), now: f.now.addingTimeInterval(1), liveSince: f.now.addingTimeInterval(0.5))
        #expect(old.evidence.first?.live == false)
        let another = TaskEvidenceResolver(home: f.home)
        let live = another.resolve(task: TaskIdentity(session: "s1"), now: f.now.addingTimeInterval(1), liveSince: f.now.addingTimeInterval(-0.1))
        #expect(live.evidence.first?.live == true)
    }
    @Test func startBeforeHookReceiptRemainsUnknownUntilFreshEvidence() throws {
        let f = try Fixture(); let file = try f.log()
        try f.append("task_started", to: file, date: f.now.addingTimeInterval(-0.01))
        let resolver = TaskEvidenceResolver(home: f.home)
        let initial = resolver.resolve(task: TaskIdentity(session: "s1"), now: f.now, liveSince: f.now)
        #expect(initial.evidence.first?.live == false)
        var r = TaskStateReducer(); for e in initial.evidence { r.apply(e, now: f.now) }
        #expect(r.snapshot(now: f.now).confirmedRunningCount == 0)
        #expect(resolver.resolve(task: TaskIdentity(session: "s1"), now: f.now.addingTimeInterval(1), liveSince: f.now).evidence.isEmpty)
        try f.append("item_completed", to: file, date: f.now.addingTimeInterval(1))
        let fresh = resolver.resolve(task: TaskIdentity(session: "s1"), now: f.now.addingTimeInterval(1.1), liveSince: f.now)
        #expect(fresh.evidence.first?.live == true)
    }
    @Test func rotationAndTruncationExposeGap() throws {
        let f = try Fixture(); let file = try f.log(records: [("task_started", "t1")])
        let resolver = TaskEvidenceResolver(home: f.home)
        _ = resolver.recover(tasks: [], now: f.now)
        let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": "s1"]]) + Data([10])
        try HookPaths.atomicWrite(header, to: file)
        try f.append("turn_aborted", to: file)
        let report = resolver.resolve(task: TaskIdentity(session: "s1"), now: f.now.addingTimeInterval(1), liveSince: nil)
        #expect(report.gaps.contains(.rotatedLog))
        #expect(report.resetTasks.contains(TaskIdentity(session: "s1")))
        #expect(report.evidence.last?.kind == .aborted)
    }
    @Test func hugeLogsAndRecoveryAreBounded() throws {
        let f = try Fixture()
        for i in 0..<33 {
            let file = try f.log("s\(i)")
            try f.appendData(Data(repeating: 120, count: 300_000) + Data([10]), to: file)
            try f.append("task_complete", to: file)
        }
        let resolver = TaskEvidenceResolver(home: f.home)
        let report = resolver.recover(tasks: [], now: f.now)
        #expect(report.filesRead <= 32)
        #expect(report.bytesRead <= 8 * 1024 * 1024)
        #expect(report.gaps.contains(.truncatedLog))
        #expect(report.gaps.contains(.recoveryBudget))
        #expect(resolver.observedFiles.count <= 32)
    }
    @Test func recoveryMetadataIsBoundedAcrossFilesNotOnlyPerFile() throws {
        let f = try Fixture()
        for session in ["s1", "s2"] {
            let file = try f.log(session)
            for turn in 0..<400 { try f.append("task_complete", turn: "t\(turn)", to: file) }
        }
        let resolver = TaskEvidenceResolver(home: f.home)
        let report = resolver.recover(tasks: [], now: f.now)
        #expect(report.evidence.count <= 512)
        #expect(resolver.retainedEvidenceCount <= 512)
        #expect(report.gaps.contains(.capacity))
    }
    @Test func missingMalformedAndOutsidePathsNeverCount() throws {
        let f = try Fixture(); let file = try f.log()
        let resolver = TaskEvidenceResolver(home: f.home)
        #expect(resolver.resolve(task: TaskIdentity(session: "missing"), now: f.now, liveSince: nil).gaps.contains(.missingLog))
        try HookPaths.atomicWrite(Data("bad header\n".utf8), to: file)
        #expect(resolver.resolve(task: TaskIdentity(session: "s1"), now: f.now, liveSince: nil).gaps.contains(.malformedLog))
        try f.sql("UPDATE threads SET rollout_path='/etc/passwd' WHERE id='s1'")
        #expect(resolver.resolve(task: TaskIdentity(session: "s1"), now: f.now, liveSince: nil).gaps.contains(.invalidPath))
    }
    @Test func mismatchedSessionAndSubagentAreExcluded() throws {
        let f = try Fixture(); let file = try f.log(source: "{\"subagent\":{}}", records: [("task_started", "t1")])
        let resolver = TaskEvidenceResolver(home: f.home)
        let child = resolver.recover(tasks: [], now: f.now)
        #expect(child.excluded.contains(TaskIdentity(session: "s1")))
        #expect(child.evidence.isEmpty)
        try f.sql("UPDATE threads SET source='vscode'")
        try HookPaths.atomicWrite(Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"other\"}}\n".utf8), to: file)
        #expect(resolver.recover(tasks: [], now: f.now).evidence.isEmpty)
    }
    @Test func splitRecordDoesNotInventTerminalAndDoesNotLeakText() throws {
        let f = try Fixture(); let file = try f.log(records: [("task_started", "t1")])
        let resolver = TaskEvidenceResolver(home: f.home); _ = resolver.recover(tasks: [], now: f.now)
        let formatter = ISO8601DateFormatter()
        let line = Data("{\"type\":\"event_msg\",\"timestamp\":\"\(formatter.string(from: f.now))\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"t1\",\"last_agent_message\":\"PRIVATE_REPLY\"}}\n".utf8)
        try f.appendData(line.prefix(line.count / 2), to: file)
        #expect(resolver.resolve(task: TaskIdentity(session: "s1"), now: f.now, liveSince: nil).evidence.isEmpty)
        try f.appendData(line.suffix(line.count - line.count / 2), to: file)
        let report = resolver.resolve(task: TaskIdentity(session: "s1"), now: f.now.addingTimeInterval(1), liveSince: nil)
        var reducer = TaskStateReducer(); for item in report.evidence { reducer.apply(item, now: f.now) }
        let data = try JSONEncoder().encode(Array(reducer.records.values))
        #expect(!String(decoding: data, as: UTF8.self).contains("PRIVATE_REPLY"))
        #expect(report.evidence.first?.kind == .complete)
    }
}
