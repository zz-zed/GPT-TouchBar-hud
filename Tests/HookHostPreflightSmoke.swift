import Foundation
import HookCore

@main enum HookHostPreflightSmoke {
    static func main() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/hud-native-preflight-\(UUID().uuidString)")
        try HookPaths.ensurePrivateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plan = try HookConfiguration.plan(target: directory.appendingPathComponent("hooks.json"), helper: directory.appendingPathComponent("not-installed"), socket: directory.appendingPathComponent("events.sock"))
        let report = try HookHostPreflight.discover(runtime: URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"), plan: plan)
        precondition(report.discoveredEvents == 4 && report.awaitingTrust)
        print("PASS: native isolated discovery; 4 events, awaiting host trust, no hooks executed")
    }
}
