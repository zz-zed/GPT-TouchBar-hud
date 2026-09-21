import Foundation
import SQLite3
import HookCore

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
    static func eventWithoutID(_ type: String, _ time: String) -> Data {
        Data("{\"timestamp\":\"\(time)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\"}}\n".utf8)
    }
    static func completion(_ id: String, at date: Date) -> TaskCompletion {
        TaskCompletion(identity: TurnIdentity(task: TaskIdentity(session: "task-status-tests"), turn: id), occurredAt: date)
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
        check(display.displayedTaskStatus == nil, "Legacy uncertainty stays internal and restores neutral presentation")
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
        check(NotchTaskPresentation(TaskStatusSummary(runningCount: 12)).badge == "12",
              "Notch presentation preserves the full running count")

        var terminal = TaskLogCursor()
        terminal.consume(event("task_started", "2026-09-16T10:01:00.000Z", id: "terminal"))
        terminal.consume(event("task_complete", "2026-09-16T10:01:01.000Z", id: "terminal"))
        terminal.consume(eventWithoutID("token_count", "2026-09-16T10:01:02.000Z"))
        check(terminal.phase == "complete", "Terminal state ignores trailing token_count without a turn identity")
        terminal.consume(event("token_count", "2026-09-16T10:01:03.000Z", id: "terminal"))
        check(terminal.phase == "complete", "Terminal state ignores trailing token_count for the same turn")
        terminal.consume(event("item_completed", "2026-09-16T10:01:04.000Z", id: "new-turn"))
        check(terminal.phase == "running" && terminal.turnID == "new-turn", "Explicit work evidence for a different turn reactivates monitoring")

        var stale = TaskLogCursor()
        stale.consume(event("task_started", "2026-09-16T10:00:00.000Z", id: "stale"))
        let staleTime = now.addingTimeInterval(TaskLogCursor.runningStaleInterval + 1)
        var staleSummary = stale.summary(now: staleTime)
        check(staleSummary.isIdle && staleSummary.legacyDiagnostics?.staleCount == 1,
              "Stale running evidence becomes a neutral diagnostic, never completion")
        stale.consume(event("thread_settings_applied", "2026-09-16T10:30:12.000Z", id: "stale"))
        staleSummary = stale.summary(now: staleTime)
        check(staleSummary.legacyDiagnostics?.staleCount == 1 && staleSummary.runningCount == 0,
              "Settings-only events cannot revive stale execution")
        stale.consume(event("token_count", "2026-09-16T10:30:13.000Z", id: "stale"))
        let revivedAt = ISO8601DateFormatter().date(from: "2026-09-16T10:30:14Z")!
        check(stale.summary(now: revivedAt).runningCount == 1, "Fresh execution evidence revives a stale task")

        let baselineFile = directory.appendingPathComponent("baseline-complete.jsonl")
        var baselineBytes = event("task_started", "2026-09-16T10:00:00.000Z", id: "old")
        baselineBytes.append(event("task_complete", "2026-09-16T10:00:05.000Z", id: "old"))
        try baselineBytes.write(to: baselineFile)
        var baselineCursor = TaskLogCursor()
        try baselineCursor.read(baselineFile)
        check(baselineCursor.completionID(for: baselineFile.path, now: now) == nil,
              "A completed file's first discovery establishes history without replay")
        let baselineHandle = try FileHandle(forWritingTo: baselineFile)
        try baselineHandle.seekToEnd()
        try baselineHandle.write(contentsOf: event("task_started", "2026-09-16T10:00:06.000Z", id: "new"))
        try baselineHandle.write(contentsOf: event("task_complete", "2026-09-16T10:00:07.000Z", id: "new"))
        try baselineHandle.close()
        try baselineCursor.read(baselineFile)
        let completionID = baselineCursor.completionID(for: baselineFile.path, now: now)
        check(completionID?.count == 64 && completionID?.contains(baselineFile.path) == false,
              "An appended completion gets an opaque identity without exposing its path")
        let duplicateHandle = try FileHandle(forWritingTo: baselineFile)
        try duplicateHandle.seekToEnd()
        try duplicateHandle.write(contentsOf: event("task_complete", "2026-09-16T10:00:08.000Z", id: "new"))
        try duplicateHandle.close()
        try baselineCursor.read(baselineFile)
        check(baselineCursor.completionID(for: baselineFile.path, now: now) == completionID,
              "Duplicate terminal evidence for one turn keeps the same completion identity")

        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let partial = TaskStatusMonitor.combinedSummary(
            values: [TaskStatusSummary(runningCount: 1, legacyHealth: .healthy)],
            readFailureCount: 1,
            discoveryFailed: false,
            lastSuccessfulCheck: checkedAt
        )
        check(partial.legacyHealth == .healthy && partial.unknownCount == 1,
              "One unreadable candidate remains a local diagnostic when another succeeds")
        check(TaskStatusAppearance(partial) == .running && !partial.badge.contains("?"),
              "Local unknown diagnostics do not replace a running primary state")
        check(partial.legacyDiagnostics?.readFailureCount == 1
              && partial.legacyDiagnostics?.lastSuccessfulCheck == checkedAt
              && !partial.detail.contains("读取失败") && !partial.detail.contains("上次成功检查"),
              "Legacy diagnostics remain internal and do not enter user-facing detail")
        let allUnreadable = TaskStatusMonitor.combinedSummary(
            values: [], readFailureCount: 2, discoveryFailed: false, lastSuccessfulCheck: checkedAt
        )
        check(allUnreadable.legacyHealth == .unavailable(.allCandidatesUnreadable)
              && TaskStatusAppearance(allUnreadable) == .idle && allUnreadable.isIdle && allUnreadable.badge.isEmpty,
              "All candidate read failures stay internal and present a neutral state")
        let discoveryFailure = TaskStatusMonitor.combinedSummary(
            values: [], readFailureCount: 0, discoveryFailed: true, lastSuccessfulCheck: checkedAt
        )
        check(discoveryFailure.legacyHealth == .unavailable(.discoveryFailure)
              && discoveryFailure.legacyDiagnostics?.lastSuccessfulCheck == checkedAt,
              "Discovery failure preserves the last successful check")
        let recovered = TaskStatusMonitor.combinedSummary(
            values: [TaskStatusSummary(legacyHealth: .healthy)],
            readFailureCount: 0, discoveryFailed: false, lastSuccessfulCheck: checkedAt.addingTimeInterval(60)
        )
        check(recovered.legacyHealth == .healthy && recovered.isIdle,
              "A healthy poll recovers from an earlier overall fault")

        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let feedback = TaskCompletionFeedbackController(now: { instant })
        let baseline = TaskStatusSummary(runningCount: 1, legacyHealth: .healthy)
        feedback.receive(baseline, enabled: true)
        check(!feedback.isActive, "Legacy first delivery establishes a no-replay baseline")
        var completed = TaskStatusSummary(
            recentlyCompletedCount: 1,
            legacyHealth: .healthy,
            legacyCompletionIDs: ["completion-a"]
        )
        instant += 1
        feedback.receive(completed, enabled: true)
        let firstDeadline = feedback.deadline
        check(feedback.isActive && firstDeadline == instant.addingTimeInterval(4),
              "New legacy completion gets exactly four seconds")
        check(feedback.applying(to: completed)?.badge == "✓", "Legacy completion decorates the shared summary")
        instant += 1
        feedback.receive(completed, enabled: true)
        check(feedback.deadline == firstDeadline, "Repeated legacy completion does not extend feedback")
        var unknownAlongside = completed
        unknownAlongside.unknownCount = 1
        unknownAlongside.legacyDiagnostics = LegacyTaskDiagnostics(
            unknownCount: 1, reasons: [.missingLifecycleEvidence], lastSuccessfulCheck: checkedAt
        )
        check(feedback.applying(to: unknownAlongside)?.badge == "✓",
              "A local unknown task does not hide a confirmed completion")
        var runningAfterCompletion = unknownAlongside
        runningAfterCompletion.runningCount = 1
        check(feedback.applying(to: runningAfterCompletion)?.badge == "1 ✓"
              && TaskStatusAppearance(feedback.applying(to: runningAfterCompletion)) == .running,
              "A newly running task has priority over retained completion feedback")
        instant += 3
        check(feedback.applying(to: completed)?.isIdle == true,
              "Completion becomes neutral after four seconds")
        feedback.receive(completed, enabled: true)
        check(!feedback.isActive, "Expired completion is not replayed")
        instant += 1
        completed.legacyCompletionIDs = ["completion-b"]
        feedback.receive(completed, enabled: true)
        check(feedback.isActive, "A different completion can signal while retained count stays constant")
        var globalFailure = completed
        globalFailure.legacyHealth = .unavailable(.allCandidatesUnreadable)
        globalFailure.legacyCompletionIDs = ["completion-c"]
        feedback.receive(globalFailure, enabled: true)
        check(!feedback.isActive && feedback.applying(to: globalFailure)?.badge.isEmpty == true
              && feedback.applying(to: globalFailure)?.isIdle == true,
              "Overall monitoring failure clears completion but remains neutral")
        feedback.reset()
        feedback.receive(completed, enabled: true)
        check(!feedback.isActive && feedback.applying(to: completed)?.isIdle == true,
              "Monitor restart baselines retained completion without replay")

        var hookSnapshot = TaskActivitySnapshot(coverage: TaskCoverage(gaps: []), updatedAt: instant)
        let hookFeedback = TaskCompletionFeedbackController(now: { instant })
        hookFeedback.receive(TaskStatusSummary(activity: hookSnapshot), enabled: true)
        instant += 1
        hookSnapshot.recentlyCompletedCount = 1
        hookSnapshot.recentCompletions = [completion("hook-complete", at: instant)]
        hookSnapshot.updatedAt = instant
        hookFeedback.receive(TaskStatusSummary(activity: hookSnapshot), enabled: true)
        check(hookFeedback.isActive && hookFeedback.applying(to: TaskStatusSummary(activity: hookSnapshot))?.badge == "✓",
              "Hook completion semantics remain unchanged")
        hookFeedback.reset()

        let localUnknown = TaskStatusSummary(
            unknownCount: 1,
            legacyHealth: .healthy,
            legacyDiagnostics: LegacyTaskDiagnostics(
                unknownCount: 1, reasons: [.missingLifecycleEvidence], lastSuccessfulCheck: checkedAt
            ),
            legacyCompletionIDs: []
        )
        check(localUnknown.isIdle && TaskStatusAppearance(localUnknown) == .idle,
              "Local unknown diagnostics keep the primary presentation neutral")
        let localPresentation = NotchTaskPresentation(localUnknown)
        check(localPresentation.badge == "0" && localPresentation.appearance == .idle
              && localPresentation.note == nil && !localUnknown.detail.contains("待确认")
              && !localUnknown.detail.contains("上次成功") && !localUnknown.detail.contains("读取失败"),
              "Notch presentation does not expose local diagnostics")
        var menuState = RateLimitDisplayState.initial
        menuState.taskStatus = localUnknown
        check(menuState.displayedTaskStatus == nil, "Neutral local diagnostics do not tint compact task surfaces")

        let multi = TaskStatusMonitor.combinedSummary(
            values: [
                TaskStatusSummary(runningCount: 1, legacyHealth: .healthy),
                TaskStatusSummary(recentlyCompletedCount: 1, legacyHealth: .healthy,
                                  legacyCompletionIDs: ["multi-completion"]),
                localUnknown
            ],
            readFailureCount: 0,
            discoveryFailed: false,
            lastSuccessfulCheck: checkedAt
        )
        check(multi.runningCount == 1 && multi.recentlyCompletedCount == 1
              && multi.unknownCount == 1 && multi.legacyCompletionIDs == ["multi-completion"],
              "Multi-task aggregation preserves confirmed facts and internal diagnostics")
        check(multi.badge == "1 ✓" && TaskStatusAppearance(multi) == .running,
              "Running stays primary when completion and internal uncertainty coexist")

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
