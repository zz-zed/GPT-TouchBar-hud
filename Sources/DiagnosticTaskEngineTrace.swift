import Foundation
import HookCore

/// Adapts only anonymized facts from the shared production engine. It never reads logs
/// or derives business state. Both modes use the same engine identity domain.
final class DiagnosticTaskEngineTrace: TaskObservationSink {
    private let recorder: DiagnosticRecording
    private let trace: DiagnosticTaskTrace
    private let lock = NSLock()
    private struct Key: Hashable { let generation: UInt64; let sequence: UInt64 }
    private var references: [Key: DiagnosticTaskSnapshotReference] = [:]
    private var lastAggregate: UUID?
    private var lastInventory: String?
    private var inventory: Set<UInt64> = []
    private var state: DiagnosticTaskTraceState?
    init(recorder: DiagnosticRecording) { self.recorder = recorder; trace = DiagnosticTaskTrace(recorder: recorder) }
    func reference(sequence: UInt64, generation: UInt64) -> DiagnosticTaskSnapshotReference? {
        lock.lock(); defer { lock.unlock() }
        let gate = recorder.taskTraceState
        guard gate.enabled, let value = references[Key(generation: generation, sequence: sequence)],
              value.recordingSessionID == gate.sessionID, value.recordingGeneration == gate.generation else { return nil }
        return value
    }
    func record(_ event: TaskObservation) {
        lock.lock(); defer { lock.unlock() }
        let gate = recorder.taskTraceState
        guard gate.enabled else { references.removeAll(); return }
        if state != gate { references.removeAll(); inventory.removeAll(); lastAggregate = nil; lastInventory = nil; state = gate }
        func context(_ sequence: UInt64, _ generation: UInt64) -> DiagnosticTaskTraceContext {
            .init(monitoringGeneration: generation, batch: sequence,
                  recordingGeneration: gate.generation, recordingSessionID: gate.sessionID)
        }
        func identity(_ alias: UInt64, _ ctx: DiagnosticTaskTraceContext) -> DiagnosticTaskTraceIdentity? {
            trace.identity(taskKey: String(alias), kind: .thread, correlation: .confirmed, context: ctx)
        }
        switch event {
        case let .read(sequence, generation, _, boundary):
            let ctx = context(sequence, generation)
            guard let id = identity(boundary.alias, ctx) else { return }
            var metrics = DiagnosticTaskReadMetrics()
            metrics.fileBytes = boundary.target; metrics.offsetBefore = boundary.before
            metrics.offsetAfter = boundary.fetched; metrics.readBytes = UInt64(max(0, boundary.bytesRead))
            metrics.skippedBytes = 0; metrics.backlogBytes = boundary.backlogBytes
            trace.read(context: ctx, identity: id, metrics: metrics)
        case let .transition(sequence, generation, alias, _, before, after, reason):
            let ctx = context(sequence, generation)
            guard let id = identity(alias, ctx) else { return }
            let evidence: DiagnosticTaskEvidenceKind = reason == .liveStart ? .started
                : (reason == .matchingTerminal ? .complete : (reason == .matchingInterrupt ? .aborted : .unknown))
            let accepted = [.liveStart, .matchingTerminal, .matchingInterrupt].contains(reason)
            trace.lifecycle(context: ctx, identity: id, transition: .init(before: Self.phase(before),
                after: Self.phase(after), evidence: evidence, accepted: accepted, reason: Self.reason(reason)))
            trace.member(context: ctx, identity: id, countedBefore: before == .active,
                         countedAfter: after == .active, reason: .lifecycleChanged)
            if reason == .liveStart { recorder.record(.moduleRecovery(module: .taskRecognition, state: .success, observation: .taskStartObserved), expectedGeneration: gate.generation) }
        case let .inventory(sequence, generation, coverage, discovered, retained):
            let key = "\(generation):\(coverage.rawValue):\(discovered):\(retained)"
            if key != lastInventory {
                lastInventory = key
                recorder.record(.moduleRecovery(module: .taskMonitor,
                    state: coverage == .unavailable ? .failed : (coverage == .complete ? .success : .unknown), observation: .indexRead), expectedGeneration: gate.generation)
            }
            trace.discovery(context: context(sequence, generation), observation: .init(scope: .latestRollouts,
                returnedRows: discovered, acceptedRows: retained, traversalComplete: coverage == .complete,
                coverage: coverage == .complete ? .complete : .limited))
        case let .checkpoint(sequence, generation, _, members, running, pending, complete):
            let ctx = context(sequence, generation)
            let current = Set(members.map(\.alias))
            for alias in inventory.subtracting(current) { trace.retire(taskKey: String(alias), kind: .thread, context: ctx) }
            inventory = current
            let safe = members.compactMap { member -> DiagnosticTaskSnapshotMember? in
                guard let id = identity(member.alias, ctx) else { return nil }
                return .init(identity: id, phase: Self.phase(member.phase), counted: member.counted)
            }
            if let value = trace.snapshot(context: ctx, members: safe, runningCount: running, unknownCount: pending,
                presentation: running > 0 ? .running : .unknown, membershipComplete: safe.count == members.count) {
                if lastAggregate != value.snapshotID {
                    lastAggregate = value.snapshotID
                    recorder.record(.moduleRecovery(module: .taskAggregation, state: complete ? .success : .unknown,
                        observation: .aggregateProduced), expectedGeneration: gate.generation)
                }
                // Inventory coverage and snapshot-member completeness are separate facts.
                if references.count >= 32, let oldest = references.keys.min(by: { $0.sequence < $1.sequence }) { references.removeValue(forKey: oldest) }
                references[Key(generation: generation, sequence: sequence)] = value
            }
            _ = complete // Discovery carries inventory coverage; members describe this snapshot.
        case let .issue(sequence, generation, alias, reason):
            let ctx = context(sequence, generation)
            if let alias, reason == .aliasRetired { trace.retire(taskKey: String(alias), kind: .thread, context: ctx) }
            if let alias, [.readFailed, .missingLog, .invalidPath, .identityMismatch].contains(reason), let id = identity(alias, ctx) {
                var metrics = DiagnosticTaskReadMetrics()
                metrics.reason = reason == .readFailed ? .readFailure : (reason == .missingLog ? .fileMissing : .fileRejected)
                trace.read(context: ctx, identity: id, metrics: metrics)
            }
        case let .delivery(sequence, generation, accepted, stage):
            guard let value = references[Key(generation: generation, sequence: sequence)] else {
                trace.observationGap(context: context(sequence, generation), droppedCount: 1, reason: .deliveryBufferLimit)
                return
            }
            trace.consume(reference: value, observation: .init(surface: stage == .coordinator ? .coordinator : .main,
                action: accepted ? .received : .skipped, logicalTaskCount: value.runningCount,
                presentation: value.runningCount > 0 ? .running : .unknown, compactRule: .exact,
                reason: accepted ? .update : .staleGeneration, consumer: stage == .coordinator ? .coordinator : .main))
        default: break // Display consumers record their own actual presentation and visibility.
        }
    }
    private static func phase(_ phase: TaskPhase) -> DiagnosticTaskTracePhase {
        switch phase { case .active: return .running; case .completed: return .completed
        case .interrupted: return .interrupted; case .submitted: return .submitted
        case .stopping: return .stopping; default: return .unknown }
    }
    private static func reason(_ reason: TaskObservationReason) -> DiagnosticTaskTransitionReason {
        switch reason { case .liveStart: return .acceptedStart; case .historicalStart: return .historicalStart
        case .matchingTerminal: return .acceptedComplete; case .matchingInterrupt: return .acceptedAbort
        case .lateOrDuplicate: return .unknown; case .weakEventIgnored: return .missingStartEvidence
        case .turnMismatch: return .turnMismatch; case .invalidTimestamp: return .invalidTimestamp
        case .fileReset: return .fileReset; case .readFailed: return .readFailure
        case .staleEvidence: return .staleEvidence; case .hostUnavailable: return .hostUnavailable
        case .suspended: return .sleep; case .capacity: return .capacityRemoved
        default: return .unknown }
    }
}
