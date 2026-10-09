import Foundation
import AppKit
import SQLite3
import Darwin
import HookCore

/// Captures observations emitted by the real workers. Tests never inject observations.
private final class ReliabilityObservationCapture: TaskObservationSink {
    private let lock = NSLock()
    private var captured: [TaskObservation] = []
    func record(_ event: TaskObservation) {
        lock.lock(); defer { lock.unlock() }
        if captured.count < 20_000 { captured.append(event) }
    }
    var events: [TaskObservation] {
        lock.lock(); defer { lock.unlock() }; return captured
    }
}

private final class ReliabilityFixture {
    let home: URL
    let hookDirectory: URL
    private var database: OpaquePointer?
    private(set) var paths: [TaskIdentity: URL] = [:]
    private(set) var mainTasks: Set<TaskIdentity> = []

    init(count: Int) throws {
        home = URL(fileURLWithPath: "/private/tmp/tkr-\(UUID().uuidString.prefix(8))")
        hookDirectory = home.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK else { throw FixtureError.sqlite }
        guard sqlite3_exec(database, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, archived INTEGER, source TEXT, updated_at INTEGER)", nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        for index in 0..<count { try add(index: index) }
    }

    deinit {
        sqlite3_close(database)
        try? FileManager.default.removeItem(at: home)
    }

    enum FixtureError: Error { case sqlite, missingTask }

    @discardableResult
    func add(index: Int, subagent: Bool = false) throws -> TaskIdentity {
        let id = String(format: "fixture-%@-%03d", subagent ? "child" : "main", index)
        let task = TaskIdentity(session: id)
        let path = home.appendingPathComponent("sessions/\(id).jsonl")
        let source: Any = subagent ? ["subagent": ["parent_thread_id": "fixture-main-000"]] : "cli"
        let record: [String: Any] = ["type": "session_meta", "payload": ["id": id, "source": source]]
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(10)
        try data.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO threads VALUES (?, ?, 0, ?, ?)", -1, &statement, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        defer { sqlite3_finalize(statement) }
        let sourceText = subagent ? "{\"subagent\":{\"parent_thread_id\":\"fixture-main-000\"}}" : "cli"
        for (position, text) in [id, path.path, sourceText].enumerated() {
            _ = text.withCString { sqlite3_bind_text(statement, Int32(position + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        sqlite3_bind_int64(statement, 4, Int64(Date().timeIntervalSince1970))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.sqlite }
        paths[task] = path
        if !subagent { mainTasks.insert(task) }
        return task
    }

    func append(_ data: Data, task: TaskIdentity) throws {
        guard let path = paths[task] else { throw FixtureError.missingTask }
        let file = try FileHandle(forWritingTo: path)
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: data)
    }

    func event(_ type: String, task: TaskIdentity, turn: String = "turn-live", date: Date = Date()) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let record: [String: Any] = ["timestamp": formatter.string(from: date), "type": "event_msg",
                                   "payload": ["type": type, "turn_id": turn]]
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(10); try append(data, task: task)
    }

    func startAll() throws {
        for task in mainTasks.sorted(by: { $0.session < $1.session }) { try event("task_started", task: task) }
    }

    func hugeOutput(task: TaskIdentity, bytes: Int = 601_826) throws {
        let prefix = Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"output\":\"".utf8)
        let suffix = Data("\"}}\n".utf8)
        var data = prefix
        data.append(Data(repeating: 120, count: bytes - prefix.count - suffix.count)); data.append(suffix)
        precondition(data.count == bytes)
        try append(data, task: task)
    }

    func size(_ task: TaskIdentity) throws -> UInt64 {
        guard let path = paths[task] else { throw FixtureError.missingTask }
        return (try FileManager.default.attributesOfItem(atPath: path.path)[.size] as! NSNumber).uint64Value
    }

