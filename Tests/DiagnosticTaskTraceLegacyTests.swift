import Foundation
import SQLite3
import HookCore

private final class TraceSink: DiagnosticRecording {
    private let lock = NSLock()
    private var values: [DiagnosticEvent] = []
    private var state = DiagnosticTaskTraceState(enabled: true, generation: 1, sessionID: UUID())
    var taskTraceState: DiagnosticTaskTraceState { lock.lock(); defer { lock.unlock() }; return state }
    func record(_ event: DiagnosticEvent) { lock.lock(); values.append(event); lock.unlock() }
    func record(_ event: DiagnosticEvent, expectedGeneration: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if state.enabled && state.generation == expectedGeneration { values.append(event) }
    }
    func events() -> [DiagnosticTaskTraceEvent] {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { if case .taskTrace(let trace) = $0 { return trace }; return nil }
    }
    func setEnabled(_ enabled: Bool) { lock.lock(); state = .init(enabled: enabled, generation: state.generation + 1, sessionID: state.sessionID); lock.unlock() }
}

/// Fixture truth is declared here and never derived from the production parser.
/// These assertions accept the current reader's known counting defect only as evidence capture.
@main enum DiagnosticTaskTraceLegacyTests {
    static var checks = 0
    static let now = Date(timeIntervalSince1970: 1_791_417_600)
    static func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/task-trace-legacy-tests/fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for bytes in [489_000, 601_826, TaskLogCursor.readLimit - 1, TaskLogCursor.readLimit, TaskLogCursor.readLimit + 1, 2 * 1024 * 1024] {
            try readBudget(bytes: bytes, multiline: false, root: root)
        }
        try readBudget(bytes: 2 * 1024 * 1024, multiline: true, root: root)
        try partialAndRotation(root: root)
        try monitorPipeline(root: root)
        try disabledPipeline(root: root)
        try discoveryLimit(33, root: root)
        try discoveryLimit(65, root: root)
        print("PASS: \(checks) legacy task trace checks (actual read, SQLite discovery and timer scheduling)")
        print("KNOWN COUNTING DEFECT CAPTURED: fixture truth remains running after oversized activity; legacy read-budget skip clears its counted state")
    }

    static func event(_ kind: String, at date: Date = now, turn: String = "private-turn-a") -> Data {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Data("{\"timestamp\":\"\(formatter.string(from: date))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(kind)\",\"turn_id\":\"\(turn)\"}}\n".utf8)
    }
    static func paddedActivity(bytes: Int, multiline: Bool = false) -> Data {
        let prefix = Data("{\"timestamp\":\"2026-10-08T00:00:01.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"turn_id\":\"private-turn-a\",\"private_response\":\"".utf8)
        let suffix = Data("\"}}\n".utf8)
        func line(_ count: Int) -> Data { var data = prefix; data.append(Data(repeating: 120, count: count - prefix.count - suffix.count)); data.append(suffix); return data }
        if !multiline { return line(bytes) }
        var result = Data()
        while bytes - result.count > 4096 { result.append(line(2048)) }
        result.append(line(bytes - result.count))
        return result
    }
    static func append(_ bytes: Data, to path: URL) throws {
        let handle = try FileHandle(forWritingTo: path); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: bytes)
    }
    static func activeCursor(_ path: URL) throws -> TaskLogCursor {
        try Data().write(to: path)
        var cursor = TaskLogCursor()
        try cursor.read(path, liveSince: now, now: now)
        try append(event("task_started"), to: path)
        try cursor.read(path, liveSince: now, now: now)
        check(cursor.monitoredSummary(now: now).runningCount == 1, "Independent explicit-start fixture is counted before the large append")
        return cursor
    }
    static func readBudget(bytes: Int, multiline: Bool, root: URL) throws {
        let path = root.appendingPathComponent("budget-\(bytes)-\(multiline).jsonl")
        var cursor = try activeCursor(path)
        let baseline = cursor.offset
        let input = paddedActivity(bytes: bytes, multiline: multiline)
        check(input.count == bytes && input.last == 10, "Fixture byte truth includes the ending newline")
        try append(input, to: path)
        var observed: [TaskLogCursor.Observation] = []
        try cursor.read(path, liveSince: now, now: now.addingTimeInterval(2), observer: { observed.append($0) })
        let reads = observed.compactMap { if case .read(let value) = $0 { return value }; return nil }
        let final = reads.last!
        check(final.fileBytes == baseline + UInt64(bytes) && final.offsetBefore == baseline && final.offsetAfter == baseline + UInt64(bytes), "Actual read records exact total size and before/after offsets")
        check(final.readBytes == min(bytes, TaskLogCursor.readLimit) && final.skippedBytes == UInt64(max(0, bytes - TaskLogCursor.readLimit)), "Actual read records exact read/skip bytes")
        check(final.pendingBytes == 0 && final.backlogBytes == 0, "Completed newline input has no backlog or pending halfline")
        let oversized = bytes > TaskLogCursor.readLimit
        check(final.stateCleared == oversized, "State-clear observation describes the actual legacy decision")
        check(cursor.monitoredSummary(now: now.addingTimeInterval(2)).runningCount == (oversized ? 0 : 1), "Diagnosis captures legacy behavior without redefining the independent running-task truth")
        if oversized {
            check(reads.contains { $0.branch == .readBudgetSkip && $0.readBytes == 0 && $0.phaseBefore == .active && $0.phaseAfter == .unknown }, "The clear decision is observed before tail parsing")
            check(reads.contains { $0.branch == .firstLineDiscarded && $0.discardedBytes > 0 }, "The actual first line discard is measured")
            try append(event("token_count", at: now.addingTimeInterval(3)), to: path)
            observed.removeAll()
            try cursor.read(path, now: now.addingTimeInterval(3), observer: { observed.append($0) })
            check(observed.contains { if case .lifecycle(let value) = $0 { return !value.accepted && value.reason == .missingStartEvidence }; return false }, "Post-skip activity is rejected by the real missing-start rule")
        }
    }

    static func partialAndRotation(root: URL) throws {
        let path = root.appendingPathComponent("partial.jsonl")
        var cursor = try activeCursor(path)
        var values: [TaskLogCursor.Observation] = []
        try append(Data(repeating: 120, count: TaskLogCursor.readLimit), to: path)
        try cursor.read(path, now: now, observer: { values.append($0) })
        check(cursor.pending.count == TaskLogCursor.readLimit && cursor.phase == "running", "Exactly-budget unfinished line retains existing production state")
        try append(Data([121]), to: path)
        values.removeAll(); try cursor.read(path, now: now, observer: { values.append($0) })
        check(values.contains { if case .read(let value) = $0 { return value.branch == .pendingLimitExceeded && value.discardedBytes == TaskLogCursor.readLimit + 1 && value.stateCleared }; return false }, "Accumulated unfinished line over the limit records the exact discarded length")
        check(cursor.phase == nil && cursor.turnID == "private-turn-a", "Observer preserves the legacy rule that this branch clears phase but retains turn")
        let oldGeneration = cursor.fileGeneration
        try event("task_started", turn: "private-turn-new").write(to: path, options: .atomic)
        values.removeAll(); try cursor.read(path, now: now, observer: { values.append($0) })
        check(values.contains { if case .read(let value) = $0 { return value.branch == .fileReplaced && value.fileGeneration > oldGeneration }; return false }, "File replacement has a distinct observed file generation")
        check(values.contains { if case .lifecycle(let value) = $0 { return value.reason == .historicalBaselineRestricted }; return false }, "Replacement preserves the existing historical baseline restriction")
        let replacedGeneration = cursor.fileGeneration
        let handle = try FileHandle(forWritingTo: path); try handle.truncate(atOffset: 0); try handle.close()
        values.removeAll(); try cursor.read(path, now: now, observer: { values.append($0) })
        check(values.contains { if case .read(let value) = $0 { return value.branch == .fileTruncated && value.fileGeneration > replacedGeneration }; return false }, "Same-file truncation is distinct from rotation")
        let split = event("task_started", at: now.addingTimeInterval(1), turn: "private-turn-new")
        try append(split.prefix(31), to: path)
        values.removeAll(); try cursor.read(path, now: now.addingTimeInterval(1), observer: { values.append($0) })
        check(cursor.pending.count == 31 && cursor.phase == nil, "Unfinished start is pending rather than accepted")
        try append(split.dropFirst(31), to: path)
        try cursor.read(path, now: now.addingTimeInterval(1), observer: { values.append($0) })
        check(cursor.phase == "running", "The actual reader accepts a start only after its newline arrives")
        try append(event("task_complete", at: now.addingTimeInterval(2), turn: "private-turn-new"), to: path)
        try cursor.read(path, now: now.addingTimeInterval(2))
        try append(event("item_completed", at: now.addingTimeInterval(3), turn: "private-turn-new"), to: path)
        values.removeAll(); try cursor.read(path, now: now.addingTimeInterval(3), observer: { values.append($0) })
        check(values.contains { if case .lifecycle(let value) = $0 { return !value.accepted && value.reason == .terminalLateActivity }; return false }, "Terminal late activity remains rejected")
        try append(event("task_started", at: now.addingTimeInterval(-1), turn: "private-turn-old"), to: path)
        values.removeAll(); try cursor.read(path, now: now.addingTimeInterval(4), observer: { values.append($0) })
        check(values.contains { if case .lifecycle(let value) = $0 { return !value.accepted && value.reason == .olderTimestamp }; return false }, "Older lifecycle evidence is not accepted")
    }

    static func database(_ home: URL, count: Int) throws -> [URL] {
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        var db: OpaquePointer?
        check(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK, "Owned fixture database opens")
        defer { sqlite3_close(db) }
        check(sqlite3_exec(db, "CREATE TABLE threads (id TEXT, rollout_path TEXT, archived INTEGER, source TEXT, updated_at INTEGER)", nil, nil, nil) == SQLITE_OK, "Independent fixture inventory schema created")
        var paths: [URL] = []
        for n in 0..<count {
            let path = home.appendingPathComponent("sessions/task-\(n).jsonl"); try Data().write(to: path); paths.append(path)
            insert(db!, path: path, n: n)
        }
        return paths
    }
    static func insert(_ db: OpaquePointer, path: URL, n: Int) {
        var statement: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, "INSERT INTO threads VALUES (?, ?, 0, 'cli', ?)", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, "private-thread-\(n)", -1, transient)
        sqlite3_bind_text(statement, 2, path.path, -1, transient); sqlite3_bind_int64(statement, 3, Int64(n))
        precondition(sqlite3_step(statement) == SQLITE_DONE)
    }
    static func wait(line: Int = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        check(condition(), "Production timer/callback reaches independently expected state at test line \(line) within five seconds")
    }
    private static func monitor(_ home: URL, sink: TraceSink) -> TaskStatusMonitor {
        let started = Date()
        var scheduling = TaskStatusMonitor.Scheduling(); scheduling.pollInterval = 0.02; scheduling.discoveryInterval = 0.04
        scheduling.now = { now.addingTimeInterval(Date().timeIntervalSince(started)) }
        return TaskStatusMonitor(home: home, diagnostics: sink, scheduling: scheduling)
    }
    static func monitorPipeline(root: URL) throws {
        let home = root.appendingPathComponent("pipeline")
        let paths = try database(home, count: 3)
        let sink = TraceSink(); let watcher = monitor(home, sink: sink)
        var summary = TaskStatusSummary(); var references: [(DiagnosticTaskSnapshotReference, Bool)] = []
        var updateCount = 0
        watcher.onUpdate = { summary = $0; updateCount += 1 }
        watcher.onDiagnosticTraceDelivery = { references.append(($0, $1)) }
        watcher.start(); defer { watcher.stop() }
        wait { !references.isEmpty }
        for path in paths { try append(event("task_started"), to: path) }
        wait { summary.runningCount == 3 }
        try append(paddedActivity(bytes: 489_000), to: paths[0])
        wait { summary.runningCount == 2 }
        let events = sink.events()
        let cleared = events.compactMap { event -> (DiagnosticTaskTraceIdentity, DiagnosticTaskReadMetrics)? in if case .read(_, let identity, let metrics) = event, metrics.reason == .readBudgetSkip && metrics.readBytes == UInt64(TaskLogCursor.readLimit) { return (identity, metrics) }; return nil }
        check(cleared.count == 1 && cleared[0].1.skippedBytes == UInt64(489_000 - TaskLogCursor.readLimit), "Actual timer pipeline identifies the one oversized task and its exact skip")
        let alias = cleared[0].0.taskAlias
        check(events.contains { if case .member(_, let identity, let before, let after, let reason) = $0 { return identity.taskAlias == alias && before && !after && reason == .readBudgetSkip }; return false }, "Actual inventory member transition names the affected anonymous file")
        check(events.compactMap { if case .member(_, let identity, true, false, .readBudgetSkip) = $0 { return identity.taskAlias }; return nil }.count == 1, "The other two independent running tasks are unaffected")
        try append(event("token_count", at: now.addingTimeInterval(1)), to: paths[0])
        wait { sink.events().contains { if case .lifecycle(_, let identity, let transition) = $0 { return identity.taskAlias == alias && !transition.accepted && transition.reason == .missingStartEvidence }; return false } }
        try append(event("turn_aborted", at: now.addingTimeInterval(1)), to: paths[0])
        wait { summary.unknownCount == 0 }
        let beforeReferences = references.count
        let beforeUpdates = updateCount
        try append(event("turn_aborted", at: now.addingTimeInterval(1)), to: paths[1])
        try append(event("task_started", at: now.addingTimeInterval(2), turn: "private-turn-b"), to: paths[0])
        wait { references.count > beforeReferences && references.last?.0.runningCount == 2 }
        check(updateCount == beforeUpdates && references.last?.1 == false, "Same-count membership swap produces a new trace without forcing an unchanged UI summary update")
        let latest = references.last!.0
        check(DiagnosticTaskSnapshotIntegrity.inspect(reference: latest, events: sink.events()).complete, "The actual production snapshot member checkpoint is complete")
        let encoded = try JSONEncoder().encode(sink.events())
        let text = String(data: encoded, encoding: .utf8)!
        check(!text.contains("private-turn") && !text.contains("private-thread") && !text.contains("private_response") && !text.contains(root.path), "Production traces omit raw IDs, paths and response contents")
        check(sink.events().allSatisfy { if case .identity(_, let identity, _) = $0 { return identity.identityKind == .file && identity.correlation == .fileOnly }; return true }, "Rollout path identities remain file identities rather than invented thread identities")
        let traceCount = sink.events().count
        let idleUntil = Date().addingTimeInterval(0.2)
        while Date() < idleUntil { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        check(sink.events().count == traceCount, "Static idle timer polling adds no trace events")
    }
    static func disabledPipeline(root: URL) throws {
        let home = root.appendingPathComponent("disabled-pipeline")
        let paths = try database(home, count: 1)
        let sink = TraceSink(); sink.setEnabled(false)
        let trace = DiagnosticTaskTrace(recorder: sink)
        let started = Date()
        var scheduling = TaskStatusMonitor.Scheduling(); scheduling.pollInterval = 0.02; scheduling.discoveryInterval = 0.04
        scheduling.now = { now.addingTimeInterval(Date().timeIntervalSince(started)) }
        let watcher = TaskStatusMonitor(home: home, diagnostics: sink, trace: trace, scheduling: scheduling)
        var summary = TaskStatusSummary(); var baselineDelivered = false
        var reference: DiagnosticTaskSnapshotReference?
        watcher.onUpdate = { summary = $0; baselineDelivered = true }
        watcher.onDiagnosticTrace = { reference = $0 }
        watcher.start(); defer { watcher.stop() }
        wait { baselineDelivered }
        try append(event("task_started"), to: paths[0])
        wait { summary.runningCount == 1 }
        check(sink.events().isEmpty && trace.mappedAliasCount == 0 && reference == nil,
            "Disabled diagnostics create no aliases or encoded task traces and preserve the actual UI summary")
        sink.setEnabled(true)
        wait { reference?.runningCount == 1 }
        check(sink.events().allSatisfy { if case .lifecycle(_, _, let change) = $0 { return change.evidence != .started }; return true },
            "Enabling diagnosis observes current membership without replaying the already consumed start")
        let oldDomain = reference!.domain
        sink.setEnabled(false); sink.setEnabled(true)
        wait { reference?.domain != oldDomain }
        check(reference?.runningCount == 1, "A new clear-generation domain retains production state without retaining prior task aliases")
    }

    static func discoveryLimit(_ truthCount: Int, root: URL) throws {
        let home = root.appendingPathComponent("inventory-\(truthCount)")
        let paths = try database(home, count: truthCount)
        let sink = TraceSink(); let watcher = monitor(home, sink: sink)
        var refs: [DiagnosticTaskSnapshotReference] = []
        watcher.onDiagnosticTrace = { refs.append($0) }
        watcher.start(); defer { watcher.stop() }
        wait { refs.last?.memberCount == 32 }
        check(sink.events().contains { if case .discovery(_, let value) = $0 { return value.queryLimit == 32 && value.returnedRows == 32 && value.acceptedRows == 32 && value.coverage == .limited && value.traversalComplete == true }; return false }, "\(truthCount) independent candidates preserve limited-32 coverage without claiming full inventory")
        // Raise one known, previously unobserved candidate into the actual latest-32 query.
        var db: OpaquePointer?; check(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK, "Fixture database reopens for inventory turnover")
        sqlite3_busy_timeout(db, 1000)
        check(sqlite3_exec(db, "UPDATE threads SET updated_at=9999 WHERE id='private-thread-0'", nil, nil, nil) == SQLITE_OK, "Independent fixture changes inventory order")
        sqlite3_close(db)
        let before = refs.last!.snapshotID
        wait { refs.last?.snapshotID != before && sink.events().contains { if case .member(_, _, _, false, .leftCurrentQueryResult) = $0 { return true }; return false } }
        check(sink.events().contains { if case .member(_, _, _, false, .leftCurrentQueryResult) = $0 { return true }; return false }, "Held task removal is recorded as leaving the query result, not an asserted 33rd-rank eviction")
        check(Set(sink.events().compactMap { if case .identity(_, let identity, _) = $0 { return identity.taskAlias }; return nil }).count == 33 && paths.count == truthCount, "Only the 33 actually observed identities are recorded; unseen truth members remain unknown")
    }
}
