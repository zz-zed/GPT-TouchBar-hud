// Compiled only into disposable integration applications, never the product.
#if MIGRATION_PROCESS_INTEGRATION
import AppKit
import Darwin

enum MigrationProcessIntegrationConfiguration {
    static let values: [String: String] = {
        guard let url = Bundle.main.url(forResource: "MigrationProcessIntegration", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let rootPath = value["root"], rootPath.hasPrefix("/"),
              value["bundleID"]?.hasPrefix("local.gpthud.migration-integration.") == true,
              value["launchAgentLabel"]?.hasPrefix("local.gpthud.migration-integration.") == true else {
            fatalError("Missing explicit isolated integration bundle configuration")
        }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        guard root.path == rootPath, root.resolvingSymlinksInPath().path == rootPath,
              value["bootFile"] == root.appendingPathComponent("boot.txt").path else {
            fatalError("Integration root must be a direct isolated path")
        }
        return value
    }()
    static var root: URL { URL(fileURLWithPath: values["root"]!) }
    static var home: URL { root.appendingPathComponent("home") }
    static var systemApplications: URL { root.appendingPathComponent("Applications") }
    static var journalDirectory: URL { home.appendingPathComponent("journal") }
    static var instanceLockURL: URL { root.appendingPathComponent("application-instance.lock") }
    #if !LAUNCH_ENTRY_INTEGRATION
    static func makeDriver() -> AppMigrationMacOSDriver {
        guard let boot = try? String(contentsOfFile: values["bootFile"]!, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), UUID(uuidString: boot) != nil else {
            fatalError("Integration boot identity requires an explicit simulated UUID")
        }
        // Boot transition is the sole platform simulation. LaunchServices,
        // running-app identities, signatures, ready files and locks stay real.
        return AppMigrationMacOSDriver(home: home, systemApplications: systemApplications,
                                      journalDirectory: journalDirectory, bootOverride: boot)
    }
    #endif
    static func event(_ name: String, additional: [String: Any] = [:], includeLaunchIdentity: Bool = true) {
        var value = additional
        value["event"] = name; value["pid"] = getpid()
        value["bundle"] = Bundle.main.bundleURL.standardizedFileURL.path
        value["time"] = Date().timeIntervalSince1970
        if includeLaunchIdentity, let launch = NSRunningApplication.current.launchDate { value["launchDate"] = launch.timeIntervalSince1970 }
        let directory = root.appendingPathComponent("events")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            try data.write(to: directory.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
        } catch { fatalError("Cannot record integration event: \(error)") }
    }
    #if !LAUNCH_ENTRY_INTEGRATION
    static func checkpoint(_ phase: String, transaction: AppMigrationTransaction) throws {
        event("checkpoint", additional: ["phase": phase, "transaction": transaction.id])
        let pause = root.appendingPathComponent("pause-phase")
        let deadline = Date(timeIntervalSinceNow: 60)
        while (try? String(contentsOf: pause, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == phase {
            guard Date() < deadline else { throw AppMigrationError.deferred("integrationCheckpointTimedOut") }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    #endif
}

enum AppIdentity {
    static let productName = "Migration integration fixture"
    static let installedBundleFileName = "Migration Integration Old.app"
    static let primaryInstalledBundleFileName = "Migration Integration New.app"
    static var executableName: String { MigrationProcessIntegrationConfiguration.values["executableName"] ?? "MigrationProcessIntegrationApp" }
    static var bundleIdentifier: String { MigrationProcessIntegrationConfiguration.values["bundleID"]! }
    static var launchAgentLabel: String { MigrationProcessIntegrationConfiguration.values["launchAgentLabel"]! }
    static var appSupportDirectoryName: String { MigrationProcessIntegrationConfiguration.values["supportDirectoryName"]! }
    static var legacyBundleIdentifier: String { bundleIdentifier + ".legacy" }
    static var legacyLaunchAgentLabel: String { launchAgentLabel + ".legacy" }
    static var legacyAppSupportDirectoryName: String { appSupportDirectoryName + "-legacy" }
}

enum AppInstallationPaths {
    static var bundleFileNames: [String] { [AppIdentity.installedBundleFileName, AppIdentity.primaryInstalledBundleFileName] }
    static func isDirectPath(_ url: URL) -> Bool {
        url.standardizedFileURL.path == url.path && url.resolvingSymlinksInPath().path == url.path
    }
}
#endif
