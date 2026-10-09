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
        // Lifecycle and reader assertions now run against TaskActivityEngine and the
        // real asynchronous adapters in JournalReaderTests / ReliabilityEngineTests /
        // TaskReliabilityIntegrationTests; the retired tail cursor is not a test oracle.
        var display = RateLimitDisplayState.initial
        display.taskStatus = TaskStatusSummary()
        check(display.displayedTaskStatus == nil, "Idle restores original presentation")
        display.taskStatus = TaskStatusSummary(unknownCount: 1)
        check(display.displayedTaskStatus == nil, "Legacy uncertainty remains neutral")
        check(TaskStatusSummary(runningCount: 12).badge == "9+", "Badge width bounded")
        check(NotchTaskPresentation(TaskStatusSummary(runningCount: 12)).badge == "12", "Notch preserves full count")
        // Production path checks intentionally reject symlinked ancestors such as /var.
        let directory = URL(fileURLWithPath: "/private/tmp/task-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

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
        try (Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"root-1\",\"source\":\"vscode\"}}\n".utf8) + event("task_started", stamp)).write(to: rollout)
        var db: OpaquePointer?
        check(sqlite3_open(directory.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK, "Fixture database opens")
        let childRollout = sessions.appendingPathComponent("child.jsonl")
        try (Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"child-1\",\"source\":{\"subagent\":{}}}}\n".utf8) + event("task_started", stamp)).write(to: childRollout)
        check(sqlite3_exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, archived INTEGER, updated_at INTEGER, source TEXT); INSERT INTO threads VALUES ('root-1', '\(rollout.path)', 0, 1, 'vscode'); INSERT INTO threads VALUES ('child-1', '\(childRollout.path)', 0, 2, '{\"subagent\":{}}');", nil, nil, nil) == SQLITE_OK, "Fixture index created")
        sqlite3_close(db)
        let monitor = TaskStatusMonitor(home: directory)
        var updates: [TaskStatusSummary] = []
        monitor.onUpdate = { updates.append($0) }
        monitor.start()
        let deadline = Date(timeIntervalSinceNow: 3)
        while (updates.last?.unknownCount != 1 || updates.last?.legacyHealth != .healthy) && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        check(updates.last?.runningCount == 0 && updates.last?.unknownCount == 1, "Historical root starts are unknown and child sessions are excluded")
        let liveHandle = try FileHandle(forWritingTo: rollout)
        try liveHandle.seekToEnd()
        let liveFormatter = ISO8601DateFormatter(); liveFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try liveHandle.write(contentsOf: event("task_started", liveFormatter.string(from: Date()), id: "live-root"))
        try liveHandle.close()
        let liveDeadline = Date(timeIntervalSinceNow: 4)
        while updates.last?.runningCount != 1 && Date() < liveDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        check(updates.last?.runningCount == 1, "Live root start is counted once with a child in the index")
        monitor.stop()
        let count = updates.count
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        check(updates.count == count, "Stop suppresses updates")

        let healthEngine = TaskActivityEngine(home: directory)
        let healthNow = Date()
        healthEngine.begin(now: healthNow, generation: 1)
        _ = healthEngine.poll(now: healthNow, generation: 1)
        let unavailableRollout = sessions.appendingPathComponent("temporarily-unavailable.jsonl")
        try FileManager.default.moveItem(at: rollout, to: unavailableRollout)
        let failedRead = TaskStatusMonitor.summary(healthEngine.poll(now: healthNow + 1, generation: 1))
        check(failedRead.legacyHealth == .unavailable(.allCandidatesUnreadable)
              && failedRead.legacyDiagnostics?.reasons.contains(.allCandidatesUnreadable) == true,
              "The actual engine's all-unreadable state survives the ordinary adapter")
        check(failedRead.isIdle && failedRead.badge.isEmpty && !failedRead.detail.contains("读取失败"),
              "Read failure health remains internal to ordinary presentation")
        try FileManager.default.moveItem(at: unavailableRollout, to: rollout)
        let healthyRead = TaskStatusMonitor.summary(healthEngine.poll(now: healthNow + 2, generation: 1))
        check(healthyRead.legacyHealth == .healthy, "Successful continuity validation clears overall read failure")
        healthEngine.reconcile(now: healthNow + 3, generation: 2, reason: .sleep)
        let sleeping = TaskStatusMonitor.summary(healthEngine.poll(now: healthNow + 3, generation: 2))
        check(sleeping.legacyHealth == .unavailable(.suspended) && sleeping.isIdle,
              "Sleep preserves internal source health and neutral presentation")
        healthEngine.reconcile(now: healthNow + 4, generation: 3, reason: .hostUnavailable)
        let absentHost = TaskStatusMonitor.summary(healthEngine.poll(now: healthNow + 4, generation: 3))
        check(absentHost.legacyHealth == .unavailable(.hostUnavailable),
              "Host loss cannot be mapped back to healthy by the ordinary adapter")

        if CommandLine.arguments.contains("--live-smoke") {
            let live = TaskStatusMonitor()
            var publications = 0
            live.onUpdate = { _ in publications += 1 }
            let startCPU = clock()
            live.start()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 15))
            live.stop()
            print("Live metadata-monitor sample: 15s, CPU \(Double(clock() - startCPU) / Double(CLOCKS_PER_SEC))s, \(publications) status publications; no conversation output")
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
