import AppKit
import Foundation

@main struct MigrationTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "MigrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }
    static func reject(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw NSError(domain: "MigrationTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Accepted: " + message])
    }
    static func run(_ executable: String, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit(); try check(p.terminationStatus == 0, "Fixture command failed")
    }
    static func fixture(_ name: String) throws -> (URL, AppMigrationMacOSDriver, URL) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("hud-migration-test-" + name + "-" + UUID().uuidString)
        let home = root.appendingPathComponent("home"), applications = root.appendingPathComponent("Applications")
        for dir in [home.appendingPathComponent("Applications"), applications] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let source = applications.appendingPathComponent(AppIdentity.installedBundleFileName)
        let contents = source.appendingPathComponent("Contents")
        let macos = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": AppIdentity.bundleIdentifier,
            "CFBundleExecutable": AppIdentity.executableName, "CFBundlePackageType": "APPL",
            "CFBundleName": "GPT HUD", "CFBundleShortVersionString": "0.1.46", "CFBundleVersion": "49"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(atPath: CommandLine.arguments[0], toPath: macos.appendingPathComponent(AppIdentity.executableName).path)
        try run("/usr/bin/codesign", ["--force", "--sign", "-", source.path])
        var driver = AppMigrationMacOSDriver(home: home, systemApplications: applications,
            journalDirectory: home.appendingPathComponent("journal"), bootOverride: "11111111-1111-1111-1111-111111111111")
        driver.updateSafetyOverride = {}
        driver.refreshReferences = { transaction in
            // An isolated registration fixture, not the real user's launchd.
            let marker = home.appendingPathComponent("registration")
            try Data(transaction.target.utf8).write(to: marker)
        }
        driver.launchCandidate = { transaction in
            let receipt = URL(fileURLWithPath: transaction.stage).appendingPathComponent("ready.json")
            let data = try JSONSerialization.data(withJSONObject: ["id": transaction.id, "target": transaction.target])
            try data.write(to: receipt, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        }
        driver.receiptValidator = { url, transaction in
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
            try check(object?["id"] == transaction.id && object?["target"] == transaction.target, "Ready nonce/path mismatch")
        }
        return (root, driver, source)
    }
    static func withFixture(_ name: String, _ body: (URL, inout AppMigrationMacOSDriver, URL) throws -> Void) throws {
        FileHandle.standardError.write(Data(("CASE " + name + "\n").utf8))
        let (root, initial, source) = try fixture(name); var driver = initial
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, &driver, source)
    }
    static func main() throws {
        try check(!AppInstallationMigrationPolicy.automaticMigrationEnabled, "Production migration must be OFF")
        try check(!AppMigrationRuntime.runHelperIfRequested(), "OFF helper must not run")
        try check(!AppMigrationRuntime.prepareStartupHandoff(), "OFF startup must not run")
        AppMigrationRuntime.didFinishCoreStartup()
        try withFixture("off") { _, driver, source in
            let coordinator = AppInstallationMigration(driver: driver, enabled: false)
            try coordinator.recordPending(source: source)
            try check(try coordinator.resume() == nil, "OFF must return no transaction")
            try check(!driver.exists(driver.journalDirectory.path), "OFF wrote journal")
        }
        try withFixture("success") { root, driver, source in
            try AppInstallationMigration(driver: driver, enabled: true).recordPending(source: source)
            try reject("same-boot migration") { _ = try AppInstallationMigration(driver: driver, enabled: true).resume() }
            driver.bootOverride = "22222222-2222-2222-2222-222222222222"
            var lock: AppInstallationMaintenanceLock? = try AppInstallationMaintenanceLock(directory: source.deletingLastPathComponent(), purpose: .migration)
            try withExtendedLifetime(lock) {
                var coordinator = AppInstallationMigration(driver: driver, enabled: true)
                coordinator.checkpoint = { FileHandle.standardError.write(Data(("PHASE " + $0.rawValue + "\n").utf8)) }
                let result = try coordinator.resume()!
                try check(result.phase == .committed, "Not committed")
                try check(!driver.exists(source.path) && driver.exists(result.target), "Wrong final paths")
                try check(try driver.fileID(result.stage + "/previous.app") == result.sourceFileID, "Original not retained")
                try check(try AppInstallationMigration(driver: driver, enabled: true).resume() == result, "Commit not idempotent")
            }
            lock = nil
            let updateLock = try AppInstallationMaintenanceLock(directory: source.deletingLastPathComponent())
            withExtendedLifetime(updateLock) {}
            try check(try String(contentsOf: driver.home.appendingPathComponent("registration")) == source.deletingLastPathComponent().appendingPathComponent(AppIdentity.primaryInstalledBundleFileName).path, "Registration target wrong")
            try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("not-owned").path), "Unexpected file")
        }
        for phase in [AppMigrationTransaction.Phase.prepared, .candidatePublished, .candidateReady, .referencesReady, .archived, .committed] {
            try withFixture("interrupt-" + phase.rawValue) { _, driver, source in
                try AppInstallationMigration(driver: driver, enabled: true).recordPending(source: source)
                driver.bootOverride = "22222222-2222-2222-2222-222222222222"
                var coordinator = AppInstallationMigration(driver: driver, enabled: true)
                coordinator.checkpoint = { if $0 == phase { throw AppMigrationError.interrupted } }
                try reject("checkpoint interruption") { _ = try coordinator.resume() }
                if phase != .committed {
                    try reject("update during persisted migration") { _ = try AppInstallationMaintenanceLock(directory: source.deletingLastPathComponent()) }
                }
                let restored = try AppInstallationMigration(driver: driver, enabled: true).resume()
                try check(restored?.phase == .committed, "Recovery failed at " + phase.rawValue)
            }
        }
        try withFixture("publish-before-journal") { _, driver, source in
            try AppInstallationMigration(driver: driver, enabled: true).recordPending(source: source)
            driver.bootOverride = "22222222-2222-2222-2222-222222222222"
            var c = AppInstallationMigration(driver: driver, enabled: true)
            c.checkpoint = { if $0 == .prepared { throw AppMigrationError.interrupted } }
            try reject("prepared interruption") { _ = try c.resume() }
            let state = try driver.load()!
            try driver.publishCandidate(state) // Simulate power loss before phase persistence.
            try check(try AppInstallationMigration(driver: driver, enabled: true).resume()?.phase == .committed, "Unjournaled publish not recovered")
        }
        try withFixture("collision") { _, driver, source in
            try AppInstallationMigration(driver: driver, enabled: true).recordPending(source: source)
            let state = try driver.load()!
            try FileManager.default.copyItem(atPath: source.path, toPath: state.target)
            let id = try driver.fileID(state.target); driver.bootOverride = "22222222-2222-2222-2222-222222222222"
            try reject("same-ID existing target") { _ = try AppInstallationMigration(driver: driver, enabled: true).resume() }
            try check(try driver.fileID(state.target) == id && driver.exists(source.path), "Collision changed user file")
        }
        for dangling in [false, true] {
            try withFixture("symlink") { _, driver, source in
                try AppInstallationMigration(driver: driver, enabled: true).recordPending(source: source)
                let state = try driver.load()!
                try FileManager.default.createSymbolicLink(atPath: state.target, withDestinationPath: dangling ? state.target + "-missing" : source.path)
                driver.bootOverride = "22222222-2222-2222-2222-222222222222"
                try reject("linked target") { _ = try AppInstallationMigration(driver: driver, enabled: true).resume() }
                try check(driver.exists(source.path), "Symlink case damaged source")
            }
        }
        try withFixture("target-race") { _, driver, source in
            try AppInstallationMigration(driver: driver, enabled: true).recordPending(source: source)
            driver.bootOverride = "22222222-2222-2222-2222-222222222222"
            var c = AppInstallationMigration(driver: driver, enabled: true)
            c.checkpoint = { if $0 == .prepared { throw AppMigrationError.interrupted } }
            try reject("prepare checkpoint") { _ = try c.resume() }
            let state = try driver.load()!
            try FileManager.default.copyItem(atPath: source.path, toPath: state.target)
            let id = try driver.fileID(state.target)
            try reject("target grabbed before publish") { _ = try AppInstallationMigration(driver: driver, enabled: true).resume() }
            try check(try driver.fileID(state.target) == id, "Target race overwritten")
        }
        try withFixture("update-busy") { _, driver, source in
            try AppInstallationMigration(driver: driver, enabled: true).recordPending(source: source)
            driver.bootOverride = "22222222-2222-2222-2222-222222222222"; driver.updateSafetyOverride = { throw AppMigrationError.deferred("activeUpdate") }
            try reject("active update") { _ = try AppInstallationMigration(driver: driver, enabled: true).resume() }
            try check(driver.exists(source.path), "Busy update damaged source")
        }
        try withFixture("permission") { _, driver, source in
            try AppInstallationMigration(driver: driver, enabled: true).recordPending(source: source)
            driver.bootOverride = "22222222-2222-2222-2222-222222222222"
            driver.updateSafetyOverride = { throw AppMigrationError.deferred("parentNotWritable") }
            try reject("permission unavailable") { _ = try AppInstallationMigration(driver: driver, enabled: true).resume() }
        }
        try withFixture("source-race") { _, driver, source in
            try AppInstallationMigration(driver: driver, enabled: true).recordPending(source: source)
            let replacement = source.deletingLastPathComponent().appendingPathComponent("replacement.app")
            try FileManager.default.copyItem(at: source, to: replacement)
            try FileManager.default.moveItem(at: source, to: source.deletingLastPathComponent().appendingPathComponent("user-preserved.app"))
            try FileManager.default.moveItem(at: replacement, to: source)
            driver.bootOverride = "22222222-2222-2222-2222-222222222222"
            try reject("same-version replacement source inode") { _ = try AppInstallationMigration(driver: driver, enabled: true).resume() }
        }
        try withFixture("references-fail") { _, driver, source in
            try AppInstallationMigration(driver: driver, enabled: true).recordPending(source: source)
            driver.bootOverride = "22222222-2222-2222-2222-222222222222"; driver.refreshReferences = { _ in throw AppMigrationError.deferred("registrationUnavailable") }
            try reject("registration failure") { _ = try AppInstallationMigration(driver: driver, enabled: true).resume() }
            let state = try driver.load()!
            try check(state.phase == .candidateReady && driver.exists(source.path) && driver.exists(state.target), "Unsafe registration fallback")
            driver.refreshReferences = { _ in }
            try check(try AppInstallationMigration(driver: driver, enabled: true).resume()?.phase == .committed, "Registration resume failed")
        }
        try withFixture("reinstalled-pending") { _, driver, source in
            try AppInstallationMigration(driver: driver, enabled: true).recordPending(source: source)
            let old = try driver.load()!
            let replacement = source.deletingLastPathComponent().appendingPathComponent("replacement.app")
            try FileManager.default.copyItem(at: source, to: replacement)
            try FileManager.default.moveItem(at: source, to: source.deletingLastPathComponent().appendingPathComponent("retained.app"))
            try FileManager.default.moveItem(at: replacement, to: source)
            driver.bootOverride = "22222222-2222-2222-2222-222222222222"
            try AppInstallationMigration(driver: driver, enabled: true).recordPending(source: source)
            let current = try driver.load()!
            try check(current.sourceFileID != old.sourceFileID && current.id != old.id, "Same-version reinstall kept stale pending")
            try reject("reinstalled pending must wait a later boot") { _ = try AppInstallationMigration(driver: driver, enabled: true).resume() }
        }
        try withFixture("deferred-this-boot") { _, driver, source in
            try AppInstallationMigration(driver: driver, enabled: true).recordPending(source: source)
            driver.bootOverride = "22222222-2222-2222-2222-222222222222"
            var current = try driver.load()!; current.deferredBoot = driver.bootOverride
            try driver.save(current)
            try reject("failed helper must not cause relaunch loop") { _ = try AppInstallationMigration(driver: driver, enabled: true).resume() }
            try check(driver.exists(source.path), "Deferred source is not usable")
        }
        try withFixture("alternate-install") { _, driver, source in
            try AppInstallationMigration(driver: driver, enabled: true).recordPending(source: source)
            let alternate = driver.home.appendingPathComponent("Applications/" + AppIdentity.primaryInstalledBundleFileName)
            try FileManager.default.copyItem(at: source, to: alternate)
            driver.bootOverride = "22222222-2222-2222-2222-222222222222"
            driver.updateSafetyOverride = nil
            try reject("second installation") { _ = try AppInstallationMigration(driver: driver, enabled: true).resume() }
            try check(driver.exists(source.path) && driver.exists(alternate.path), "Independent install changed")
        }
        try withFixture("signed-private-helper") { _, driver, source in
            try AppInstallationMigration(driver: driver, enabled: true).recordPending(source: source)
            let transaction = try driver.load()!
            driver.helperSourceBundle = source
            let helper = try driver.preparePrivateHelper(transaction)
            try check(helper.path.hasSuffix("/migration-helper.app/Contents/MacOS/" + AppIdentity.executableName), "Helper lost signed bundle structure")
            try check(try driver.inspect(transaction.stage + "/migration-helper.app") == transaction.identity, "Copied helper signature/identity mismatch")
            try check(try driver.preparePrivateHelper(transaction) == helper, "Helper copy not idempotent")
        }
        print("PASS: \(checks) dormant migration / real filesystem, signature, interruption and recovery checks")
        print("BOUNDARY: launch/readiness/launchd are injected fixtures; real LaunchServices handoff and real boot transition are not exercised.")
    }
}
