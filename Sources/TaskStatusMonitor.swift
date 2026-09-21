import Foundation
import SQLite3
import CryptoKit

/// Bounded, incremental reader. Never persists or publishes conversation contents.
struct TaskLogCursor {
    static let readLimit = 256 * 1024
    static let runningStaleInterval: TimeInterval = 30 * 60
    var offset: UInt64 = 0
    var pending = Data()
    var identity: UInt64?
    var phase: String?
    var turnID: String?
    var eventDate: Date?
    var activityDate: Date?
    var fileModifiedAt: Date?
    var observedLiveChange = false
    var completionFeedbackEligible = false
    private let formatter = ISO8601DateFormatter()

    mutating func read(_ url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        let reset = identity != inode || size < offset
        let hadBaseline = identity != nil && !reset
        if reset { self = TaskLogCursor(); identity = inode }
        fileModifiedAt = attrs[.modificationDate] as? Date
        guard size > offset else { return }
        if hadBaseline || fileModifiedAt.map({ Date().timeIntervalSince($0) < Self.runningStaleInterval }) == true {
            observedLiveChange = true
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let skipped = size - offset > UInt64(Self.readLimit)
        if skipped {
            offset = size - UInt64(Self.readLimit)
            pending.removeAll()
            phase = nil; turnID = nil; eventDate = nil; activityDate = nil
        }
        try handle.seek(toOffset: offset)
        let bytes = try handle.read(upToCount: Self.readLimit) ?? Data()
        offset += UInt64(bytes.count)
        consume(bytes, discardFirstLine: skipped, allowsCompletionFeedback: hadBaseline)
    }

    mutating func consume(
        _ bytes: Data,
        discardFirstLine: Bool = false,
        allowsCompletionFeedback: Bool = true
    ) {
        pending.append(bytes)
        var discard = discardFirstLine
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end])
            pending.removeSubrange(...end)
            if discard { discard = false; continue }
            guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  root["type"] as? String == "event_msg",
                  let payload = root["payload"] as? [String: Any],
                  let type = payload["type"] as? String,
                  let timestamp = root["timestamp"] as? String else { continue }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var date = formatter.date(from: timestamp)
            if date == nil {
                formatter.formatOptions = [.withInternetDateTime]
                date = formatter.date(from: timestamp)
            }
            guard let date else { continue }
            let id = payload["turn_id"] as? String
            if type == "task_started" {
                guard activityDate.map({ date >= $0 }) ?? true else { continue }
                activityDate = date
                phase = "running"; turnID = id; eventDate = date
                completionFeedbackEligible = false
            } else if type == "task_complete" || type == "turn_aborted" {
                if let turnID, let id, turnID != id { continue }
                guard activityDate.map({ date >= $0 }) ?? true else { continue }
                activityDate = date
                phase = type == "task_complete" ? "complete" : "idle"
                eventDate = date
                completionFeedbackEligible = type == "task_complete" && allowsCompletionFeedback
            } else if type == "item_completed" || type == "token_count" {
                let startsDifferentTurn: Bool
                if phase != nil, phase != "running", let id, let turnID {
                    startsDifferentTurn = id != turnID
                } else {
                    startsDifferentTurn = false
                }
                guard phase == nil || phase == "running" || startsDifferentTurn else { continue }
                guard activityDate.map({ date >= $0 }) ?? true else { continue }
                // Large rollouts can push task_started outside the bounded tail.
                // Fresh durable work events still prove that this turn was active.
                activityDate = date
                phase = "running"; turnID = id ?? turnID; eventDate = date
                completionFeedbackEligible = false
            }
        }
        // A malformed/huge single record must not grow memory without bound.
        if pending.count > Self.readLimit { pending.removeAll(); phase = nil }
    }

    func summary(now: Date) -> TaskStatusSummary {
        if phase == "running", let activityDate,
           now.timeIntervalSince(activityDate) >= -5,
           now.timeIntervalSince(activityDate) < Self.runningStaleInterval {
            return TaskStatusSummary(runningCount: 1, legacyHealth: .healthy)
        }
        if phase == "complete", let eventDate,
           now.timeIntervalSince(eventDate) >= -5 {
            return now.timeIntervalSince(eventDate) < 30
                ? TaskStatusSummary(recentlyCompletedCount: 1, legacyHealth: .healthy) : TaskStatusSummary(legacyHealth: .healthy)
        }
        if phase == "idle" { return TaskStatusSummary(legacyHealth: .healthy) }
        let reason: LegacyTaskDiagnosticReason = phase == "running" ? .staleWithoutTerminal : .missingLifecycleEvidence
        let diagnostics = LegacyTaskDiagnostics(
            unknownCount: 1,
            staleCount: phase == "running" ? 1 : 0,
            reasons: [reason]
        )
        return TaskStatusSummary(unknownCount: 1, legacyHealth: .healthy, legacyDiagnostics: diagnostics)
    }

    /// Old unobserved history is outside the live indicator's scope, not proof of idle.
    func monitoredSummary(now: Date) -> TaskStatusSummary {
        guard observedLiveChange || fileModifiedAt.map({ now.timeIntervalSince($0) < Self.runningStaleInterval }) == true else {
            return TaskStatusSummary(legacyHealth: .healthy)
        }
        return summary(now: now)
    }

    func completionID(for path: String, now: Date) -> String? {
        guard completionFeedbackEligible, phase == "complete", summary(now: now).recentlyCompletedCount > 0,
              let eventDate else { return nil }
        let terminalIdentity = turnID.map { "turn:\($0)" } ?? "event:\(eventDate.timeIntervalSince1970)"
        let value = path + "\u{0}" + terminalIdentity
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

final class TaskStatusMonitor {
    var onUpdate: ((TaskStatusSummary) -> Void)?
    private let queue = DispatchQueue(label: "GPTTouchBarHUD.task-status", qos: .utility)
    private let home: URL
    private var timer: DispatchSourceTimer?
    private var cursors: [String: TaskLogCursor] = [:]
    private var nextDiscovery = Date.distantPast
    private var previous: TaskStatusSummary?
    private var discoveryFailed = false
    private var lastSuccessfulCheck: Date?
    // Accessed on main only, suppresses queued callbacks after stop/restart.
    private var generation = 0

    init(home: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"]
                        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)) {
        self.home = home
    }

    func start() {
        stop()
        let currentGeneration = generation
        queue.async { [weak self] in
            guard let self else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.poll(generation: currentGeneration) }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        generation += 1
        queue.async { [weak self] in
            self?.timer?.cancel(); self?.timer = nil
            self?.cursors.removeAll(); self?.previous = nil
            self?.nextDiscovery = .distantPast
            self?.discoveryFailed = false
            self?.lastSuccessfulCheck = nil
        }
    }

    private func poll(generation: Int) {
        let now = Date()
        if now >= nextDiscovery {
            let discovered = recentPaths()
            discoveryFailed = discovered == nil
            if let paths = discovered {
                cursors = Dictionary(uniqueKeysWithValues: paths.map { ($0, cursors[$0] ?? TaskLogCursor()) })
            }
            nextDiscovery = now.addingTimeInterval(10)
        }
        var values: [TaskStatusSummary] = []
        var readFailureCount = 0
        for path in Array(cursors.keys) {
            do { try cursors[path]?.read(URL(fileURLWithPath: path)) }
            catch {
                readFailureCount += 1
                continue
            }
            var value = cursors[path]!.monitoredSummary(now: now)
            if let id = cursors[path]!.completionID(for: path, now: now) {
                value.legacyCompletionIDs.insert(id)
            }
            values.append(value)
        }
        let hasSuccessfulPoll = !discoveryFailed && (cursors.isEmpty || !values.isEmpty)
        if hasSuccessfulPoll { lastSuccessfulCheck = Self.minuteBucket(now) }
        let result = Self.combinedSummary(
            values: values,
            readFailureCount: readFailureCount,
            discoveryFailed: discoveryFailed,
            lastSuccessfulCheck: lastSuccessfulCheck
        )
        guard result != previous else { return }
        previous = result
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.onUpdate?(result)
        }
    }

    static func combinedSummary(
        values: [TaskStatusSummary],
        readFailureCount: Int,
        discoveryFailed: Bool,
        lastSuccessfulCheck: Date?
    ) -> TaskStatusSummary {
        var result = TaskStatusSummary(legacyHealth: .healthy)
        var diagnostics = LegacyTaskDiagnostics(lastSuccessfulCheck: lastSuccessfulCheck)
        for value in values {
            result.runningCount += value.runningCount
            result.recentlyCompletedCount += value.recentlyCompletedCount
            result.unknownCount += value.unknownCount
            result.legacyCompletionIDs.formUnion(value.legacyCompletionIDs)
            if let source = value.legacyDiagnostics {
                diagnostics.unknownCount += source.unknownCount
                diagnostics.readFailureCount += source.readFailureCount
                diagnostics.staleCount += source.staleCount
                diagnostics.reasons.formUnion(source.reasons)
            }
        }
        if readFailureCount > 0 {
            result.unknownCount += readFailureCount
            diagnostics.unknownCount += readFailureCount
            diagnostics.readFailureCount += readFailureCount
            diagnostics.reasons.insert(.readFailure)
        }
        if discoveryFailed {
            result.legacyHealth = .unavailable(.discoveryFailure)
            diagnostics.reasons.insert(.discoveryFailure)
        } else if readFailureCount > 0 && values.isEmpty {
            result.legacyHealth = .unavailable(.allCandidatesUnreadable)
            diagnostics.reasons.insert(.allCandidatesUnreadable)
        }
        result.legacyDiagnostics = diagnostics
        return result
    }

    private static func minuteBucket(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    private func recentPaths() -> [String]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(home.appendingPathComponent("state_5.sqlite").path, &db,
                             SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT rollout_path FROM threads WHERE archived=0 ORDER BY updated_at DESC LIMIT 32", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var paths: [String] = []
        let root = home.resolvingSymlinksInPath().path + "/sessions/"
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(statement) }
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let path = URL(fileURLWithPath: String(cString: raw)).resolvingSymlinksInPath().path
            if path.hasPrefix(root), path.hasSuffix(".jsonl") { paths.append(path) }
        }
        guard step == SQLITE_DONE else { return nil }
        return Array(Set(paths))
    }
}
