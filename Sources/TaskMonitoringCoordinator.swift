import Foundation
import HookCore

/// A single selected source. Start/stop and callbacks are main-thread owned.
final class TaskMonitoringCoordinator {
    var onUpdate: ((TaskStatusSummary?) -> Void)?
    private let legacy: TaskStatusMonitor
    private let hooks: HookConnectionController
    private let sink: TaskObservationSink
    init(legacy: TaskStatusMonitor = TaskStatusMonitor(), hooks: HookConnectionController = HookConnectionController(),
         sink: TaskObservationSink = TaskObservationRelay.shared) {
        self.legacy = legacy; self.hooks = hooks; self.sink = sink
    }
    private var generation = 0
    private var enabled = false
    private var experimental = false
    static var experimentEnabled: Bool { UserDefaults.standard.object(forKey: "hookTaskMonitoringEnabled") as? Bool ?? false }

    func start(displayEnabled: Bool, experimental: Bool = TaskMonitoringCoordinator.experimentEnabled) {
        stop(); enabled = displayEnabled; self.experimental = experimental
        guard displayEnabled else { onUpdate?(nil); return }
        let token = generation
        if experimental {
            onUpdate?(TaskStatusSummary(activity: TaskActivitySnapshot(sourceHealth: [HookSourceHealth(state: .awaitingEvents)])))
            hooks.onUpdate = { [weak self] snapshot in
                guard let self else { return }
                let accepted = self.enabled && self.generation == token && self.experimental
                self.sink.record(.delivery(sequence: snapshot.snapshotSequence,
                                          generation: snapshot.observationGeneration, accepted: accepted, stage: .coordinator))
                guard accepted else { return }
                self.onUpdate?(TaskStatusSummary(snapshotSequence: snapshot.snapshotSequence,
                    observationGeneration: snapshot.observationGeneration, activity: snapshot))
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
                self.onUpdate?(snapshot)
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
    func stop() { generation += 1; enabled = false; legacy.stop(); hooks.stop() }
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
