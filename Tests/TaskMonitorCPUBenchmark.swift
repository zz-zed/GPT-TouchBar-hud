import Foundation
import Darwin
import SQLite3
import HookCore

/// Runs the production controller and diagnostic recorder against a private copy.
/// Never point it at a live CODEX_HOME: lifecycle probes append to this fixture.
@main enum TaskMonitorCPUBenchmark {
    static func main() throws {
        guard CommandLine.arguments.count == 4,
              let seconds = Double(CommandLine.arguments[3]), seconds >= 10 else {
            fatalError("Usage: benchmark PRIVATE_FIXTURE OUTPUT_JSON IDLE_SECONDS")
        }
        let home = URL(fileURLWithPath: CommandLine.arguments[1])
        let resultURL = URL(fileURLWithPath: CommandLine.arguments[2])
        precondition(home.path.contains("/build/task-monitor-cpu/"))
        let recorder = DiagnosticRecorder(directory: home.deletingLastPathComponent().appendingPathComponent("diagnostics"))
        recorder.start()
        let trace = DiagnosticTaskEngineTrace(recorder: recorder)
        let controller = TaskEngineController(home: home, mode: .legacy, sink: trace)
        var latest: TaskEngineSnapshot?
        var polls = 0, filesRead = 0, bytesRead = 0, fastPolls = 0
        controller.onEngineSnapshot = {
            latest = $0; polls += 1; filesRead += $0.filesRead; bytesRead += $0.bytesRead
            if $0.hasBacklog { fastPolls += 1 }
        }
        controller.start()
        defer { controller.stop() }
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        let initialFailures = latest?.readFailureCount ?? -1
        polls = 0; filesRead = 0; bytesRead = 0; fastPolls = 0
        let started = ProcessInfo.processInfo.systemUptime, cpuStarted = clock()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let cpu = Double(clock() - cpuStarted) / Double(CLOCKS_PER_SEC)
        let idle: [String: Any] = ["wall_seconds": elapsed, "cpu_seconds": cpu, "cpu_percent_one_core": cpu / elapsed * 100,
            "polls": polls, "fast_polls": fastPolls, "files_attempted": filesRead, "bytes_read": bytesRead,
            "initial_read_failures": initialFailures, "final_read_failures": latest?.readFailureCount ?? -1]
        let session = "cpu-benchmark-live", identity = TaskIdentity(session: session)
        let log = home.appendingPathComponent("sessions/\(session).jsonl")
        try HookPaths.atomicWrite(JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": session, "source": "vscode"]]) + Data([10]), to: log)
        var db: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK else { throw HookFailure.io }
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO threads VALUES('\(session)','\(log.path)','vscode',0,\(Int(Date().timeIntervalSince1970)))"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw HookFailure.io }
        func append(_ kind: String, turn: String) throws {
            let date = ISO8601DateFormatter(); date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": date.string(from: Date()), "payload": ["type": kind, "turn_id": turn]]) + Data([10])
            let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        }
        var probes: [[String: Any]] = []
        func probe(_ kind: String, turn: String, phase: TaskPhase) throws {
            try append(kind, turn: turn)
            let start = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - start < 3 {
                if latest?.records[identity]?.phase == phase && latest?.records[identity]?.turnID == turn { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            let matched = latest?.records[identity]?.phase == phase && latest?.records[identity]?.turnID == turn
            probes.append(["event": kind, "matched": matched,
                           "latency_seconds": ProcessInfo.processInfo.systemUptime - start,
                           "counted": latest?.runningIDs.contains(identity) ?? false])
        }
        try probe("task_started", turn: "first", phase: .active)
        try probe("task_complete", turn: "first", phase: .completed)
        try probe("task_started", turn: "second", phase: .active)
        try probe("turn_aborted", turn: "second", phase: .interrupted)
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let result: [String: Any] = ["idle": idle, "lifecycle_probes": probes, "peak_rss_bytes": usage.ru_maxrss,
                                    "diagnostics_enabled": recorder.isEnabled, "pid": getpid()]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: resultURL)
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        guard probes.allSatisfy({ ($0["matched"] as? Bool) == true && ($0["latency_seconds"] as? Double ?? 99) < 1.5 }) else { throw HookFailure.unavailable }
    }
}
