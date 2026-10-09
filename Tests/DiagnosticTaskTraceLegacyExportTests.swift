import AppKit
import SQLite3

#if !DIAGNOSTIC_TRACE_BUNDLE
@main
#endif
enum DiagnosticTaskTraceLegacyExportTests {
    private static var checks = 0
    private static var cases: [[String: Any]] = []
    private static func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
    private static func traces(_ values: [DiagnosticEventEnvelope]) -> [DiagnosticTaskTraceEvent] {
        values.compactMap { if case .taskTrace(let value) = $0.event { return value }; return nil }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/diagnostic-task-trace-tests/legacy-zip-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for bytes in [489_000, 601_826, 262_143, 262_144, 262_145, 2_097_152] { try budget(bytes, multiline: false, root: root) }
        try budget(2_097_152, multiline: true, root: root)
        try membersAndLateActivity(root)
        try discovery(33, root: root); try discovery(65, root: root)
        try recordingControls(root)
        let report: [String: Any] = ["schemaVersion": 1, "checks": checks, "cases": cases,
            "diagnosticAcceptance": "passed", "countCorrectness": "knownProductionDefectsPreserved",
            "physicalVisibility": "unverified", "fixtureTruth": "declared independently of production parser",
            "zipDirectory": root.path]
        let output = root.deletingLastPathComponent().appendingPathComponent("legacy-evidence.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("PASS: \(checks) legacy production-to-ZIP assertions; counting truth remains independent and known defects remain failures")
    }
    private static func setup(_ count: Int, root: URL, name: String) throws -> (TracePipelineHarness, [URL]) {
        let harness = try TracePipelineHarness(root: root.appendingPathComponent(name))
        var db: OpaquePointer?
        check(sqlite3_open(harness.home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK, "Create isolated fixture DB")
        defer { sqlite3_close(db) }
        check(sqlite3_exec(db, "CREATE TABLE threads(id TEXT,rollout_path TEXT,source TEXT,archived INTEGER,updated_at INTEGER)", nil, nil, nil) == SQLITE_OK, "Create real discovery schema")
        var paths: [URL] = []
        for i in 0..<count {
            let path = harness.home.appendingPathComponent("sessions/private-task-\(i).jsonl")
            try Data().write(to: path); paths.append(path)
            var statement: OpaquePointer?
            check(sqlite3_prepare_v2(db, "INSERT INTO threads VALUES (?,?, 'cli',0,?)", -1, &statement, nil) == SQLITE_OK, "Prepare index insert")
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, "RAW_THREAD_\(i)", -1, transient)
            sqlite3_bind_text(statement, 2, path.path, -1, transient)
            sqlite3_bind_int(statement, 3, Int32(count - i))
            check(sqlite3_step(statement) == SQLITE_DONE, "Insert fixture index row"); sqlite3_finalize(statement)
        }
        harness.start(hooks: false); harness.pump(0.3)
        return (harness, paths)
    }
    private static func event(_ kind: String, turn: String = "RAW_TURN", bytes: Int? = nil) -> Data {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let prefix = Data("{\"type\":\"event_msg\",\"timestamp\":\"\(formatter.string(from: Date()))\",\"payload\":{\"type\":\"\(kind)\",\"turn_id\":\"\(turn)\",\"private_response\":\"SECRET_TASK_BODY".utf8)
        let suffix = Data("\"}}\n".utf8)
        var output = prefix
        if let bytes { precondition(bytes >= prefix.count + suffix.count); output.append(Data(repeating: 120, count: bytes - prefix.count - suffix.count)) }
        output.append(suffix); return output
    }
    private static func append(_ bytes: Data, _ file: URL) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: bytes)
    }
    private static func verifyPrivacy(_ snapshot: DiagnosticExportSnapshot) {
        for file in snapshot.files {
            for forbidden in ["RAW_TURN", "RAW_THREAD", "SECRET_TASK_BODY", "private-task-", "/fixture-home/"] {
                check(!file.text.contains(forbidden), "Frozen export must not contain raw task identity, path or body")
            }
        }
    }
    private static func verifyConsumers(_ events: [DiagnosticTaskTraceEvent], reference: DiagnosticTaskSnapshotReference) {
        let consumers = events.compactMap { event -> DiagnosticTaskTraceSurface? in
            guard case .consumption(let ref, let observation) = event, ref == reference, observation.action == .received else { return nil }
            check(observation.logicalTaskCount == reference.runningCount, "Consumer logical count matches exact source reference")
            return observation.surface
        }
        check(Set([.coordinator, .main, .touchBar, .floating, .notch, .menuBar]).isSubset(of: Set(consumers)), "Same production snapshot reaches coordinator/main/four actual consumers")
    }
    private static func budget(_ bytes: Int, multiline: Bool, root: URL) throws {
        let id = "budget-\(bytes)-\(multiline ? "lines" : "giant")"
        let (harness, paths) = try setup(3, root: root, name: id); defer { harness.stop() }
        for path in paths { try append(event("task_started"), path) }
        harness.pump(0.35)
        check(harness.latest?.runningCount == 3, "Three independently declared running tasks must enter production")
        let before = try Data(contentsOf: paths[0]).count
        var payload = Data()
        if multiline {
            while bytes - payload.count > 4096 { payload.append(event("item_completed", bytes: 2048)) }
            payload.append(event("item_completed", bytes: bytes - payload.count))
        } else { payload = event("item_completed", bytes: bytes) }
        check(payload.count == bytes && payload.last == 10, "Declared bytes include every newline")
        try append(payload, paths[0]); harness.pump(0.35)
        let expectedProduction = bytes > 262_144 ? 2 : 3
        check(harness.latest?.runningCount == expectedProduction, "Record current production result separately from truth=3")
        try append(event("token_count"), paths[0]); harness.pump(0.2)
        let frozen = try harness.export(name: id); let events = traces(frozen.events)
        let reads = events.compactMap { value -> (DiagnosticTaskTraceIdentity, DiagnosticTaskReadMetrics)? in
            if case .read(_, let identity, let metrics) = value, metrics.fileBytes == UInt64(before + bytes), metrics.readBytes ?? 0 > 0 { return (identity, metrics) }; return nil
        }
        check(!reads.isEmpty, "Exact fixture length is extracted from actual ZIP read event")
        let identity = reads[0].0
        check(reads.contains { $0.1.offsetBefore == UInt64(before) && $0.1.offsetAfter == UInt64(before + bytes)
            && $0.1.readBytes == UInt64(min(bytes, 262_144)) && $0.1.skippedBytes == UInt64(max(0, bytes - 262_144)) }, "ZIP explains exact read, skip and offset units")
        if bytes > 262_144 {
            check(events.contains { if case .member(_, let member, true, false, .readBudgetSkip) = $0 { return member.taskAlias == identity.taskAlias }; return false }, "ZIP names the one member removed by the real read-budget decision")
            check(events.contains { if case .lifecycle(_, let member, let change) = $0 { return member.taskAlias == identity.taskAlias && !change.accepted && change.reason == .missingStartEvidence }; return false }, "ZIP explains why subsequent activity cannot reactivate the cleared task")
            check(Set(events.compactMap { value -> UUID? in if case .member(_, let member, true, false, .readBudgetSkip) = value { return member.taskAlias }; return nil }).count == 1, "Other two members were not removed by this defect")
        }
        let reference = events.compactMap { if case .snapshot(let ref, _) = $0, ref.runningCount == expectedProduction { return ref }; return nil }.last!
        verifyConsumers(events, reference: reference); verifyPrivacy(frozen.snapshot)
        cases.append(["id": id, "inputBytesIncludingNewline": bytes, "fixtureTruthRunning": 3,
            "productionRunning": expectedProduction, "countCorrectnessPassed": expectedProduction == 3,
            "diagnosticAcceptancePassed": true, "zip": frozen.zip.lastPathComponent, "taskAlias": identity.taskAlias.uuidString])
    }
    private static func membersAndLateActivity(_ root: URL) throws {
        let (harness, paths) = try setup(2, root: root, name: "members-late-rotation"); defer { harness.stop() }
        try append(event("task_started", turn: "RAW_TURN_A"), paths[0]); harness.pump()
        let before = harness.latest?.diagnosticSnapshot
        try append(event("task_complete", turn: "RAW_TURN_A"), paths[0])
        try append(event("task_started", turn: "RAW_TURN_B"), paths[1]); harness.pump()
        check(harness.latest?.runningCount == 1, "One end plus another start preserves running total")
        let changed = harness.latest?.diagnosticSnapshot
        check(changed != nil && changed?.snapshotID != before?.snapshotID, "Member substitution generates a new snapshot despite equal total")
        try append(event("token_count", turn: "RAW_TURN_A"), paths[0]); harness.pump()
        check(harness.latest?.runningCount == 1, "Late terminal activity cannot revive the completed task")
        let fileBefore = try Data(contentsOf: paths[1]).count
        let firstHalf = Data(event("item_completed", turn: "RAW_TURN_B").dropLast())
        try append(firstHalf, paths[1]); harness.pump()
        try append(Data([10]), paths[1]); harness.pump()
        try Data().write(to: paths[1], options: .atomic); harness.pump()
        try append(event("task_started", turn: "RAW_TURN_C"), paths[1]); harness.pump()
        let frozen = try harness.export(name: "members-late-rotation"); let events = traces(frozen.events)
        check(events.contains { if case .lifecycle(_, _, let transition) = $0 { return !transition.accepted && transition.reason == .terminalLateActivity }; return false }, "ZIP retains terminal late rejection reason")
        check(events.contains { if case .read(_, _, let metrics) = $0 { return metrics.offsetBefore == UInt64(fileBefore) && (metrics.pendingBytes ?? 0) > 0 }; return false }, "ZIP measures carried halfline bytes")
        check(events.contains { if case .read(_, _, let metrics) = $0 { return metrics.reason == .fileReplaced || metrics.reason == .fileTruncated }; return false }, "ZIP preserves actual rotation/reset branch")
        verifyConsumers(events, reference: changed!); verifyPrivacy(frozen.snapshot)
        cases.append(["id": "same-total-late-halfline-rotation", "fixtureTruthRunning": 1, "productionRunning": harness.latest?.runningCount ?? -1,
            "countCorrectnessPassed": harness.latest?.runningCount == 1, "diagnosticAcceptancePassed": true, "zip": frozen.zip.lastPathComponent])
    }
    private static func discovery(_ count: Int, root: URL) throws {
        let (harness, paths) = try setup(count, root: root, name: "discovery-\(count)"); defer { harness.stop() }
        for path in paths { try append(event("task_started"), path) }; harness.pump(0.4)
        check(harness.latest?.runningCount == 32, "Actual production query is limited to 32 observed tasks")
        var db: OpaquePointer?; check(sqlite3_open(harness.home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK, "Reopen fixture DB")
        sqlite3_busy_timeout(db, 1_000)
        check(sqlite3_exec(db, "UPDATE threads SET updated_at=999 WHERE id='RAW_THREAD_\(count - 1)'", nil, nil, nil) == SQLITE_OK, "Change fixture index order")
        sqlite3_close(db); harness.pump(0.4)
        let frozen = try harness.export(name: "discovery-\(count)"); let events = traces(frozen.events)
        check(events.contains { if case .discovery(_, let observation) = $0 { return observation.queryLimit == 32 && observation.returnedRows == 32 && observation.coverage == .limited }; return false }, "ZIP states observed rows and limited coverage, never fabricated host total")
        check(events.contains { if case .member(_, _, true, false, .leftCurrentQueryResult) = $0 { return true }; return false }, "ZIP records a concrete previously counted member leaving the actual query")
        verifyPrivacy(frozen.snapshot)
        cases.append(["id": "discovery-\(count)", "fixtureTruthRunning": count, "productionRunning": harness.latest?.runningCount ?? -1,
            "countCorrectnessPassed": false, "diagnosticAcceptancePassed": true, "coverage": "limited", "zip": frozen.zip.lastPathComponent])
    }
    private static func recordingControls(_ root: URL) throws {
        let (harness, paths) = try setup(1, root: root, name: "controls"); defer { harness.stop() }
        try append(event("task_started"), paths[0]); harness.pump()
        let original = try harness.export(name: "before-clear")
        let oldReference = harness.latest?.diagnosticSnapshot
        let cleared: Result<Void, Error> = harness.wait { harness.recorder.clear(completion: $0) }
        try cleared.get(); harness.pump()
        harness.render()
        let afterClear = try harness.export(name: "after-clear")
        let current = harness.latest?.diagnosticSnapshot
        check(current?.domain != oldReference?.domain, "Clear rotates the alias domain through real polling")
        check(!afterClear.snapshot.files.first(where: { $0.name == "events.jsonl" })!.text.contains(oldReference!.snapshotID.uuidString), "Old snapshot cannot be reintroduced by queued UI callbacks")
        let disabled: Result<Bool, Error> = harness.wait { harness.recorder.setEnabledReporting(false, completion: $0) }
        check(try disabled.get() == false, "Persistent diagnostic recording disabled")
        try append(event("task_complete"), paths[0]); harness.pump()
        check(harness.latest?.runningCount == 0, "Business monitoring continues while diagnostics are disabled")
        let enabled: Result<Bool, Error> = harness.wait { harness.recorder.setEnabledReporting(true, completion: $0) }
        check(try enabled.get(), "Recording can be reenabled")
        harness.pump()
        let resumed = try harness.export(name: "after-enable")
        verifyPrivacy(original.snapshot); verifyPrivacy(afterClear.snapshot); verifyPrivacy(resumed.snapshot)
        cases.append(["id": "clear-disable-enable", "diagnosticAcceptancePassed": true, "countCorrectnessPassed": true,
            "zip": resumed.zip.lastPathComponent])
    }
}
