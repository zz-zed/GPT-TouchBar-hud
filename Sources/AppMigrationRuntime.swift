import AppKit
import Darwin

/// Dormant production wiring. No flag or preference can bypass the policy gate.
enum AppMigrationRuntime {
    static let helperArgument = "--hud-private-migration-helper"
    static let candidateArgument = "--hud-migration-candidate"
    struct Readiness: Codable {
        let id: String
        let target: String
        let identity: AppMigrationIdentity
        let pid: Int32
        let launchedAt: Date
    }
    private struct Handoff: Codable {
        let id: String
        let pid: Int32
        let launchedAt: Date
        let boot: String
    }
    static var isCandidate: Bool {
        guard AppInstallationMigrationPolicy.automaticMigrationEnabled else { return false }
        let driver = AppMigrationMacOSDriver.production()
        guard let transaction = try? driver.load(), transaction.phase != .committed,
              transaction.target == Bundle.main.bundleURL.standardizedFileURL.path,
              (try? driver.ownsPublishedTarget(transaction)) == true else { return false }
        return true
    }
    static func runHelperIfRequested() -> Bool {
        guard AppInstallationMigrationPolicy.automaticMigrationEnabled else { return false }
        let args = ProcessInfo.processInfo.arguments
        guard args.count == 3, args[1] == helperArgument else { return false }
        do {
            var driver = AppMigrationMacOSDriver.production()
            guard let transaction = try driver.load(), transaction.id == args[2],
                  Bundle.main.executableURL?.standardizedFileURL.path == transaction.stage + "/migration-helper.app/Contents/MacOS/" + AppIdentity.executableName else {
                throw AppMigrationError.invalidState
            }
            try driver.validate(transaction)
            let handoff = try JSONDecoder().decode(Handoff.self,
                from: driver.readPrivateFile(URL(fileURLWithPath: transaction.stage + "/handoff.json")))
            guard handoff.id == transaction.id, UUID(uuidString: handoff.boot) != nil, handoff.pid > 0 else {
                throw AppMigrationError.invalidState
            }
            let deadline = Date(timeIntervalSinceNow: 30)
            while handoff.boot == (try driver.bootIdentity) {
                if kill(handoff.pid, 0) != 0 {
                    guard errno == ESRCH else { throw AppMigrationError.deferred("ownerIdentityUnavailable") }
                    break
                }
                if let owner = NSRunningApplication(processIdentifier: handoff.pid), let date = owner.launchDate,
                   date != handoff.launchedAt { break } // Same PID, a different process.
                guard Date() < deadline else { throw AppMigrationError.deferred("ownerStillRunning") }
                Thread.sleep(forTimeInterval: 0.05)
            }
            driver.ignoredSourcePID = getpid() // The private signed helper shares the bundle ID.
            let lock = try AppInstallationMaintenanceLock(directory: URL(fileURLWithPath: transaction.source).deletingLastPathComponent(), purpose: .migration)
            try withExtendedLifetime(lock) {
                _ = try AppInstallationMigration(driver: driver, enabled: true).resume()
            }
        } catch AppInstallationMaintenanceLock.LockError.busy {
            // Another validated helper/installer owns maintenance; do not alter
            // its journal or interfere with an already running candidate.
            exit(EXIT_FAILURE)
        } catch {
            // A helper failure must not turn each old-path launch into an exit
            // loop. Defer this boot and keep or reopen the verified usable copy.
            let driver = AppMigrationMacOSDriver.production()
            if var transaction = try? driver.load(), let boot = try? driver.bootIdentity {
                transaction.deferredBoot = boot
                try? driver.save(transaction)
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleIdentifier)
                    .filter { $0.processIdentifier != getpid() }
                if running.isEmpty {
                    let path: String?
                    if (try? driver.ownsPublishedTarget(transaction)) == true { path = transaction.target }
                    else if (try? driver.fileID(transaction.source)) == transaction.sourceFileID,
                            (try? driver.inspect(transaction.source)) == transaction.identity { path = transaction.source }
                    else { path = nil }
                    if let path {
                        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        task.arguments = ["-n", path]; task.standardInput = FileHandle.nullDevice
                        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
                        do { try task.run(); task.waitUntilExit() } catch { /* Remain deferred. */ }
                    }
                }
            }
            exit(EXIT_FAILURE)
        }
        exit(EXIT_SUCCESS)
    }
    /// Runs inside the existing application lock, before UI/services are created.
    /// A successful handoff lets main return naturally and release that lock.
    static func prepareStartupHandoff() -> Bool {
        guard AppInstallationMigrationPolicy.automaticMigrationEnabled else { return false }
        guard !isCandidate, !ProcessInfo.processInfo.arguments.contains(AppUpdateProgressChannel.argument) else { return false }
        do {
            var driver = AppMigrationMacOSDriver.production()
            guard let transaction = try driver.load() else { return false }
            let path = Bundle.main.bundleURL.standardizedFileURL.path
            if path == transaction.stage + "/migration-helper.app" { return true }
            if path == transaction.stage + "/previous.app" {
                try driver.validate(transaction)
                guard try driver.fileID(path) == transaction.sourceFileID,
                      try driver.ownsPublishedTarget(transaction) else { return true }
                let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                task.arguments = ["-n", transaction.target]; task.standardInput = FileHandle.nullDevice
                task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
                try task.run(); task.waitUntilExit()
                return true
            }
            guard transaction.phase != .committed, transaction.source == path,
                  transaction.deferredBoot != (try driver.bootIdentity),
                  transaction.observedBoot != (try driver.bootIdentity),
                  let launchedAt = NSRunningApplication.current.launchDate else { return false }
            try driver.validate(transaction)
            if transaction.phase == .pending, driver.exists(transaction.target) { return false }
            guard try driver.fileID(transaction.source) == transaction.sourceFileID,
                  try driver.inspect(transaction.source) == transaction.identity else { return false }
            driver.ignoredSourcePID = getpid()
            try driver.safeToMigrate(transaction)
            let helper = try driver.preparePrivateHelper(transaction)
            let handoff = Handoff(id: transaction.id, pid: getpid(), launchedAt: launchedAt, boot: try driver.bootIdentity)
            try driver.atomic(JSONEncoder().encode(handoff), at: URL(fileURLWithPath: transaction.stage + "/handoff.json"))
            let process = Process(); process.executableURL = helper
            process.arguments = [helperArgument, transaction.id]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            return true
        } catch { return false }
    }
    /// Called after the same core initialization that emits an update receipt.
    static func didFinishCoreStartup() {
        guard AppInstallationMigrationPolicy.automaticMigrationEnabled else { return }
        let driver = AppMigrationMacOSDriver.production()
        do {
            if isCandidate {
                let args = ProcessInfo.processInfo.arguments
                guard let transaction = try driver.load(),
                      (!args.contains(candidateArgument) || (args.count == 3 && args[1] == candidateArgument && transaction.id == args[2])),
                      [.candidatePublished, .candidateReady, .referencesReady, .archived].contains(transaction.phase),
                      transaction.target == Bundle.main.bundleURL.standardizedFileURL.path,
                      try driver.inspect(transaction.target) == transaction.identity,
                      let date = NSRunningApplication.current.launchDate else { return }
                let ready = Readiness(id: transaction.id, target: transaction.target, identity: transaction.identity,
                                      pid: getpid(), launchedAt: date)
                try driver.atomic(JSONEncoder().encode(ready), at: URL(fileURLWithPath: transaction.stage + "/ready.json"))
                // A prior helper may have crashed. Its validated handoff still
                // names the exited source; a competing helper simply fails the
                // maintenance lock. The candidate continues serving normally.
                guard transaction.deferredBoot != (try driver.bootIdentity) else { return }
                let helper = try driver.preparePrivateHelper(transaction)
                let process = Process(); process.executableURL = helper; process.arguments = [helperArgument, transaction.id]
                process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
            } else {
                try AppInstallationMigration(driver: driver, enabled: true).recordPending(source: Bundle.main.bundleURL)
            }
        } catch { /* Deferred migration does not turn a functional upgrade into failure. */ }
    }
}
