import Foundation

@main
struct DiagnosticEnvironmentTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { fatalError(message) }
        }
        func snapshot(_ value: String?) -> DiagnosticEnvironmentSnapshot {
            DiagnosticEnvironmentSnapshot(capturedAt: Date(timeIntervalSince1970: 100), appVersion: value,
                appBuild: value, buildSource: value, operatingSystemVersion: value, operatingSystemBuild: value,
                model: value, hardwareArchitecture: .unknown, processArchitecture: .arm64,
                translated: nil, host: .unknown, hostVersion: value, location: .other)
        }
        for secret in ["person@example.com", "/Users/private/test", "sk-secret\nhello", "26.1\rsecret", "26.1\n", "Task title", String(repeating: "1", count: 100), "{\"token\": 99}"] {
            let result = snapshot(secret)
            let bytes = try JSONEncoder().encode(result)
            let text = String(decoding: bytes, as: UTF8.self)
            check(result.appVersion.status == .unknown && result.model.status == .unknown, "Reject arbitrary environment input")
            check(!text.contains(secret) && result.buildSource.value == nil, "No sensitive metadata output")
        }
        let missing = snapshot(nil)
        check(missing.rosetta.status == .unknown && missing.hardwareArchitecture.value == nil, "Unknown is not false or zero")
        check(missing.hostVersion.status == .unknown, "Missing host version remains unknown")
        let known = DiagnosticEnvironmentSnapshot(capturedAt: Date(timeIntervalSince1970: 100), appVersion: "0.1.39",
            appBuild: "43", buildSource: String(repeating: "a", count: 64), operatingSystemVersion: "11.0.0",
            operatingSystemBuild: "20A2411", model: "MacBookPro17,1", hardwareArchitecture: .arm64,
            processArchitecture: .x86_64, translated: true, host: .codex, hostVersion: "26.1007.1", location: .applications)
        check(known.model.value == "MacBookPro17,1" && known.rosetta.value == "translated", "Whitelisted metadata retained")
        check(known.buildSource.value?.count == 64 && known.appBuild.value == "43", "Build identity admitted")
        check(DiagnosticEnvironmentSnapshot.locationCategory(URL(fileURLWithPath: "/Applications/Private.app")) == .applications, "Location reduced to category")
        check(DiagnosticEnvironmentSnapshot.locationCategory(URL(fileURLWithPath: "/Volumes/private/App.app")) == .other, "Volume alone is not proof of DMG")
        print("PASS: \(checks) diagnostic environment checks")
    }
}
