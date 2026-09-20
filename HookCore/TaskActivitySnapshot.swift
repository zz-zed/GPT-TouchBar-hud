import Foundation

public enum CoverageGap: String, Codable, Sendable, CaseIterable {
    case initialCoverageUnknown, capacity, recoveryBudget, truncatedLog, missingLog, invalidPath
    case malformedLog, rotatedLog, orderingConflict, disconnected, restart, sleep, staleEvidence, protocolError
}

public struct TaskCoverage: Equatable, Codable, Sendable {
    public var scope: String
    public var gaps: Set<CoverageGap>
    public var isComplete: Bool { gaps.isEmpty }
    public init(scope: String = "localConnectedSessions", gaps: Set<CoverageGap> = [.initialCoverageUnknown]) {
        self.scope = scope; self.gaps = gaps
    }
}

public enum HookHealthState: String, Codable, Sendable {
    case disabled, awaitingEvents, connected, degraded, unavailable, suspended
}

public struct HookSourceHealth: Equatable, Codable, Sendable {
    public var source: String
    public var state: HookHealthState
    public var lastReceipt: Date?
    public init(source: String = "codexLocal", state: HookHealthState = .disabled, lastReceipt: Date? = nil) {
        self.source = source; self.state = state; self.lastReceipt = lastReceipt
    }
}

public struct TaskCompletion: Equatable, Codable, Sendable {
    public let id: String
    public let occurredAt: Date
    public init(identity: TurnIdentity, occurredAt: Date) {
        self.id = identity.task.source + ":" + identity.task.session + ":" + identity.turn + ":" + String(occurredAt.timeIntervalSince1970)
        self.occurredAt = occurredAt
    }
}

/// Only reducer facts cross this boundary. No conversation text, paths, or mutable state.
public struct TaskActivitySnapshot: Equatable, Codable, Sendable {
    public var confirmedRunningCount: Int
    public var pendingVerificationCount: Int
    public var submittedCount: Int
    public var recentlyCompletedCount: Int
    public var recentCompletions: [TaskCompletion] = []
    public var coverage: TaskCoverage
    public var sourceHealth: [HookSourceHealth]
    public var updatedAt: Date

    public init(confirmedRunningCount: Int = 0, pendingVerificationCount: Int = 0,
                submittedCount: Int = 0, recentlyCompletedCount: Int = 0,
                coverage: TaskCoverage = TaskCoverage(), sourceHealth: [HookSourceHealth] = [], updatedAt: Date = Date()) {
        self.confirmedRunningCount = confirmedRunningCount; self.pendingVerificationCount = pendingVerificationCount
        self.submittedCount = submittedCount; self.recentlyCompletedCount = recentlyCompletedCount
        self.coverage = coverage; self.sourceHealth = sourceHealth; self.updatedAt = updatedAt
    }
    public var hasUncertainty: Bool { pendingVerificationCount > 0 || !coverage.isComplete }
    public var compactText: String {
        if confirmedRunningCount > 0 { return "\(confirmedRunningCount)" + (hasUncertainty ? " ?" : "") }
        if submittedCount > 0 && submittedCount == pendingVerificationCount { return "…" }
        if hasUncertainty { return "—" }
        return recentlyCompletedCount > 0 ? "✓" : "0"
    }
    public var showsCompletion: Bool { confirmedRunningCount == 0 && !hasUncertainty && recentlyCompletedCount > 0 }
}
