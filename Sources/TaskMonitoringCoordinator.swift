import Foundation
import HookCore

/// A single selected source. Start/stop and callbacks are main-thread owned.
final class TaskMonitoringCoordinator {
    var onUpdate: ((TaskStatusSummary?) -> Void)?
    private let legacy: TaskStatusMonitor
    private let hooks: HookConnectionController
    init(legacy: TaskStatusMonitor = TaskStatusMonitor(), hooks: HookConnectionController = HookConnectionController()) {
        self.legacy = legacy; self.hooks = hooks
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
                guard let self, self.enabled, self.generation == token, self.experimental else { return }
                self.onUpdate?(TaskStatusSummary(activity: snapshot))
            }
            hooks.start()
        } else {
            onUpdate?(TaskStatusSummary(unknownCount: 1)) // Legacy source is explicitly not ready yet.
            legacy.onUpdate = { [weak self] snapshot in
                guard let self, self.enabled, self.generation == token, !self.experimental else { return }
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
        } else { onUpdate?(TaskStatusSummary(unknownCount: 1)) }
    }
    func stop() { generation += 1; enabled = false; legacy.stop(); hooks.stop() }
    func suspend() {
        guard enabled else { return }
        if experimental { hooks.suspend() }
        else { legacy.stop(); onUpdate?(TaskStatusSummary(unknownCount: 1)) }
    }
    func resume() {
        guard enabled else { return }
        if experimental { hooks.resume() }
        else { start(displayEnabled: true, experimental: false) }
    }
    func hostUnavailable() {
        if experimental { hooks.hostUnavailable() }
        else if enabled { legacy.stop(); onUpdate?(TaskStatusSummary(unknownCount: 1)) }
    }
}
