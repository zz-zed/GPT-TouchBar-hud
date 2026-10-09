import Foundation
import HookCore

/// The worker anonymizes facts supplied by HookCore. It never reads files or reduces task state.
final class DiagnosticHookTaskTrace {
    private let recorder: DiagnosticRecording
    private let trace: DiagnosticTaskTrace
    private var state: DiagnosticTaskTraceState?
    private var files: [TaskIdentity: String] = [:]
    private var inventory: Set<TaskIdentity> = []
    private let deliveryLock = NSLock()
    private struct Delivery: Hashable { let generation: UInt64; let sequence: UInt64 }
    private var deliveries: [Delivery: DiagnosticTaskSnapshotReference] = [:]

    init(recorder: DiagnosticRecording) { self.recorder = recorder; trace = DiagnosticTaskTrace(recorder: recorder) }

    func observe(_ batch: HookTaskTraceBatch, monitoringGeneration: UInt64) {
        let gate = recorder.taskTraceState
        guard gate.enabled, batch.traceEpoch == gate.generation else { return }
        if state != gate { files.removeAll(); inventory.removeAll(); state = gate }
        let context = DiagnosticTaskTraceContext(monitoringGeneration: monitoringGeneration, batch: batch.sequence | (1 << 63),
            recordingGeneration: gate.generation, recordingSessionID: gate.sessionID)
        trace.observationGap(context: context, droppedCount: UInt64(max(0, batch.observationsDropped)), reason: .producerBufferLimit)
        for observation in batch.observations {
            switch observation {
            case .read(let value):
                // Bounded to the production inventory; the raw key is never encoded.
                if files.count < 4096 || files[value.task] != nil { files[value.task] = value.path.path + ":" + String(value.fileGeneration) }
                guard let identity = identity(value.task, context: context) else { continue }
                let reasons = value.reasons.isEmpty ? [HookTaskReadReason.normal] : value.reasons.sorted { $0.rawValue < $1.rawValue }
                for reason in reasons {
                    if reason == .normal, value.offsetBefore == value.offsetAfter,
                       value.bytesRead == value.headerBytesRead, value.pendingBefore == value.pendingAfter { continue }
                    var metrics = DiagnosticTaskReadMetrics()
                    metrics.fileBytes = value.fileSize; metrics.offsetBefore = value.offsetBefore; metrics.offsetAfter = value.offsetAfter
                    metrics.readBytes = UInt64(max(0, value.bytesRead)); metrics.headerReadBytes = UInt64(max(0, value.headerBytesRead))
                    metrics.skippedBytes = value.skippedBytes; metrics.backlogBytes = value.backlogBytes
                    metrics.pendingBytesBefore = value.pendingBefore.map { UInt64(max(0, $0)) }
                    metrics.pendingBytes = value.pendingAfter.map { UInt64(max(0, $0)) }
                    metrics.discardedBytes = UInt64(max(0, value.discardedPartialBytes))
                    metrics.stateCleared = reason == .fileReset || reason == .readBudgetSkip
                    switch reason {
                    case .normal: metrics.reason = .normalRead
                    case .initialBaseline: metrics.reason = .initialRead
                    case .fileReset: metrics.reason = .fileReset
                    case .readBudgetSkip: metrics.reason = .readBudgetSkip
                    case .discardedHalfLine: metrics.reason = .firstLineDiscarded
                    case .pendingLineCleared: metrics.reason = .pendingLimitExceeded
                    case .sourceExcluded, .sourceUnsupported, .pathRejected, .malformedHeader: metrics.reason = .fileRejected
                    case .readFailed: metrics.reason = .readFailure
                    case .malformedLine: metrics.reason = .malformedLine
                    case .invalidEventMetadata: metrics.reason = .invalidEventMetadata
                    }
                    trace.read(context: context, identity: identity, metrics: metrics)
                }
            case .decision(let value):
                guard let identity = identity(value.identity.task, turn: value.identity.turn, context: context) else { continue }
                let reason = Self.reason(value.reason)
                trace.lifecycle(context: context, identity: identity,
                    transition: .init(before: Self.phase(value.phaseBefore), after: Self.phase(value.phaseAfter),
                        evidence: Self.evidence(value.kind), accepted: value.accepted, reason: reason))
                let memberReason: DiagnosticTaskMemberReason
                switch reason {
                case .readBudgetSkip: memberReason = .readBudgetSkip
                case .fileReset: memberReason = .fileReset
                case .capacityRemoved: memberReason = .capacityRemoved
                case .sourceRemoved: memberReason = .sourceRemoved
                case .readFailure: memberReason = .readFailure
                case .verificationExpired, .staleEvidence: memberReason = .staleWithoutTerminal
                default: memberReason = .lifecycleChanged
                }
                trace.member(context: context, identity: identity, countedBefore: value.countedBefore,
                    countedAfter: value.countedAfter, reason: memberReason)
            case .inventory(let value):
                guard let identity = identity(value.task, context: context) else { continue }
                if value.added { trace.member(context: context, identity: identity, countedBefore: false, countedAfter: false, reason: .inventoryAdded) }
                // Reducer decision observations carry the real countedBefore/After for removals.
                if !value.added && value.reason != .evidenceCapacity {
                    files.removeValue(forKey: value.task); trace.retire(taskKey: key(value.task), kind: .hookTask, context: context)
                }
            case .discovery(let value):
                trace.discovery(context: context, observation: .init(scope: .hookEvidence, queryLimit: value.queryLimit,
                    returnedRows: value.returnedRows, acceptedRows: value.validRows, rejectedPaths: nil,
                    sourceFilteredRows: nil, traversalComplete: value.queryComplete,
                    coverage: value.coverageLimited ? .limited : .unknown))
            }
        }
        let current = Set(batch.members.members.map(\.task))
        for task in inventory.subtracting(current) { trace.retire(taskKey: key(task), kind: .hookTask, context: context); files.removeValue(forKey: task) }
        inventory = current
        var members: [DiagnosticTaskSnapshotMember] = []
        for member in batch.members.members {
            let selected = member.turns.first { $0.identity == member.selectedTurn }
            guard let identity = identity(member.task, turn: member.selectedTurn?.turn, context: context) else { continue }
            members.append(.init(identity: identity, phase: Self.phase(selected?.phase), counted: member.counted))
        }
        // Preserve the existing Hook presentation's uncertainty and submitted states;
        // a zero count alone cannot establish an idle or completed presentation.
        let presentation = TaskStatusSummary(activity: batch.activity).diagnosticPresentation
        guard let reference = trace.snapshot(context: context, members: members, runningCount: batch.members.runningCount,
            unknownCount: batch.members.unknownCount, presentation: presentation,
            membershipComplete: members.count == batch.members.members.count && batch.observationsDropped == 0) else { return }
        deliveryLock.lock()
        // Pending main deliveries are bounded; missing delivery is reported rather than reusing a wrong snapshot.
        let droppedDeliveries = deliveries.count >= 32 ? deliveries.count : 0
        if droppedDeliveries > 0 { deliveries.removeAll() }
        deliveries[Delivery(generation: batch.generation, sequence: batch.sequence)] = reference
        deliveryLock.unlock()
        trace.observationGap(context: context, droppedCount: UInt64(droppedDeliveries), reason: .deliveryBufferLimit)
    }

