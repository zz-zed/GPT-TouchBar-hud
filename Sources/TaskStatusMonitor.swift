import Foundation
import HookCore

/// Ordinary presentation adapter over the same production runtime used by Hooks.
final class TaskStatusMonitor {
    var onUpdate: ((TaskStatusSummary) -> Void)?
    var onSnapshot: ((TaskEngineSnapshot) -> Void)?
    private let runtime: TaskEngineController
    init(home: URL = TaskEngineController.defaultHome, checkpointURL: URL? = nil,
         sink: TaskObservationSink = TaskObservationRelay.shared) {
        runtime = TaskEngineController(home: home, mode: .legacy, checkpointURL: checkpointURL, sink: sink)
        runtime.onUpdate = { [weak self] snapshot in
            self?.onSnapshot?(snapshot)
            self?.onUpdate?(Self.summary(snapshot))
        }
    }
    func start() { runtime.start() }
    func stop() { runtime.stop() }
    func suspend() { runtime.suspend() }
    func resume() { runtime.resume() }
    func hostUnavailable() { runtime.hostUnavailable() }

    static func summary(_ snapshot: TaskEngineSnapshot) -> TaskStatusSummary {
        let activity = snapshot.activity
        var diagnostics = LegacyTaskDiagnostics(unknownCount: activity.pendingVerificationCount,
            readFailureCount: snapshot.readFailureCount, lastSuccessfulCheck: snapshot.lastSuccessfulCheck)
        if activity.pendingVerificationCount > 0 { diagnostics.reasons.insert(.missingLifecycleEvidence) }
        if snapshot.readFailureCount > 0 { diagnostics.reasons.insert(.readFailure) }
        if snapshot.discoveryFailed { diagnostics.reasons.insert(.discoveryFailure) }
        let sourceStates = Set(activity.sourceHealth.map(\.state))
        let health: LegacyTaskMonitoringHealth
        if sourceStates.contains(.suspended) {
            health = .unavailable(.suspended)
        } else if sourceStates.contains(.unavailable) || sourceStates.contains(.disabled) {
            health = .unavailable(.hostUnavailable)
        } else if snapshot.discoveryFailed {
            health = .unavailable(.discoveryFailure)
        } else if snapshot.readFailureCount > 0 && snapshot.readFailureCount >= snapshot.records.count {
            health = .unavailable(.allCandidatesUnreadable)
        } else if sourceStates.contains(.awaitingEvents) {
            health = .unavailable(.starting)
        } else {
            health = .healthy
        }
        if let reason = health.reason { diagnostics.reasons.insert(reason) }
        return TaskStatusSummary(snapshotSequence: snapshot.sequence,
            observationGeneration: snapshot.generation,
            runningCount: activity.confirmedRunningCount,
            recentlyCompletedCount: activity.recentlyCompletedCount,
            unknownCount: activity.pendingVerificationCount,
            legacyHealth: health,
            legacyDiagnostics: diagnostics,
            legacyCompletionIDs: Set(activity.recentCompletions.map { $0.id }))
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

}
