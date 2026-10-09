import Foundation
import Darwin
import SQLite3
import HookCore

private struct ProcessSample {
    let time: Double
    let userCPU: Double
    let systemCPU: Double
    let residentBytes: UInt64
    let peakResidentBytes: Int64
    static func capture() -> ProcessSample {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return ProcessSample(time: ProcessInfo.processInfo.systemUptime,
            userCPU: Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6,
            systemCPU: Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6,
            residentBytes: status == KERN_SUCCESS ? info.resident_size : 0,
            peakResidentBytes: Int64(usage.ru_maxrss))
    }
    func delta(to end: ProcessSample, sampledPeak: UInt64) -> [String: Any] {
        let elapsed = end.time - time, cpu = end.userCPU - userCPU + end.systemCPU - systemCPU
        return ["wall_seconds": elapsed, "user_cpu_seconds": end.userCPU - userCPU,
                "system_cpu_seconds": end.systemCPU - systemCPU, "cpu_percent_of_one_core": cpu / elapsed * 100,
                "resident_start_bytes": residentBytes, "resident_end_bytes": end.residentBytes,
                "sampled_peak_resident_bytes": sampledPeak, "process_peak_resident_bytes": end.peakResidentBytes]
    }
}

#if CURRENT_ENGINE
private final class BenchmarkSink: TaskObservationSink {
    private let lock = NSLock()
    private var maximumBacklog: UInt64 = 0
    private var bytesRead: Int = 0
    private var maximumFetched: UInt64 = 0
    func record(_ event: TaskObservation) {
        guard case .read(_, _, _, let boundary) = event else { return }
        lock.lock(); defer { lock.unlock() }
        maximumBacklog = max(maximumBacklog, boundary.backlogBytes)
        bytesRead += boundary.bytesRead; maximumFetched = max(maximumFetched, boundary.fetched)
    }
    func reset() { lock.lock(); maximumBacklog = 0; bytesRead = 0; maximumFetched = 0; lock.unlock() }
    func values() -> (UInt64, Int, UInt64) {
        lock.lock(); defer { lock.unlock() }; return (maximumBacklog, bytesRead, maximumFetched)
    }
}
#endif

private final class BenchmarkFixture {
    let home = URL(fileURLWithPath: "/private/tmp/hud-benchmark-\(UUID().uuidString)")
    var database: OpaquePointer?
    let giantID = "benchmark-giant", otherID = "benchmark-other"
    init() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK else { throw HookFailure.io }
        try sql("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, archived INTEGER, source TEXT, updated_at INTEGER)")
        for id in [giantID, otherID] {
            let data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "source": "cli"]]) + Data([10])
            try data.write(to: path(id)); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path(id).path)
            try sql("INSERT INTO threads VALUES ('\(id)', '\(path(id).path)', 0, 'cli', \(Int(Date().timeIntervalSince1970)))")
        }
    }
    deinit { sqlite3_close(database); try? FileManager.default.removeItem(at: home) }
    func path(_ id: String) -> URL { home.appendingPathComponent("sessions/\(id).jsonl") }
    func sql(_ value: String) throws { guard sqlite3_exec(database, value, nil, nil, nil) == SQLITE_OK else { throw HookFailure.io } }
    func append(_ data: Data, id: String) throws {
        let handle = try FileHandle(forWritingTo: path(id)); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    func event(_ type: String, id: String) throws {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": formatter.string(from: Date()),
            "payload": ["type": type, "turn_id": "turn-live"]]) + Data([10])
        try append(data, id: id)
    }
    func appendLargeOutput(bytes: Int) throws -> UInt64 {
        let prefix = Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"output\":\"".utf8)
        let suffix = Data("\"}}\n".utf8)
        let handle = try FileHandle(forWritingTo: path(giantID)); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: prefix)
        let chunk = Data(repeating: 120, count: 64 * 1024)
        var remaining = bytes - prefix.count - suffix.count
        while remaining > 0 {
            let amount = min(chunk.count, remaining)
            try handle.write(contentsOf: chunk.prefix(amount)); remaining -= amount
        }
        try handle.write(contentsOf: suffix)
        return try handle.offset()
    }
}

