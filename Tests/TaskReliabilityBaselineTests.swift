import Foundation
import SQLite3
import Darwin

/// Independent input truth against the unchanged production cursor and monitor.
/// This suite intentionally fails against the archived pre-fix source revision.
@main
enum TaskReliabilityBaselineTests {
    static var checks = 0
    static var failures = 0

    static func check(_ condition: Bool, _ description: String) {
        checks += 1
        if condition {
            print("PASS \(description)")
        } else {
            failures += 1
            print("FAIL \(description)")
        }
    }

    static func event(_ type: String, turn: String) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let root: [String: Any] = [
            "timestamp": formatter.string(from: Date()), "type": "event_msg",
            "payload": ["type": type, "turn_id": turn]
        ]
        var bytes = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        bytes.append(10)
        return bytes
    }

    static func append(_ bytes: Data, to path: URL) throws {
        let file = try FileHandle(forWritingTo: path)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: bytes)
    }

    static func fixtureDirectory(_ suffix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-reliability-baseline-\(suffix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func largeOutputRetainsActiveTurn() throws {
        let directory = try fixtureDirectory("large-output")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("rollout.jsonl")
        try Data().write(to: path)
        var cursor = TaskLogCursor()
        try cursor.read(path)
        try append(event("task_started", turn: "turn-large-output"), to: path)
        try cursor.read(path)
        check(cursor.summary(now: Date()).runningCount == 1, "production read confirms explicit live start")

        // Exactly the user-reported increment, as a valid JSONL response_item record.
        let prefix = Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"output\":\"".utf8)
        let suffix = Data("\"}}\n".utf8)
        var output = prefix
        output.append(Data(repeating: 120, count: 601_826 - prefix.count - suffix.count))
        output.append(suffix)
        precondition(output.count == 601_826)
        _ = try JSONSerialization.jsonObject(with: output)
        try append(output, to: path)
        try cursor.read(path)
        let afterOutput = cursor.summary(now: Date())
        print("OBSERVATION large_increment_bytes=\(output.count) running=\(afterOutput.runningCount) unknown=\(afterOutput.unknownCount)")
        check(afterOutput.runningCount == 1, "601826-byte output preserves the independently known active turn")

        try append(event("item_completed", turn: "turn-large-output"), to: path)
        try cursor.read(path)
        let afterActivity = cursor.summary(now: Date())
        print("OBSERVATION subsequent_same_turn_execution running=\(afterActivity.runningCount) unknown=\(afterActivity.unknownCount)")
        check(afterActivity.runningCount == 1, "same-turn tool activity retains the explicit start without requiring another start")
    }

    static func inventoryIncludesAllCandidates(_ count: Int) throws {
        let directory = try fixtureDirectory("inventory-\(count)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = directory.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        var db: OpaquePointer?
        precondition(sqlite3_open(directory.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, archived INTEGER, source TEXT, updated_at INTEGER)", nil, nil, nil) == SQLITE_OK)
        var paths: [URL] = []
        for index in 0..<count {
            let path = sessions.appendingPathComponent("thread-\(index).jsonl")
            try Data().write(to: path)
            paths.append(path)
            let query = "INSERT INTO threads VALUES ('thread-\(index)', '\(path.path)', 0, 'cli', \(index))"
            precondition(sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK)
        }

        let monitor = TaskStatusMonitor(home: directory)
        var baselineObserved = false
        var bestRunningCount = 0
        var failure: Error?
        monitor.onUpdate = { summary in
            bestRunningCount = max(bestRunningCount, summary.runningCount)
            guard !baselineObserved else { return }
            baselineObserved = true
            do {
                // Start AFTER the production monitor has established its baseline;
                // every fixture task has an independent live-start truth.
                for (index, path) in paths.enumerated() {
                    try append(event("task_started", turn: "turn-\(index)"), to: path)
                }
            } catch { failure = error }
        }
        monitor.start()
        defer { monitor.stop() }
        let deadline = Date().addingTimeInterval(4.5)
        while Date() < deadline && bestRunningCount < count && failure == nil {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if let failure { throw failure }
        check(baselineObserved, "production monitor completed initial discovery for \(count) fixture threads")
        print("OBSERVATION production_inventory fixture_threads=\(count) observed_running=\(bestRunningCount) expected_running=\(count)")
        check(bestRunningCount == count, "production SQLite discovery retains all \(count) active fixture tasks")
    }

    static func main() throws {
        try largeOutputRetainsActiveTurn()
        try inventoryIncludesAllCandidates(33)
        try inventoryIncludesAllCandidates(65)
        print("RESULT checks=\(checks) failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
