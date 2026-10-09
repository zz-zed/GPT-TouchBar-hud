import Foundation
import SQLite3
import HookCore

/// Real SQLite + rollout files feed the production Hooks worker, coordinator, display consumers and ZIP exporter.
/// Fixture truth describes ongoing work independently of the production parser's result.
#if !DIAGNOSTIC_TRACE_BUNDLE
@main
#endif
enum DiagnosticTaskTraceHookExportTests {
    private static var checks = 0
    private struct Truth: Codable {
        let scenario: String
        let inputBytesIncludingNewline: Int
        let expectedRunningFromFixture: Int
        let observedRunningFromProduction: Int
        let diagnosticAcceptance: Bool
        let countCorrectness: Bool
    }
    private static var truths: [Truth] = []
    private static var artifacts: URL!
    private static func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }

    static func main() throws {
        let evidenceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/diagnostic-task-trace-tests")
        artifacts = evidenceRoot.appendingPathComponent("hooks-pipeline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        // Unix-domain socket paths are capped independently of file-path length.
        let root = URL(fileURLWithPath: "/private/tmp/ht-" + String(UUID().uuidString.prefix(16)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try threeTasksOversizedActivity(root: root)
        for bytes in [489_000, 601_826, HookBudget.readBytes - 1, HookBudget.readBytes, HookBudget.readBytes + 1, 2 * 1_024 * 1_024] {
            try readBoundary(root: root, bytes: bytes)
        }
        try readBoundary(root: root, bytes: 2 * 1_024 * 1_024, multiline: true)
        try memberReplacementAndLateActivity(root: root)
        try partialLineAndRecordingEpoch(root: root)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(truths).write(to: artifacts.appendingPathComponent("truth.json"))
        try encoder.encode(truths).write(to: evidenceRoot.appendingPathComponent("hooks-evidence.json"))
        print("PASS: \(checks) Hooks production-to-ZIP task trace checks")
        print("KNOWN COUNTING DEFECT CAPTURED: oversized activity loses the existing counted task; diagnostic acceptance and count correctness are separate")
    }

    private static func fixture(_ harness: TracePipelineHarness, sessions: [String]) throws -> [URL] {
        try FileManager.default.createDirectory(at: harness.home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        var db: OpaquePointer?
        precondition(sqlite3_open(harness.home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS threads (id TEXT PRIMARY KEY, rollout_path TEXT, source TEXT, archived INT DEFAULT 0, updated_at INT)", nil, nil, nil) == SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        return try sessions.map { session in
            let file = harness.home.appendingPathComponent("sessions/\(session).jsonl")
            let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": session, "source": "vscode"]]) + Data([10])
            try header.write(to: file)
            var statement: OpaquePointer?
            precondition(sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO threads VALUES (?,?,'vscode',0,?)", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            precondition(sqlite3_bind_text(statement, 1, session, -1, transient) == SQLITE_OK)
            precondition(sqlite3_bind_text(statement, 2, file.path, -1, transient) == SQLITE_OK)
            precondition(sqlite3_bind_int64(statement, 3, Int64(Date().timeIntervalSince1970)) == SQLITE_OK)
            precondition(sqlite3_step(statement) == SQLITE_DONE)
            return file
        }
    }
    private static func event(_ kind: String, turn: String = "PRIVATE_TRACE_TURN_A", date: Date = Date()) -> Data {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Data("{\"timestamp\":\"\(formatter.string(from: date))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(kind)\",\"turn_id\":\"\(turn)\"}}\n".utf8)
    }
    private static func activity(bytes: Int, turn: String = "PRIVATE_TRACE_TURN_A") -> Data {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let prefix = Data("{\"timestamp\":\"\(formatter.string(from: Date()))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"turn_id\":\"\(turn)\",\"private_body\":\"PRIVATE_TOOL_RESPONSE_".utf8)
        let suffix = Data("\"}}\n".utf8)
        precondition(bytes > prefix.count + suffix.count)
        return prefix + Data(repeating: 120, count: bytes - prefix.count - suffix.count) + suffix
    }
    private static func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    private static func wait(_ harness: TracePipelineHarness, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline { harness.pump(0.03) }
        check(condition(), "Production Hooks pipeline did not converge")
    }
    private static func traces(_ events: [DiagnosticEventEnvelope]) -> [DiagnosticTaskTraceEvent] {
        events.compactMap { if case .taskTrace(let trace) = $0.event { return trace }; return nil }
    }
    private static func export(_ harness: TracePipelineHarness, name: String) throws -> (snapshot: DiagnosticExportSnapshot, zip: URL, events: [DiagnosticEventEnvelope]) {
        let result = try harness.export(name: name)
        let saved = artifacts.appendingPathComponent(name + ".zip")
        try FileManager.default.copyItem(at: result.zip, to: saved)
        return (result.snapshot, saved, result.events)
    }
    private static func privacy(_ snapshot: DiagnosticExportSnapshot, home: URL) {
        let bytes = snapshot.files.map(\.text).joined()
        for forbidden in [home.path, "PRIVATE_TRACE_SESSION_", "PRIVATE_TRACE_TURN_", "PRIVATE_TOOL_RESPONSE", "private_body"] {
            check(!bytes.contains(forbidden), "Private fixture evidence escaped into the frozen ZIP")
        }
    }
    private static func consumers(_ values: [DiagnosticTaskTraceEvent], snapshotID: UUID) {
        let seen = Set(values.compactMap { value -> DiagnosticTaskTraceSurface? in
            guard case let .consumption(reference, observation) = value, reference.snapshotID == snapshotID else { return nil }
            return observation.surface
        })
        check(Set([DiagnosticTaskTraceSurface.main, .touchBar, .menuBar, .floating, .notch]).isSubset(of: seen), "ZIP lacks an actual observation from a task display consumer")
    }

    private static func threeTasksOversizedActivity(root: URL) throws {
        let harness = try TracePipelineHarness(root: root.appendingPathComponent("three-tasks-489KiB"))
        let files = try fixture(harness, sessions: ["PRIVATE_TRACE_SESSION_A", "PRIVATE_TRACE_SESSION_B", "PRIVATE_TRACE_SESSION_C"])
        harness.start(hooks: true); defer { harness.stop() }
        harness.pump(0.25)
        for file in files { try append(event("task_started"), to: file) }
        wait(harness) { harness.latest?.activity?.confirmedRunningCount == 3 }
        let beforeSize = try Data(contentsOf: files[0]).count
        let inputBytes = 489 * 1_024
        try append(activity(bytes: inputBytes), to: files[0])
        wait(harness) { harness.latest?.activity?.confirmedRunningCount == 2 }
        try append(event("token_count"), to: files[0]); harness.pump(0.35)
        let output = try export(harness, name: "three-tasks-489KiB")
        let values = traces(output.events)
        let affected = values.compactMap { value -> UUID? in
            if case let .read(_, identity, metrics) = value, metrics.reason == .readBudgetSkip,
               metrics.fileBytes == UInt64(beforeSize + inputBytes), metrics.offsetBefore == UInt64(beforeSize),
               metrics.offsetAfter == UInt64(beforeSize + inputBytes), metrics.readBytes == UInt64(HookBudget.readBytes),
               metrics.skippedBytes == UInt64(inputBytes - HookBudget.readBytes), metrics.stateCleared { return identity.taskAlias }
            return nil
        }
        check(Set(affected).count == 1, "ZIP cannot identify the one task whose exact append exceeded the read budget")
        let alias = affected.first!
        check(values.contains { if case let .member(_, identity, before, after, reason) = $0 { return identity.taskAlias == alias && before && !after && reason == .readBudgetSkip }; return false }, "ZIP lacks the actual counted member removal")
        check(values.contains { if case let .lifecycle(_, identity, transition) = $0 { return identity.taskAlias == alias && !transition.accepted && transition.reason == .missingStartEvidence }; return false }, "ZIP cannot explain why later activity failed to recover the skipped task")
        let snapshot = values.compactMap { value -> DiagnosticTaskSnapshotReference? in
            if case let .snapshot(reference, _) = value, reference.runningCount == 2 { return reference }; return nil
        }.last!
        let members = values.flatMap { value -> [DiagnosticTaskSnapshotMember] in
            if case let .snapshotMembers(reference, _, members) = value, reference.snapshotID == snapshot.snapshotID { return members }; return []
        }
        check(snapshot.membershipComplete && Set(members.filter(\.counted).map(\.taskAlias)).count == 2, "ZIP's surviving counted member checkpoint is incomplete")
        check(members.first { $0.taskAlias == alias }?.counted == false, "Affected member remained counted in the saved checkpoint")
        consumers(values, snapshotID: snapshot.snapshotID)
        privacy(output.snapshot, home: harness.home)
        truths.append(.init(scenario: "threeTasksOversizedActivity", inputBytesIncludingNewline: inputBytes,
            expectedRunningFromFixture: 3, observedRunningFromProduction: harness.latest?.activity?.confirmedRunningCount ?? -1,
            diagnosticAcceptance: true, countCorrectness: false))
    }

    private static func readBoundary(root: URL, bytes: Int, multiline: Bool = false) throws {
        let name = "bytes-\(bytes)-\(multiline ? "multi" : "giant")"
        let harness = try TracePipelineHarness(root: root.appendingPathComponent(name))
        let file = try fixture(harness, sessions: ["PRIVATE_TRACE_SESSION_BOUNDARY"])[0]
        harness.start(hooks: true); defer { harness.stop() }
        harness.pump(0.2)
        try append(event("task_started"), to: file)
        wait(harness) { harness.latest?.activity?.confirmedRunningCount == 1 }
        let before = try Data(contentsOf: file).count
        let input: Data
        if multiline {
            let line = activity(bytes: 2_048)
            input = Array(repeating: line, count: bytes / 2_048).reduce(into: Data()) { $0.append($1) }
        } else { input = activity(bytes: bytes) }
        check(input.count == bytes && input.last == 10, "Boundary truth includes the ending newline")
        try append(input, to: file)
        harness.pump(0.35)
        let output = try export(harness, name: name)
        let read = traces(output.events).compactMap { value -> DiagnosticTaskReadMetrics? in
            if case let .read(_, _, metrics) = value, metrics.offsetBefore == UInt64(before), metrics.fileBytes == UInt64(before + bytes) { return metrics }; return nil
        }
        check(read.contains { $0.offsetAfter == UInt64(before + bytes) && $0.readBytes == UInt64(min(bytes, HookBudget.readBytes)) && $0.skippedBytes == UInt64(max(0, bytes - HookBudget.readBytes)) && $0.pendingBytes == 0 && $0.backlogBytes == 0 }, "Actual read byte boundaries did not survive ZIP encoding")
        check(read.contains { $0.reason == .readBudgetSkip } == (bytes > HookBudget.readBytes), "ZIP confuses ordinary reading with production budget skip")
        if multiline { check(read.contains { $0.reason == .firstLineDiscarded && $0.discardedBytes == 2_048 }, "Multiline input lost the exact first tail line discard") }
        check(harness.latest?.activity?.confirmedRunningCount == (bytes > HookBudget.readBytes ? 0 : 1), "Observer changed the current production count behavior")
        privacy(output.snapshot, home: harness.home)
        truths.append(.init(scenario: multiline ? "readBoundaryMultiline" : "readBoundaryGiant", inputBytesIncludingNewline: bytes, expectedRunningFromFixture: 1,
            observedRunningFromProduction: harness.latest?.activity?.confirmedRunningCount ?? -1, diagnosticAcceptance: true,
            countCorrectness: bytes <= HookBudget.readBytes))
    }

    private static func memberReplacementAndLateActivity(root: URL) throws {
        let harness = try TracePipelineHarness(root: root.appendingPathComponent("member-replacement"))
        let file = try fixture(harness, sessions: ["PRIVATE_TRACE_SESSION_REPLACEMENT"])[0]
        harness.start(hooks: true); defer { harness.stop() }
        harness.pump(0.2)
        try append(event("task_started"), to: file)
        wait(harness) { harness.latest?.activity?.confirmedRunningCount == 1 }
        // One production read sees old-turn abort and new-turn start together; aggregate count stays one.
        let replacement = event("turn_aborted") + event("task_started", turn: "PRIVATE_TRACE_TURN_B")
        try append(replacement, to: file)
        harness.pump(0.35)
        let late = event("token_count", turn: "PRIVATE_TRACE_TURN_A")
        try append(late, to: file)
        harness.pump(0.25)
        let output = try export(harness, name: "member-replacement")
        let values = traces(output.events)
        let snapshots = values.compactMap { value -> DiagnosticTaskSnapshotReference? in
            if case let .snapshot(reference, _) = value, reference.runningCount == 1 { return reference }; return nil
        }
        let turnAliases = Set(snapshots.flatMap { snapshot in values.flatMap { value -> [UUID] in
            if case let .snapshotMembers(reference, _, members) = value, reference.snapshotID == snapshot.snapshotID {
                return members.filter(\.counted).compactMap(\.turnAlias)
            }; return []
        } })
        check(snapshots.count >= 2 && turnAliases.count == 2, "Same-count turn replacement lost its two distinct production snapshots")
        check(values.contains { if case let .lifecycle(_, _, transition) = $0 { return !transition.accepted && transition.reason == .terminalLateActivity }; return false }, "Late execution did not retain its actual terminal rejection")
        check(harness.latest?.activity?.confirmedRunningCount == 1, "Late old-turn execution changed the production count")
        consumers(values, snapshotID: snapshots.last!.snapshotID)
        privacy(output.snapshot, home: harness.home)
        truths.append(.init(scenario: "sameCountReplacementAndLateActivity", inputBytesIncludingNewline: replacement.count + late.count,
            expectedRunningFromFixture: 1, observedRunningFromProduction: harness.latest?.activity?.confirmedRunningCount ?? -1,
            diagnosticAcceptance: true, countCorrectness: true))
    }

    private static func partialLineAndRecordingEpoch(root: URL) throws {
        let harness = try TracePipelineHarness(root: root.appendingPathComponent("partial-clear-disable"))
        let file = try fixture(harness, sessions: ["PRIVATE_TRACE_SESSION_EPOCH"])[0]
        harness.start(hooks: true); defer { harness.stop() }
        harness.pump(0.2)
        try append(event("task_started"), to: file)
        wait(harness) { harness.latest?.activity?.confirmedRunningCount == 1 }
        try append(Data(repeating: 120, count: HookBudget.readBytes), to: file); harness.pump(0.2)
        try append(Data([120]), to: file); harness.pump(0.2)
        let partial = try export(harness, name: "pending-halfline")
        check(traces(partial.events).contains {
            if case let .read(_, _, metrics) = $0 { return metrics.reason == .pendingLimitExceeded && metrics.readBytes == 1 && metrics.pendingBytesBefore == UInt64(HookBudget.readBytes) && metrics.pendingBytes == 0 && metrics.discardedBytes == UInt64(HookBudget.readBytes + 1) && !metrics.stateCleared }; return false
        }, "Hooks partial-line clearing was confused with live-state clearing")
        check(harness.latest?.activity?.confirmedRunningCount == 1, "Hook diagnostics changed the partial-line production state")
        try append(Data([10]), to: file); harness.pump(0.2)
        let oldAliases = Set(traces(partial.events).compactMap { value -> UUID? in
            if case let .identity(_, identity, _) = value { return identity.taskAlias }; return nil
        })
        let cleared: Result<Void, Error> = harness.wait { harness.recorder.clear(completion: $0) }
        try cleared.get()
        try append(event("token_count"), to: file); harness.pump(0.25)
        harness.render()
        let afterClear = try export(harness, name: "after-clear")
        let aliases = Set(traces(afterClear.events).compactMap { value -> UUID? in
            if case let .identity(_, identity, _) = value { return identity.taskAlias }; return nil
        })
        check(!aliases.isEmpty && aliases.isDisjoint(with: oldAliases), "Clear reused the old anonymous identity domain")
        check(!traces(afterClear.events).contains {
            if case let .read(_, _, metrics) = $0 { return metrics.reason == .pendingLimitExceeded }; return false
        }, "Clear restored pending observations from an old diagnostic epoch")
        let disabled: Result<Bool, Error> = harness.wait { harness.recorder.setEnabledReporting(false, completion: $0) }
        check(try disabled.get() == false, "Recording disable did not obtain durable confirmation")
        try append(event("turn_aborted"), to: file)
        wait(harness) { harness.latest?.activity?.confirmedRunningCount == 0 }
        let whileDisabled = try export(harness, name: "disabled")
        check(whileDisabled.events.count == afterClear.events.count, "Disabled Hooks pipeline persisted extra observations")
        let enabled: Result<Bool, Error> = harness.wait { harness.recorder.setEnabledReporting(true, completion: $0) }
        check(try enabled.get(), "Recording enable did not obtain durable confirmation")
        try append(event("task_started", turn: "PRIVATE_TRACE_TURN_NEW"), to: file)
        wait(harness) { harness.latest?.activity?.confirmedRunningCount == 1 }
        let resumed = try export(harness, name: "enabled-new-domain")
        check(traces(resumed.events).contains {
            if case let .identity(_, identity, _) = $0 { return !aliases.contains(identity.taskAlias) }; return false
        }, "Re-enabling diagnostics did not assign a new anonymous domain")
        privacy(resumed.snapshot, home: harness.home)
        truths.append(.init(scenario: "partialBufferClearAndRecordingEpoch", inputBytesIncludingNewline: HookBudget.readBytes + 2,
            expectedRunningFromFixture: 1, observedRunningFromProduction: harness.latest?.activity?.confirmedRunningCount ?? -1,
            diagnosticAcceptance: true, countCorrectness: true))
    }
}
