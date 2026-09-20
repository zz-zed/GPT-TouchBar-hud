import Foundation
import Darwin
import SQLite3

public struct EvidenceReport {
    public var evidence: [TaskEvidence] = []
    public var gaps: Set<CoverageGap> = []
    public var excluded: Set<TaskIdentity> = []
    public var resetTasks: Set<TaskIdentity> = []
    public var files: [TaskIdentity: URL] = [:]
    public var bytesRead = 0
    public var filesRead = 0
}

/// Worker-confined reader; lookup only the requested session except once at recovery.
public final class TaskEvidenceResolver {
    private struct Cursor {
        var inode: ino_t
        var offset: UInt64 = 0
        var pending = Data()
        var pendingStart: UInt64 = 0
        var discardLine = false
        var changedAt: Date
        var latest: [String: TaskEvidence] = [:]
        var path: URL
    }
    private struct Row { let task: TaskIdentity; let url: URL; let source: String }
    public let home: URL
    private var cursors: [TaskIdentity: Cursor] = [:]
    private let formatter = ISO8601DateFormatter()
    public init(home: URL) { self.home = home }
    var retainedEvidenceCount: Int { cursors.values.reduce(0) { $0 + $1.latest.count } }
    public var observedFiles: [TaskIdentity: URL] { cursors.mapValues(\.path) }
    public func forget(_ task: TaskIdentity) { cursors.removeValue(forKey: task) }
    public func reset() { cursors.removeAll() }

