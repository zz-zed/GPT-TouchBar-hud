import Foundation
import SQLite3
import HookCore
import AppKit

@main
enum TaskStatusTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }
    static func event(_ type: String, _ time: String = "2026-09-16T10:00:00.000Z", id: String = "turn-a") -> Data {
        Data("{\"timestamp\":\"\(time)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\",\"turn_id\":\"\(id)\"}}\n".utf8)
    }
    static func main() throws {
        let now = ISO8601DateFormatter().date(from: "2026-09-16T10:00:10Z")!
        var cursor = TaskLogCursor()
        check(cursor.summary(now: now).unknownCount == 1, "Missing evidence is unknown")
        var inferred = TaskLogCursor()
        inferred.consume(event("item_completed"))
        check(inferred.summary(now: now).runningCount == 1, "Recent work event infers running when start fell outside tail")
        inferred.consume(event("task_complete", "2026-09-16T10:00:05Z"))
        check(inferred.summary(now: now).recentlyCompletedCount == 1, "Completion ends inferred running state")
        var settingsOnly = TaskLogCursor()
        settingsOnly.consume(event("thread_settings_applied"))
        check(settingsOnly.summary(now: now).unknownCount == 1, "Settings event alone does not infer execution")
        let start = event("task_started")
        cursor.consume(start.prefix(20))
        check(cursor.phase == nil, "Partial records are not parsed")
        cursor.consume(start.dropFirst(20))
        check(cursor.summary(now: now).runningCount == 1, "Split start record")
        cursor.consume(event("task_complete", id: "other-turn"))
        check(cursor.phase == "running", "Unrelated completion cannot complete current turn")
        cursor.consume(event("task_complete", "2026-09-16T10:00:05Z"))
        check(cursor.summary(now: now).recentlyCompletedCount == 1, "Turn completion and non-fraction timestamp")
        cursor.consume(event("task_started", "2026-09-16T09:59:00.000Z"))
        check(cursor.phase == "complete", "Older events cannot overwrite state")
        check(cursor.summary(now: now.addingTimeInterval(40)).isIdle, "Expired completion becomes idle")
        check(cursor.summary(now: now.addingTimeInterval(25)).isIdle, "Completion expires at exactly 30 seconds")
        cursor.consume(event("task_started", "2026-09-16T10:00:06.000Z", id: "b"))
        check(cursor.summary(now: now).runningCount == 1, "New turn resumes")
        check(cursor.summary(now: now.addingTimeInterval(301)).runningCount == 1, "Silent long-running task remains running after five minutes")
        check(cursor.summary(now: now.addingTimeInterval(TaskLogCursor.runningStaleInterval + 1)).unknownCount == 1,
              "Running becomes unknown only after the stale interval")
        cursor.consume(event("turn_aborted", "2026-09-16T10:00:07.000Z", id: "b"))
        check(cursor.summary(now: now).isIdle, "Explicit abort ends execution without reporting success")
        var display = RateLimitDisplayState.initial
        display.taskStatus = TaskStatusSummary()
        check(display.displayedTaskStatus == nil, "Idle restores original presentation")
        display.taskStatus = TaskStatusSummary(unknownCount: 1)
        check(display.displayedTaskStatus?.badge == "?", "Unknown still displays question mark")
        var historical = TaskLogCursor()
        historical.fileModifiedAt = now.addingTimeInterval(-86400)
        check(historical.monitoredSummary(now: now).isIdle, "Old incomplete history does not hold unknown indicator")
        historical.fileModifiedAt = now
        check(historical.monitoredSummary(now: now).unknownCount == 1, "Recent incomplete log remains unknown")
        historical.fileModifiedAt = now.addingTimeInterval(-600)
        check(historical.monitoredSummary(now: now).unknownCount == 1, "Recently silent task remains in monitoring scope")
        historical.observedLiveChange = true
        historical.fileModifiedAt = now.addingTimeInterval(-86400)
        check(historical.monitoredSummary(now: now).unknownCount == 1, "Observed live task is not silently discarded after becoming stale")
        cursor.consume(Data(repeating: 120, count: TaskLogCursor.readLimit + 1))
        check(cursor.pending.isEmpty, "Malformed record buffer bounded")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.jsonl")
        try start.write(to: file)
        var reader = TaskLogCursor()
        try reader.read(file)
        check(reader.phase == "running", "Initial tail read")
        check(reader.monitoredSummary(now: Date().addingTimeInterval(600)).unknownCount == 1,
              "Initially fresh unfinished task remains unknown after timeout")
        let oldOffset = reader.offset
        try reader.read(file)
        check(reader.offset == oldOffset, "Unchanged file is not reread")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: event("task_complete"))
        try handle.close()
        try reader.read(file)
        check(reader.phase == "complete", "Appended event read incrementally")
        try Data("{}\n".utf8).write(to: file)
        try reader.read(file)
        check(reader.phase == nil, "Truncation clears obsolete state")
        var large = Data(repeating: 120, count: TaskLogCursor.readLimit + 30)
        large.append(10); large.append(start)
        try large.write(to: file, options: .atomic)
        try reader.read(file)
        check(reader.phase == "running", "Bounded tail discards partial first line")
        check(reader.pending.count <= TaskLogCursor.readLimit, "Tail memory remains bounded")
        check(TaskStatusSummary(runningCount: 12).badge == "9+", "Badge width bounded")

        let sessions = directory.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("task.jsonl")
        let stamp = ISO8601DateFormatter().string(from: Date())
        try event("task_started", stamp).write(to: rollout)
        var db: OpaquePointer?
        check(sqlite3_open(directory.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK, "Fixture database opens")
        check(sqlite3_exec(db, "CREATE TABLE threads (rollout_path TEXT, archived INTEGER, updated_at INTEGER); INSERT INTO threads VALUES ('\(rollout.path)', 0, 1);", nil, nil, nil) == SQLITE_OK, "Fixture index created")
        sqlite3_close(db)
        let monitor = TaskStatusMonitor(home: directory)
        var updates: [TaskStatusSummary] = []
        monitor.onUpdate = { updates.append($0) }
        monitor.start()
        let deadline = Date(timeIntervalSinceNow: 3)
        while updates.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        check(updates.last?.runningCount == 1, "Read-only discovery and initial publication")
        monitor.stop()
        let count = updates.count
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        check(updates.count == count, "Stop suppresses updates")

        if CommandLine.arguments.contains("--live-smoke") {
            let live = TaskStatusMonitor()
            var publications = 0
            live.onUpdate = { _ in publications += 1 }
            let startCPU = clock()
            live.start()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 15))
            live.stop()
            print("Live read-only sample: 15s, CPU \(Double(clock() - startCPU) / Double(CLOCKS_PER_SEC))s, \(publications) status publications; no conversation output")
        }
        let hookActivity = TaskActivitySnapshot(confirmedRunningCount: 2, pendingVerificationCount: 1, recentlyCompletedCount: 4)
        let hookSummary = TaskStatusSummary(activity: hookActivity, runningCount: 0, recentlyCompletedCount: 99, unknownCount: 0)
        check(hookSummary.badge == "2 ?", "Hooks adapter ignores legacy default counters")
        check(hookSummary.hasRunningTasks, "Touch Bar activity reads the same Hook snapshot")
        check(TaskStatusAppearance(hookSummary) == .running, "Hooks icon color reads the same Hook snapshot")
        let hookUnknown = TaskStatusSummary(activity: TaskActivitySnapshot(recentlyCompletedCount: 4))
        check(TaskStatusAppearance(hookUnknown) == .unknown && hookUnknown.badge == "—", "Coverage gap cannot show completion icon")
        var hookState = RateLimitDisplayState.initial
        hookState.taskStatus = TaskStatusSummary(activity: TaskActivitySnapshot(coverage: TaskCoverage(gaps: [])))
        check(hookState.displayedTaskStatus?.badge == "0", "Confirmed Hook zero stays visible")
        hookState.taskStatus = TaskStatusSummary(activity: TaskActivitySnapshot())
        check(hookState.displayedTaskStatus?.badge == "—", "Initial Hook unknown stays visible")
        hookState.taskStatus = nil
        check(hookState.displayedTaskStatus == nil, "Explicitly disabled task display stays hidden")
        print("PASS: \(checks) task status checks")
    }
}
