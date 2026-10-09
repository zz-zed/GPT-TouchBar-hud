import Foundation

// These values are ephemeral production observations, deliberately not Codable.
// Task/turn identities and paths must be anonymized before crossing a storage boundary.
public enum HookTaskReadReason: String, Sendable {
    case normal, initialBaseline, fileReset, readBudgetSkip, discardedHalfLine, pendingLineCleared
    case sourceExcluded, sourceUnsupported, pathRejected, malformedHeader, malformedLine, invalidEventMetadata, readFailed
}
public struct HookTaskReadObservation: Sendable {
    public let task: TaskIdentity
    public let path: URL
    public var fileGeneration: UInt64 = 0
    public var fileSize: UInt64?
    public var offsetBefore: UInt64?
    public var offsetAfter: UInt64?
    /// Physical bytes read, including repeated header validation; headerBytesRead is a subset.
    public var bytesRead: Int = 0
    public var headerBytesRead: Int = 0
    public var skippedBytes: UInt64 = 0
    public var backlogBytes: UInt64?
    public var pendingBefore: Int?
    public var pendingAfter: Int?
    /// Bytes removed from a carried partial line or discarded first tail line, including its newline.
    public var discardedPartialBytes: Int = 0
    public var reasons: Set<HookTaskReadReason> = []
}
public enum HookTaskDecisionReason: String, Sendable {
    case acceptedStart, acceptedExecution, acceptedComplete, acceptedAbort, historicalStart
    case excludedSource, olderPosition, duplicatePosition, settledTerminal
    case oldTimestamp, historicalBaseline, missingStart, terminalActivity, staleActivity
    case submissionHint, stopHint, interruptHint, missingTurnHint, terminalHintIgnored
    case invalidProtocol, fileReset, readBudgetSkip, readFailure, sleep, hostUnavailable, restart
    case verificationExpired, staleEvidence, capacityRemoved, sourceRemoved, supersededHint
}
public struct HookTaskDecisionObservation: Sendable {
    public let identity: TurnIdentity
    public let kind: EvidenceKind?
    public let phaseBefore: TaskPhase?
    public let phaseAfter: TaskPhase?
    public let accepted: Bool
    public let reason: HookTaskDecisionReason
    public let countedBefore: Bool
    public let countedAfter: Bool
    public let position: UInt64?
}
public enum HookTaskInventoryReason: String, Sendable {
    case discovered, sourceExcluded, cursorCapacity, forgotten, reset, evidenceCapacity
}
public struct HookTaskInventoryObservation: Sendable {
    public let task: TaskIdentity
    public let reason: HookTaskInventoryReason
    public let added: Bool
    public let inventoryCount: Int
    public let inventoryLimit: Int
}
public enum HookTaskQuery: String, Sendable { case target, recentRecovery }
public struct HookTaskDiscoveryObservation: Sendable {
    public let query: HookTaskQuery
    public let queryLimit: Int
    public let inventoryLimit: Int
    public let returnedRows: Int?
    public let validRows: Int?
    public let queryComplete: Bool
    /// A limited SQL query cannot prove desktop-wide candidate coverage, even below the limit.
    public let coverageLimited: Bool
}
public struct HookTaskVisibleTurn: Equatable, Sendable {
    public let identity: TurnIdentity
    public let phase: TaskPhase
    public let visible: Bool
}
public struct HookTaskMember: Equatable, Sendable {
    public let task: TaskIdentity
    public let turns: [HookTaskVisibleTurn]
    public let selectedTurn: TurnIdentity?
    /// Multiple unordered hints may be visible; these are exactly the visible turns satisfying the production count predicate.
    public let countedTurns: [TurnIdentity]
    public let counted: Bool
    public let unknown: Bool
    public let submitted: Bool
    public let completed: Bool
}
public struct HookTaskMemberSnapshot: Equatable, Sendable {
    public let members: [HookTaskMember]
    public let runningCount: Int
    public let unknownCount: Int
    public let submittedCount: Int
    public let completedCount: Int
    public let gaps: Set<CoverageGap>
    public let inventoryLimit: Int
}
public enum HookTaskTraceObservation: Sendable {
    case read(HookTaskReadObservation)
    case decision(HookTaskDecisionObservation)
    case inventory(HookTaskInventoryObservation)
    case discovery(HookTaskDiscoveryObservation)
}
public struct HookTaskTraceBatch: Sendable {
    public let generation: UInt64
    public let traceEpoch: UInt64
    public let sequence: UInt64
    public let observations: [HookTaskTraceObservation]
    public let observationsDropped: Int
    public let members: HookTaskMemberSnapshot
    public let activity: TaskActivitySnapshot
    public let businessDelivery: Bool
}
