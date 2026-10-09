import Foundation
import Darwin
import SQLite3

public struct TaskInventoryEntry: Codable, Equatable, Sendable {
    public let identity: TaskIdentity
    public var path: URL
    public var updatedAt: Int64
    public var source: String
    public var isSubagent: Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any] else { return false }
        return object["subagent"] != nil
    }
    public var isSupported: Bool { ["cli", "exec", "vscode"].contains(source) }
}
public struct TaskInventoryResult {
    public var entries: [TaskInventoryEntry] = []
    public var coverage: TaskInventoryCoverage = .partial
    public var failed = false
    public var completedTraversal = false
    public var evicted: Set<TaskIdentity> = []
    public var malformedRowCount = 0
}

/// Worker confined. ID-keyset traversal is independent of mutable updated_at ordering.
/// An overlapping recent traversal accelerates discovery; it never defines completeness.
public final class TaskInventory {
    public let home: URL
    public let pageSize: Int
    public let capacity: Int
    public private(set) var entries: [TaskIdentity: TaskInventoryEntry] = [:]
    public private(set) var hasCompletedTraversal = false
    private struct PageKey {
        let rowID: Int64
        let isNullID: Bool
        let updatedAt: Int64
        let idType: Int32
        let idPrefix: Data
    }
    private struct Page {
        var entries: [TaskInventoryEntry] = []
        var rawRowsCount = 0
        var lastKey: PageKey?
        var rawKeys: [PageKey] = []
        var validRowIDs: Set<Int64> = []
        var malformedRowIDs: Set<Int64> = []
    }
    private var fullCursor: PageKey?
    private var fullUpper: PageKey?
    private var quarantinedRows: Set<Int64> = []
    private var quarantineOverflow = false
    private var traversalMalformedRows: Set<Int64> = []
    private var traversalMalformedOverflow = false
    private var fullInProgress = false
    private var nextFullScan = Date.distantPast
    private var recentCursor: PageKey?
    private var recentLower: Int64 = 0
    private var recentUpper: Int64 = 0
    private var recentInProgress = false
    private var lastRecentUpper: Int64 = 0
    private var hints: Set<String> = []
    private var capacityLimited = false
    private var queryDeadline: TimeInterval = 0

    public init(home: URL, pageSize: Int = 32, capacity: Int = 8192) {
        self.home = home; self.pageSize = max(1, pageSize); self.capacity = max(pageSize, capacity)
    }
    public func hint(_ task: TaskIdentity) { if task.source == "codexLocal", HookEvent.validID(task.session) {
        if hints.count < capacity { hints.insert(task.session) } else { capacityLimited = true }
    } }
    public func restore(_ saved: [TaskInventoryEntry]) {
        for entry in saved.prefix(capacity) where entry.identity.source == "codexLocal" && HookEvent.validID(entry.identity.session) {
            entries[entry.identity] = entry
        }
    }
    public func requestFullReconciliation() { nextFullScan = .distantPast }