    func checkpointOffsets() throws -> [String: UInt64] {
        let data = try Data(contentsOf: home.appendingPathComponent(".hud-task-state/checkpoint-v1.json"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["entries"] as? [[String: Any]] else { return [:] }
        var offsets: [String: UInt64] = [:]
        for entry in entries {
            guard let inventory = entry["inventory"] as? [String: Any],
                  let identity = inventory["identity"] as? [String: Any], let session = identity["session"] as? String,
                  let journal = entry["journal"] as? [String: Any], let offset = journal["committedOffset"] as? NSNumber else { continue }
            offsets[session] = offset.uint64Value
        }
        return offsets
    }
}

@main enum UnifiedDiagnosticTaskTraceTests {
    static var checks = 0
    static func check(_ result: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(result(), message)
    }
    static func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(12)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check(condition(), "Production runtime did not converge")
    }
    static func main() throws {
        _ = NSApplication.shared
        for mode in [false, true] {
            let f = try ReliabilityFixture(count: 33)
            let diagnosticRoot = f.home.appendingPathComponent("diagnostics")
            var configuration = DiagnosticRecorder.Configuration(); configuration.flushDelay = 0.02
            let recorder = DiagnosticRecorder(directory: diagnosticRoot, configuration: configuration)
            recorder.start()
            let coordinator = TaskMonitoringCoordinator(legacy: TaskStatusMonitor(home: f.home),
                hooks: HookConnectionController(directory: f.hookDirectory, home: f.home), diagnostics: recorder)
            var latest: TaskStatusSummary?
            var state = RateLimitDisplayState.initial
            let display = DiagnosticTaskDisplayObserver(recorder, surface: .menuBar, consumer: .menuBar)
            let touchBar = TouchBarRateLimitsView(diagnostics: recorder, consumer: .touchBarPersistent)
            let floating = CompactQuotaHUDView(initialAppearance: .load(), onRefresh: {}, onClose: {}, contextMenuProvider: { NSMenu() }, diagnostics: recorder)
            let notch = NotchPresentationModel(diagnostics: recorder)
            var businessDeliveries = 0
            coordinator.onDiagnosticSnapshot = { latest?.diagnosticSnapshot = $0 }
            coordinator.onUpdate = { summary in
                businessDeliveries += 1
                latest = summary; state.taskStatus = summary
                state.taskTrace = .init(reference: summary?.diagnosticSnapshot)
                display.record(state, action: .received)
                touchBar.update(with: state); floating.update(with: state); notch.update(state, tasksEnabled: true)
                coordinator.recordDisplaySubmission()
            }
            coordinator.start(displayEnabled: true, experimental: mode)
            wait { latest?.diagnosticSnapshot != nil }
            try f.startAll()
            wait { latest?.runningCount == 33 || latest?.activity?.confirmedRunningCount == 33 }
            check(latest?.diagnosticSnapshot?.runningCount == 33, "Diagnostic count matches all 33 main tasks")
            check(latest?.diagnosticSnapshot?.memberCount == 33, "All indexed identities reach snapshot")
            check(latest?.diagnosticSnapshot?.membershipComplete == true, "Snapshot pages cover actual inventory")
            let task = f.mainTasks.sorted { $0.session < $1.session }.first!
            try f.hugeOutput(task: task)
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            check(latest?.diagnosticSnapshot?.runningCount == 33, "601826-byte burst preserves running identity set")
            try f.event("task_complete", task: task)
            wait { latest?.diagnosticSnapshot?.runningCount == 32 }
            try f.event("token_count", task: task)
            RunLoop.main.run(until: Date().addingTimeInterval(1.1))
            check(latest?.diagnosticSnapshot?.runningCount == 32, "Late weak events do not reactivate completed task")
            var flushed = false; recorder.flush { flushed = true }; wait { flushed }
            let events = try FileManager.default.contentsOfDirectory(at: diagnosticRoot, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }.flatMap { url -> [Data] in
                    let bytes = [UInt8](try Data(contentsOf: url))
                    return bytes.split(separator: UInt8(10)).map { Data($0) }
                }
            let envelopes = try events.map { try DiagnosticEventEnvelope.decoder().decode(DiagnosticEventEnvelope.self, from: $0) }
            check(envelopes.contains { if case .taskTrace(.read(_, _, let metrics)) = $0.event { return (metrics.backlogBytes ?? 0) > 0 && metrics.skippedBytes == 0 }; return false }, "Actual backlog reads are persisted without skip")
            check(envelopes.contains { if case .taskTrace(.consumption(_, let value)) = $0.event { return value.surface == .menuBar }; return false }, "Actual display consumes matching snapshot")
            check(envelopes.contains { if case .taskTrace(.discovery(_, let value)) = $0.event { return value.coverage == .complete && value.acceptedRows == 33 }; return false }, "Full index traversal coverage is persisted")
            let text = events.map { String(decoding: $0, as: UTF8.self) }.joined()
            check(!text.contains("fixture-main") && !text.contains(f.home.path) && !text.contains("turn-live"), "Identifiers and paths stay out of persisted diagnostics")
            let exporter = DiagnosticExportCoordinator(recorder: recorder)
            var preview: Result<DiagnosticExportSnapshot, DiagnosticExportError>?
            exporter.preview(request: .init(range: .all), report: nil) { preview = $0 }
            wait { preview != nil }
            let frozen = try preview!.get()
            let zip = f.home.appendingPathComponent("frozen.zip")
            var saved: Result<Void, DiagnosticExportError>?
            exporter.save(frozen, to: zip) { saved = $0 }
            wait { saved != nil }; try saved!.get()
            let extraction = Process(); extraction.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            extraction.arguments = ["-p", zip.path, "events.jsonl"]
            let pipe = Pipe(); extraction.standardOutput = pipe
            try extraction.run()
            let extracted = pipe.fileHandleForReading.readDataToEndOfFile(); extraction.waitUntilExit()
            check(extraction.terminationStatus == 0, "Frozen ZIP is readable")
            check(extracted == frozen.files.first { $0.name == "events.jsonl" }?.data, "ZIP contains exact frozen events")
            let exported = try extracted.split(separator: 10).map { try DiagnosticEventEnvelope.decoder().decode(DiagnosticEventEnvelope.self, from: Data($0)) }
            for surface in [DiagnosticTaskTraceSurface.menuBar, .touchBar, .floating, .notch] {
                check(exported.contains { if case .taskTrace(.consumption(_, let value)) = $0.event { return value.surface == surface }; return false }, "Four actual consumer surfaces reach frozen export")
            }
            if let reference = latest?.diagnosticSnapshot {
                let traceEvents = exported.compactMap { if case .taskTrace(let event) = $0.event { return event }; return nil }
                check(DiagnosticTaskSnapshotIntegrity.inspect(reference: reference, events: traceEvents).complete, "Current snapshot has complete page/checkpoint chain")
            }
            let old = latest?.diagnosticSnapshot
            var cleared = false; recorder.clear { _ in cleared = true }; wait { cleared }
            check(old?.recordingGeneration != recorder.taskTraceState.generation, "Clear invalidates source references")
            let deliveriesBeforeRefresh = businessDeliveries
            wait { latest?.diagnosticSnapshot?.recordingGeneration == recorder.taskTraceState.generation }
            check(businessDeliveries == deliveriesBeforeRefresh, "Clear refreshes diagnostic reference without business rendering")
            check(latest?.diagnosticSnapshot?.runningCount == 32, "Observation refresh preserves actual business count")
            coordinator.stop()
            print("PASS: unified diagnostic runtime mode \(mode ? "hooks" : "legacy")")
        }
        print("PASS: \(checks) unified diagnostic integration assertions")
    }
}
