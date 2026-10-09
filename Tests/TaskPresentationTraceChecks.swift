import AppKit
import SQLite3
import HookCore

private final class PresentationTraceRecorder: TaskObservationSink {
    private let lock = NSLock()
    private var events: [TaskObservation] = []
    func record(_ event: TaskObservation) { lock.lock(); events.append(event); lock.unlock() }
    func captured() -> [TaskObservation] { lock.lock(); defer { lock.unlock() }; return events }
}

/// The input snapshot comes from the production engine reading a private SQLite/log
/// fixture; all four observations are emitted by actual UI consumers, not a test shim.
enum TaskPresentationTraceChecks {
    static func run() throws {
        let home = URL(fileURLWithPath: "/private/tmp/hud-presentation-\(UUID().uuidString)")
        try HookPaths.ensurePrivateDirectory(home)
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent("sessions")
        try HookPaths.ensurePrivateDirectory(sessions)
        let file = sessions.appendingPathComponent("fixture.jsonl")
        let header = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"presentation-fixture\",\"source\":\"vscode\"}}\n".utf8)
        try header.write(to: file)
        var db: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK else { throw HookFailure.io }
        let sql = "CREATE TABLE threads(id TEXT PRIMARY KEY,rollout_path TEXT,source TEXT,archived INTEGER,updated_at INTEGER); INSERT INTO threads VALUES('presentation-fixture','\(file.path)','vscode',0,1);"
        let code = sqlite3_exec(db, sql, nil, nil, nil); sqlite3_close(db)
        guard code == SQLITE_OK else { throw HookFailure.io }
        let sink = PresentationTraceRecorder()
        TaskObservationRelay.shared.connect(sink)
        defer { TaskObservationRelay.shared.connect(nil) }
        let engine = TaskActivityEngine(home: home, sink: TaskObservationRelay.shared)
        let now = Date()
        engine.begin(now: now, generation: 12)
        _ = engine.poll(now: now, generation: 12)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": formatter.string(from: now.addingTimeInterval(0.01)),
            "payload": ["type": "task_started", "turn_id": "presentation-turn"]]) + Data([10])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
        let snapshot = engine.poll(now: now.addingTimeInterval(0.02), generation: 12)
        NotchHUDTests.check(snapshot.runningIDs == [TaskIdentity(session: "presentation-fixture")], "Trace fixture is independently expected to contain exactly one running task")
        var state = RateLimitDisplayState.initial
        state.taskStatus = TaskStatusMonitor.summary(snapshot)
        let defaultsName = "task-presentation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.register(defaults: [ResetNewsMonitor.enabledPreferenceKey: false, QuotaAlertMonitor.enabledPreferenceKey: false])
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let news = ResetNewsMonitor(repository: ResetNewsRepository(directory: home.appendingPathComponent("news")), defaults: defaults)
        let menu = AppDelegate(resetNewsMonitor: news, quotaAlerts: QuotaAlertMonitor(defaults: defaults))
        menu.updateStatusTitle(with: state)
        let touch = TouchBarRateLimitsView()
        touch.update(with: state)
        let floating = CompactHUDViewController(initialAppearance: HUDAppearance.load(), onRefresh: {}, onClose: {}, onPresentTouchBar: { false }, contextMenuProvider: { NSMenu() })
        _ = floating.view
        floating.update(with: state)
        let notch = NotchHUDController()
        notch.update(state)
        var observed: Set<TaskObservationSurface> = []
        for event in sink.captured() {
            guard case let .surface(sequence, generation, surface, _, running, _, _, mode) = event,
                  sequence == snapshot.sequence else { continue }
            NotchHUDTests.check(generation == 12 && running == 1 && mode == .legacy, "Every consumer keeps the production snapshot and logical count")
            observed.insert(surface)
        }
        NotchHUDTests.check(observed == [.menuBar, .floatingHUD, .touchBar, .notch], "All four actual consumers observe the same engine snapshot")
        NotchHUDTests.check(state.taskStatus?.badge == "1" && !(state.taskStatus?.detail.contains("?") ?? true), "Internal trace does not add ordinary-mode uncertainty decoration")
    }
}
