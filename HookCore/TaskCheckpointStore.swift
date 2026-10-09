import Foundation
import Darwin

public struct TaskEngineRecord: Codable, Equatable, Sendable {
    public let identity: TaskIdentity
    public var turnID: String?
    public var phase: TaskPhase = .unknown
    public var lastKnownPhase: TaskPhase = .unknown
    public var evidenceAt: Date?
    public var startsAtEvidenceTime: Set<String> = []
    public var retiredTurnIDs: Set<String> = []
    public var orderingCapacityLimited = false
    public var hasUnresolvedGap = false
    public var firstPosition: UInt64?
    public var lastPosition: UInt64?
    public var terminalAt: Date?
    public var confirmedGeneration: UInt64?
    public var fileGeneration: UInt64 = 0
    public var freshness: TaskEvidenceFreshness = .pendingReconciliation
    public init(identity: TaskIdentity) { self.identity = identity }
    public var isRunning: Bool { phase == .active }
    public var isPending: Bool { [.unknown, .submitted, .stopping].contains(phase) }
}

struct TaskCheckpointEntry: Codable {
    var inventory: TaskInventoryEntry
    var journal: JournalCheckpoint?
    var published: TaskEngineRecord
    var candidate: TaskEngineRecord
    var targetEOF: UInt64?
}
struct TaskEngineCheckpoint: Codable {
    var schema = 1
    var savedAt: Date
    var entries: [TaskCheckpointEntry]
    var completionIDs: [String: Date]
}

/// Internal identity metadata only; this is deliberately not a diagnostic export format.
/// State and committed record boundaries are encoded into one atomic replacement.
public final class TaskCheckpointStore {
    public let url: URL
    public static let maximumBytes = 8 * 1024 * 1024
    public static let maximumEntries = 8192
    public init(url: URL) { self.url = url }
    func load() throws -> TaskEngineCheckpoint {
        let data = try HookPaths.read(url, maximum: Self.maximumBytes, privateOnly: true)
        let value = try JSONDecoder().decode(TaskEngineCheckpoint.self, from: data)
        guard value.schema == 1, value.entries.count <= Self.maximumEntries, value.completionIDs.count <= 4096 else { throw HookFailure.malformed }
        var identities: Set<TaskIdentity> = []
        for entry in value.entries {
            guard HookEvent.validID(entry.inventory.identity.session), entry.inventory.identity.source == "codexLocal",
                  entry.published.identity == entry.inventory.identity, entry.candidate.identity == entry.inventory.identity,
                  entry.published.turnID.map(HookEvent.validID) ?? true,
                  entry.candidate.turnID.map(HookEvent.validID) ?? true,
                  identities.insert(entry.inventory.identity).inserted,
                  valid(entry.published, journal: entry.journal), valid(entry.candidate, journal: entry.journal) else { throw HookFailure.malformed }
            if let journal = entry.journal {
                guard entry.inventory.path.path == journal.path,
                      entry.targetEOF.map({ $0 >= journal.committedOffset && $0 <= journal.observedLength }) ?? true else { throw HookFailure.malformed }
            } else if entry.targetEOF != nil { throw HookFailure.malformed }
        }
        return value
    }
    private func valid(_ record: TaskEngineRecord, journal: JournalCheckpoint?) -> Bool {
        if let journal {
            guard record.lastPosition.map({ $0 <= journal.committedOffset }) ?? true,
                  record.fileGeneration == 0 || record.fileGeneration == journal.generation else { return false }
        } else {
            guard record.phase == .unknown, record.confirmedGeneration == nil,
                  record.firstPosition == nil, record.lastPosition == nil, record.fileGeneration == 0 else { return false }
        }
        guard record.firstPosition.map({ $0 <= (record.lastPosition ?? 0) }) ?? true,
              record.startsAtEvidenceTime.count <= 64, record.startsAtEvidenceTime.allSatisfy(HookEvent.validID),
              record.retiredTurnIDs.count <= 512, record.retiredTurnIDs.allSatisfy(HookEvent.validID),
              record.evidenceAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { return false }
        return true
    }
    /// Conservative upper bound before JSONEncoder allocates its output. Every source
    /// byte can expand to at most six JSON bytes (\u00XX); fixed allowances cover all
    /// keys, punctuation, numeric/date values and optional fields in schema 1.
    @discardableResult
    static func validateEncodingBudget(_ checkpoint: TaskEngineCheckpoint) throws -> Int {
        guard checkpoint.schema == 1, checkpoint.entries.count <= maximumEntries, checkpoint.completionIDs.count <= 4096 else { throw HookFailure.budget }
        var budget = EncodingBudget(remaining: maximumBytes)
        try budget.fixed(1024)
        for entry in checkpoint.entries {
            try budget.fixed(2048)
            try budget.identity(entry.inventory.identity)
            try budget.string(entry.inventory.path.absoluteString)
            try budget.string(entry.inventory.source)
            if let journal = entry.journal {
                try budget.string(journal.path)
                for anchor in [journal.prefixAnchor, journal.boundaryAnchor] {
                    try budget.string(anchor.sha256)
                }
                if let anchor = journal.sessionAnchor { try budget.string(anchor.sha256) }
                if let session = journal.verifiedSession {
                    try budget.string(session.id)
                    if let source = session.source { try budget.string(source) }
                }
            }
            try budget.record(entry.published)
            try budget.record(entry.candidate)
        }
        for key in checkpoint.completionIDs.keys {
            try budget.fixed(64)
            try budget.string(key)
        }
        return maximumBytes - budget.remaining
    }
    private struct EncodingBudget {
        var remaining: Int
        mutating func fixed(_ amount: Int) throws {
            guard amount >= 0, amount <= remaining else { throw HookFailure.budget }
            remaining -= amount
        }
        mutating func string(_ value: String) throws {
            let count = value.utf8.count
            // Check using division and subtraction so multiplication cannot overflow.
            guard remaining >= 2, count <= (remaining - 2) / 6 else { throw HookFailure.budget }
            remaining -= count * 6 + 2
        }
        mutating func identity(_ value: TaskIdentity) throws {
            try string(value.source); try string(value.session)
        }
        mutating func record(_ value: TaskEngineRecord) throws {
            guard value.startsAtEvidenceTime.count <= 64, value.retiredTurnIDs.count <= 512 else { throw HookFailure.budget }
            try fixed(1024); try identity(value.identity)
            if let turn = value.turnID { try string(turn) }
            for turn in value.startsAtEvidenceTime { try fixed(1); try string(turn) }
            for turn in value.retiredTurnIDs { try fixed(1); try string(turn) }
        }
    }
    func save(_ checkpoint: TaskEngineCheckpoint) throws {
        try Self.validateEncodingBudget(checkpoint)
        let data = try JSONEncoder().encode(checkpoint)
        guard data.count <= Self.maximumBytes else { throw HookFailure.budget }
        try HookPaths.ensurePrivateDirectory(url.deletingLastPathComponent())
        try HookPaths.atomicWrite(data, to: url)
        // fsync of the containing directory makes the rename durable across a power loss.
        let directory = try HookPaths.openDirectory(url.deletingLastPathComponent(), privateOnly: true)
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw HookFailure.io }
    }
}
