#if MIGRATION_PROCESS_INTEGRATION
import AppKit
import CoreServices
import Darwin

final class IntegrationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // This deliberately minimal core is not the product's AppDelegate:
        // it validates the signed bundle and then calls the real ready entry.
        do {
            _ = try MigrationProcessIntegrationConfiguration.makeDriver().inspect(Bundle.main.bundleURL.path)
            AppMigrationRuntime.didFinishCoreStartup()
            MigrationProcessIntegrationConfiguration.event("minimal-core-ready")
        } catch {
            MigrationProcessIntegrationConfiguration.event("minimal-core-failed", additional: ["error": String(describing: error)])
            NSApp.terminate(nil)
        }
    }
}

@main struct MigrationProcessIntegrationApp {
    static func main() throws {
        FileHandle.standardError.write(Data("Migration process integration entered main; pid=\(getpid()) args=\(CommandLine.arguments)\n".utf8))
        guard !AppInstallationMigrationPolicy.automaticMigrationEnabled else { fatalError("Production migration policy changed") }
        let config = MigrationProcessIntegrationConfiguration.self
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--preferences-contract" {
            let defaults = try AppMigrationMacOSDriver.launchPreferencesDefaults()
            let preferences = HostAutoLaunchPreferences(defaults: defaults)
            switch CommandLine.arguments[2] {
            case "clear": defaults.removePersistentDomain(forName: AppIdentity.bundleIdentifier)
            case "set-false": preferences.saveEnabled(false)
            case "read": break
            default: throw AppMigrationError.invalidState
            }
            _ = defaults.synchronize()
            let stored = defaults.persistentDomain(forName: AppIdentity.bundleIdentifier) ?? [:]
            let record: [String: Any] = ["contextBundleID": Bundle.main.bundleIdentifier ?? "nil",
                "stableDomain": AppIdentity.bundleIdentifier, "key": HostAutoLaunchPreferences.enabledKey,
                "branch": defaults === UserDefaults.standard ? "standard" : "suite",
                "storedKeyPresent": stored[HostAutoLaunchPreferences.enabledKey] != nil,
                "value": preferences.isEnabled]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--diagnose-workspace-launch" {
            let target = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
            guard target.path.hasPrefix(config.root.path + "/") else { throw AppMigrationError.invalidState }
            let options = NSWorkspace.OpenConfiguration()
            options.createsNewApplicationInstance = true
            options.activates = false
            options.addsToRecentItems = false
            options.promptsUserIfNeeded = false
            var record: [String: Any] = ["target": target.path, "completed": false,
                                         "purpose": "diagnostic retry only; original failure remains failed"]
            var completed = false
            NSWorkspace.shared.openApplication(at: target, configuration: options) { application, error in
                record["completed"] = true
                record["pid"] = application?.processIdentifier ?? -1
                record["bundleURL"] = application?.bundleURL?.path ?? "nil"
                record["executableURL"] = application?.executableURL?.path ?? "nil"
                record["launchDate"] = application?.launchDate?.timeIntervalSince1970 ?? -1
                record["isTerminated"] = application?.isTerminated ?? true
                if let error = error as NSError? {
                    record["errorDomain"] = error.domain; record["errorCode"] = error.code
                    record["errorDescription"] = error.localizedDescription
                    record["errorUserInfo"] = error.userInfo.mapValues { String(describing: $0) }
                }
                completed = true
            }
            let deadline = Date(timeIntervalSinceNow: 15)
            while !completed && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        if CommandLine.arguments.dropFirst().first == "--probe-registrations" {
            let urls = [AppIdentity.bundleIdentifier, AppIdentity.bundleIdentifier + ".controller"].flatMap { identifier in
                LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil)?.takeRetainedValue() as? [URL] ?? []
            }
            let paths = urls.filter { $0.path.hasPrefix(config.root.path + "/") }.map(\.path)
            let data = try JSONSerialization.data(withJSONObject: paths, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        if CommandLine.arguments.dropFirst().first == "--probe-readiness" {
            do {
                let driver = config.makeDriver()
                guard let transaction = try driver.load() else { throw AppMigrationError.invalidState }
                let confirmed = try driver.candidateReadinessIsCurrent(transaction)
                print(confirmed ? "CURRENT" : "NOT_CURRENT")
            } catch {
                FileHandle.standardError.write(Data("Rejected readiness: \(error)\n".utf8))
                exit(2)
            }
            return
        }
        if CommandLine.arguments.dropFirst().first == "--hold-maintenance" {
            let lock = try AppInstallationMaintenanceLock(directory: config.systemApplications, purpose: .migration)
            withExtendedLifetime(lock) {
                config.event("maintenance-holder-ready")
                while true { Thread.sleep(forTimeInterval: 1) }
            }
            return
        }
        // Same ordering as product main: helper, application lock, handoff, core.
        config.event("main-entered", additional: ["arguments": CommandLine.arguments], includeLaunchIdentity: false)
        let defaults = try AppMigrationMacOSDriver.launchPreferencesDefaults()
        HostAutoLaunchPreferences(defaults: defaults).saveEnabled(config.values["autoLaunchEnabled"] == "true")
        _ = defaults.synchronize() // Publish the isolated test preference before cross-process handoff.
        if AppMigrationRuntime.runHelperIfRequested() { return }
        guard let lock = try SingleInstanceLock(url: config.instanceLockURL) else {
            config.event("duplicate-application-rejected")
            return
        }
        withExtendedLifetime(lock) {
            config.event("application-lock-acquired")
            if AppMigrationRuntime.prepareStartupHandoff() {
                config.event("startup-handed-off")
                return
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let delegate = IntegrationDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}
#endif
