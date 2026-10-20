// A disposable NSApplication and control tool, never linked into the product.
import AppKit
import CoreServices
import Darwin

@_silgen_name("launch_entry_process_path")
private func processPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

private func executablePath(_ pid: Int32) -> String? {
    var bytes = [CChar](repeating: 0, count: 4096)
    let count = bytes.withUnsafeMutableBytes { processPath(pid, $0.baseAddress!, UInt32($0.count)) }
    return count > 0 ? String(cString: bytes) : nil
}

private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw NSError(domain: "LaunchEntryIntegration", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func emit(_ value: [String: Any]) throws {
    let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: bytes, as: UTF8.self))
}

private func ownApplication(_ app: NSRunningApplication) -> Bool {
    let root = MigrationProcessIntegrationConfiguration.root.path + "/"
    guard app.bundleIdentifier == AppIdentity.bundleIdentifier, let url = app.bundleURL,
          url.path.hasPrefix(root), url.resolvingSymlinksInPath() == url.standardizedFileURL else { return false }
    return executablePath(app.processIdentifier) == url.appendingPathComponent("Contents/MacOS/" + AppIdentity.executableName).path
}

private final class LaunchEntryDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MigrationProcessIntegrationConfiguration.event("launchEntryReady", additional: [
            "executable": executablePath(getpid()) ?? "", "nonce": MigrationProcessIntegrationConfiguration.values["nonce"] ?? "",
            "identity": AppIdentity.bundleIdentifier
        ])
    }
}

@main enum LaunchEntryIntegration {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--control" {
            try control(Array(args.dropFirst(2)))
            return
        }
        let app = NSApplication.shared
        let delegate = LaunchEntryDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func control(_ args: [String]) throws {
        let config = MigrationProcessIntegrationConfiguration.self
        let root = config.root
        try require(AppIdentity.bundleIdentifier.hasPrefix("local.gpthud.migration-integration."), "Test identity required")
        let preferences = HostAutoLaunchPreferences(defaults: UserDefaults(suiteName: AppIdentity.bundleIdentifier)!)
        let command = args[0]
        if command == "environment" {
            let result = try HostLaunchctlResult.run(arguments: ["print", "gui/\(getuid())"])
            try emit(["uid": getuid(), "guiDomainAvailable": result.status == 0, "guiStatus": result.status,
                      "guiOutput": result.output, "label": AppIdentity.launchAgentLabel,
                      "bundleID": AppIdentity.bundleIdentifier, "root": root.path])
            return
        }
        if command == "registered-paths" {
            let urls = [AppIdentity.bundleIdentifier, AppIdentity.bundleIdentifier + ".controller"].flatMap { identifier in
                LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil)?.takeRetainedValue() as? [URL] ?? []
            }
            try emit(["paths": urls.filter { $0.path.hasPrefix(root.path + "/") }.map(\.path)])
            return
        }
        if command == "stop" || command == "list" {
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleIdentifier)
                .filter(ownApplication)
            let identities: [[String: Any]] = applications.map { ["pid": $0.processIdentifier,
                "bundle": $0.bundleURL!.path, "executable": executablePath($0.processIdentifier) ?? "",
                "launchDate": $0.launchDate?.timeIntervalSince1970 ?? 0] }
            if command == "stop" {
                // All decisions use fresh OS identities and exact configured fixture paths.
                for app in applications { try require(app.terminate(), "Fixture refused normal termination") }
                let deadline = Date(timeIntervalSinceNow: 10)
                while applications.contains(where: { !$0.isTerminated }) && Date() < deadline {
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                }
                try require(applications.allSatisfy(\.isTerminated), "Fixture termination timed out")
            }
            try emit(["applications": identities, "command": command])
            return
        }
        try require(args.count == 2, "Expected one exact fixture bundle path")
        let appURL = URL(fileURLWithPath: args[1]).standardizedFileURL
        try require(appURL.path.hasPrefix(root.path + "/") && appURL.resolvingSymlinksInPath() == appURL,
                    "Control target must be a direct path inside this fixture root")
        let manager = HostAutoLaunchManager(preferences: preferences, appBundleURL: appURL,
            launchAgentsDirectory: config.home.appendingPathComponent("Library/LaunchAgents"), userID: getuid())
        switch command {
        case "install": try manager.installOrUpdate().get()
        case "enable": try manager.setEnabled(true).get()
        case "disable": try manager.setEnabled(false).get()
        case "clear-preferences":
            preferences.defaults.removePersistentDomain(forName: AppIdentity.bundleIdentifier)
            preferences.defaults.synchronize()
        case "register-open":
            try require(LSRegisterURL(appURL as CFURL, true) == noErr, "Real LSRegisterURL failed")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = false
            var completed = false
            var opened: NSRunningApplication?
            var launchError: Error?
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
                opened = application; launchError = error; completed = true
            }
            let deadline = Date(timeIntervalSinceNow: 20)
            while !completed && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
            if let launchError { throw launchError }
            try require(completed && opened != nil, "Explicit-URL launch did not return an application")
            try require(opened!.bundleURL?.standardizedFileURL == appURL && ownApplication(opened!),
                        "LaunchServices returned a process from a different path or identity")
            try emit(["command": command, "pid": opened!.processIdentifier, "bundle": appURL.path,
                      "executable": executablePath(opened!.processIdentifier)!, "lsRegistered": true])
            return
        default: throw NSError(domain: "LaunchEntryIntegration", code: 2)
        }
        preferences.defaults.synchronize()
        try emit(["command": command, "enabled": preferences.isEnabled, "label": AppIdentity.launchAgentLabel])
    }
}
