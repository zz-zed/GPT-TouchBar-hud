import Foundation

/// A diagnostic side channel. Equality intentionally excludes observation metadata.
struct DiagnosticTaskDisplayContext: Equatable {
    var reference: DiagnosticTaskSnapshotReference? = nil
    var tasksEnabled = true
    var presentationRevision: UInt64 = 0
    var reason: DiagnosticTaskConsumptionReason = .update
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension TaskStatusSummary {
    var diagnosticPresentation: DiagnosticTaskPresentation {
        if hasRunningTasks { return .running }
        if activityPresentation?.state == .completed || (activity == nil && legacyCompletionFeedbackVisible) {
            return .completedFeedback
        }
        if activityPresentation?.state == .unknown || activityPresentation?.state == .submitted { return .unknown }
        return .neutral
    }
}

/// One instance per actual consumer; no view creation, file lookup, or rendering here.
final class DiagnosticTaskDisplayObserver {
    private let recorder: DiagnosticRecording
    private let surface: DiagnosticTaskTraceSurface
    private let consumer: DiagnosticTaskTraceConsumer
    private struct Observation: Equatable {
        let reference: DiagnosticTaskSnapshotReference
        let consumption: DiagnosticTaskConsumption
    }
    // At most the four action kinds, never an unbounded snapshot-ID history.
    private var previous: [DiagnosticTaskConsumptionAction: Observation] = [:]

    init(_ recorder: DiagnosticRecording, surface: DiagnosticTaskTraceSurface, consumer: DiagnosticTaskTraceConsumer) {
        self.recorder = recorder; self.surface = surface; self.consumer = consumer
    }

    func record(_ state: RateLimitDisplayState, action: DiagnosticTaskConsumptionAction,
                reason: DiagnosticTaskConsumptionReason? = nil, compact: DiagnosticTaskCompactRule? = nil,
                presentation: DiagnosticTaskPresentation? = nil) {
        let gate = recorder.taskTraceState
        guard gate.enabled, let reference = state.taskTrace.reference ?? state.taskStatus?.diagnosticSnapshot,
              reference.recordingGeneration == gate.generation, reference.recordingSessionID == gate.sessionID
        else { previous.removeAll(keepingCapacity: true); return }
        let presentation: DiagnosticTaskPresentation = state.taskTrace.tasksEnabled
            ? (presentation ?? state.taskStatus?.diagnosticPresentation ?? .neutral) : .disabled
        let rule = compact ?? (state.displayedTaskStatus == nil ? .hidden
            : (state.displayedTaskStatus?.badge.contains("9+") == true ? .ninePlus : .exact))
        let actualCount = state.taskStatus?.activity?.confirmedRunningCount ?? state.taskStatus?.runningCount ?? 0
        let mismatch = state.taskTrace.tasksEnabled && actualCount != reference.runningCount
        let observation = DiagnosticTaskConsumption(surface: surface, action: action,
            logicalTaskCount: actualCount, presentation: presentation, compactRule: rule,
            reason: mismatch ? .snapshotMismatch : (reason ?? state.taskTrace.reason), presentationRevision: state.taskTrace.presentationRevision,
            consumer: consumer)
        let next = Observation(reference: reference, consumption: observation)
        guard previous[action] != next else { return }
        previous[action] = next
        recorder.record(.taskTrace(.consumption(reference: reference, observation: observation)),
                        expectedGeneration: reference.recordingGeneration)
    }
}
