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
        guard !AppInstallationMigrationPolicy.automaticMigrationEnabled else { fatalError("Production migration policy changed") }
        let config = MigrationProcessIntegrationConfiguration.self
        if CommandLine.arguments.dropFirst().first == "--probe-registrations" {
            let urls = LSCopyApplicationURLsForBundleIdentifier(AppIdentity.bundleIdentifier as CFString, nil)?
                .takeRetainedValue() as? [URL] ?? []
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
        guard let defaults = UserDefaults(suiteName: AppIdentity.bundleIdentifier) else { fatalError("Missing fixture defaults") }
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
