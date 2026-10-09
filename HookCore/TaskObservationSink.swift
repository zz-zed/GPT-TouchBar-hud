import Foundation

public enum TaskSourceMode: String, Codable, Sendable { case legacy, hooks }
public enum TaskSourceCapability: String, Codable, Sendable { case continuousLogsOnly, verifiedHost }
public enum TaskInventoryCoverage: String, Codable, Sendable { case partial, complete, unavailable, capacityLimited, malformedRows }
public enum TaskEvidenceFreshness: String, Codable, Sendable { case current, catchingUp, pendingReconciliation, unavailable }
public enum TaskObservationReason: String, Codable, Sendable {
    case liveStart, historicalStart, matchingTerminal, matchingInterrupt, lateOrDuplicate
    case weakEventIgnored, turnMismatch, invalidTimestamp, malformedRecord, fileReset
    case restoredPending, hostUnavailable, suspended, resumed, excludedSubagent, unsupportedSource
    case missingLog, invalidPath, identityMismatch, readFailed, checkpointFailed, checkpointInvalid
    case budgetBacklog, hintOnly, staleGeneration, disabled, capacity, staleEvidence, aliasRetired, aliasCapacity, continuityRevalidated, malformedIndex
}
public enum TaskReconciliationReason: String, Codable, Sendable { case reconnect, wake, hostRestart, monitoringEnabled, sleep, hostUnavailable, resume }

/// No identifier, path, title, body, or usage value is admitted by this diagnostic boundary.
public struct TaskReadObservation: Equatable, Sendable {
    public let alias: UInt64
    public let fileGeneration: UInt64
    public let before: UInt64
    public let fetched: UInt64
    public let committed: UInt64
    public let target: UInt64
    public let bytesRead: Int
    public let backlogBytes: UInt64
}
public enum TaskObservationDeliveryStage: String, Codable, Sendable { case runtime, coordinator }
public enum TaskObservationSurface: String, Codable, Sendable { case menuBar, floatingHUD, touchBar, notch }
public enum TaskObservationDisplayAction: String, Codable, Sendable { case consumed, renderRequested, hidden, notLoaded, unavailable, disabled }
public enum TaskObservation: Sendable {
    case members(sequence: UInt64, generation: UInt64, mode: TaskSourceMode, aliases: [UInt64], pageIndex: Int, pageCount: Int, memberCount: Int)
    case surface(sequence: UInt64, generation: UInt64, surface: TaskObservationSurface, action: TaskObservationDisplayAction, running: Int, pending: Int, completionVisible: Bool, mode: TaskSourceMode)
    case read(sequence: UInt64, generation: UInt64, mode: TaskSourceMode, boundary: TaskReadObservation)
    case transition(sequence: UInt64, generation: UInt64, alias: UInt64, mode: TaskSourceMode,
                    before: TaskPhase, after: TaskPhase, reason: TaskObservationReason)
    case excluded(sequence: UInt64, generation: UInt64, alias: UInt64, mode: TaskSourceMode, reason: TaskObservationReason)
    case inventory(sequence: UInt64, generation: UInt64, coverage: TaskInventoryCoverage, discovered: Int, retained: Int)
    case snapshot(sequence: UInt64, generation: UInt64, mode: TaskSourceMode, running: Int, pending: Int,
                  freshness: TaskEvidenceFreshness, coverage: TaskInventoryCoverage, backlogBytes: UInt64)
    case issue(sequence: UInt64, generation: UInt64, alias: UInt64?, reason: TaskObservationReason)
    case delivery(sequence: UInt64, generation: UInt64, accepted: Bool, stage: TaskObservationDeliveryStage = .runtime)
    case presentation(sequence: UInt64, generation: UInt64, running: Int, pending: Int, completionVisible: Bool, sourceMode: TaskSourceMode)
}

/// Called from the engine worker and display queue. Implementations must be thread safe,
/// bounded, and nonblocking; the engine does not own diagnostic persistence or export.
public protocol TaskObservationSink: AnyObject { func record(_ event: TaskObservation) }

/// Shared across engine instances and mode switches for unambiguous process-local joins.
public enum TaskObservationSequence {
    private static let lock = NSLock()
    private static var nextValue: UInt64 = 0
    public static func next() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        nextValue &+= 1
        return nextValue
    }
}

/// Explicit admission boundary. No sidecar or log heuristic implements host truth.
public protocol TaskHostStateSource: AnyObject {
    var capability: TaskSourceCapability { get }
    var isSameHostVerified: Bool { get }
}
public final class UnavailableTaskHostStateSource: TaskHostStateSource {
    public init() {}
    public var capability: TaskSourceCapability { .continuousLogsOnly }
    public var isSameHostVerified: Bool { false }
}

/// Process-only identity registry. Raw keys never cross TaskObservationSink and are
/// never serialized. Active engine inventories pin their entries during LRU eviction.
public enum TaskObservationAliases {
    private struct Key: Hashable { let home: String; let identity: TaskIdentity }
    private struct Entry { let alias: UInt64; var used: UInt64 }
    private static let lock = NSLock()
    private static var entries: [Key: Entry] = [:]
    private static var scopes: [UInt64: Set<Key>] = [:]
    private static var protectedCounts: [Key: Int] = [:]
    private static var clock: UInt64 = 0
    public static let capacity = 8192

    static func protect(scope: UInt64, home: URL, identities: Set<TaskIdentity>) {
        lock.lock(); defer { lock.unlock() }
        let desired = Set(identities.map { Key(home: home.path, identity: $0) })
        let old = scopes[scope] ?? []
        for key in old.subtracting(desired) {
            if let count = protectedCounts[key], count > 1 { protectedCounts[key] = count - 1 }
            else { protectedCounts.removeValue(forKey: key) }
        }
        for key in desired.subtracting(old) { protectedCounts[key, default: 0] += 1 }
        if desired.isEmpty { scopes.removeValue(forKey: scope) } else { scopes[scope] = desired }
    }
    static func release(scope: UInt64) {
        lock.lock(); defer { lock.unlock() }
        for key in scopes.removeValue(forKey: scope) ?? [] {
            if let count = protectedCounts[key], count > 1 { protectedCounts[key] = count - 1 }
            else { protectedCounts.removeValue(forKey: key) }
        }
    }
    static func lookup(home: URL, identity: TaskIdentity) -> (alias: UInt64, retired: UInt64?, overflow: Bool) {
        lock.lock(); defer { lock.unlock() }
        clock &+= 1
        let key = Key(home: home.path, identity: identity)
        if var entry = entries[key] {
            entry.used = clock; entries[key] = entry
            return (entry.alias, nil, false)
        }
        var retired: UInt64?
        if entries.count >= capacity {
            if let oldest = entries.filter({ protectedCounts[$0.key] == nil }).min(by: { $0.value.used < $1.value.used }) {
                retired = oldest.value.alias; entries.removeValue(forKey: oldest.key)
            }
        }
        let alias = TaskObservationSequence.next()
        guard entries.count < capacity else { return (alias, nil, true) }
        entries[key] = Entry(alias: alias, used: clock)
        return (alias, retired, false)
    }
}
