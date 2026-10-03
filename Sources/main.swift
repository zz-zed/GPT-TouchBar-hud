import AppKit

// The temporary update window has no HUD services, and must survive
// the owning HUD process. Only the private copied executable accepts this mode.
if AppUpdateProgressHelper.runIfRequested() { exit(EXIT_SUCCESS) }

do {
    // Acquire before AppDelegate's stored properties create the status item or
    // initialize services. All launch paths and app copies share this lock.
    guard let instanceLock = try SingleInstanceLock(url: SingleInstanceLock.defaultURL) else {
        exit(EXIT_SUCCESS)
    }
    withExtendedLifetime(instanceLock) {
        LegacyAppMigration.migratePreferences()

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
} catch {
    NSLog("%@ could not acquire its application lock: %@", AppIdentity.productName, String(describing: error))
    exit(EXIT_FAILURE)
}
