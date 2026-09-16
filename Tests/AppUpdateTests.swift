import Foundation

@main enum AppUpdateTests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message); count += 1
    }
    static func main() throws {
        check(AppVersion("0.1.9")! < AppVersion("0.1.10")!, "Numeric version comparison")
        check(AppVersion("v1.2.0") == AppVersion("1.2"), "Normalize tag and trailing zeros")
        check(AppVersion("0.1.21")! > AppVersion("v0.1.20")!, "Do not downgrade development versions")
        for value in ["", "1", "1..2", "1.2-beta", "1.2/evil", "1.２", "1.-2", "1.9999999999999999999999999"] {
            check(AppVersion(value) == nil, "Reject invalid version \(value)")
        }
        let name = "GPT-TouchBar-HUD-1.2.3-arm64.dmg"
        let root = "https://github.com/\(AppRelease.repository)/releases/download/v1.2.3/"
        let asset = AppRelease.Asset(name: name, browser_download_url: URL(string: root + name)!, size: 123)
        let sums = AppRelease.Asset(name: "SHA256SUMS.txt", browser_download_url: URL(string: root + "SHA256SUMS.txt")!, size: 100)
        let release = AppRelease(tag_name: "v1.2.3", draft: false, prerelease: false, assets: [asset, sums])
        check(release.installer(architecture: "arm64")?.name == name, "Matching architecture")
        check(release.installer(architecture: "x86_64") == nil, "Wrong architecture not selected")
        check(release.checksums != nil, "Checksum asset matched")
        let fallback = AppRelease.fromLatestPageURL(URL(string: "https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v1.2.3")!)
        check(fallback?.installer(architecture: "arm64")?.name == name, "Latest page redirect constructs trusted release assets")
        check(fallback?.installer(architecture: "arm64")?.size == 0, "Fallback defers size verification to asset HEAD")
        for url in [
            "http://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v1.2.3",
            "https://evil.example/zz-zed/GPT-TouchBar-hud/releases/tag/v1.2.3",
            "https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v1.2.3/extra",
            "https://github.com/other/repo/releases/tag/v1.2.3",
            "https://user@github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v1.2.3"
        ] {
            check(AppRelease.fromLatestPageURL(URL(string: url)!) == nil, "Reject untrusted latest-page redirect")
        }
        for url in ["https://example.com/" + name, "http://github.com/" + name, root.replacingOccurrences(of: "v1.2.3", with: "v1.2.4") + name] {
            let bad = AppRelease(tag_name: "v1.2.3", draft: false, prerelease: false, assets: [.init(name: name, browser_download_url: URL(string: url)!, size: 123)])
            check(bad.installer(architecture: "arm64") == nil, "Reject untrusted asset location")
        }
        let hash = String(repeating: "ab", count: 32)
        check(AppRelease.checksum(in: hash + "  " + name + "\n", filename: name) == hash, "Parse shasum format")
        check(AppRelease.checksum(in: hash + " *" + name, filename: name) == hash, "Parse binary checksum format")
        check(AppRelease.checksum(in: "123  " + name, filename: name) == nil, "Reject short checksum")
        check(AppRelease.checksum(in: hash + "  other.dmg", filename: name) == nil, "Reject unrelated checksum")
        check(AppRelease.checksum(in: "\(hash)  \(name)\n\(hash)  \(name)", filename: name) == nil, "Reject duplicate checksum entries")
        try testInstaller()
        let updaterSource = try String(contentsOfFile: "Sources/AppUpdater.swift", encoding: .utf8)
        check(!updaterSource.contains("Timer.") && !updaterSource.contains("asyncAfter") && !updaterSource.contains("scheduledCheck"),
              "No startup or background update scheduling")
        print("PASS: \(count) update policy checks")
    }

    static func testInstaller() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("update-test-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let original = try String(contentsOfFile: "Resources/install-update.sh", encoding: .utf8)
        let guardLine = "[[ \"$target_app\" == /Applications/'GPT TouchBar HUD.app' || \"$target_app\" == \"$HOME/Applications/GPT TouchBar HUD.app\" ]] || exit 2"
        check(original.contains(guardLine), "Installer target guard is present")
        // Only the temporary test copy permits an isolated target and mocks LaunchServices.
        for scenario in ["success", "move-failure", "launch-failure"] {
            let directory = root.appendingPathComponent(scenario)
            let target = directory.appendingPathComponent("GPT TouchBar HUD.app")
            let staging = directory.appendingPathComponent(".GPTTouchBarHUD-update-fixture")
            let newApp = staging.appendingPathComponent("new.app")
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            try manager.createDirectory(at: newApp, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: target.appendingPathComponent("marker"))
            try Data("new".utf8).write(to: newApp.appendingPathComponent("marker"))
            var script = original.replacingOccurrences(of: guardLine, with: "[[ \"$target_app\" == \"$UPDATE_TEST_TARGET\" ]] || exit 2")
                .replacingOccurrences(of: "/usr/bin/open", with: scenario == "launch-failure" ? "/usr/bin/false" : "/usr/bin/true")
            if scenario == "move-failure" {
                script = script.replacingOccurrences(of: "if ! /bin/mv \"$staging_dir/new.app\" \"$target_app\"; then", with: "if ! /usr/bin/false; then")
            }
            let helper = directory.appendingPathComponent("helper.sh")
            try script.write(to: helper, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [helper.path, "999999", target.path, staging.path]
            var environment = ProcessInfo.processInfo.environment
            environment["UPDATE_TEST_TARGET"] = target.path
            process.environment = environment
            try process.run(); process.waitUntilExit()
            let installed = try String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8)
            check(installed == (scenario == "success" ? "new" : "old"), "\(scenario): correct application retained")
            check((process.terminationStatus == 0) == (scenario == "success"), "\(scenario): correct exit status")
            if scenario == "success" {
                let previous = try String(contentsOf: staging.appendingPathComponent("previous.app/marker"), encoding: .utf8)
                check(previous == "old", "Old app retained for recovery")
            }
        }
    }
}
