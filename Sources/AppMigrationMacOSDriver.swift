import AppKit
import CoreServices
import Darwin

/// Real filesystem/launchd/LaunchServices driver. Production construction uses
/// only the two Applications directories; tests must explicitly inject a root.
struct AppMigrationMacOSDriver: AppMigrationDriving {
    let home: URL
    let systemApplications: URL
    let journalDirectory: URL
    var launchCandidate: ((AppMigrationTransaction) throws -> Void)?
    var refreshReferences: ((AppMigrationTransaction) throws -> Void)?
    var bootOverride: String?
    var updateSafetyOverride: (() throws -> Void)?
    var helperSourceBundle: URL?
    var ignoredSourcePID: Int32?
    var receiptValidator: ((URL, AppMigrationTransaction) throws -> Void)?
    private let fm = FileManager.default

    static func production() -> Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Self(home: home, systemApplications: URL(fileURLWithPath: "/Applications"),
            journalDirectory: home.appendingPathComponent("Library/Application Support/" + AppIdentity.appSupportDirectoryName + "/installation-migration"))
    }
    var bootIdentity: String {
        get throws {
            if let bootOverride { return bootOverride }
            var size = 0
            guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size < 256 else {
                throw AppMigrationError.deferred("bootIdentityUnavailable")
            }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { throw AppMigrationError.invalidState }
            let value = String(cString: bytes)
            guard UUID(uuidString: value) != nil else { throw AppMigrationError.invalidState }
            return value
        }
    }
    var journal: URL { journalDirectory.appendingPathComponent("state.json") }
    func exists(_ path: String) -> Bool { (try? fm.attributesOfItem(atPath: path)) != nil }
    private func direct(_ url: URL) throws {
        guard url.standardizedFileURL.path == url.path, url.resolvingSymlinksInPath().path == url.path else { throw AppMigrationError.deferred("nonDirectPath:" + url.lastPathComponent) }
        if let attributes = try? fm.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw AppMigrationError.invalidState
        }
    }
    func fileID(_ path: String) throws -> String {
        var value = stat()
        guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw AppMigrationError.invalidState }
        return "\(value.st_dev):\(value.st_ino)"
    }
    private func privateDirectory(_ url: URL, create: Bool = false) throws {
        try direct(url)
        if !exists(url.path), create {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let a = try fm.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeDirectory,
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (a[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw AppMigrationError.invalidState }
    }
    func validate(_ transaction: AppMigrationTransaction) throws {
        let parent = URL(fileURLWithPath: transaction.source).deletingLastPathComponent()
        let allowed = [systemApplications.standardizedFileURL, home.appendingPathComponent("Applications").standardizedFileURL]
        guard transaction.schema == 1, UUID(uuidString: transaction.id) != nil,
              allowed.contains(where: { $0.standardizedFileURL.path == parent.standardizedFileURL.path }), transaction.source == parent.appendingPathComponent(AppIdentity.installedBundleFileName).path,
              transaction.target == parent.appendingPathComponent(AppIdentity.primaryInstalledBundleFileName).path,
              transaction.stage == parent.appendingPathComponent(".GPTTouchBarHUD-migration-" + transaction.id).path,
              transaction.identity.bundleID == AppIdentity.bundleIdentifier,
              UUID(uuidString: transaction.observedBoot) != nil,
              (transaction.deferredBoot == nil || UUID(uuidString: transaction.deferredBoot!) != nil), !transaction.sourceFileID.isEmpty else { throw AppMigrationError.invalidState }
        for url in [parent, URL(fileURLWithPath: transaction.source), URL(fileURLWithPath: transaction.target),
                    URL(fileURLWithPath: transaction.stage)] { try direct(url) }
    }
    func load() throws -> AppMigrationTransaction? {
        guard exists(journalDirectory.path) else { return nil }
        try privateDirectory(journalDirectory)
        guard exists(journal.path) else { return nil }
        return try JSONDecoder().decode(AppMigrationTransaction.self, from: secureData(journal))
    }
    func save(_ transaction: AppMigrationTransaction) throws {
        try validate(transaction)
        try privateDirectory(journalDirectory, create: true)
        let bytes = try JSONEncoder().encode(transaction)
        // A durable marker also prevents a later updater from starting while a
        // crashed migration awaits reconciliation. Pending alone never blocks it.
        if transaction.phase != .pending {
            try privateDirectory(stage(transaction))
            try atomic(bytes, at: stage(transaction).appendingPathComponent("transaction.json"))
        }
        try atomic(bytes, at: journal)
    }
    private func secureData(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw AppMigrationError.invalidState }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var a = stat()
        guard fstat(fd, &a) == 0, a.st_mode & S_IFMT == S_IFREG, a.st_uid == getuid(),
              a.st_mode & 0o777 == 0o600, a.st_nlink == 1, a.st_size <= 65536 else { throw AppMigrationError.invalidState }
        return handle.readDataToEndOfFile()
    }
    func atomic(_ data: Data, at url: URL) throws {
        try direct(url.deletingLastPathComponent())
        if exists(url.path) { _ = try secureData(url) }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".state-" + UUID().uuidString)
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AppMigrationError.invalidState }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? fm.removeItem(at: temp) }
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0, rename(temp.path, url.path) == 0 else { throw AppMigrationError.invalidState }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        if parent >= 0 { defer { close(parent) }; _ = fsync(parent) }
    }
    @discardableResult private func run(_ command: String, _ arguments: [String]) throws -> String {
        let task = Process(); task.executableURL = URL(fileURLWithPath: command); task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        let output = Pipe(); task.standardOutput = output; task.standardError = output
        try task.run()
        // Commands here produce bounded metadata. Drain before wait to avoid a full pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw AppMigrationError.deferred("platformOperationFailed") }
        return String(decoding: data, as: UTF8.self)
    }
    func inspect(_ path: String) throws -> AppMigrationIdentity {
        let url = URL(fileURLWithPath: path); try direct(url)
        guard let b = Bundle(url: url), b.bundleIdentifier == AppIdentity.bundleIdentifier else { throw AppMigrationError.deferred("bundleIDMismatch") }
        guard let version = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              AppVersion(version) != nil, let build = b.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty else { throw AppMigrationError.deferred("bundleVersionMissing") }
        guard let executable = b.executableURL, executable.lastPathComponent == AppIdentity.executableName else {
            throw AppMigrationError.deferred("bundleExecutableMissing")
        }
        guard executable.resolvingSymlinksInPath().path == executable.standardizedFileURL.path else { throw AppMigrationError.deferred("linkedExecutable") }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", path])
        let signature = try run("/usr/bin/codesign", ["-dvvv", path])
        guard let hash = signature.split(separator: "\n").first(where: { $0.hasPrefix("CDHash=") })?.dropFirst(7),
              hash.count == 40, hash.allSatisfy({ $0.isHexDigit }) else { throw AppMigrationError.invalidState }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let architectures = try run("/usr/bin/lipo", ["-archs", executable.path]).split(whereSeparator: \.isWhitespace)
        guard architectures == [Substring(architecture)] else { throw AppMigrationError.deferred("architectureMismatch") }
        return AppMigrationIdentity(bundleID: AppIdentity.bundleIdentifier, version: version, build: build,
                                    architecture: architecture, cdhash: String(hash))
    }
    func safeToMigrate(_ transaction: AppMigrationTransaction) throws {
        try validate(transaction)
        if let updateSafetyOverride { try updateSafetyOverride(); return }
        let parent = URL(fileURLWithPath: transaction.source).deletingLastPathComponent()
        let alternate = parent.standardizedFileURL.path == systemApplications.standardizedFileURL.path ? home.appendingPathComponent("Applications") : systemApplications
        for name in [AppIdentity.installedBundleFileName, AppIdentity.primaryInstalledBundleFileName] {
            if exists(alternate.appendingPathComponent(name).path) { throw AppMigrationError.deferred("anotherInstallation") }
        }
        guard fm.isWritableFile(atPath: parent.path) else { throw AppMigrationError.deferred("parentNotWritable") }
        var boot = timeval(); var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { throw AppMigrationError.deferred("bootTimeUnavailable") }
        let bootDate = Date(timeIntervalSince1970: Double(boot.tv_sec))
        for entry in try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            where entry.lastPathComponent.hasPrefix(".GPTTouchBarHUD-update-") {
            let a = try fm.attributesOfItem(atPath: entry.path)
            // New historical clients create a fresh stage in this boot. Unknown,
            // linked or recently touched stages defer; mtime never proves success.
            guard a[.type] as? FileAttributeType == .typeDirectory else { throw AppMigrationError.deferred("unknownUpdateState") }
            if let date = a[.modificationDate] as? Date, date >= bootDate { throw AppMigrationError.deferred("updateInCurrentBoot") }
        }
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleIdentifier)
        guard candidates.allSatisfy({ $0.processIdentifier == ignoredSourcePID || $0.bundleURL?.standardizedFileURL.path == transaction.target }) else {
            throw AppMigrationError.deferred("sourceOrOtherInstanceStillRunning")
        }
    }
    private func stage(_ transaction: AppMigrationTransaction) -> URL { URL(fileURLWithPath: transaction.stage) }
    private func candidate(_ transaction: AppMigrationTransaction) -> URL { stage(transaction).appendingPathComponent("candidate.app") }
    private func publishedID(_ transaction: AppMigrationTransaction) -> URL { stage(transaction).appendingPathComponent("published-file-id") }
    func copyCandidate(_ transaction: AppMigrationTransaction) throws {
        try privateDirectory(stage(transaction), create: true)
        let destination = candidate(transaction)
        if exists(destination.path) {
            guard try inspect(destination.path) == transaction.identity else { throw AppMigrationError.invalidState }; return
        }
        let copying = stage(transaction).appendingPathComponent("copying.app")
        if exists(copying.path) {
            // Preserve interrupted copies rather than deleting an uncertain tree.
            try exclusiveMove(copying.path, stage(transaction).appendingPathComponent("incomplete-" + UUID().uuidString).path)
        }
        _ = try run("/usr/bin/ditto", [transaction.source, copying.path])
        guard try inspect(copying.path) == transaction.identity else { throw AppMigrationError.invalidState }
        try exclusiveMove(copying.path, destination.path)
    }
    func publishCandidate(_ transaction: AppMigrationTransaction) throws {
        try privateDirectory(stage(transaction))
        if exists(transaction.target) {
            guard !exists(candidate(transaction).path), try ownsTarget(transaction) else { throw AppMigrationError.deferred("targetCollision") }; return
        }
        guard try inspect(candidate(transaction).path) == transaction.identity else { throw AppMigrationError.invalidState }
        try atomic(Data(try fileID(candidate(transaction).path).utf8), at: publishedID(transaction))
        try exclusiveMove(candidate(transaction).path, transaction.target)
    }
    private func ownsTarget(_ transaction: AppMigrationTransaction) throws -> Bool {
        try validate(transaction)
        let id = String(decoding: try secureData(publishedID(transaction)), as: UTF8.self)
        return try fileID(transaction.target) == id && inspect(transaction.target) == transaction.identity
    }
    func confirmCandidate(_ transaction: AppMigrationTransaction) throws {
        guard try ownsTarget(transaction) else { throw AppMigrationError.invalidState }
        let receipt = stage(transaction).appendingPathComponent("ready.json")
        func confirmed() throws -> Bool {
            guard exists(receipt.path) else { return false }
            if let receiptValidator { try receiptValidator(receipt, transaction); return true }
            let value = try JSONDecoder().decode(AppMigrationRuntime.Readiness.self, from: secureData(receipt))
            guard value.id == transaction.id, value.target == transaction.target, value.identity == transaction.identity else {
                throw AppMigrationError.invalidState
            }
            guard let process = NSRunningApplication(processIdentifier: value.pid),
                  process.bundleURL?.standardizedFileURL.path == transaction.target,
                  process.launchDate == value.launchedAt else { return false }
            return true
        }
        if try confirmed() { return } // Reconcile without disturbing a live candidate.
        if let launchCandidate { try launchCandidate(transaction) }
        else { _ = try run("/usr/bin/open", ["-n", transaction.target, "--args", AppMigrationRuntime.candidateArgument, transaction.id]) }
        let deadline = Date(timeIntervalSinceNow: 30)
        repeat {
            if try confirmed() { return }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw AppMigrationError.deferred("candidateNotConfirmed")
    }
    func ownsPublishedTarget(_ transaction: AppMigrationTransaction) throws -> Bool { try ownsTarget(transaction) }
    func refreshLaunchReferences(_ transaction: AppMigrationTransaction) throws {
        guard try ownsTarget(transaction) else { throw AppMigrationError.invalidState }
        if let refreshReferences { try refreshReferences(transaction); return }
        guard let defaults = UserDefaults(suiteName: AppIdentity.bundleIdentifier) else { throw AppMigrationError.deferred("preferencesUnavailable") }
        let preferences = HostAutoLaunchPreferences(defaults: defaults)
        if preferences.isEnabled {
            let directory = home.appendingPathComponent("Library/LaunchAgents")
            let file = directory.appendingPathComponent(AppIdentity.launchAgentLabel + ".plist")
            if exists(file.path) {
                try direct(file)
                let data = try Data(contentsOf: file)
                guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      plist["Label"] as? String == AppIdentity.launchAgentLabel,
                      let arguments = plist["ProgramArguments"] as? [String], arguments.count == 3,
                      arguments[0] == "/bin/zsh", [transaction.source, transaction.target].contains(arguments[2]),
                      arguments[1] == arguments[2] + "/Contents/Resources/gpt-touchbar-hud-launcher.sh" else {
                    throw AppMigrationError.deferred("unownedLaunchAgent")
                }
            }
            try HostAutoLaunchManager(preferences: preferences, appBundleURL: URL(fileURLWithPath: transaction.target),
                launchAgentsDirectory: directory, userID: getuid()).installOrUpdate().get()
        }
        // Registration is not a promise that Dock/third-party aliases follow.
        guard LSRegisterURL(URL(fileURLWithPath: transaction.target) as CFURL, true) == noErr else {
            throw AppMigrationError.deferred("launchServicesRegistrationFailed")
        }
    }
    func archiveSource(_ transaction: AppMigrationTransaction) throws {
        guard try ownsTarget(transaction) else { throw AppMigrationError.invalidState }
        let backup = stage(transaction).appendingPathComponent("previous.app").path
        if !exists(transaction.source) {
            guard try fileID(backup) == transaction.sourceFileID, try inspect(backup) == transaction.identity else { throw AppMigrationError.invalidState }; return
        }
        guard !exists(backup), try fileID(transaction.source) == transaction.sourceFileID,
              try inspect(transaction.source) == transaction.identity else { throw AppMigrationError.deferred("sourceChanged") }
        try exclusiveMove(transaction.source, backup)
    }
    private func exclusiveMove(_ source: String, _ target: String) throws {
        try direct(URL(fileURLWithPath: source)); try direct(URL(fileURLWithPath: target))
        guard renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 else { throw AppMigrationError.deferred("exclusiveMoveFailed") }
    }
    func readPrivateFile(_ url: URL) throws -> Data { try secureData(url) }
    func preparePrivateHelper(_ transaction: AppMigrationTransaction) throws -> URL {
        try validate(transaction)
        try privateDirectory(stage(transaction), create: true)
        let helperBundle = stage(transaction).appendingPathComponent("migration-helper.app")
        if !exists(helperBundle.path) {
            let source = helperSourceBundle ?? Bundle.main.bundleURL
            guard [transaction.source, transaction.target].contains(source.standardizedFileURL.path),
                  try inspect(source.path) == transaction.identity else { throw AppMigrationError.invalidState }
            // A signed app executable's signature binds its Info.plist. Moving
            // the bare executable outside the bundle fails strict verification;
            // preserve the whole signed bundle rather than resigning/bypassing it.
            try fm.copyItem(at: source, to: helperBundle)
        }
        try direct(helperBundle)
        let attributes = try fm.attributesOfItem(atPath: helperBundle.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0,
              try inspect(helperBundle.path) == transaction.identity,
              let executable = Bundle(url: helperBundle)?.executableURL else { throw AppMigrationError.invalidState }
        return executable
    }
}
