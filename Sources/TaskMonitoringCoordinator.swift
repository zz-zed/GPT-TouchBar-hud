import Foundation
import HookCore

/// A single selected source. Start/stop and callbacks are main-thread owned.
final class TaskMonitoringCoordinator {
    var onDiagnosticSnapshot: ((DiagnosticTaskSnapshotReference?) -> Void)?
    private let diagnostics: DiagnosticRecording
    private let engineTrace: DiagnosticTaskEngineTrace
    private var currentDiagnosticReference: DiagnosticTaskSnapshotReference?
    private var currentDiagnosticBatch: UInt64?
    var onUpdate: ((TaskStatusSummary?) -> Void)?
    private let legacy: TaskStatusMonitor
    private let hooks: HookConnectionController
    private let sink: TaskObservationSink
    init(legacy: TaskStatusMonitor = TaskStatusMonitor(), hooks: HookConnectionController = HookConnectionController(),
         sink: TaskObservationSink = TaskObservationRelay.shared, diagnostics: DiagnosticRecording = NoopDiagnosticRecorder()) {
        self.legacy = legacy; self.hooks = hooks; self.sink = sink; self.diagnostics = diagnostics
        engineTrace = DiagnosticTaskEngineTrace(recorder: diagnostics)
    }
    private var generation = 0
    private var enabled = false
    private var experimental = false
    static var experimentEnabled: Bool { UserDefaults.standard.object(forKey: "hookTaskMonitoringEnabled") as? Bool ?? false }

    func start(displayEnabled: Bool, experimental: Bool = TaskMonitoringCoordinator.experimentEnabled) {
        if !(diagnostics is NoopDiagnosticRecorder) { TaskObservationRelay.shared.connect(engineTrace) }
        stop(); enabled = displayEnabled; self.experimental = experimental
        diagnostics.record(.task(stage: .mode, mode: displayEnabled ? (experimental ? .hooks : .legacy) : .disabled))
        if displayEnabled { diagnostics.record(.task(stage: .monitorStarted, mode: experimental ? .hooks : .legacy)) }
        guard displayEnabled else { onUpdate?(nil); return }
        let token = generation
        let observation: (UInt64, UInt64) -> Void = { [weak self] sequence, sourceGeneration in
            guard let self, self.enabled, self.generation == token else { return }
            let value = self.engineTrace.reference(sequence: sequence, generation: sourceGeneration)
            guard value != self.currentDiagnosticReference else { return }
            self.currentDiagnosticReference = value
            self.onDiagnosticSnapshot?(value)
        }
        legacy.onDiagnosticSnapshot = observation
        hooks.onDiagnosticSnapshot = observation
        if experimental {
            onUpdate?(TaskStatusSummary(activity: TaskActivitySnapshot(sourceHealth: [HookSourceHealth(state: .awaitingEvents)])))
            hooks.onUpdate = { [weak self] snapshot in
                guard let self else { return }
                let accepted = self.enabled && self.generation == token && self.experimental
                self.sink.record(.delivery(sequence: snapshot.snapshotSequence,
                                          generation: snapshot.observationGeneration, accepted: accepted, stage: .coordinator))
                guard accepted else { return }
                self.diagnostics.record(.task(stage: .mainAccepted, batch: snapshot.snapshotSequence,
                    mode: self.experimental ? .hooks : .legacy))
                var value = TaskStatusSummary(snapshotSequence: snapshot.snapshotSequence,
                    observationGeneration: snapshot.observationGeneration, activity: snapshot)
                value.diagnosticSnapshot = self.engineTrace.reference(sequence: snapshot.snapshotSequence, generation: snapshot.observationGeneration)
                self.currentDiagnosticBatch = snapshot.snapshotSequence
                self.onDiagnosticSnapshot?(value.diagnosticSnapshot)
                self.onUpdate?(value)
            }
            hooks.start()
        } else {
            onUpdate?(Self.legacyUnavailable(.starting))
            legacy.onUpdate = { [weak self] snapshot in
                guard let self else { return }
                let accepted = self.enabled && self.generation == token && !self.experimental
                self.sink.record(.delivery(sequence: snapshot.snapshotSequence,
                                          generation: snapshot.observationGeneration, accepted: accepted, stage: .coordinator))
                guard accepted else { return }
                self.diagnostics.record(.task(stage: .mainAccepted, batch: snapshot.snapshotSequence,
                    mode: self.experimental ? .hooks : .legacy))
                var value = snapshot
                value.diagnosticSnapshot = self.engineTrace.reference(sequence: snapshot.snapshotSequence, generation: snapshot.observationGeneration)
                self.currentDiagnosticBatch = snapshot.snapshotSequence
                self.onDiagnosticSnapshot?(value.diagnosticSnapshot)
                self.onUpdate?(value)
            }
            legacy.start()
        }
    }
    func prepareForHost(displayEnabled: Bool) {
        stop(); enabled = displayEnabled; experimental = Self.experimentEnabled
        guard displayEnabled else { onUpdate?(nil); return }
        if experimental {
            onUpdate?(TaskStatusSummary(activity: TaskActivitySnapshot(sourceHealth: [HookSourceHealth(state: .unavailable)])))
        } else { onUpdate?(Self.legacyUnavailable(.hostUnavailable)) }
    }
    func stop() { if enabled { diagnostics.record(.task(stage: .monitorStopped, mode: experimental ? .hooks : .legacy)) }; generation += 1; enabled = false; currentDiagnosticReference = nil; legacy.stop(); hooks.stop() }
    func recordDisplaySubmission() {
        guard let batch = currentDiagnosticBatch else { return }
        diagnostics.record(.task(stage: .uiSubmitted, batch: batch, mode: experimental ? .hooks : .legacy))
        currentDiagnosticBatch = nil
    }
    func suspend() {
        guard enabled else { return }
        if experimental { hooks.suspend() }
        else { legacy.suspend() }
    }
    func resume() {
        guard enabled else { return }
        if experimental { hooks.resume() }
        else { legacy.resume() }
    }
    func hostUnavailable() {
        if experimental { hooks.hostUnavailable() }
        else if enabled { legacy.hostUnavailable() }
    }

    private static func legacyUnavailable(_ reason: LegacyTaskDiagnosticReason) -> TaskStatusSummary {
        TaskStatusSummary(
            unknownCount: 1,
            legacyHealth: .unavailable(reason),
            legacyDiagnostics: LegacyTaskDiagnostics(unknownCount: 1, reasons: [reason])
        )
    }
}