    func take(generation: UInt64, sequence: UInt64) -> DiagnosticTaskSnapshotReference? {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        return deliveries.removeValue(forKey: Delivery(generation: generation, sequence: sequence))
    }
    private func identity(_ task: TaskIdentity, turn: String? = nil, context: DiagnosticTaskTraceContext) -> DiagnosticTaskTraceIdentity? {
        trace.identity(taskKey: key(task), turnKey: turn, fileKey: files[task], kind: .hookTask, correlation: .confirmed, context: context)
    }
    private func key(_ task: TaskIdentity) -> String { "\(task.source.utf8.count):" + task.source + task.session }
    private static func phase(_ value: TaskPhase?) -> DiagnosticTaskTracePhase {
        switch value { case .active: return .running; case .stopping: return .stopping; case .submitted: return .submitted
        case .completed: return .completed; case .interrupted: return .interrupted; default: return .unknown }
    }
    private static func evidence(_ value: EvidenceKind?) -> DiagnosticTaskEvidenceKind {
        switch value { case .started: return .started; case .execution: return .execution
        case .complete: return .complete; case .aborted: return .aborted; default: return .unknown }
    }
    private static func reason(_ value: HookTaskDecisionReason) -> DiagnosticTaskTransitionReason {
        switch value {
        case .acceptedStart: return .acceptedStart
        case .acceptedExecution: return .acceptedExecution
        case .acceptedComplete: return .acceptedComplete
        case .acceptedAbort: return .acceptedAbort
        case .oldTimestamp: return .olderTimestamp
        case .historicalBaseline: return .historicalBaselineRestricted
        case .missingStart: return .missingStartEvidence
        case .terminalActivity: return .terminalLateActivity
        case .staleActivity: return .staleExecution
        case .excludedSource: return .sourceExcluded
        default: return DiagnosticTaskTransitionReason(rawValue: value.rawValue) ?? .unknown
        }
    }
}
