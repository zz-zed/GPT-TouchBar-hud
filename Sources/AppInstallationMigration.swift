import Foundation

/// This capability ships dormant. Enabling requires a reviewed source change;
/// preferences, environment variables and command-line flags cannot enable it.
enum AppInstallationMigrationPolicy {
    static let automaticMigrationEnabled = false
}

struct AppMigrationIdentity: Codable, Equatable {
    let bundleID: String
    let version: String
    let build: String
    let architecture: String
    let cdhash: String
}

struct AppMigrationTransaction: Codable, Equatable {
    enum Phase: String, Codable {
        case pending, prepared, candidatePublished, candidateReady, referencesReady, archived, committed
    }
    let schema: Int
    let id: String
    let source: String
    let target: String
    let stage: String
    let identity: AppMigrationIdentity
    let sourceFileID: String
    let observedBoot: String
    var phase: Phase
    var deferredBoot: String? = nil
}

enum AppMigrationError: Error { case deferred(String), invalidState, interrupted }

/// Filesystem and OS operations have a real macOS implementation. Tests replace
/// only platform boundaries, while using the same journal/recovery coordinator.
protocol AppMigrationDriving {
    var bootIdentity: String { get throws }
    func validate(_ transaction: AppMigrationTransaction) throws
    func load() throws -> AppMigrationTransaction?
    func save(_ transaction: AppMigrationTransaction) throws
    func inspect(_ path: String) throws -> AppMigrationIdentity
    func fileID(_ path: String) throws -> String
    func exists(_ path: String) -> Bool
    func safeToMigrate(_ transaction: AppMigrationTransaction) throws
    func copyCandidate(_ transaction: AppMigrationTransaction) throws
    func publishCandidate(_ transaction: AppMigrationTransaction) throws
    func confirmCandidate(_ transaction: AppMigrationTransaction) throws
    func refreshLaunchReferences(_ transaction: AppMigrationTransaction) throws
    func archiveSource(_ transaction: AppMigrationTransaction) throws
}

struct AppInstallationMigration<Driver: AppMigrationDriving> {
    var driver: Driver
    let enabled: Bool
    var checkpoint: (AppMigrationTransaction.Phase) throws -> Void = { _ in }

    /// A pending record is made only after normal core startup, never before an
    /// old updater has had the opportunity to receive its old-path acknowledgement.
    func recordPending(source: URL) throws {
        guard enabled else { return }
        let source = source.standardizedFileURL
        guard source.lastPathComponent == AppIdentity.installedBundleFileName else { return }
        let identity = try driver.inspect(source.path)
        let sourceID = try driver.fileID(source.path)
        if let existing = try driver.load() {
            try driver.validate(existing)
            guard existing.phase == .pending else { return }
            if existing.source == source.path && existing.identity == identity && existing.sourceFileID == sourceID { return }
            // A later update invalidates old eligibility; start again in this boot.
        }
        let id = UUID().uuidString
        let parent = source.deletingLastPathComponent()
        let transaction = AppMigrationTransaction(schema: 1, id: id, source: source.path,
            target: parent.appendingPathComponent(AppIdentity.primaryInstalledBundleFileName).path,
            stage: parent.appendingPathComponent(".GPTTouchBarHUD-migration-" + id).path,
            identity: identity, sourceFileID: sourceID, observedBoot: try driver.bootIdentity, phase: .pending)
        try driver.validate(transaction)
        try driver.save(transaction)
    }

    /// Caller must own the maintenance lock and arrange the application-instance
    /// handoff. A new boot removes last boot's writers, but is not proof of success.
    func resume() throws -> AppMigrationTransaction? {
        guard enabled else { return nil }
        guard var transaction = try driver.load() else { return nil }
        try driver.validate(transaction)
        if transaction.phase == .committed { return transaction }
        guard transaction.observedBoot != (try driver.bootIdentity) else {
            throw AppMigrationError.deferred("waitingForNaturalSystemRestart")
        }
        guard transaction.deferredBoot != (try driver.bootIdentity) else { throw AppMigrationError.deferred("deferredInThisBoot") }
        try driver.safeToMigrate(transaction)
        func advance(_ phase: AppMigrationTransaction.Phase) throws {
            transaction.phase = phase
            try driver.save(transaction)
            try checkpoint(phase)
        }
        if transaction.phase == .pending {
            guard !driver.exists(transaction.target), try driver.inspect(transaction.source) == transaction.identity,
                  try driver.fileID(transaction.source) == transaction.sourceFileID else {
                throw AppMigrationError.deferred("sourceChangedOrTargetExists")
            }
            try driver.copyCandidate(transaction)
            try advance(.prepared)
        }
        if transaction.phase == .prepared {
            try driver.publishCandidate(transaction)
            try advance(.candidatePublished)
        }
        if transaction.phase == .candidatePublished {
            guard try driver.inspect(transaction.target) == transaction.identity else { throw AppMigrationError.invalidState }
            // open() returning success alone is insufficient: this waits for a
            // private nonce, exact-path and actual-process readiness receipt.
            try driver.confirmCandidate(transaction)
            try advance(.candidateReady)
        }
        if [.candidateReady, .referencesReady, .archived].contains(transaction.phase) {
            // A durable receipt from a previous boot does not prove a process
            // is ready now. Recovery must validate or relaunch the candidate.
            try driver.confirmCandidate(transaction)
        }
        if transaction.phase == .candidateReady {
            try driver.refreshLaunchReferences(transaction)
            try advance(.referencesReady)
        }
        if transaction.phase == .referencesReady {
            try driver.archiveSource(transaction)
            try advance(.archived)
        }
        if transaction.phase == .archived {
            guard try driver.inspect(transaction.target) == transaction.identity else { throw AppMigrationError.invalidState }
            try advance(.committed)
        }
        return transaction
    }
}