    public func discover(now: Date, evictable: Set<TaskIdentity> = [], timeBudget: TimeInterval = 0.05, cancelled: () -> Bool = { false }) -> TaskInventoryResult {
        var result = TaskInventoryResult()
        var found: [TaskInventoryEntry] = []
        queryDeadline = ProcessInfo.processInfo.systemUptime + max(0.001, timeBudget)
        guard !cancelled() else { result.coverage = .partial; return result }
        do {
            if !fullInProgress, now >= nextFullScan {
                let upper = try query("SELECT id, rollout_path, source, updated_at, rowid FROM threads WHERE archived=0 ORDER BY id DESC,rowid DESC LIMIT 1")
                observe(upper)
                fullUpper = upper.lastKey
                fullCursor = nil; fullInProgress = true; capacityLimited = false
                traversalMalformedRows.removeAll(); traversalMalformedOverflow = false
            }
            if fullInProgress, !cancelled() {
                var page = Page()
                if let upper = fullUpper {
                    // Keep oversized/invalid IDs inside SQLite. The rowid references the
                    // raw boundary value without copying arbitrary strings into memory.
                    let boundaries = [upper.rowID] + (fullCursor.map { [$0.rowID] } ?? [])
                    let placeholders = Array(repeating: "?", count: boundaries.count).joined(separator: ",")
                    let present = try query("SELECT id, rollout_path, source, updated_at, rowid FROM threads WHERE rowid IN (\(placeholders))", numbers: boundaries)
                    let expectedKeys = [upper] + (fullCursor.map { [$0] } ?? [])
                    let unchanged = expectedKeys.allSatisfy { expected in
                        present.rawKeys.contains { current in current.rowID == expected.rowID
                            && current.idType == expected.idType && current.idPrefix == expected.idPrefix }
                    }
                    guard present.rawRowsCount == Set(boundaries).count && unchanged else {
                        fullInProgress = false; hasCompletedTraversal = false; nextFullScan = .distantPast
                        throw HookFailure.changed
                    }
                    var sql = "SELECT id, rollout_path, source, updated_at, rowid FROM threads WHERE archived=0 AND "
                    var bounds: [Int64] = []
                    if upper.isNullID {
                        sql += "id IS NULL AND rowid<=?"; bounds.append(upper.rowID)
                    } else {
                        sql += "(id IS NULL OR id<=(SELECT id FROM threads WHERE rowid=?))"; bounds.append(upper.rowID)
                    }
                    if let cursor = fullCursor {
                        if cursor.isNullID {
                            sql += " AND (id IS NOT NULL OR rowid>?)"; bounds.append(cursor.rowID)
                        } else {
                            sql += " AND id>(SELECT id FROM threads WHERE rowid=?)"; bounds.append(cursor.rowID)
                        }
                    }
                    sql += " ORDER BY id ASC,rowid ASC LIMIT ?"
                    page = try query(sql, numbers: bounds, limit: pageSize)
                }
                found += page.entries; observe(page)
                retainMalformed(page.malformedRowIDs, in: &traversalMalformedRows, overflow: &traversalMalformedOverflow)
                fullCursor = page.lastKey ?? fullCursor
                if page.rawRowsCount < pageSize || fullCursor?.rowID == fullUpper?.rowID {
                    fullInProgress = false; hasCompletedTraversal = true; result.completedTraversal = true
                    quarantinedRows = traversalMalformedRows; quarantineOverflow = traversalMalformedOverflow
                    nextFullScan = now.addingTimeInterval(30)
                }
            }
            if !recentInProgress {
                recentUpper = Int64(now.timeIntervalSince1970) + 5
                recentLower = max(lastRecentUpper - 60, Int64(now.timeIntervalSince1970) - 120)
                recentCursor = nil; recentInProgress = true
            }
            if !cancelled(), ProcessInfo.processInfo.systemUptime < queryDeadline {
                var sql = "SELECT id, rollout_path, source, updated_at, rowid FROM threads WHERE archived=0 AND updated_at>=? AND updated_at<=?"
                var numbers = [recentLower, recentUpper]
                if let cursor = recentCursor {
                    // rowid provides the tie break; no malformed ID can stall recent discovery.
                    sql += " AND (updated_at<? OR (updated_at=? AND rowid<?))"
                    numbers += [cursor.updatedAt, cursor.updatedAt, cursor.rowID]
                }
                sql += " ORDER BY updated_at DESC,rowid DESC LIMIT ?"
                let page = try query(sql, numbers: numbers, limit: pageSize)
                found += page.entries; observe(page)
                recentCursor = page.lastKey ?? recentCursor
                if page.rawRowsCount < pageSize { recentInProgress = false; lastRecentUpper = recentUpper }
            }
            if !hints.isEmpty, !cancelled(), ProcessInfo.processInfo.systemUptime < queryDeadline {
                let ids = Array(hints.sorted().prefix(pageSize))
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                let page = try query("SELECT id, rollout_path, source, updated_at, rowid FROM threads WHERE id IN (\(placeholders))", texts: ids)
                found += page.entries; observe(page)
                for entry in page.entries { hints.remove(entry.identity.session) }
            }
        } catch { result.failed = true }
        // Commit each successfully fetched page even if a subsequent query failed. The
        // keyset cursor must never advance beyond rows absent from retained inventory.
        var changed: [TaskIdentity: TaskInventoryEntry] = [:]
        for entry in found {
            if entry.isSubagent || !entry.isSupported {
                entries.removeValue(forKey: entry.identity)
                changed[entry.identity] = entry
                continue
            }
            if entries[entry.identity] == nil && entries.count >= capacity {
                let oldest = entries.values.filter { evictable.contains($0.identity) }
                    .min { $0.updatedAt < $1.updatedAt }
                if let oldest {
                    entries.removeValue(forKey: oldest.identity); changed.removeValue(forKey: oldest.identity)
                    result.evicted.insert(oldest.identity)
                } else { capacityLimited = true; continue }
            }
            entries[entry.identity] = entry; changed[entry.identity] = entry
        }
        result.entries = changed.values.sorted { $0.identity.session < $1.identity.session }
        result.malformedRowCount = quarantinedRows.count + (quarantineOverflow ? 1 : 0)
        result.coverage = result.failed ? .unavailable : (capacityLimited ? .capacityLimited
            : (!hasCompletedTraversal ? .partial : (result.malformedRowCount > 0 ? .malformedRows : .complete)))
        return result
    }

