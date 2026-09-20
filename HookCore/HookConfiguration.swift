import Foundation
import Darwin
import CryptoKit

public struct HookConfigurationPlan {
    public let target: URL
    public let original: Data?
    public let proposed: Data
    public let ownedCommand: String
    public let removing: Bool
    public var reviewText: String {
        "Scope: \(target.path)\nHelper: \(ownedCommand)\nEvents: UserPromptSubmit, Stop, Interrupt, SessionEnd\nTimeout: 1 second; synchronous; neutral {} output.\n\n" + (String(data: proposed, encoding: .utf8) ?? "")
    }
}

/// Planning is read-only; apply is an explicit user action. Never reads or writes trust records.
public enum HookConfiguration {
    public static let ownerArgument = "--owner=gpt-touchbar-hud-v1"
    public static let maximumBytes = 1024 * 1024
    public static func command(helper: URL, socket: URL) throws -> String {
        guard helper.path.hasPrefix("/"), socket.path.hasPrefix("/"), helper.path.utf8.count <= 1024,
              socket.path.utf8.count < 104, !helper.path.contains("\n"), !socket.path.contains("\n"),
              !helper.path.utf8.contains(0), !socket.path.utf8.contains(0) else { throw HookFailure.unsafePath }
        return [helper.path, "emit", ownerArgument, "--socket", socket.path].map(quote).joined(separator: " ")
    }
    public static func plan(target: URL, helper: URL, socket: URL, removing: Bool = false) throws -> HookConfigurationPlan {
        let parent = try HookPaths.openDirectory(target.deletingLastPathComponent()); close(parent)
        let original = try readOptional(target)
        let command = try command(helper: helper, socket: socket)
        var root: [String: Any] = [:]
        if let original {
            guard let decoded = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw HookFailure.malformed }
            root = decoded
        }
        if let hooks = root["hooks"], !(hooks is [String: Any]) { throw HookFailure.malformed }
        var events = root["hooks"] as? [String: Any] ?? [:]
        let definition: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 1]]]
        for event in HookEventKind.allCases {
            if let value = events[event.rawValue], !(value is [[String: Any]]) { throw HookFailure.malformed }
            var entries = events[event.rawValue] as? [[String: Any]] ?? []
            // Modified definitions remain user-owned. Never infer ownership from a command substring.
            let exact = entries.indices.filter { NSDictionary(dictionary: entries[$0]).isEqual(to: definition) }
            if removing {
                entries = entries.enumerated().filter { !exact.contains($0.offset) }.map(\.element)
            } else if exact.isEmpty {
                if entries.contains(where: { entry in
                    (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(ownerArgument) == true }
                }) { throw HookFailure.changed }
                entries.append(definition)
            }
            if entries.isEmpty { events.removeValue(forKey: event.rawValue) } else { events[event.rawValue] = entries }
        }
        root["hooks"] = events
        let proposed = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard proposed.count <= maximumBytes else { throw HookFailure.budget }
        return HookConfigurationPlan(target: target, original: original, proposed: proposed, ownedCommand: command, removing: removing)
    }
    /// Returns the byte-verified backup, when the target already existed. Rejects stale review plans.
    @discardableResult public static func apply(_ plan: HookConfigurationPlan) throws -> URL? {
        guard try readOptional(plan.target) == plan.original else { throw HookFailure.changed }
        var backup: URL?
        if let data = plan.original {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let url = plan.target.deletingLastPathComponent().appendingPathComponent(plan.target.lastPathComponent + ".gpt-hud-" + formatter.string(from: Date()) + "-" + UUID().uuidString + ".backup")
            try HookPaths.atomicWrite(data, to: url)
            guard try HookPaths.read(url, maximum: maximumBytes, privateOnly: true) == data else { throw HookFailure.io }
            backup = url
        }
        guard try readOptional(plan.target) == plan.original else { throw HookFailure.changed }
        try HookPaths.atomicWrite(plan.proposed, to: plan.target)
        let readback = try HookPaths.read(plan.target, maximum: maximumBytes, privateOnly: true)
        guard readback == plan.proposed, (try JSONSerialization.jsonObject(with: readback)) is [String: Any] else { throw HookFailure.io }
        return backup
    }
    public static func rollback(_ plan: HookConfigurationPlan, backup: URL) throws {
        // Do not overwrite concurrent user changes, and do not delete a newly-created user file.
        guard try readOptional(plan.target) == plan.proposed,
              let original = plan.original, try HookPaths.read(backup, maximum: maximumBytes, privateOnly: true) == original else { throw HookFailure.changed }
        try HookPaths.atomicWrite(original, to: plan.target)
        guard try readOptional(plan.target) == original else { throw HookFailure.io }
    }
    private static func readOptional(_ url: URL) throws -> Data? {
        let parent = try HookPaths.openDirectory(url.deletingLastPathComponent()); defer { close(parent) }
        var info = stat()
        if fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw HookFailure.io
        }
        return try HookPaths.read(url, maximum: maximumBytes)
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
