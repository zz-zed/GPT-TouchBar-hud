import Foundation
import HookCore

@main enum HookMonitoringBenchmark {
    static func main() throws {
        precondition(CommandLine.arguments.count == 2)
        let home = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = home.deletingLastPathComponent().appendingPathComponent("ipc")
        let duration: TimeInterval = 12
        let legacy = TaskStatusMonitor(home: home)
        var legacyChanges = 0
        legacy.onUpdate = { _ in legacyChanges += 1 }
        let oldCPU = clock(); legacy.start()
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
        legacy.stop()
        let oldSeconds = Double(clock() - oldCPU) / Double(CLOCKS_PER_SEC)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let hooks = HookConnectionController(directory: directory, home: home)
        var hookChanges = 0, measurements = HookMeasurements()
        hooks.onUpdate = { _ in hookChanges += 1 }; hooks.onMeasurements = { measurements = $0 }
        let newCPU = clock(); hooks.start()
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
        let newSeconds = Double(clock() - newCPU) / Double(CLOCKS_PER_SEC)
        // Flush final cumulative instrumentation via a metadata-only synthetic event.
        _ = HookEmitter.send(HookEvent(kind: .sessionEnd, session: "s0", turn: nil), socketURL: directory.appendingPathComponent("events.sock"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1)); hooks.stop()
        let result: [String: Any] = ["scenario": "32 static synthetic logs, 300000-byte padding plus metadata each; startup included; no host", "duration_each_seconds": duration,
                                   "legacy_cpu_seconds": oldSeconds, "hooks_cpu_seconds": newSeconds, "legacy_publications": legacyChanges,
                                   "hooks_publications": hookChanges, "hooks_read_bytes": measurements.bytesRead, "hooks_file_reads": measurements.filesRead,
                                   "notes": "Single short sequential sample, different conservative startup semantics; not an energy or accuracy benchmark"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