    private func query(_ sql: String, numbers: [Int64] = [], texts: [String] = [], limit: Int? = nil) throws -> Page {
        guard ProcessInfo.processInfo.systemUptime < queryDeadline else { throw HookFailure.budget }
        let url = home.appendingPathComponent("state_5.sqlite")
        let fd = try HookPaths.openRegular(url); defer { close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0 else { throw HookFailure.io }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw HookFailure.io
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, Int32(max(1, min(25, (queryDeadline - ProcessInfo.processInfo.systemUptime) * 1000))))
        var deadline = queryDeadline
        return try withUnsafeMutablePointer(to: &deadline) { pointer in
            sqlite3_progress_handler(db, 1000, { context in
                guard let context else { return 1 }
                return ProcessInfo.processInfo.systemUptime > context.assumingMemoryBound(to: TimeInterval.self).pointee ? 1 : 0
            }, pointer)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw HookFailure.io }
            defer { sqlite3_finalize(statement) }
            var binding: Int32 = 1
            for number in numbers { sqlite3_bind_int64(statement, binding, number); binding += 1 }
            for text in texts {
                _ = text.withCString { sqlite3_bind_text(statement, binding, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }; binding += 1
            }
            if let limit { sqlite3_bind_int(statement, binding, Int32(limit)) }
            var page = Page()
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                let rowID = sqlite3_column_int64(statement, 4)
                page.rawRowsCount += 1
                let idType = sqlite3_column_type(statement, 0)
                // Valid IDs contain at most 160 ASCII bytes. A 161-byte raw prefix
                // detects every mutation that can change ordering relative to a valid ID,
                // without retaining arbitrarily large malformed boundary strings.
                let rawID: UnsafeRawPointer?
                if idType == SQLITE_TEXT { rawID = sqlite3_column_text(statement, 0).map(UnsafeRawPointer.init) }
                else { rawID = sqlite3_column_blob(statement, 0) }
                let prefix = rawID.map { Data(bytes: $0, count: min(161, Int(sqlite3_column_bytes(statement, 0)))) } ?? Data()
                let key = PageKey(rowID: rowID, isNullID: idType == SQLITE_NULL,
                    updatedAt: sqlite3_column_int64(statement, 3), idType: idType, idPrefix: prefix)
                page.lastKey = key; page.rawKeys.append(key)
                if idType == SQLITE_TEXT, let session = text(statement, column: 0, maximum: 160), HookEvent.validID(session),
                   let path = text(statement, column: 1, maximum: 4096), !path.isEmpty,
                   let source = text(statement, column: 2, maximum: 4096), !source.isEmpty,
                   sqlite3_column_type(statement, 3) == SQLITE_INTEGER {
                    page.entries.append(TaskInventoryEntry(identity: TaskIdentity(session: session), path: URL(fileURLWithPath: path),
                        updatedAt: sqlite3_column_int64(statement, 3), source: source))
                    page.validRowIDs.insert(rowID)
                } else { page.malformedRowIDs.insert(rowID) }
                step = sqlite3_step(statement)
            }
            guard step == SQLITE_DONE else { throw HookFailure.io }
            let afterFD = try HookPaths.openRegular(url); defer { close(afterFD) }
            var after = stat()
            guard fstat(afterFD, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino else { throw HookFailure.changed }
            return page
        }
    }
    private func text(_ statement: OpaquePointer?, column: Int32, maximum: Int) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= maximum, let bytes = sqlite3_column_text(statement, column) else { return nil }
        let data = Data(bytes: bytes, count: count)
        guard !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func observe(_ page: Page) {
        quarantinedRows.subtract(page.validRowIDs)
        retainMalformed(page.malformedRowIDs, in: &quarantinedRows, overflow: &quarantineOverflow)
    }
    private func retainMalformed(_ additions: Set<Int64>, in rows: inout Set<Int64>, overflow: inout Bool) {
        for row in additions {
            if rows.count < capacity { rows.insert(row) }
            else if !rows.contains(row) { overflow = true }
        }
    }

}
