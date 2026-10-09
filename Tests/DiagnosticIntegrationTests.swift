import Foundation
import SQLite3
import HookCore

// Standalone runner matches the repository's focused swiftc regression entry points.
private final class IntegrationDiagnosticRecorder: DiagnosticRecording {
    private let lock = NSLock()
    private var events: [DiagnosticEvent] = []
    func record(_ event: DiagnosticEvent) { lock.lock(); events.append(event); lock.unlock() }
    func snapshot() -> [DiagnosticEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

@main enum DiagnosticIntegrationTests {
    static func main() throws {
        try emptyAndUnknownEvidence()
        try scanToDisplayCorrelation()
        try hookStartBatchWhenCountsUnchanged()
        try lifecycleTraceDoesNotReactivate()
        try rejectedCandidateAndTruncation()
        try discardedMainCallback()
        try safeConnectionFailure()
        print("PASS: diagnostic integration, unknown versus empty, correlated scan/UI, bounded reads, stale callback and private connection metadata")
    }

    private static func fixture(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hud-diag-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }
    private static func index(_ home: URL, paths: [String] = []) throws {
        var db: OpaquePointer?
        precondition(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, "CREATE TABLE threads (rollout_path TEXT, archived INTEGER, source TEXT, updated_at INTEGER)", nil, nil, nil) == SQLITE_OK)
        for path in paths {
            var statement: OpaquePointer?
            precondition(sqlite3_prepare_v2(db, "INSERT INTO threads VALUES (?,0,'cli',1)", -1, &statement, nil) == SQLITE_OK)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            precondition(sqlite3_bind_text(statement, 1, path, -1, transient) == SQLITE_OK)
            precondition(sqlite3_step(statement) == SQLITE_DONE)
            sqlite3_finalize(statement)
        }
    }
    private static func pump(_ interval: TimeInterval = 0.35) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }
    private static func taskEvent(_ events: [DiagnosticEvent], stage: DiagnosticTaskStage,
                                  matching predicate: (DiagnosticResult, Int?, Int?) -> Bool) -> Bool {
        events.contains {
            guard case let .task(actual, _, result, running, unknown, _, _, _, _) = $0, actual == stage else { return false }
            return predicate(result, running, unknown)
        }
    }
    private static func emptyAndUnknownEvidence() throws {
        try fixture { home in
            let recorder = IntegrationDiagnosticRecorder()
            let monitor = TaskStatusMonitor(home: home, diagnostics: recorder)
            monitor.start(); pump(); monitor.stop()
            precondition(taskEvent(recorder.snapshot(), stage: .aggregate) { result, running, _ in result == .unknown && running == nil }, "Missing database became a confirmed zero")
            try index(home)
            monitor.start(); pump(); monitor.stop()
            precondition(taskEvent(recorder.snapshot(), stage: .aggregate) { $0 == .success && $1 == 0 && $2 == 0 }, "Successful empty index was not a confirmed zero")
        }
        try fixture { home in
            try index(home, paths: [home.appendingPathComponent("sessions/missing.jsonl").path])
            let recorder = IntegrationDiagnosticRecorder()
            let monitor = TaskStatusMonitor(home: home, diagnostics: recorder)
            monitor.start(); pump(); monitor.stop()
            precondition(taskEvent(recorder.snapshot(), stage: .aggregate) { $0 == .unknown && $1 == nil && $2 == 1 }, "All unreadable candidates became zero")
        }
    }
    private static func scanToDisplayCorrelation() throws {
        try fixture { home in
            try index(home)
            let recorder = IntegrationDiagnosticRecorder()
            let legacy = TaskStatusMonitor(home: home, diagnostics: recorder)
            let hooks = HookConnectionController(directory: home.appendingPathComponent("ipc"), home: home)
            let coordinator = TaskMonitoringCoordinator(legacy: legacy, hooks: hooks, diagnostics: recorder)
            coordinator.onUpdate = { _ in coordinator.recordDisplaySubmission() }
            coordinator.start(displayEnabled: true, experimental: false); pump()
            let events = recorder.snapshot()
            var stages: [UInt64: Set<DiagnosticTaskStage>] = [:]
            for event in events {
                if case let .task(stage, batch?, _, _, _, _, _, _, _) = event { stages[batch, default: []].insert(stage) }
            }
            precondition(stages.values.contains { Set([.index, .candidates, .read, .aggregate, .mainAccepted, .uiSubmitted]).isSubset(of: $0) })
            let count = events.count
            pump(2.25)
            precondition(recorder.snapshot().count == count, "Stable normal scan generated additional diagnostic events")
            coordinator.stop()
        }
    }
    private static func lifecycleTraceDoesNotReactivate() throws {
        try fixture { home in
            let file = home.appendingPathComponent("sessions/private-session.jsonl")
            try Data().write(to: file)
            try index(home, paths: [file.path])
            let recorder = IntegrationDiagnosticRecorder()
            let monitor = TaskStatusMonitor(home: home, diagnostics: recorder)
            monitor.start(); pump()
            func append(_ type: String) throws {
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let line = "{\"type\":\"event_msg\",\"timestamp\":\"\(formatter.string(from: Date()))\",\"payload\":{\"type\":\"\(type)\",\"turn_id\":\"PRIVATE_TURN_ID\"}}\n"
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: Data(line.utf8))
            }
            try append("task_started"); pump(2.25)
            precondition(taskEvent(recorder.snapshot(), stage: .lifecycle) { $0 == .success && $1 == 1 && $2 == 0 })
            try append("task_complete"); pump(2.25)
            precondition(taskEvent(recorder.snapshot(), stage: .lifecycle) { $0 == .success && $1 == 0 && $2 == 0 })
            let count = recorder.snapshot().count
            try append("token_count"); pump(2.25)
            precondition(recorder.snapshot().count == count, "Late execution event changed diagnostic lifecycle after terminal")
            monitor.stop()
        }
    }

    private static func hookStartBatchWhenCountsUnchanged() throws {
        try fixture { home in
            try index(home)
            let recorder = IntegrationDiagnosticRecorder()
            let hooks = HookConnectionController(directory: home.appendingPathComponent("ipc"), home: home)
            let coordinator = TaskMonitoringCoordinator(legacy: TaskStatusMonitor(home: home), hooks: hooks, diagnostics: recorder)
            coordinator.onUpdate = { _ in coordinator.recordDisplaySubmission() }
            coordinator.start(displayEnabled: true, experimental: true)
            pump()
            let snapshot = TaskActivitySnapshot(confirmedRunningCount: 1, sourceHealth: [HookSourceHealth(state: .connected)])
            hooks.onUpdate?(snapshot)
            let count = recorder.snapshot().count
            // One turn ends and another starts in the same read, preserving aggregate counts.
            hooks.onTaskStartObserved?()
            hooks.onUpdate?(snapshot)
            let events = Array(recorder.snapshot().dropFirst(count))
            let stages = events.compactMap { event -> (DiagnosticTaskStage, UInt64)? in
                guard case let .task(stage, batch?, _, _, _, _, _, _, _) = event else { return nil }
                return (stage, batch)
            }
            precondition(stages.map(\.0) == [.explicitStart, .hooks, .hookCoverage, .aggregate, .mainAccepted, .uiSubmitted], "Unchanged counts lost the new start's diagnostic chain")
            precondition(Set(stages.map(\.1)).count == 1, "Start and display observations used different batches")
            let stableCount = recorder.snapshot().count
            hooks.onUpdate?(snapshot)
            precondition(recorder.snapshot().count == stableCount, "Stable snapshots generated additional diagnostic events")
            // An old callback cannot leave a pending start in a newly started monitor.
            let oldStart = hooks.onTaskStartObserved
            coordinator.stop()
            oldStart?()
            coordinator.start(displayEnabled: true, experimental: true)
            hooks.onUpdate?(snapshot)
            let restartCount = recorder.snapshot().count
            hooks.onUpdate?(snapshot)
            precondition(recorder.snapshot().count == restartCount, "Stale start observation survived generation reset")
            coordinator.stop(); pump(0.1)
        }
    }

    private static func rejectedCandidateAndTruncation() throws {
        try fixture { home in
            let file = home.appendingPathComponent("sessions/private-user@example.com.jsonl")
            let secrets = "private-user@example.com RAW_TOKEN_SECRET private task title"
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let line = "{\"type\":\"event_msg\",\"timestamp\":\"\(formatter.string(from: Date()))\",\"payload\":{\"type\":\"token_count\",\"turn_id\":\"PRIVATE_TURN_ID\",\"title\":\"\(secrets)\"}}\n"
            var bytes = Data(repeating: 32, count: TaskLogCursor.readLimit + 32); bytes.append(10); bytes.append(Data(line.utf8))
            try bytes.write(to: file)
            try index(home, paths: [file.path, home.appendingPathComponent("outside-private-path.jsonl").path])
            let recorder = IntegrationDiagnosticRecorder()
            let monitor = TaskStatusMonitor(home: home, diagnostics: recorder)
            monitor.start(); pump(); monitor.stop()
            let events = recorder.snapshot()
            precondition(events.contains { if case .task(.candidateRejected, _, .rejected, _, _, 1, _, _, _) = $0 { return true }; return false })
            precondition(events.contains { if case .task(.read, _, .truncated, _, _, _, 0, 1, _) = $0 { return true }; return false })
            precondition(taskEvent(events, stage: .aggregate) { $0 == .unknown && $1 == nil && $2 == 1 }, "Missing task_started evidence became running")
            let encoded = try String(decoding: DiagnosticEventEnvelope.encoder().encode(events), as: UTF8.self)
            for secret in [home.path, "private-user@example.com", "RAW_TOKEN_SECRET", "private task title", "PRIVATE_TURN_ID", "outside-private-path"] {
                precondition(!encoded.contains(secret), "Sensitive production evidence entered events")
            }
        }
    }
    private static func discardedMainCallback() throws {
        try fixture { home in
            try index(home)
            let recorder = IntegrationDiagnosticRecorder()
            let monitor = TaskStatusMonitor(home: home, diagnostics: recorder)
            var updates = 0
            monitor.onUpdate = { _ in updates += 1 }
            monitor.start()
            // Keep main blocked until the real production scan has queued its callback.
            let deadline = Date().addingTimeInterval(2)
            while !taskEvent(recorder.snapshot(), stage: .aggregate, matching: { _, _, _ in true }), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            monitor.stop(); pump()
            precondition(updates == 0)
            precondition(taskEvent(recorder.snapshot(), stage: .mainDiscarded) { result, _, _ in result == .stale })
        }
    }
    private static func safeConnectionFailure() throws {
        let recorder = IntegrationDiagnosticRecorder()
        let client = CodexAppServerClient(executableURL: URL(fileURLWithPath: "/nonexistent/private-account@example.com/RAW_TOKEN_SECRET"),
                                          diagnostics: recorder, diagnosticSource: .check)
        var completed = false
        client.start { _ in completed = true }; pump(); client.stop()
        precondition(completed)
        precondition(recorder.snapshot().contains { if case .connection(.check, .start, _, _, .failed, _, _, _, _, .transport) = $0 { return true }; return false })
        precondition(CodexAppServerClient.diagnosticResult(for: CodexAppServerError.serverError("PRIVATE_SERVER_RESPONSE")) == .serverError)
        precondition(CodexAppServerClient.diagnosticResult(for: CodexAppServerError.requestTimedOut) == .timedOut)
        let encoded = String(decoding: try DiagnosticEventEnvelope.encoder().encode(recorder.snapshot()), as: UTF8.self)
        precondition(!encoded.contains("private-account@example.com") && !encoded.contains("RAW_TOKEN_SECRET"))
    }
}
