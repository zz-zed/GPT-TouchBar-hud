import Foundation
@testable import HUDCoreTestSupport

/// Reuses the original model/geometry assertions without NSApplication.run,
/// NSMenu tracking, a window, an event tap, or a physical display.
@main
enum NotchHarness {
    static var checks: [String] = []
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        checks.append(message)
    }
    static func main() {
        let suite = "CoreNotchModelChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        DisplayLanguage.defaults = defaults
        defer {
            DisplayLanguage.defaults = .standard
            defaults.removePersistentDomain(forName: suite)
        }
        modelChecks()
        geometryChecks()
        contentChecks()
        print("PASS: \(checks.count) original pure notch model, layout and content checks")
    }
}
