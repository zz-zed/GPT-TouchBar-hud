import AppKit
import HookCore

@main enum HookMonitoringIntegrationTests {
    static func main() throws {
        let suite = "hud-hooks-isolation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = URL(fileURLWithPath: "/private/tmp/hud-ui-\(UUID().uuidString)")
        try HookPaths.ensurePrivateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Constructing the settings entry must not create a config, install a helper, or enable it.
        _ = NSApplication.shared
        let ui = HookExperimentPreferencesController(target: directory.appendingPathComponent("hooks.json"),
              helper: directory.appendingPathComponent("HookEmitter"), directory: directory.appendingPathComponent("ipc"), defaults: defaults)
        precondition(ui.window != nil)
        precondition(!defaults.bool(forKey: "hookTaskMonitoringEnabled"))
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("hooks.json").path))
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("HookEmitter").path))
        let hooks = HookConnectionController(directory: directory.appendingPathComponent("ipc"), home: directory)
        let coordinator = TaskMonitoringCoordinator(legacy: TaskStatusMonitor(home: directory), hooks: hooks)
        var updates: [TaskStatusSummary?] = []
        coordinator.onUpdate = { updates.append($0) }
        coordinator.start(displayEnabled: true, experimental: true)
        precondition(updates.last??.activity != nil && updates.last??.badge == "—")
        coordinator.start(displayEnabled: false, experimental: false)
        precondition(updates.last! == nil)
        let count = updates.count
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(updates.count == count, "Old Hook callbacks escaped after disable")
        coordinator.start(displayEnabled: true, experimental: false)
        precondition(updates.last??.activity == nil && updates.last??.unknownCount == 1)
        coordinator.start(displayEnabled: true, experimental: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(updates.last??.activity != nil, "Legacy callback replaced Hook snapshot")
        coordinator.stop()
        print("PASS: default-off settings, no installation on open, explicit unready/disabled states, generation-isolated mode switching")
    }
}
