import Foundation
import HookCore

/// A single selected source. Start/stop and callbacks are main-thread owned.
final class TaskMonitoringCoordinator {
    var onUpdate: ((TaskStatusSummary?) -> Void)?
    var onDiagnosticSnapshot: ((DiagnosticTaskSnapshotReference?) -> Void)?
    private(set) var currentDiagnosticSnapshot: DiagnosticTaskSnapshotReference?
    private let legacy: TaskStatusMonitor
    private let diagnostics: DiagnosticRecording
    private let taskTrace: DiagnosticTaskTrace
    private let hookTrace: DiagnosticHookTaskTrace
    private(set) var currentDiagnosticBatch: UInt64?
    private var hookBatch: UInt64 = 1 << 63
    private var previousHookEvidence: HookEvidence?
    private var pendingHookStartObservation = false
    private struct HookEvidence: Equatable {
        let running: Int
        let pending: Int
        let submitted: Int
        let completed: Int
        let gaps: Set<CoverageGap>
        let health: [HookHealthState]
        init(_ snapshot: TaskActivitySnapshot) {
            running = snapshot.confirmedRunningCount; pending = snapshot.pendingVerificationCount
            submitted = snapshot.submittedCount; completed = snapshot.recentlyCompletedCount
            gaps = snapshot.coverage.gaps; health = snapshot.sourceHealth.map(\.state)
        }
    }
    private let hooks: HookConnectionController
    init(legacy: TaskStatusMonitor? = nil, hooks: HookConnectionController = HookConnectionController(),
         diagnostics: DiagnosticRecording = NoopDiagnosticRecorder()) {
        self.legacy = legacy ?? TaskStatusMonitor(diagnostics: diagnostics); self.hooks = hooks
        self.diagnostics = diagnostics
        taskTrace = DiagnosticTaskTrace(recorder: diagnostics)
        hookTrace = DiagnosticHookTaskTrace(recorder: diagnostics)
    }
    private var generation = 0
    private var enabled = false
    private var experimental = false
    static var experimentEnabled: Bool { UserDefaults.standard.object(forKey: "hookTaskMonitoringEnabled") as? Bool ?? false }

    func start(displayEnabled: Bool, experimental: Bool = TaskMonitoringCoordinator.experimentEnabled) {
        stop(); enabled = displayEnabled; self.experimental = experimental
        diagnostics.record(.task(stage: .mode, mode: displayEnabled ? (experimental ? .hooks : .legacy) : .disabled))
        guard displayEnabled else { onUpdate?(nil); return }
        diagnostics.record(.task(stage: .monitorStarted, mode: experimental ? .hooks : .legacy))
        let token = generation
        if experimental {
            publishBoundary(TaskStatusSummary(activity: TaskActivitySnapshot(sourceHealth: [HookSourceHealth(state: .awaitingEvents)])))
            let bridge = hookTrace
            hooks.onTrace = { batch in bridge.observe(batch, monitoringGeneration: UInt64(token)) }
            hooks.traceEnabled = { [diagnostics] in diagnostics.taskTraceState.enabled }
            hooks.traceEpoch = { [diagnostics] in diagnostics.taskTraceState.generation }
            hooks.onTraceDiscarded = { [weak self] generation, sequence in
                guard let self, let reference = bridge.take(generation: generation, sequence: sequence) else { return }
                self.receiveTrace(reference, accepted: false, delivered: false)
            }
            hooks.onTraceDelivery = { [weak self] generation, sequence, delivered in
                guard let self else { return }
                let accepted = self.enabled && self.generation == token && self.experimental
                guard let reference = bridge.take(generation: generation, sequence: sequence) else {
                    if accepted { self.currentDiagnosticSnapshot = nil; self.onDiagnosticSnapshot?(nil) }
                    return
                }
                self.receiveTrace(reference, accepted: accepted, delivered: delivered)
            }
            hooks.setTraceEnabled(true)
            hooks.onUpdate = { [weak self] snapshot in
                guard let self else { return }
                self.hookBatch &+= 1
                let batch = self.hookBatch
                guard self.enabled, self.generation == token, self.experimental else {
                    self.diagnostics.record(.task(stage: .mainDiscarded, batch: batch, result: .stale, mode: .hooks))
                    return
                }
                let evidence = HookEvidence(snapshot)
                let observedStart = self.pendingHookStartObservation
                self.pendingHookStartObservation = false
                let recordsTrace = self.previousHookEvidence != evidence || observedStart
                self.previousHookEvidence = evidence
                self.currentDiagnosticBatch = recordsTrace ? batch : nil
                // Counts come from the production snapshot; missing coverage remains unknown.
                let unavailable = snapshot.sourceHealth.isEmpty || snapshot.sourceHealth.contains { $0.state != .connected } || !snapshot.coverage.isComplete
                if recordsTrace {
                    if observedStart {
                        self.diagnostics.record(.task(stage: .explicitStart, batch: batch, mode: .hooks))
                    }
                    let connected = !snapshot.sourceHealth.isEmpty && snapshot.sourceHealth.allSatisfy { $0.state == .connected }
                    self.diagnostics.record(.task(stage: .hooks, batch: batch, result: connected ? .success : .unavailable, mode: .hooks))
                    self.diagnostics.record(.task(stage: .hookCoverage, batch: batch,
                                                  result: snapshot.coverage.isComplete ? .success : .unknown, mode: .hooks))
                    self.diagnostics.record(.task(stage: .aggregate, batch: batch, result: unavailable ? .unknown : .success,
                                                  runningCount: unavailable && snapshot.confirmedRunningCount == 0 ? nil : snapshot.confirmedRunningCount,
                                                  unknownCount: unavailable && snapshot.pendingVerificationCount == 0 ? nil : snapshot.pendingVerificationCount, mode: .hooks))
                    self.diagnostics.record(.task(stage: .mainAccepted, batch: batch, result: unavailable ? .unknown : .success, mode: .hooks))
                }
                self.onUpdate?(TaskStatusSummary(diagnosticSnapshot: self.currentDiagnosticSnapshot, activity: snapshot))
            }
            hooks.onTaskStartObserved = { [weak self] in
                guard let self, self.enabled, self.generation == token, self.experimental else { return }
                self.pendingHookStartObservation = true
            }
            hooks.start()
        } else {
            publishBoundary(Self.legacyUnavailable(.starting))
            legacy.onDiagnosticBatch = { [weak self] batch in self?.currentDiagnosticBatch = batch }
            legacy.onDiagnosticTraceDelivery = { [weak self] reference, delivered in
                guard let self else { return }
                self.receiveTrace(reference, accepted: self.enabled && self.generation == token && !self.experimental, delivered: delivered)
            }
            legacy.onUpdate = { [weak self] snapshot in
                guard let self else { return }
                guard self.enabled, self.generation == token, !self.experimental else {
                    if let batch = self.currentDiagnosticBatch {
                        self.diagnostics.record(.task(stage: .mainDiscarded, batch: batch, result: .stale, mode: .legacy))
                    }
                    return
                }
                var result = snapshot
                result.diagnosticSnapshot = self.currentDiagnosticSnapshot
                self.onUpdate?(result)
            }
            legacy.start()
        }
    }
    func prepareForHost(displayEnabled: Bool) {
        stop(); enabled = displayEnabled; experimental = Self.experimentEnabled
        diagnostics.record(.task(stage: .mode, mode: displayEnabled ? (experimental ? .hooks : .legacy) : .disabled))
        guard displayEnabled else { onUpdate?(nil); return }
        if experimental {
            publishBoundary(TaskStatusSummary(activity: TaskActivitySnapshot(sourceHealth: [HookSourceHealth(state: .unavailable)])))
        } else { publishBoundary(Self.legacyUnavailable(.hostUnavailable)) }
    }
    func stop() { if enabled { diagnostics.record(.task(stage: .monitorStopped, mode: experimental ? .hooks : .legacy)) }; generation += 1; enabled = false; currentDiagnosticBatch = nil; currentDiagnosticSnapshot = nil; previousHookEvidence = nil; pendingHookStartObservation = false; legacy.stop(); hooks.stop() }
    func recordDisplaySubmission() {
        guard let batch = currentDiagnosticBatch else { return }
        diagnostics.record(.task(stage: .uiSubmitted, batch: batch, mode: experimental ? .hooks : .legacy))
        currentDiagnosticBatch = nil
    }
    func suspend() {
        guard enabled else { return }
        if experimental { hooks.suspend() }
        else { legacy.stop(); publishBoundary(Self.legacyUnavailable(.suspended)) }
    }
    func resume() {
        guard enabled else { return }
        if experimental { hooks.resume() }
        else { start(displayEnabled: true, experimental: false) }
    }
    func hostUnavailable() {
        if experimental { hooks.hostUnavailable() }
        else if enabled { legacy.stop(); publishBoundary(Self.legacyUnavailable(.hostUnavailable)) }
    }

