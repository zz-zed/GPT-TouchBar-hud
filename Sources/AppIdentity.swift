import AppKit

enum AppIdentity {
    static let productName = "GPT TouchBar HUD"
    static let bundleIdentifier = "io.github.zz-zed.GPTTouchBarHUD"
    static let launchAgentLabel = "io.github.zz-zed.GPTTouchBarHUD.CodexLauncher"
    static let appSupportDirectoryName = "GPT TouchBar HUD"

    static let legacyBundleIdentifier = "com.jackchen.TouchBarCodexToken"
    static let legacyLaunchAgentLabel = "com.jackchen.TouchBarCodexToken.CodexLauncher"
    static let legacyAppSupportDirectoryName = "TouchBarCodexToken"
}

enum LegacyAppMigration {
    private static let preferenceKeys = [
        "hud.color",
        "hud.backgroundOpacity",
        "hud.contentOpacity",
        "hud.opacity",
        "persistentTouchBarEnabled"
    ]

    /// Copies only settings owned by this app, and never overwrites a value
    /// already saved under the new bundle identifier.
    static func migratePreferences(
        defaults: UserDefaults = .standard,
        legacyDomain: String = AppIdentity.legacyBundleIdentifier
    ) {
        guard let legacyValues = defaults.persistentDomain(forName: legacyDomain) else {
            return
        }

        for key in preferenceKeys where defaults.object(forKey: key) == nil {
            guard let value = legacyValues[key] else { continue }
            defaults.set(value, forKey: key)
        }
    }

    /// Avoids two menu bar items and two competing system-modal Touch Bars
    /// when the renamed app is launched while the legacy app is still running.
    static func terminateLegacyApplications() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(
            withBundleIdentifier: AppIdentity.legacyBundleIdentifier
        )
        .filter { $0.processIdentifier != currentPID }
        .forEach { _ = $0.terminate() }
    }
}