@main enum TaskReliabilityBenchmark {
    static func pump(_ duration: Double, tick: () -> Void = {}) {
        let end = ProcessInfo.processInfo.systemUptime + duration
        while ProcessInfo.processInfo.systemUptime < end {
            tick(); _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        tick()
    }
    static func wait(_ duration: Double, until predicate: () -> Bool) -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + duration
        while !predicate(), ProcessInfo.processInfo.systemUptime < end {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return predicate()
    }
    static func main() throws {
        let fixture = try BenchmarkFixture()
        #if CURRENT_ENGINE
        let implementation = "current"
        let sink = BenchmarkSink()
        let monitor = TaskStatusMonitor(home: fixture.home, sink: sink)
        var latestIDs: [String] = []
        var snapshotCount = 0
        var otherTerminal: Double?
        monitor.onSnapshot = { snapshot in
            latestIDs = snapshot.runningIDs.map(\.session).sorted(); snapshotCount += 1
            if snapshot.records[TaskIdentity(session: fixture.otherID)]?.phase == .completed && otherTerminal == nil {
                otherTerminal = ProcessInfo.processInfo.systemUptime
            }
        }
        #else
        let implementation = "baseline"
        let monitor = TaskStatusMonitor(home: fixture.home)
        var otherTerminal: Double?
        #endif
        var latest = TaskStatusSummary()
        var hasUpdate = false
        var stressStarted: Double?
        var trace: [[String: Any]] = []
        monitor.onUpdate = { summary in
            latest = summary; hasUpdate = true
            if let start = stressStarted {
                trace.append(["seconds": ProcessInfo.processInfo.systemUptime - start, "running_count": summary.runningCount,
                              "completed_count": summary.recentlyCompletedCount, "unknown_count": summary.unknownCount])
                #if !CURRENT_ENGINE
                if summary.recentlyCompletedCount > 0 && otherTerminal == nil { otherTerminal = ProcessInfo.processInfo.systemUptime }
                #endif
            }
        }
        monitor.start()
        let initialized = wait(4, until: { hasUpdate })
        // Matching, bounded idle windows include real production polling and checkpoint behavior.
        let idleStart = ProcessSample.capture(); var idlePeak = idleStart.residentBytes
        pump(3) { idlePeak = max(idlePeak, ProcessSample.capture().residentBytes) }
        let idleEnd = ProcessSample.capture()
        try fixture.event("task_started", id: fixture.giantID)
        try fixture.event("task_started", id: fixture.otherID)
        let bothActive = wait(5, until: { latest.runningCount == 2 })
        #if CURRENT_ENGINE
        let beforeIDs = latestIDs; sink.reset()
        #endif
        let writeStart = ProcessSample.capture()
        let expectedEOF = try fixture.appendLargeOutput(bytes: 16 * 1024 * 1024)
        try fixture.event("task_complete", id: fixture.otherID)
        let writeEnd = ProcessSample.capture()
        // The fixture writer streams64KiB blocks; it never allocates the16MiB body in memory.
        let stressStart = ProcessSample.capture(); stressStarted = stressStart.time
        var stressPeak = stressStart.residentBytes
        var drainLatency: Double?
        pump(8) {
            let sample = ProcessSample.capture(); stressPeak = max(stressPeak, sample.residentBytes)
            #if CURRENT_ENGINE
            if drainLatency == nil, sink.values().2 >= expectedEOF { drainLatency = sample.time - stressStart.time }
            #endif
        }
        let stressEnd = ProcessSample.capture()
        let remainingCountCorrect = latest.runningCount == 1
        var result: [String: Any] = [
            "schema": 1, "implementation": implementation, "fixture": "two explicit live starts; one exact16MiB JSON tool-output line; other task completes",
            "measurement_scope": "whole benchmark process including runtime, aggregate sink,20ms RSS sampler; fixture write measured separately",
            "configured_idle_seconds": 3, "configured_stress_seconds": 8, "tool_output_bytes": 16 * 1024 * 1024,
            "initialized": initialized, "both_active_before_stress": bothActive,
            "expected_remaining_ids": [fixture.giantID], "observed_remaining_count": latest.runningCount,
            "remaining_count_correct": remainingCountCorrect, "other_terminal_observed": otherTerminal != nil,
            "other_terminal_latency_seconds": otherTerminal.map { max(0, $0 - stressStart.time) } as Any? ?? NSNull(),
            "idle": idleStart.delta(to: idleEnd, sampledPeak: idlePeak),
            "fixture_write": writeStart.delta(to: writeEnd, sampledPeak: writeEnd.residentBytes),
            "stress": stressStart.delta(to: stressEnd, sampledPeak: stressPeak), "display_trace": trace,
            "not_measured": ["long-term energy", "real desktop tasks", "Intel hardware", "whole-file tamper resistance"]
        ]
        #if CURRENT_ENGINE
        let sinkValues = sink.values()
        result["observed_before_ids"] = beforeIDs; result["observed_remaining_ids"] = latestIDs
        result["remaining_identity_set_correct"] = latestIDs == [fixture.giantID]
        result["max_backlog_bytes"] = sinkValues.0; result["production_bytes_read"] = sinkValues.1
        result["giant_file_drain_latency_seconds"] = drainLatency as Any? ?? NSNull()
        result["delivered_snapshot_count"] = snapshotCount
        let fair = otherTerminal.map { terminal in drainLatency.map { terminal - stressStart.time < $0 } ?? false } ?? false
        result["other_completes_before_giant_drains"] = fair
        result["expected_behavior"] = "identity preserved and independent terminal delivered during backlog"
        let valid = initialized && bothActive && latestIDs == [fixture.giantID] && otherTerminal != nil && drainLatency != nil && fair
        #else
        result["observed_before_ids"] = NSNull(); result["observed_remaining_ids"] = NSNull()
        result["remaining_identity_set_correct"] = NSNull(); result["max_backlog_bytes"] = NSNull()
        result["production_bytes_read"] = NSNull(); result["giant_file_drain_latency_seconds"] = NSNull()
        result["expected_behavior"] = "known baseline defect may drop the giant-output task; baseline correctness failure is reported, not redefined as success"
        let valid = initialized && bothActive && otherTerminal != nil
        #endif
        monitor.stop(); pump(0.15)
        let output = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(output); FileHandle.standardOutput.write(Data([10]))
        if !valid { exit(1) }
    }
}
