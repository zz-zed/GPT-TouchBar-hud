import Foundation
import Darwin

public struct HookHostCapabilityReport {
    public let discoveredEvents: Int
    public let awaitingTrust: Bool
}

/// Configuration discovery in a NEW isolated instance. This never queries desktop task state,
/// runs a hook, creates a task, contacts a model, or writes the user's configuration/trust store.
public enum HookHostPreflight {
    public static func discover(runtime: URL, plan: HookConfigurationPlan, timeout: TimeInterval = 8) throws -> HookHostCapabilityReport {
        guard timeout > 0 && timeout <= 8 else { throw HookFailure.budget }
        let fd = try HookPaths.openRegular(runtime, allowRootOwner: true); close(fd)
        let temporary = URL(fileURLWithPath: "/private/tmp/gpt-hud-discovery-\(UUID().uuidString)", isDirectory: true)
        try HookPaths.ensurePrivateDirectory(temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Only probe our definitions, never load another user's Hook command into the probe.
        let events = Dictionary(uniqueKeysWithValues: HookEventKind.allCases.map {
            ($0.rawValue, [["hooks": [["type": "command", "command": plan.ownedCommand, "timeout": 1]]]])
        })
        try HookPaths.atomicWrite(JSONSerialization.data(withJSONObject: ["hooks": events]), to: temporary.appendingPathComponent("hooks.json"))
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = runtime; process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = temporary
        var environment = ProcessInfo.processInfo.environment; environment["CODEX_HOME"] = temporary.path
        process.environment = environment; process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            // Never allow a non-responsive discovery subprocess to outlive this bounded operation.
            let end = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < end { usleep(5_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close()
        }
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "gpt_hud_hook_discovery", "version": "1"], "capabilities": ["experimentalApi": true]]])
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffer = Data(), total = 0
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) <= 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            guard count > 0 else { break }
            total += count; guard total <= 2 * 1024 * 1024 else { throw HookFailure.budget }
            buffer.append(contentsOf: bytes.prefix(count))
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if message["id"] as? Int == 1 {
                    guard message["error"] == nil else { throw HookFailure.unavailable }
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "hooks/list", "params": ["cwds": [temporary.path]]])
                }
                if message["id"] as? Int == 2 {
                    guard message["error"] == nil, let result = message["result"] as? [String: Any],
                          let entries = result["data"] as? [[String: Any]],
                          entries.allSatisfy({ ($0["errors"] as? [Any])?.isEmpty == true }) else { throw HookFailure.unavailable }
                    let hooks = entries.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.filter { $0["command"] as? String == plan.ownedCommand }
                    let names = Set(hooks.compactMap { $0["eventName"] as? String })
                    guard names == Set(["userPromptSubmit", "stop", "interrupt", "sessionEnd"]), hooks.count == 4,
                          hooks.allSatisfy({ ($0["enabled"] as? Bool) == true && ($0["timeoutSec"] as? Int) == 1 && ($0["async"] as? Bool) == false }) else { throw HookFailure.unavailable }
                    return HookHostCapabilityReport(discoveredEvents: hooks.count, awaitingTrust: hooks.contains { $0["trustStatus"] as? String == "untrusted" })
                }
            }
        }
        throw HookFailure.unavailable
    }
}
