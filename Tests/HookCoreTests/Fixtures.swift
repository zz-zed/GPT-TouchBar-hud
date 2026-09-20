import Foundation
import Darwin
import SQLite3
import Testing
@testable import HookCore

final class Fixture {
    let root = URL(fileURLWithPath: "/private/tmp/hud-hooks-\(UUID().uuidString)", isDirectory: true)
    var home: URL { root.appendingPathComponent("codex") }
    var ipc: URL { root.appendingPathComponent("ipc") }
    let now = Date()
    init() throws {
        try HookPaths.ensurePrivateDirectory(root)
        try HookPaths.ensurePrivateDirectory(home)
        try HookPaths.ensurePrivateDirectory(home.appendingPathComponent("sessions"))
        try HookPaths.ensurePrivateDirectory(ipc)
        try sql("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, source TEXT, archived INT DEFAULT 0, updated_at INT)")
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func sql(_ value: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK else { throw HookFailure.io }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, value, nil, nil, nil) == SQLITE_OK else { throw HookFailure.io }
    }
    func log(_ session: String = "s1", source: String = "vscode", records: [(String, String)] = []) throws -> URL {
        let url = home.appendingPathComponent("sessions/\(session).jsonl")
        let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": session, "source": "vscode"]]) + Data([10])
        try HookPaths.atomicWrite(header, to: url)
        try sql("INSERT INTO threads(id,rollout_path,source,updated_at) VALUES('\(session)','\(url.path)','\(source)',\(Int(now.timeIntervalSince1970)))")
        for (kind, turn) in records { try append(kind, turn: turn, to: url) }
        return url
    }
    func append(_ kind: String, turn: String = "t1", to url: URL, date: Date? = nil) throws {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": formatter.string(from: date ?? now), "payload": ["type": kind, "turn_id": turn]]) + Data([10])
        try appendData(data, to: url)
    }
    func appendData(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
}
