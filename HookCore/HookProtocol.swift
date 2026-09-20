import Foundation

public enum HookBudget {
    public static let inputBytes = 1024 * 1024
    public static let wireBytes = 4 * 1024
    public static let connections = 16
    public static let turns = 512
    public static let diagnostics = 128
    public static let readBytes = 256 * 1024
    public static let recoveryFiles = 32
    public static let recoveryBytes = 8 * 1024 * 1024
    public static let cacheBytes = 512 * 1024
    public static let connectionSeconds = 0.2
    public static let helperSeconds = 0.5
    public static let verificationSeconds = 5.0
    public static let staleSeconds = 30.0 * 60
}

public enum HookEventKind: String, Codable, CaseIterable, Sendable {
    case submitted = "UserPromptSubmit", stop = "Stop", interrupt = "Interrupt", sessionEnd = "SessionEnd"
}

public struct HookEvent: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var source: String = "codexLocal"
    public let kind: HookEventKind
    public let session: String
    public let turn: String?
    public let continued: Bool
    public init(kind: HookEventKind, session: String, turn: String?, continued: Bool = false) {
        self.kind = kind; self.session = session; self.turn = turn; self.continued = continued
    }
    public var isValid: Bool {
        version == 1 && source == "codexLocal" && Self.validID(session)
        && (kind == .sessionEnd ? turn == nil : turn.map(Self.validID) == true)
    }
    public static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 160 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,58,95].contains($0)
        }
    }
    /// Reject subagent-specific inputs; never forward prompt/reply/tool/cwd/transcript fields.
    public static func sanitize(_ bytes: Data) -> HookEvent? {
        guard bytes.count <= HookBudget.inputBytes,
              let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let name = root["hook_event_name"] as? String, let kind = HookEventKind(rawValue: name),
              let session = root["session_id"] as? String,
              root["agent_id"] == nil, root["agent_transcript_path"] == nil else { return nil }
        let event = HookEvent(kind: kind, session: session, turn: kind == .sessionEnd ? nil : root["turn_id"] as? String,
                              continued: (root["stop_hook_active"] as? Bool) ?? false)
        return event.isValid ? event : nil
    }
}

struct HookAck: Codable {
    let version: Int
    let generation: String
    let sequence: UInt64
}

public struct TaskIdentity: Hashable, Codable, Sendable {
    public let source: String
    public let session: String
    public init(source: String = "codexLocal", session: String) { self.source = source; self.session = session }
}

public struct TurnIdentity: Hashable, Codable, Sendable {
    public let task: TaskIdentity
    public let turn: String
    public init(task: TaskIdentity, turn: String) { self.task = task; self.turn = turn }
}

public enum TaskPhase: String, Codable, Sendable { case submitted, active, stopping, completed, interrupted, unknown }
public enum EvidenceKind: String, Codable, Sendable { case started, execution, complete, aborted }

/// Positions refer only to this session's validated file generation, never a global host sequence.
public struct TaskEvidence: Equatable, Sendable {
    public let identity: TurnIdentity
    public let kind: EvidenceKind
    public let position: UInt64
    public let date: Date
    public let live: Bool
    public let settled: Bool
    public init(identity: TurnIdentity, kind: EvidenceKind, position: UInt64, date: Date, live: Bool, settled: Bool = false) {
        self.identity = identity; self.kind = kind; self.position = position; self.date = date; self.live = live; self.settled = settled
    }
}