    private func publishBoundary(_ summary: TaskStatusSummary) {
        hookBatch &+= 1
        currentDiagnosticBatch = hookBatch
        let event: DiagnosticEvent = .task(stage: .mainAccepted, batch: hookBatch, result: .unknown,
                                           runningCount: nil, unknownCount: summary.activity == nil ? summary.unknownCount : nil,
                                           mode: experimental ? .hooks : .legacy)
        diagnostics.record(event)
        var result = summary
        result.diagnosticSnapshot = taskTrace.snapshot(context: .init(monitoringGeneration: UInt64(generation), batch: hookBatch),
            members: [], runningCount: 0, unknownCount: summary.activity?.pendingVerificationCount ?? summary.unknownCount,
            presentation: .unknown, membershipComplete: false)
        currentDiagnosticSnapshot = result.diagnosticSnapshot
        if let reference = result.diagnosticSnapshot { receiveTrace(reference, accepted: true, delivered: true) }
        onUpdate?(result)
    }

    private func receiveTrace(_ reference: DiagnosticTaskSnapshotReference, accepted: Bool, delivered: Bool) {
        let gate = diagnostics.taskTraceState
        guard gate.enabled, reference.recordingGeneration == gate.generation, reference.recordingSessionID == gate.sessionID else { return }
        taskTrace.consume(reference: reference, observation: .init(surface: .coordinator,
            action: accepted && delivered ? .received : .skipped, logicalTaskCount: reference.runningCount,
            presentation: reference.runningCount > 0 ? .running : .unknown, compactRule: .exact,
            reason: !accepted ? .staleGeneration : (delivered ? .update : .sameValueSuppressed), consumer: .coordinator))
        guard accepted else { return }
        currentDiagnosticSnapshot = reference
        onDiagnosticSnapshot?(reference)
    }

    private static func legacyUnavailable(_ reason: LegacyTaskDiagnosticReason) -> TaskStatusSummary {
        TaskStatusSummary(
            unknownCount: 1,
            legacyHealth: .unavailable(reason),
            legacyDiagnostics: LegacyTaskDiagnostics(unknownCount: 1, reasons: [reason])
        )
    }
}
