import AppKit

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
