import Foundation
import Darwin

struct DiagnosticControlState: Codable, Equatable {
    let protocolVersion: Int
    let enabled: Bool
    let clearEpoch: UUID
    init(enabled: Bool, clearEpoch: UUID = UUID()) { protocolVersion = 1; self.enabled = enabled; self.clearEpoch = clearEpoch }
}

/// Private recovery metadata. Paths and host process evidence never enter an event or export.
struct DiagnosticUpgradePrivateMetadata: Codable, Equatable {
    let channelDirectory: String
    let targetPath: String
    let hostPID: Int32?
    let hostStartTime: Date?
    init(channelDirectory: URL, targetPath: URL, hostPID: Int32? = nil, hostStartTime: Date? = nil) throws {
        guard channelDirectory.isFileURL, targetPath.isFileURL,
              channelDirectory.path.utf8.count <= 4096, targetPath.path.utf8.count <= 4096,
              !channelDirectory.pathComponents.contains(".."), !targetPath.pathComponents.contains("..") else {
            throw DiagnosticStoreError.unsafePath
        }
        self.channelDirectory = channelDirectory.path; self.targetPath = targetPath.path
        self.hostPID = hostPID; self.hostStartTime = hostStartTime
    }
}
struct DiagnosticUpgradeCandidate: Codable {
    let handoff: DiagnosticUpgradeHandoff
    let metadata: DiagnosticUpgradePrivateMetadata
}

/// All callers are background workers. One nonblocking flock protects control, allocation, append and cleanup.
/// Helper paths are always derived from the fixed application identity, never from a channel output argument.
final class DiagnosticProcessStore {
    struct FileInfo {
        let path: [String]
        let bytes: Int
        let modified: Date
        let earliest: Date?
        var isEvent: Bool { path.last?.hasSuffix(".jsonl") == true }
        var updateID: UUID? { path.count == 3 ? UUID(uuidString: path[1]) : nil }
    }
    let directory: URL
    let configuration: DiagnosticStore.Configuration
    let now: () -> Date
    private(set) var descriptor: Int32 = -1
    private var device: dev_t = 0
    private var inode: ino_t = 0
    private(set) var issues: [DiagnosticGapReason: Int] = [:]
    static let lockName = "diagnostic.lock"
    static let controlName = "control.json"
    init(directory: URL, configuration: DiagnosticStore.Configuration = .init(), now: @escaping () -> Date = Date.init) {
        self.directory = directory; self.configuration = configuration; self.now = now
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    func withLock<T>(create: Bool = true, _ body: () throws -> T) throws -> T {
        try ensureDirectory(create: create)
        let fd = openat(descriptor, Self.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw DiagnosticStoreError.unsafePath }
        defer { Darwin.close(fd) }
        try Self.validateFile(fd)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw DiagnosticStoreError.lockBusy }
            throw DiagnosticStoreError.ioFailure
        }
        defer { _ = flock(fd, LOCK_UN) }
        // A substituted lock must never split the critical section into two locking domains.
        var held = stat(); var named = stat()
        guard fstat(fd, &held) == 0, fstatat(descriptor, Self.lockName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_ino == named.st_ino, held.st_dev == named.st_dev else { throw DiagnosticStoreError.unsafePath }
        return try body()
    }

