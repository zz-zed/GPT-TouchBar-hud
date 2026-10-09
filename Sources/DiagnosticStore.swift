import Foundation
import Darwin

enum DiagnosticStoreError: Error, Equatable {
    case unsafePath, ioFailure, invalidConfiguration, cancelled, lockBusy, disabled, staleEpoch, unknownProtocol, budgetExceeded, upgradeLimit
}

/// Ordinary HUD writer. Helpers use DiagnosticUpgradeWriter and cannot mutate its session marker.
final class DiagnosticStore {
    struct Configuration {
        var maximumAge: TimeInterval = 72 * 60 * 60
        var maximumTotalBytes = 10 * 1024 * 1024
        var maximumFileBytes = 1024 * 1024
        var maximumEventBytes = 4 * 1024
        var maximumUpgradeBytes = 64 * 1024
    }
    private struct SessionMarker: Codable { let sessionID: UUID; let closedNormally: Bool }
    let processStore: DiagnosticProcessStore
    private let configuration: Configuration
    private let now: () -> Date
    private let beforeWrite: (() throws -> Void)?
    private var currentFile: String?
    private var currentFileBytes = 0
    private var lease: Int32 = -1
    private var sessionID = UUID()
    private var epoch: UUID?
    private let markerName = "session-state.json"
    init(directory: URL, configuration: Configuration = Configuration(), now: @escaping () -> Date = Date.init,
         beforeWrite: (() throws -> Void)? = nil) {
        processStore = DiagnosticProcessStore(directory: directory, configuration: configuration, now: now)
        self.configuration = configuration; self.now = now; self.beforeWrite = beforeWrite
    }
    deinit { releaseLease() }
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GPT TouchBar HUD/Diagnostics", isDirectory: true)
    }
    private func releaseLease() { if lease >= 0 { Darwin.close(lease); lease = -1 } }
    private func resetCurrent() { releaseLease(); currentFile = nil; currentFileBytes = 0 }
    func controlState(defaultEnabled: Bool? = nil) throws -> DiagnosticControlState {
        try processStore.currentControl(defaultEnabled: defaultEnabled)
    }
    func setEnabled(_ value: Bool, create: Bool = true) throws -> DiagnosticControlState {
        let state = try processStore.setEnabled(value, create: create)
        epoch = state.clearEpoch
        if !value { releaseLease() }
        return state
    }
    func startSession(_ id: UUID) throws -> Bool {
        try processStore.withLock {
            sessionID = id
            let control = try processStore.readControl(defaultEnabled: true)
            guard control.enabled else { throw DiagnosticStoreError.disabled }
            epoch = control.clearEpoch
            var confirmed = false
            if let data = try? processStore.read([markerName], limit: 4096),
               let marker = try? JSONDecoder().decode(SessionMarker.self, from: data) { confirmed = marker.closedNormally }
            try writeMarker(closedNormally: false)
            try cleanupExportStaging(expiredOnly: true)
            releaseLease(); try processStore.prune()
            return confirmed
        }
    }
    func markShutdownConfirmed(shouldWrite: () -> Bool = { true }) throws {
        try processStore.withLock {
            guard shouldWrite() else { throw DiagnosticStoreError.cancelled }
            guard let epoch else { throw DiagnosticStoreError.disabled }; try processStore.validateControl(epoch: epoch)
            try writeMarker(closedNormally: true)
        }
    }
    func append(_ lines: [Data], shouldWrite: () -> Bool = { true }) throws {
        // The injectable hook deliberately runs outside the cross-process critical section.
        try beforeWrite?()
        var completed = false
        defer { if !completed { resetCurrent() } }
        try processStore.withLock {
            guard shouldWrite() else { throw DiagnosticStoreError.cancelled }
            guard let epoch else { throw DiagnosticStoreError.disabled }; try processStore.validateControl(epoch: epoch)
            releaseLease()
            try processStore.prune()
            let batchBytes = lines.reduce(0) { $0 + $1.count }
            if batchBytes <= configuration.maximumTotalBytes { try processStore.makeSpace(for: batchBytes) }
            for line in lines {
                guard shouldWrite() else { throw DiagnosticStoreError.cancelled }
                guard !line.isEmpty, line.last == 10, line.count <= configuration.maximumEventBytes,
                      line.count <= min(configuration.maximumFileBytes, configuration.maximumTotalBytes) else { throw DiagnosticStoreError.invalidConfiguration }
                if batchBytes > configuration.maximumTotalBytes { releaseLease(); try processStore.makeSpace(for: line.count) }
                if let file = currentFile, !processStore.exists([file]) { resetCurrent() }
                if currentFile == nil || currentFileBytes + line.count > min(configuration.maximumFileBytes, configuration.maximumTotalBytes) {
                    resetCurrent(); currentFile = "events-\(UUID().uuidString.lowercased()).jsonl"
                }
                guard let file = currentFile else { throw DiagnosticStoreError.ioFailure }
                if lease < 0 { lease = try processStore.openAppender([file], expectedBytes: currentFileBytes) }
                try processStore.append(line, fd: lease); currentFileBytes += line.count
            }
            // fsync success is required before the recorder can report persisted.
            if lease >= 0 && fsync(lease) != 0 { throw DiagnosticStoreError.ioFailure }
            completed = true
        }
    }
    func clear() throws {
        try processStore.withLock {
            let state = try processStore.rotateEpoch(); epoch = state.clearEpoch
            resetCurrent()
            for file in try processStore.files() { try processStore.remove(file, force: true) }
            try processStore.removeEmptyUpdateDirectories()
            if processStore.exists([markerName]) {
                _ = try processStore.read([markerName], limit: 4096)
                guard unlinkat(processStore.descriptor, markerName, 0) == 0 else { throw DiagnosticStoreError.ioFailure }
            }
            try cleanupExportStaging(expiredOnly: false)
            processStore.clearIssues()
        }
    }
    func nextRetentionDate() throws -> Date? {
        try processStore.withLock { try processStore.files().map { ($0.earliest ?? $0.modified).addingTimeInterval(configuration.maximumAge) }.min() }
    }
    func maintainRetentionIfPresent() throws -> Bool {
        var info = stat()
        if lstat(processStore.directory.path, &info) != 0 { if errno == ENOENT { return false }; throw DiagnosticStoreError.ioFailure }
        try maintainRetention(); return true
    }
    func maintainRetention() throws {
        try processStore.withLock { releaseLease(); try processStore.prune() }
    }
    private func writeMarker(closedNormally: Bool) throws {
        try processStore.writeAtomic(JSONEncoder().encode(SessionMarker(sessionID: sessionID, closedNormally: closedNormally)), path: [markerName])
    }
    private func cleanupExportStaging(expiredOnly: Bool) throws {
        guard processStore.exists(["export-staging"]) else { return }
        let fd: Int32
        do { fd = try processStore.parentDescriptor(for: ["export-staging", "placeholder"]) }
        catch { processStore.note(.unsafeFile); if expiredOnly { return }; throw error }
        defer { Darwin.close(fd) }
        for name in try DiagnosticProcessStore.names(fd) where name.hasPrefix("export-") && name.hasSuffix(".tmp") {
            guard name.count == 47, UUID(uuidString: String(name.dropFirst(7).dropLast(4))) != nil else { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_nlink == 1, info.st_uid == geteuid() else { continue }
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
            if !expiredOnly || modified < now().addingTimeInterval(-3600) {
                guard unlinkat(fd, name, 0) == 0 else { throw DiagnosticStoreError.ioFailure }
            }
        }
    }
    func snapshot(since: Date?, until: Date? = nil, generation: UInt64, isEnabled: Bool,
                  additionalGaps: [DiagnosticGap] = []) throws -> DiagnosticStoreSnapshot {
        // Explicit export may inspect retained files after recording has been disabled.
        // Freeze bytes under the same process lock; JSON decoding and rebuilding happen outside it.
        let frozen: [(DiagnosticProcessStore.FileInfo, Data?)] = try processStore.withLock {
            releaseLease(); try processStore.prune()
            return try processStore.files(includeEarliest: false).filter(\.isEvent).map { file in
                (file, try? processStore.read(file.path, limit: file.updateID == nil ? configuration.maximumFileBytes : configuration.maximumUpgradeBytes))
            }
        }
        var envelopes: [DiagnosticEventEnvelope] = []
        var gaps = additionalGaps
        var counts = processStore.issues
        var outsideRange = Set<UUID>()
        var seen = Set<String>()
        let decoder = DiagnosticEventEnvelope.decoder()
        for (file, frozenData) in frozen {
            do {
                guard let data = frozenData else { throw DiagnosticStoreError.ioFailure }
                let pieces = data.split(separator: 10, omittingEmptySubsequences: false)
                for (index, piece) in pieces.enumerated() {
                    if piece.isEmpty { continue }
                    guard index < pieces.count - 1, piece.count + 1 <= configuration.maximumEventBytes else {
                        counts[.corruptedLine, default: 0] += 1; continue
                    }
                    struct Header: Decodable { let schemaVersion: Int }
                    if let header = try? decoder.decode(Header.self, from: Data(piece)), header.schemaVersion != 1 {
                        counts[.unknownProtocol, default: 0] += 1; continue
                    }
                    guard let event = try? decoder.decode(DiagnosticEventEnvelope.self, from: Data(piece)),
                          event.timestamp.timeIntervalSince1970.isFinite else {
                        let object = (try? JSONSerialization.jsonObject(with: Data(piece))) as? [String: Any]
                        let payload = object?["event"] as? [String: Any]
                        let known: Set<String> = ["lifecycle", "exitRequested", "connection", "task", "taskTrace", "display", "componentFailure", "gap", "upgrade", "moduleRecovery"]
                        let unknown = payload.map { !$0.isEmpty && Set($0.keys).isDisjoint(with: known) } ?? false
                        counts[unknown ? .unknownEvent : .corruptedLine, default: 0] += 1; continue
                    }
                    guard event.schemaVersion == 1 else { counts[.unknownProtocol, default: 0] += 1; continue }
                    if case .taskTrace(let trace) = event.event, !trace.isValid {
                        counts[.corruptedLine, default: 0] += 1; continue
                    }
                    if let id = event.updateSessionID {
                        guard event.writerRole != nil, let eventID = event.eventID,
                              eventID.sessionID == event.sessionID, eventID.sequence == event.sequence,
                              file.updateID == nil || file.updateID == id else { counts[.corruptedLine, default: 0] += 1; continue }
                        let key = id.uuidString + event.sessionID.uuidString + String(event.sequence)
                        guard seen.insert(key).inserted else { continue }
                    } else if file.updateID != nil { counts[.corruptedLine, default: 0] += 1; continue }
                    guard event.timestamp >= now().addingTimeInterval(-configuration.maximumAge),
                          since.map({ event.timestamp >= $0 }) ?? true,
                          until.map({ event.timestamp <= $0 }) ?? true else {
                        if let id = event.updateSessionID { outsideRange.insert(id) }; continue
                    }
                    // Rebuild the envelope rather than trusting stored module/severity or unknown keys.
                    envelopes.append(DiagnosticEventEnvelope(timestamp: event.timestamp,
                        sessionID: event.sessionID, sequence: event.sequence,
                        monotonicMilliseconds: event.monotonicMilliseconds, event: event.event, repetition: event.repetition,
                        updateSessionID: event.updateSessionID, writerRole: event.writerRole, eventID: event.eventID,
                        processIdentity: event.processIdentity, upgradeSourceIdentity: event.upgradeSourceIdentity,
                        upgradeTargetIdentity: event.upgradeTargetIdentity))
                }
            } catch {
                counts[error is DiagnosticStoreError && (error as? DiagnosticStoreError) == .unsafePath
                    ? .unsafeFile : .unreadableFile, default: 0] += 1
            }
        }
        let sessions = Dictionary(grouping: envelopes, by: \.sessionID)
        let orderedSessions = sessions.keys.sorted {
            let left = sessions[$0]?.map(\.timestamp).min() ?? .distantPast
            let right = sessions[$1]?.map(\.timestamp).min() ?? .distantPast
            return left == right ? $0.uuidString < $1.uuidString : left < right
        }
        envelopes = orderedSessions.flatMap { id in
            (sessions[id] ?? []).sorted { $0.sequence < $1.sequence }
        }
        // Script-backed producers use stable session IDs and explicit sequence numbers across CLI invocations.
        // An observed hole explains dropped stages even when the failed CLI could not save its own gap.
        for values in Dictionary(grouping: envelopes.filter { $0.updateSessionID != nil }, by: { $0.sessionID }).values {
            let ordered = values.sorted { $0.sequence < $1.sequence }
            for pair in zip(ordered, ordered.dropFirst()) where pair.0.sequence < UInt64.max && pair.1.sequence > pair.0.sequence + 1 {
                gaps.append(DiagnosticGap(reason: .sequenceGap, count: 1, first: pair.0.timestamp, last: pair.1.timestamp))
            }
        }
        var data = Data()
        let encoder = DiagnosticEventEnvelope.encoder()
        for envelope in envelopes {
            if case .gap(let reason, let count) = envelope.event {
                gaps.append(DiagnosticGap(reason: reason, count: max(0, count),
                                          first: envelope.timestamp, last: envelope.timestamp))
            }
            let encoded = try encoder.encode(envelope)
            guard encoded.count + 1 <= configuration.maximumEventBytes else {
                counts[.oversizedEvent, default: 0] += 1
                continue
            }
            data.append(encoded)
            data.append(10)
        }
        for (reason, count) in counts where count > 0 {
            gaps.append(DiagnosticGap(reason: reason, count: count, first: now(), last: now()))
        }
        let issues = Set(gaps.map(\.reason)).sorted { $0.rawValue < $1.rawValue }
        return DiagnosticStoreSnapshot(eventsData: data, earliest: envelopes.map(\.timestamp).min(),
            latest: envelopes.map(\.timestamp).max(), droppedCount: gaps.reduce(0) { partial, gap in
                guard gap.unit == .droppedEvents else { return partial }
                let sum = partial.addingReportingOverflow(max(0, gap.count))
                return sum.overflow ? Int.max : sum.partialValue
            },
            issues: issues, gaps: gaps, generation: generation, isEnabled: isEnabled,
            truncatedUpdateIDs: Array(outsideRange.intersection(Set(envelopes.compactMap(\.updateSessionID)))).sorted { $0.uuidString < $1.uuidString })
    }

}
