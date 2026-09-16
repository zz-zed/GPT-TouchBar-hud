import Foundation

@main
enum AppMigrationTests {
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func main() {
        let suffix = UUID().uuidString
        let legacyDomain = "io.github.zz-zed.GPTTouchBarHUD.Tests.legacy.\(suffix)"
        let currentDomain = "io.github.zz-zed.GPTTouchBarHUD.Tests.current.\(suffix)"
        let defaults = UserDefaults(suiteName: currentDomain)!

        defer {
            defaults.removePersistentDomain(forName: legacyDomain)
            defaults.removePersistentDomain(forName: currentDomain)
        }

        defaults.setPersistentDomain([
            "hud.color": "green",
            "hud.backgroundOpacity": 0.6,
            "persistentTouchBarEnabled": false,
            "unrelated.preference": "must not migrate"
        ], forName: legacyDomain)
        defaults.set("purple", forKey: "hud.color")

        LegacyAppMigration.migratePreferences(defaults: defaults, legacyDomain: legacyDomain)

        check(defaults.string(forKey: "hud.color") == "purple", "New preference wins over legacy value")
        check(defaults.double(forKey: "hud.backgroundOpacity") == 0.6, "Missing HUD preference migrates")
        check(defaults.object(forKey: "persistentTouchBarEnabled") as? Bool == false,
              "Persistent Touch Bar preference migrates")
        check(defaults.object(forKey: "unrelated.preference") == nil, "Unknown legacy keys are ignored")

        print("PASS: \(checks) legacy migration checks")
    }
}