    func ensureDirectory(create: Bool = true) throws {
        guard directory.isFileURL, !directory.pathComponents.contains(".."),
              configuration.maximumAge > 0, configuration.maximumTotalBytes > 0,
              configuration.maximumFileBytes > 0, configuration.maximumEventBytes > 0,
              configuration.maximumUpgradeBytes > 0 else { throw DiagnosticStoreError.invalidConfiguration }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw DiagnosticStoreError.unsafePath }
        defer { Darwin.close(parent) }
        for part in directory.pathComponents where part != "/" {
            var next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            if next < 0 && errno == ENOENT && create {
                guard mkdirat(parent, part, 0o700) == 0 || errno == EEXIST else { throw DiagnosticStoreError.ioFailure }
                next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            }
            guard next >= 0 else { throw DiagnosticStoreError.unsafePath }
            Darwin.close(parent); parent = next
        }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFDIR,
              fchmod(parent, 0o700) == 0 else { throw DiagnosticStoreError.unsafePath }
        if descriptor >= 0 {
            guard device == info.st_dev, inode == info.st_ino else { throw DiagnosticStoreError.unsafePath }
        } else {
            descriptor = dup(parent); device = info.st_dev; inode = info.st_ino
            guard descriptor >= 0 else { throw DiagnosticStoreError.ioFailure }
        }
    }

    func readControl(defaultEnabled: Bool? = nil) throws -> DiagnosticControlState {
        if !exists([Self.controlName]) {
            guard let enabled = defaultEnabled else { throw DiagnosticStoreError.disabled }
            let value = DiagnosticControlState(enabled: enabled)
            try writeAtomic(try JSONEncoder().encode(value), path: [Self.controlName])
            return value
        }
        let value = try JSONDecoder().decode(DiagnosticControlState.self, from: read([Self.controlName], limit: 2048))
        guard value.protocolVersion == 1 else { throw DiagnosticStoreError.unknownProtocol }
        return value
    }
    func validateControl(epoch: UUID) throws {
        let control = try readControl()
        guard control.enabled else { throw DiagnosticStoreError.disabled }
        guard control.clearEpoch == epoch else { throw DiagnosticStoreError.staleEpoch }
    }
    func setEnabled(_ enabled: Bool, create: Bool = true) throws -> DiagnosticControlState {
        try withLock(create: create) {
            let old = try readControl(defaultEnabled: enabled)
            let value = DiagnosticControlState(enabled: enabled, clearEpoch: old.clearEpoch)
            try writeAtomic(try JSONEncoder().encode(value), path: [Self.controlName])
            return value
        }
    }
    func currentControl(defaultEnabled: Bool? = nil) throws -> DiagnosticControlState {
        try withLock { try readControl(defaultEnabled: defaultEnabled) }
    }
    func rotateEpoch() throws -> DiagnosticControlState {
        let old = try readControl(defaultEnabled: false)
        let value = DiagnosticControlState(enabled: old.enabled)
        // Commit the epoch first. Any failed cleanup remains inaccessible to old producers.
        try writeAtomic(try JSONEncoder().encode(value), path: [Self.controlName])
        return value
    }

    func parentDescriptor(for path: [String], create: Bool = false) throws -> Int32 {
        guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else { throw DiagnosticStoreError.unsafePath }
        var current = dup(descriptor)
        guard current >= 0 else { throw DiagnosticStoreError.ioFailure }
        do {
            for component in path.dropLast() {
                var child = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
                if child < 0 && errno == ENOENT && create {
                    guard mkdirat(current, component, 0o700) == 0 || errno == EEXIST else { throw DiagnosticStoreError.ioFailure }
                    child = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
                }
                guard child >= 0 else { throw DiagnosticStoreError.unsafePath }
                var info = stat()
                guard fstat(child, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFDIR,
                      fchmod(child, 0o700) == 0 else { Darwin.close(child); throw DiagnosticStoreError.unsafePath }
                Darwin.close(current); current = child
            }
            return current
        } catch { Darwin.close(current); throw error }
    }
    static func validateFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, fchmod(fd, 0o600) == 0 else { throw DiagnosticStoreError.unsafePath }
    }
    func exists(_ path: [String]) -> Bool {
        guard let parent = try? parentDescriptor(for: path) else { return false }
        defer { Darwin.close(parent) }
        var info = stat(); return fstatat(parent, path.last!, &info, AT_SYMLINK_NOFOLLOW) == 0
    }
    func read(_ path: [String], limit: Int) throws -> Data {
        let parent = try parentDescriptor(for: path); defer { Darwin.close(parent) }
        let fd = openat(parent, path.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw DiagnosticStoreError.unsafePath }
        defer { Darwin.close(fd) }; try Self.validateFile(fd)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0, info.st_size <= limit else { throw DiagnosticStoreError.ioFailure }
        var output = Data(); var buffer = [UInt8](repeating: 0, count: min(16384, limit + 1))
        while output.count <= limit {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, limit + 1 - output.count)) }
            if count == 0 { return output }
            if count < 0 { if errno == EINTR { continue }; throw DiagnosticStoreError.ioFailure }
            output.append(contentsOf: buffer.prefix(count))
        }
        throw DiagnosticStoreError.ioFailure
    }
    static func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DiagnosticStoreError.ioFailure }; offset += count
            }
        }
    }
    func writeAtomic(_ data: Data, path: [String]) throws {
        let parent = try parentDescriptor(for: path, create: true); defer { Darwin.close(parent) }
        if exists(path) { _ = try read(path, limit: 16384) }
        let temporary = ".diagnostic-\(UUID().uuidString.lowercased()).tmp"
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw DiagnosticStoreError.ioFailure }
        defer { Darwin.close(fd); unlinkat(parent, temporary, 0) }
        try Self.validateFile(fd); try Self.writeAll(data, fd: fd)
        guard fsync(fd) == 0, renameat(parent, temporary, parent, path.last!) == 0 else { throw DiagnosticStoreError.ioFailure }
    }
    /// An open appender lease prevents another producer pruning an active file.
    func openAppender(_ path: [String], expectedBytes: Int? = nil) throws -> Int32 {
        let parent = try parentDescriptor(for: path, create: true); defer { Darwin.close(parent) }
        let fd = openat(parent, path.last!, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw DiagnosticStoreError.unsafePath }
        do {
            try Self.validateFile(fd)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw DiagnosticStoreError.lockBusy }
            var info = stat()
            guard fstat(fd, &info) == 0, expectedBytes.map({ Int(info.st_size) == $0 }) ?? true else { throw DiagnosticStoreError.unsafePath }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    func append(_ line: Data, fd: Int32) throws {
        try Self.writeAll(line, fd: fd)
        let stamp = now().timeIntervalSince1970
        var times = [timeval(tv_sec: Int(stamp), tv_usec: 0), timeval(tv_sec: Int(stamp), tv_usec: 0)]
        _ = times.withUnsafeMutableBufferPointer { futimes(fd, $0.baseAddress) }
    }
    static func names(_ fd: Int32) throws -> [String] {
        // fdopendir shares offsets with dup; rewind before each bounded enumeration.
        let copy = dup(fd); guard copy >= 0 else { throw DiagnosticStoreError.ioFailure }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw DiagnosticStoreError.ioFailure }
        defer { closedir(stream) }; rewinddir(stream)
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            guard result.count < 4096 else { throw DiagnosticStoreError.budgetExceeded }
            result.append(name)
        }
        return result.sorted()
    }
    static func eventName(_ value: String, prefix: String = "events-") -> Bool {
        guard value.hasPrefix(prefix), value.hasSuffix(".jsonl"), value.count == prefix.count + 36 + 6 else { return false }
        return UUID(uuidString: String(value.dropFirst(prefix.count).dropLast(6))) != nil
    }
    func files(includeEarliest: Bool = true) throws -> [FileInfo] {
        var paths = try Self.names(descriptor).filter { Self.eventName($0) }.map { [$0] }
        if exists(["updates"]) {
            do {
                let updates = try parentDescriptor(for: ["updates", "placeholder"]); defer { Darwin.close(updates) }
                for name in try Self.names(updates) where UUID(uuidString: name) != nil {
                    do {
                        let session = try parentDescriptor(for: ["updates", name, "placeholder"]); defer { Darwin.close(session) }
                        for file in try Self.names(session) where Self.eventName(file, prefix: "writer-") || file == "handoff.json" {
                            guard paths.count < 4096 else { throw DiagnosticStoreError.budgetExceeded }
                            paths.append(["updates", name, file])
                        }
                    } catch { if (error as? DiagnosticStoreError) == .budgetExceeded { throw error }; note(.unsafeFile) }
                }
            } catch { if (error as? DiagnosticStoreError) == .budgetExceeded { throw error }; note(.unsafeFile) }
        }
        var result: [FileInfo] = []
        for path in paths {
            do {
                let parent = try parentDescriptor(for: path); defer { Darwin.close(parent) }
                var info = stat()
                guard fstatat(parent, path.last!, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid(), info.st_size >= 0 else {
                    note(.unsafeFile); continue
                }
                var earliest: Date?
                if includeEarliest, path.last?.hasSuffix(".jsonl") == true {
                    // Inspect only the first bounded line for an expiry deadline. The latest filesystem
                    // timestamp is the fallback for corrupt first lines; full validation belongs to export.
                    let fd = openat(parent, path.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                    if fd >= 0 {
                        defer { Darwin.close(fd) }
                        if (try? Self.validateFile(fd)) != nil {
                            var prefix = [UInt8](repeating: 0, count: configuration.maximumEventBytes)
                            let count = prefix.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                            if count > 0, let end = prefix.prefix(count).firstIndex(of: 10),
                               let value = try? DiagnosticEventEnvelope.decoder().decode(DiagnosticEventEnvelope.self, from: Data(prefix[..<end])),
                               value.schemaVersion == 1, value.timestamp.timeIntervalSince1970.isFinite {
                                earliest = value.timestamp
                            }
                        }
                    }
                }
                result.append(FileInfo(path: path, bytes: Int(info.st_size), modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)), earliest: earliest))
            } catch { note(.unsafeFile) }
        }
        return result.sorted { $0.modified == $1.modified ? $0.path.joined(separator: "/") < $1.path.joined(separator: "/") : $0.modified < $1.modified }
    }
    @discardableResult func remove(_ file: FileInfo, force: Bool = false) throws -> Bool {
        let parent = try parentDescriptor(for: file.path); defer { Darwin.close(parent) }
        let fd = openat(parent, file.path.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw DiagnosticStoreError.unsafePath }; defer { Darwin.close(fd) }
        try Self.validateFile(fd)
        if !force && flock(fd, LOCK_EX | LOCK_NB) != 0 { return false }
        guard unlinkat(parent, file.path.last!, 0) == 0 else { throw DiagnosticStoreError.ioFailure }
        return true
    }
    func prune() throws {
        var remaining: [FileInfo] = []
        for file in try files() {
            let maximum = file.isEvent ? (file.updateID == nil ? configuration.maximumFileBytes : configuration.maximumUpgradeBytes) : 16384
            if file.bytes > maximum || (file.earliest ?? file.modified) <= now().addingTimeInterval(-configuration.maximumAge) {
                if try remove(file, force: (file.earliest ?? file.modified) <= now().addingTimeInterval(-configuration.maximumAge)) { note(.retentionLimit); continue }
            }
            remaining.append(file)
        }
        var total = totalBytes(remaining)
        for file in remaining where total > configuration.maximumTotalBytes {
            if try remove(file) { total -= file.bytes; note(.retentionLimit) }
        }
        try removeEmptyUpdateDirectories()
    }
    func makeSpace(for bytes: Int, updateID: UUID? = nil) throws {
        let values = try files(includeEarliest: false)
        if let id = updateID {
            let updateBytes = totalBytes(values.filter { $0.updateID == id })
            guard bytes <= configuration.maximumUpgradeBytes - min(updateBytes, configuration.maximumUpgradeBytes) else { throw DiagnosticStoreError.upgradeLimit }
        }
        var total = totalBytes(values)
        for file in values where bytes > configuration.maximumTotalBytes - min(total, configuration.maximumTotalBytes) {
            // Preserve all stages of this upgrade until its separate budget is exhausted.
            if file.updateID == updateID && updateID != nil { continue }
            if try remove(file) { total -= file.bytes; note(.retentionLimit) }
        }
        guard bytes <= configuration.maximumTotalBytes - min(total, configuration.maximumTotalBytes) else { throw DiagnosticStoreError.budgetExceeded }
    }
    func totalBytes(_ files: [FileInfo]) -> Int {
        files.reduce(0) { sum, file in let next = sum.addingReportingOverflow(max(0, file.bytes)); return next.overflow ? Int.max : next.partialValue }
    }
    func removeEmptyUpdateDirectories() throws {
        guard exists(["updates"]) else { return }
        let parent = try parentDescriptor(for: ["updates", "placeholder"]); defer { Darwin.close(parent) }
        for name in try Self.names(parent) where UUID(uuidString: name) != nil {
            guard let child = try? parentDescriptor(for: ["updates", name, "placeholder"]) else { continue }
            defer { Darwin.close(child) }
            if try Self.names(child).isEmpty { _ = unlinkat(parent, name, AT_REMOVEDIR) }
        }
    }
    func note(_ reason: DiagnosticGapReason) { issues[reason] = 1 }
    func clearIssues() { issues.removeAll() }

    func saveCandidate(_ candidate: DiagnosticUpgradeCandidate) throws {
        try withLock {
            try validateControl(epoch: candidate.handoff.clearEpoch)
            guard candidate.handoff.protocolVersion == 1 else { throw DiagnosticStoreError.unknownProtocol }
            let data = try DiagnosticEventEnvelope.encoder().encode(candidate)
            guard data.count <= 16384 else { throw DiagnosticStoreError.budgetExceeded }
            let path = ["updates", candidate.handoff.updateSessionID.uuidString.lowercased(), "handoff.json"]
            if exists(path) { return } // A source handoff is immutable.
            guard try files(includeEarliest: false).filter({ !$0.isEvent }).count < 32 else { throw DiagnosticStoreError.budgetExceeded }
            try makeSpace(for: data.count, updateID: candidate.handoff.updateSessionID)
            try writeAtomic(data, path: path)
        }
    }
    func candidates() throws -> [DiagnosticUpgradeCandidate] {
        try withLock {
            let control = try readControl()
            guard control.enabled else { return [] }
            try prune()
            let values = try files(includeEarliest: false).filter { !$0.isEvent }
            guard values.count <= 32 else { throw DiagnosticStoreError.budgetExceeded }
            return values.compactMap { file in
                guard let data = try? read(file.path, limit: 16384),
                      let value = try? DiagnosticEventEnvelope.decoder().decode(DiagnosticUpgradeCandidate.self, from: data),
                      value.handoff.protocolVersion == 1, value.handoff.clearEpoch == control.clearEpoch,
                      value.handoff.updateSessionID == file.updateID,
                      value.handoff.createdAt >= now().addingTimeInterval(-configuration.maximumAge),
                      value.handoff.createdAt <= now().addingTimeInterval(300) else { return nil }
                return value
            }
        }
    }
}