    /// Initial history can establish terminal facts, but never a live running claim.
    public func recover(tasks: [TaskIdentity], now: Date) -> EvidenceReport {
        var report = EvidenceReport()
        var rows: [Row] = []
        do {
            for task in tasks.prefix(HookBudget.recoveryFiles) {
                if let row = try lookup(task: task, now: now).first { rows.append(row) }
                else { report.gaps.insert(.missingLog) }
            }
            // A bounded initial candidate inventory; it does not establish desktop-wide coverage.
            if rows.count < HookBudget.recoveryFiles {
                for row in try lookup(task: nil, now: now) where !rows.contains(where: { $0.task == row.task }) {
                    rows.append(row)
                    if rows.count > HookBudget.recoveryFiles { break }
                }
            }
        } catch { report.gaps.insert(.missingLog) }
        if rows.count >= HookBudget.recoveryFiles || tasks.count > HookBudget.recoveryFiles { report.gaps.insert(.recoveryBudget) }
        for row in rows.prefix(HookBudget.recoveryFiles) {
            merge(read(row, now: now, liveSince: nil), into: &report)
        }
        return report
    }
    public func resolve(task: TaskIdentity, now: Date, liveSince: Date?) -> EvidenceReport {
        do {
            guard let row = try lookup(task: task, now: now).first else { var result = EvidenceReport(); result.gaps.insert(.missingLog); return result }
            return read(row, now: now, liveSince: liveSince)
        } catch { var result = EvidenceReport(); result.gaps.insert(.invalidPath); return result }
    }
    private func lookup(task: TaskIdentity?, now: Date) throws -> [Row] {
        if let task { guard task.source == "codexLocal", HookEvent.validID(task.session) else { throw HookFailure.malformed } }
        let url = home.appendingPathComponent("state_5.sqlite")
        let verified = try HookPaths.openRegular(url); defer { close(verified) }
        var before = stat(); guard fstat(verified, &before) == 0 else { throw HookFailure.io }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw HookFailure.io
        }
        defer { sqlite3_close(db) }
        // No model data selected, no writes/extension loading; cap lock waits and VM execution.
        sqlite3_busy_timeout(db, 50)
        var deadline = ProcessInfo.processInfo.systemUptime + 0.1
        return try withUnsafeMutablePointer(to: &deadline) { limit in
            sqlite3_progress_handler(db, 1000, { context in
                guard let context else { return 1 }
                return ProcessInfo.processInfo.systemUptime > context.assumingMemoryBound(to: TimeInterval.self).pointee ? 1 : 0
            }, limit)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            var statement: OpaquePointer?
            let query = task == nil
                ? "SELECT id, rollout_path, source FROM threads WHERE archived=0 AND updated_at >= ? ORDER BY updated_at DESC LIMIT 33"
                : "SELECT id, rollout_path, source FROM threads WHERE id=? LIMIT 1"
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw HookFailure.io }
            defer { sqlite3_finalize(statement) }
            if let task { _ = task.session.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } }
            else { sqlite3_bind_int64(statement, 1, Int64(now.addingTimeInterval(-HookBudget.staleSeconds).timeIntervalSince1970)) }
            var rows: [Row] = []
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                guard (0...2).allSatisfy({ sqlite3_column_bytes(statement, Int32($0)) <= 4096 }),
                      let id = sqlite3_column_text(statement, 0), let path = sqlite3_column_text(statement, 1),
                      let source = sqlite3_column_text(statement, 2) else { throw HookFailure.budget }
                let session = String(cString: id)
                guard HookEvent.validID(session) else { throw HookFailure.malformed }
                rows.append(Row(task: TaskIdentity(session: session), url: URL(fileURLWithPath: String(cString: path)), source: String(cString: source)))
                step = sqlite3_step(statement)
            }
            guard step == SQLITE_DONE else { throw HookFailure.io }
            let afterFD = try HookPaths.openRegular(url); defer { close(afterFD) }
            var after = stat(); guard fstat(afterFD, &after) == 0, after.st_ino == before.st_ino, after.st_dev == before.st_dev else { throw HookFailure.changed }
            return rows
        }
    }
    private func read(_ row: Row, now: Date, liveSince: Date?) -> EvidenceReport {
        var report = EvidenceReport()
        if let source = try? JSONSerialization.jsonObject(with: Data(row.source.utf8)) as? [String: Any], source["subagent"] != nil {
            report.excluded.insert(row.task); return report
        }
        guard ["cli", "exec", "vscode"].contains(row.source) else { report.gaps.insert(.orderingConflict); return report }
        do {
            let roots = ["sessions", "archived_sessions"].map { home.appendingPathComponent($0).path + "/" }
            guard roots.contains(where: { row.url.path.hasPrefix($0) }), row.url.path.hasSuffix(".jsonl") else { throw HookFailure.unsafePath }
            let fd = try HookPaths.openRegular(row.url); defer { close(fd) }
            var info = stat(); guard fstat(fd, &info) == 0, info.st_size >= 0 else { throw HookFailure.io }
            var cursor = cursors[row.task]
            let hadCursor = cursor != nil
            let reset = cursor.map { $0.inode != info.st_ino || UInt64(info.st_size) < $0.offset || $0.path != row.url } ?? true
            if reset {
                // Verify the indexed file's session identity before accepting any tail evidence.
                var head = [UInt8](repeating: 0, count: 8192)
                let count = pread(fd, &head, head.count, 0)
                guard count >= 0 else { throw HookFailure.io }
                report.bytesRead += count
                guard let end = head.prefix(count).firstIndex(of: 10),
                      let object = try? JSONSerialization.jsonObject(with: Data(head[..<end])) as? [String: Any],
                      object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any],
                      payload["id"] as? String == row.task.session else { throw HookFailure.malformed }
                if let source = payload["source"] as? [String: Any], source["subagent"] != nil { report.excluded.insert(row.task); return report }
                cursor = Cursor(inode: info.st_ino, changedAt: now, path: row.url)
                if hadCursor { report.gaps.insert(.rotatedLog); report.resetTasks.insert(row.task) }
            }
            guard var current = cursor else { throw HookFailure.io }
            let size = UInt64(info.st_size)
            let remaining = HookBudget.readBytes - report.bytesRead
            if size - current.offset > UInt64(remaining) {
                current.offset = size - UInt64(remaining)
                current.pending.removeAll(); current.latest.removeAll(); current.discardLine = true
                current.pendingStart = current.offset
                report.gaps.insert(.truncatedLog); report.resetTasks.insert(row.task)
            }
            let countToRead = min(remaining, Int(size - current.offset))
            var bytes = [UInt8](repeating: 0, count: countToRead)
            let count = countToRead > 0 ? pread(fd, &bytes, countToRead, off_t(current.offset)) : 0
            guard count >= 0 else { throw HookFailure.io }
            report.filesRead = 1; report.bytesRead += count
            if count > 0 {
                if current.pending.isEmpty { current.pendingStart = current.offset }
                current.offset += UInt64(count); current.changedAt = now
                current.pending.append(contentsOf: bytes.prefix(count))
                var start = current.pending.startIndex
                while let end = current.pending[start...].firstIndex(of: 10) {
                    let absolute = current.pendingStart + UInt64(end - current.pending.startIndex)
                    defer { start = current.pending.index(after: end) }
                    if current.discardLine { current.discardLine = false; continue }
                    let line = Data(current.pending[start..<end])
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        report.gaps.insert(.malformedLog); continue
                    }
                    guard object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any],
                          let type = payload["type"] as? String else { continue }
                    let kinds: [String: EvidenceKind] = ["task_started": .started, "task_complete": .complete, "turn_aborted": .aborted,
                                                         "item_completed": .execution, "token_count": .execution]
                    guard let kind = kinds[type] else { continue }
                    guard let turn = payload["turn_id"] as? String, HookEvent.validID(turn),
                          let timestamp = object["timestamp"] as? String, let date = date(timestamp), date <= now.addingTimeInterval(5) else {
                        report.gaps.insert(.orderingConflict); continue
                    }
                    // Initial reads are live only when correlated to a received submit, not file mtime.
                    let live = (!reset && hadCursor) || liveSince.map { date >= $0 && date <= now.addingTimeInterval(5) } == true
                    let evidence = TaskEvidence(identity: TurnIdentity(task: row.task, turn: turn), kind: kind,
                                                position: absolute, date: date, live: live)
                    report.evidence.append(evidence); current.latest[turn] = evidence
                    if report.evidence.count > HookBudget.turns {
                        report.evidence.removeFirst(); report.gaps.insert(.capacity)
                    }
                    if current.latest.count > HookBudget.turns {
                        if let oldest = current.latest.min(by: { $0.value.position < $1.value.position })?.key { current.latest.removeValue(forKey: oldest) }
                        report.gaps.insert(.capacity)
                    }
                }
                let consumed = start - current.pending.startIndex
                current.pending = Data(current.pending[start...]); current.pendingStart += UInt64(consumed)
                if current.pending.count > HookBudget.readBytes {
                    current.pending.removeAll(); current.discardLine = true; report.gaps.insert(.truncatedLog)
                }
            }
            if current.pending.isEmpty, now.timeIntervalSince(current.changedAt) >= 0.1, size == current.offset {
                for evidence in current.latest.values where evidence.kind == .complete {
                    report.evidence.append(TaskEvidence(identity: evidence.identity, kind: .complete, position: evidence.position,
                                                        date: evidence.date, live: false, settled: true))
                }
            }
            report.files[row.task] = row.url
            cursors[row.task] = current
            if retainedEvidenceCount > HookBudget.turns {
                // This is a retention policy, not a claim of cross-session event order.
                let retained = cursors.flatMap { task, cursor in cursor.latest.map { (task, $0.key, $0.value.date) } }
                    .sorted { $0.2 < $1.2 }
                for (task, turn, _) in retained.prefix(retained.count - HookBudget.turns) { cursors[task]?.latest.removeValue(forKey: turn) }
                report.gaps.insert(.capacity)
            }
            if cursors.count > HookBudget.recoveryFiles {
                if let oldest = cursors.filter({ $0.key != row.task }).min(by: { $0.value.changedAt < $1.value.changedAt })?.key { cursors.removeValue(forKey: oldest) }
                report.gaps.insert(.recoveryBudget)
            }
        } catch HookFailure.malformed { report.gaps.insert(.malformedLog) }
        catch { report.gaps.insert(.invalidPath) }
        return report
    }
    private func date(_ value: String) -> Date? {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value)
    }
    private func merge(_ value: EvidenceReport, into result: inout EvidenceReport) {
        result.evidence += value.evidence; result.gaps.formUnion(value.gaps); result.excluded.formUnion(value.excluded)
        result.resetTasks.formUnion(value.resetTasks); result.files.merge(value.files) { _, rhs in rhs }
        result.bytesRead += value.bytesRead; result.filesRead += value.filesRead
        if result.evidence.count > HookBudget.turns {
            result.evidence.removeFirst(result.evidence.count - HookBudget.turns)
            result.gaps.insert(.capacity)
        }
    }
}
