import Foundation
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

@main
enum TaskReliabilityIntegrationTests {
    static var checks = 0
    static var failures = 0

    static func check(_ condition: Bool, _ description: String) {
        checks += 1
        if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL") \(description)")
    }

    @discardableResult
    static func wait(_ description: String, timeout: TimeInterval = 12, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        let result = condition()
        check(result, description)
        return result
    }

    static func pump(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    private static func reached(_ target: UInt64, capture: ReliabilityObservationCapture) -> Bool {
        capture.events.contains { event in
            if case .read(_, _, _, let boundary) = event {
                return boundary.target == target && boundary.fetched == target && boundary.committed == target && boundary.bytesRead > 0
            }
            return false
        }
    }

    static func run(mode: TaskSourceMode, count: Int) throws {
        let label = "\(mode.rawValue) / \(count) main tasks"
        print("SCENARIO \(label)")
        let fixture = try ReliabilityFixture(count: count)
        let child = try fixture.add(index: 0, subagent: true)
        let capture = ReliabilityObservationCapture()
        let legacy = TaskStatusMonitor(home: fixture.home, sink: capture)
        let hooks = HookConnectionController(directory: fixture.hookDirectory, home: fixture.home, sink: capture)
        let coordinator = TaskMonitoringCoordinator(legacy: legacy, hooks: hooks, sink: capture)
        var latest: TaskEngineSnapshot?
        var presented: TaskStatusSummary?
        var deliveries = 0
        legacy.onSnapshot = { latest = $0; deliveries += 1 }
        hooks.onEngineSnapshot = { latest = $0; deliveries += 1 }
        coordinator.onUpdate = { presented = $0 }
        coordinator.start(displayEnabled: true, experimental: mode == .hooks)
        defer { coordinator.stop(); pump(0.05) }
        guard wait("\(label): paginated production inventory reaches complete baseline", until: {
            latest.map { $0.inventoryComplete && !$0.hasBacklog && $0.records.count >= count } ?? false
        }) else { return }
        check(latest?.runningIDs.isEmpty == true, "\(label): session metadata alone cannot establish current execution")
        check(latest?.capability == .continuousLogsOnly, "\(label): runtime truth remains explicitly unavailable")

        if mode == .hooks, let task = fixture.mainTasks.sorted(by: { $0.session < $1.session }).first {
            check(HookEmitter.send(HookEvent(kind: .submitted, session: task.session, turn: "turn-live"),
                                   socketURL: fixture.hookDirectory.appendingPathComponent("events.sock")),
                  "\(label): real private Hook socket acknowledges the submit hint")
            _ = wait("\(label): production engine observes the actual socket hint", until: {
                capture.events.contains { if case .issue(_, _, _, .hintOnly) = $0 { return true }; return false }
            })
            check(latest?.runningIDs.isEmpty == true, "\(label): a Hook hint alone cannot establish execution")
        }

        try fixture.startAll()
        try fixture.event("task_started", task: child)
        guard wait("\(label): independently listed identity set matches all explicit live starts", until: {
            latest?.runningIDs == fixture.mainTasks
        }) else { return }
        check(latest?.activity.confirmedRunningCount == count, "\(label): aggregate matches the independent identity manifest")
        check(latest?.runningIDs.contains(child) == false, "\(label): subagent never adds to primary task count")
        check(presented?.snapshotSequence == latest?.sequence && presented?.observationGeneration == latest?.generation,
              "\(label): coordinator preserves engine snapshot and generation")
        check((presented?.activity?.confirmedRunningCount ?? presented?.runningCount) == count,
              "\(label): selected display adapter consumes the same count")

        let tasks = fixture.mainTasks.sorted { $0.session < $1.session }
        let first = tasks[0]
        let beforeLargeEventCount = capture.events.count
        try fixture.hugeOutput(task: first)
        let target = try fixture.size(first)
        guard wait("\(label): production reader continuously commits exact 601826-byte increment", until: {
            reached(target, capture: capture)
        }) else { return }
        check(latest?.runningIDs == fixture.mainTasks, "\(label): huge output retains every independently active identity")
        let largeEvents = capture.events.dropFirst(beforeLargeEventCount)
        check(largeEvents.contains { if case .read(_, _, _, let value) = $0 { return value.backlogBytes > 0 }; return false },
              "\(label): real reader observations prove budget backlog rather than skipping")

        try fixture.event("task_complete", task: first)
        let remaining = fixture.mainTasks.subtracting([first])
        guard wait("\(label): explicit terminal removes exactly its own identity", until: {
            latest?.runningIDs == remaining
        }) else { return }
        try fixture.event("item_completed", task: first)
        try fixture.event("token_count", task: first)
        let afterLate = try fixture.size(first)
        _ = wait("\(label): real reader consumes late terminal-tail activity", until: { reached(afterLate, capture: capture) })
        check(latest?.runningIDs == remaining, "\(label): terminal-tail activity cannot revive the completed turn")

        if count > 1 {
            let second = tasks[1]
            try fixture.event("task_complete", task: second)
            try fixture.event("task_started", task: first, turn: "turn-next")
            let replaced = remaining.subtracting([second]).union([first])
            let oldSequence = latest?.sequence
            _ = wait("\(label): same-count member replacement is delivered by identity", until: { latest?.runningIDs == replaced })
            check(latest?.sequence != oldSequence, "\(label): equal aggregate with changed membership receives a new snapshot")
        }

        let events = capture.events
        check(events.contains { if case .transition(_, _, _, let observedMode, _, .active, .liveStart) = $0 { return observedMode == mode }; return false },
              "\(label): live-start observations came from the production engine")
        check(events.contains { if case .excluded(_, _, _, let observedMode, .excludedSubagent) = $0 { return observedMode == mode }; return false },
              "\(label): production exclusion has a fixed subagent reason")
        check(events.contains { if case .delivery(_, _, true, .runtime) = $0 { return true }; return false },
              "\(label): real main-queue delivery is observable")
        check(events.contains { if case .delivery(_, _, true, .coordinator) = $0 { return true }; return false },
              "\(label): coordinator acceptance is distinguishable from runtime delivery")

        coordinator.stop()
        let deliveryCountAtStop = deliveries
        pump(0.15)
        let readCountAtStop = capture.events.filter { if case .read = $0 { return true }; return false }.count
        try fixture.event("task_started", task: first, turn: "turn-after-stop")
        pump(1.1)
        check(deliveries == deliveryCountAtStop, "\(label): stop invalidates pending and later callbacks")
        check(capture.events.filter { if case .read = $0 { return true }; return false }.count == readCountAtStop,
              "\(label): stopped runtime performs no new log I/O")

        if count == 3 {
            let saved = try fixture.checkpointOffsets()
            check(Set(saved.keys) == Set(fixture.mainTasks.map(\.session)), "\(label): stopping inactive adapters preserves the selected engine checkpoint inventory")
            check((saved[first.session] ?? 0) > 601_826, "\(label): selected engine persisted the large file's committed record boundary")
            try recovery(fixture: fixture, mode: mode, capture: capture)
        }
    }

    private static func recovery(fixture: ReliabilityFixture, mode: TaskSourceMode, capture: ReliabilityObservationCapture) throws {
        let observationStart = capture.events.count
        let legacy = TaskStatusMonitor(home: fixture.home, sink: capture)
        let hooks = HookConnectionController(directory: fixture.hookDirectory, home: fixture.home, sink: capture)
        let coordinator = TaskMonitoringCoordinator(legacy: legacy, hooks: hooks, sink: capture)
        var latest: TaskEngineSnapshot?
        var deliveredMode: TaskSourceMode?
        legacy.onSnapshot = { latest = $0; deliveredMode = .legacy }
        hooks.onEngineSnapshot = { latest = $0; deliveredMode = .hooks }
        coordinator.start(displayEnabled: true, experimental: mode == .hooks)
        defer { coordinator.stop(); pump(0.05) }
        guard wait("\(mode.rawValue): new runtime recovers checkpoint and continuous inventory", until: {
            latest.map { $0.inventoryComplete && !$0.hasBacklog && $0.records.count >= fixture.mainTasks.count } ?? false
        }) else { return }
        check(latest?.runningIDs.isEmpty == true, "\(mode.rawValue): persisted and pre-restart starts recover pending, not current execution")
        check((latest?.activity.pendingVerificationCount ?? 0) > 0, "\(mode.rawValue): restored unresolved tasks remain explicitly pending")
        check(latest?.recentCompletions.isEmpty == true, "\(mode.rawValue): restart does not replay old completion feedback")
        let recoveredReads = capture.events.dropFirst(observationStart).compactMap { event -> TaskReadObservation? in
            if case .read(_, _, _, let boundary) = event { return boundary }; return nil
        }
        check(recoveredReads.contains { $0.before > 601_826 }, "\(mode.rawValue): production recovery actually resumes the large file at its saved offset")
        check(recoveredReads.reduce(0) { $0 + $1.bytesRead } < 4096, "\(mode.rawValue): valid checkpoint recovery reads only appended records, not old large output")
        let task = fixture.mainTasks.sorted { $0.session < $1.session }[2]
        try fixture.event("item_completed", task: task)
        let target = try fixture.size(task)
        _ = wait("\(mode.rawValue): recovered runtime reads weak activity from the checkpoint", until: { reached(target, capture: capture) })
        check(latest?.runningIDs.isEmpty == true, "\(mode.rawValue): historical start plus current tool activity cannot revive pending task")
        try fixture.event("task_started", task: task, turn: "turn-confirmed-after-restart")
        _ = wait("\(mode.rawValue): explicit new-observation start confirms exactly one task", until: { latest?.runningIDs == Set([task]) })

        let opposite: TaskSourceMode = mode == .legacy ? .hooks : .legacy
        for nextMode in [opposite, mode] {
            let observationsBeforeSwitch = capture.events.count
            latest = nil; deliveredMode = nil
            coordinator.start(displayEnabled: true, experimental: nextMode == .hooks)
            guard wait("\(mode.rawValue): mode switch to \(nextMode.rawValue) loads the shared checkpoint", until: {
                deliveredMode == nextMode && latest.map { $0.inventoryComplete && !$0.hasBacklog } == true
            }) else { return }
            check(latest?.runningIDs.isEmpty == true, "\(mode.rawValue): mode switch conservatively rechecks previous running claims")
            let switchBytes = capture.events.dropFirst(observationsBeforeSwitch).reduce(0) { result, event in
                if case .read(_, _, _, let boundary) = event { return result + boundary.bytesRead }; return result
            }
            check(switchBytes < 4096, "\(mode.rawValue): \(nextMode.rawValue) reuses committed offsets after switching modes")
            try fixture.event("task_started", task: task, turn: "turn-switch-\(nextMode.rawValue)")
            _ = wait("\(mode.rawValue): \(nextMode.rawValue) accepts only its new-generation explicit start", until: {
                latest?.runningIDs == Set([task])
            })
        }
    }

    static func main() throws {
        for count in [1, 3, 8, 33, 65] { try run(mode: .legacy, count: count) }
        for count in [3, 65] { try run(mode: .hooks, count: count) }
        print("RESULT checks=\(checks) failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