/// A single producer. It neither starts a normal HUD session nor changes global controls.
final class DiagnosticUpgradeWriter {
    let handoff: DiagnosticUpgradeHandoff
    let writerRole: DiagnosticWriterRole
    let sessionID: UUID
    private let identity: DiagnosticProcessIdentity
    private let processStore: DiagnosticProcessStore
    private let lock = NSLock()
    private let start = DispatchTime.now().uptimeNanoseconds
    private var sequence: UInt64 = 0
    private var skipped: [DiagnosticGapReason: Int] = [:]
    private init(handoff: DiagnosticUpgradeHandoff, role: DiagnosticWriterRole, identity: DiagnosticProcessIdentity,
                 directory: URL, configuration: DiagnosticStore.Configuration, now: @escaping () -> Date, writerSessionID: UUID?) {
        self.handoff = handoff; writerRole = role; self.identity = identity
        sessionID = writerSessionID ?? UUID()
        processStore = DiagnosticProcessStore(directory: directory, configuration: configuration, now: now)
    }
    static func bootstrapFromProtectedHandoff(_ handoff: DiagnosticUpgradeHandoff, role: DiagnosticWriterRole,
        identity: DiagnosticProcessIdentity = .current, directory: URL = DiagnosticStore.defaultDirectory,
        configuration: DiagnosticStore.Configuration = .init(), now: @escaping () -> Date = Date.init,
        writerSessionID: UUID? = nil) throws -> DiagnosticUpgradeWriter {
        guard handoff.protocolVersion == 1 else { throw DiagnosticStoreError.unknownProtocol }
        guard handoff.recordingEnabled, handoff.createdAt.timeIntervalSince1970.isFinite,
              handoff.createdAt >= now().addingTimeInterval(-configuration.maximumAge),
              handoff.createdAt <= now().addingTimeInterval(300) else { throw DiagnosticStoreError.disabled }
        let value = Self(handoff: handoff, role: role, identity: identity, directory: directory,
                         configuration: configuration, now: now, writerSessionID: writerSessionID)
        try value.processStore.withLock(create: false) { try value.processStore.validateControl(epoch: handoff.clearEpoch) }
        return value
    }
    @discardableResult func record(stage: DiagnosticUpgradeStage, result: DiagnosticResult = .success, sequence: UInt64? = nil) -> DiagnosticWriteResult {
        recordEvent(.upgrade(stage: stage, result: result), explicitSequence: sequence)
    }
    @discardableResult func recordRecovery(module: DiagnosticRecoveryModule, state: DiagnosticRecoveryState,
        observation: DiagnosticRecoveryObservation = .afterRestart) -> DiagnosticWriteResult {
        recordEvent(.moduleRecovery(module: module, state: state, observation: observation))
    }
    private func recordEvent(_ event: DiagnosticEvent, explicitSequence: UInt64? = nil) -> DiagnosticWriteResult {
        // Never wait behind another caller; this object is normally owned by one worker.
        guard lock.try() else { return .lockBusy }; defer { lock.unlock() }
        do {
            return try processStore.withLock(create: false) {
                try processStore.validateControl(epoch: handoff.clearEpoch)
                try processStore.prune()
                let path = ["updates", handoff.updateSessionID.uuidString.lowercased(), "writer-\(sessionID.uuidString.lowercased()).jsonl"]
                let existing = processStore.exists(path) ? try processStore.read(path, limit: processStore.configuration.maximumUpgradeBytes) : Data()
                guard existing.isEmpty || existing.last == 10 else { throw DiagnosticStoreError.unsafePath }
                let previous = existing.split(separator: 10).last.flatMap { try? DiagnosticEventEnvelope.decoder().decode(DiagnosticEventEnvelope.self, from: Data($0)) }
                let maximum = max(sequence, previous?.sequence ?? 0)
                guard explicitSequence != nil || maximum < UInt64.max else { throw DiagnosticStoreError.invalidConfiguration }
                let next = explicitSequence ?? maximum + 1
                guard next > (previous?.sequence ?? 0), next <= UInt64.max - UInt64(skipped.count) else {
                    throw DiagnosticStoreError.invalidConfiguration
                }
                var events: [(UInt64, DiagnosticEvent)] = []
                // Explicit script sequences remain unchanged. A combined gap uses the same event's repetition-free extra slot only for local writers.
                if explicitSequence == nil {
                    for (reason, count) in skipped.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                        events.append((next + UInt64(events.count), .gap(reason: reason, count: count)))
                    }
                }
                events.append((next + UInt64(events.count), event))
                var data = Data()
                for (number, item) in events {
                    let tick = DispatchTime.now().uptimeNanoseconds
                    let envelope = DiagnosticEventEnvelope(timestamp: processStore.now(), sessionID: sessionID, sequence: number,
                        monotonicMilliseconds: explicitSequence == nil && tick >= start ? (tick - start) / 1_000_000 : 0,
                        event: item, updateSessionID: handoff.updateSessionID, writerRole: writerRole,
                        eventID: .init(sessionID: sessionID, sequence: number), processIdentity: identity,
                        upgradeSourceIdentity: handoff.sourceIdentity, upgradeTargetIdentity: handoff.targetIdentity)
                    let line = try DiagnosticEventEnvelope.encoder().encode(envelope)
                    guard line.count + 1 <= processStore.configuration.maximumEventBytes else { throw DiagnosticStoreError.invalidConfiguration }
                    data.append(line); data.append(10)
                }
                try processStore.makeSpace(for: data.count, updateID: handoff.updateSessionID)
                let fd = try processStore.openAppender(path, expectedBytes: existing.count); defer { Darwin.close(fd) }
                try processStore.append(data, fd: fd)
                guard fsync(fd) == 0 else { throw DiagnosticStoreError.ioFailure }
                sequence = events.last!.0; skipped.removeAll()
                return .persisted
            }
        } catch {
            let reason: DiagnosticGapReason
            let result: DiagnosticWriteResult
            switch error as? DiagnosticStoreError {
            case .disabled: reason = .recordingDisabled; result = .disabled
            case .staleEpoch: reason = .staleEpoch; result = .staleEpoch
            case .lockBusy: reason = .lockBusy; result = .lockBusy
            case .budgetExceeded, .upgradeLimit: reason = .upgradeLimit; result = .budgetExceeded
            default: reason = .writeFailure; result = .failed
            }
            skipped[reason, default: 0] += 1
            return result
        }
    }
    func freezeSnapshot(since: Date? = nil, until: Date = Date()) throws -> DiagnosticStoreSnapshot {
        try DiagnosticStore(directory: processStore.directory, configuration: processStore.configuration, now: processStore.now)
            .snapshot(since: since, until: until, generation: 0, isEnabled: true)
    }
}
