import Foundation

struct DiagnosticTaskTraceState: Equatable {
    let enabled: Bool
    let generation: UInt64
    let sessionID: UUID
    static let disabled = Self(enabled: false, generation: 0, sessionID: UUID())
}
struct DiagnosticTaskTraceContext: Codable, Hashable {
    let monitoringGeneration: UInt64
    let batch: UInt64
    var snapshotID: UUID? = nil
    var recordingGeneration: UInt64? = nil
    var recordingSessionID: UUID? = nil
    init(monitoringGeneration: UInt64, batch: UInt64, snapshotID: UUID? = nil,
         recordingGeneration: UInt64? = nil, recordingSessionID: UUID? = nil) {
        self.monitoringGeneration = monitoringGeneration; self.batch = batch; self.snapshotID = snapshotID
        self.recordingGeneration = recordingGeneration; self.recordingSessionID = recordingSessionID
    }
}
enum DiagnosticTaskIdentityKind: String, Codable { case file, thread, hookTask, unknown }
enum DiagnosticTaskCorrelation: String, Codable { case confirmed, fileOnly, unknown, discontinuous }
enum DiagnosticTaskAliasContinuity: String, Codable { case allocated, retained, remappedAfterEviction, possibleDiscontinuity, capacityReached }
struct DiagnosticTaskTraceIdentity: Codable, Hashable {
    let domain: UUID
    let taskAlias: UUID
    let turnAlias: UUID?
    let fileGeneration: UUID?
    let identityKind: DiagnosticTaskIdentityKind
    let correlation: DiagnosticTaskCorrelation
}
enum DiagnosticTaskTracePhase: String, Codable { case unknown, submitted, running, stopping, completed, interrupted }
enum DiagnosticTaskReadReason: String, Codable {
    case unchanged, initialRead, fileReplaced, fileTruncated, fileReset, normalRead, readBudgetSkip
    case firstLineDiscarded, pendingLimitExceeded, readFailure, fileMissing, fileRejected, headerRead, boundedTailRead, malformedLine, invalidEventMetadata
}
struct DiagnosticTaskReadMetrics: Codable, Equatable {
    var fileBytes: UInt64? = nil
    var offsetBefore: UInt64? = nil
    var offsetAfter: UInt64? = nil
    var readBytes: UInt64? = nil
    var headerReadBytes: UInt64? = nil
    var skippedBytes: UInt64? = nil
    var backlogBytes: UInt64? = nil
    var pendingBytesBefore: UInt64? = nil
    var pendingBytes: UInt64? = nil
    var discardedBytes: UInt64? = nil
    var stateCleared: Bool = false
    var reason: DiagnosticTaskReadReason = .normalRead
}
enum DiagnosticTaskEvidenceKind: String, Codable { case started, complete, aborted, execution, weakActivity, unknown }
enum DiagnosticTaskTransitionReason: String, Codable {
    case acceptedStart, acceptedComplete, acceptedAbort, acceptedExecution
    case turnMismatch, missingStartEvidence, olderTimestamp, historicalBaselineRestricted
    case terminalLateActivity, staleExecution, invalidTurnIdentity, invalidTimestamp
    case fileReset, readBudgetSkip, pendingLimitExceeded, staleWithoutTerminal, historyOutOfScope, readFailure, unknown
    case historicalStart, sourceExcluded, olderPosition, duplicatePosition, settledTerminal
    case submissionHint, stopHint, interruptHint, missingTurnHint, terminalHintIgnored, invalidProtocol
    case sleep, hostUnavailable, restart, verificationExpired, staleEvidence, capacityRemoved, sourceRemoved, supersededHint
}
struct DiagnosticTaskLifecycleTransition: Codable, Equatable {
    let before: DiagnosticTaskTracePhase
    let after: DiagnosticTaskTracePhase
    let evidence: DiagnosticTaskEvidenceKind
    let accepted: Bool
    let reason: DiagnosticTaskTransitionReason
}
enum DiagnosticTaskMemberReason: String, Codable {
    case lifecycleChanged, readBudgetSkip, pendingLimitExceeded, fileReset, staleWithoutTerminal
    case historyOutOfScope, readFailure, inventoryAdded, leftCurrentQueryResult, monitorStopped, modeChanged, capacityRemoved, sourceRemoved, unknown
}
enum DiagnosticTaskDiscoveryScope: String, Codable { case latestRollouts, hooksInventory, hookEvidence, unknown }
enum DiagnosticTaskDiscoveryCoverage: String, Codable { case limited, complete, unknown }
struct DiagnosticTaskDiscovery: Codable, Equatable {
    var scope: DiagnosticTaskDiscoveryScope = .unknown
    var queryLimit: Int? = nil
    var returnedRows: Int? = nil
    var acceptedRows: Int? = nil
    var rejectedPaths: Int? = nil
    var sourceFilteredRows: Int? = nil
    var traversalComplete: Bool? = nil
    var coverage: DiagnosticTaskDiscoveryCoverage = .unknown
}
enum DiagnosticTaskPresentation: String, Codable { case running, completedFeedback, neutral, disabled, unknown }
struct DiagnosticTaskSnapshotMember: Codable, Hashable {
    let taskAlias: UUID
    let turnAlias: UUID?
    let fileGeneration: UUID?
    let phase: DiagnosticTaskTracePhase
    let counted: Bool
    init(identity: DiagnosticTaskTraceIdentity, phase: DiagnosticTaskTracePhase, counted: Bool) {
        taskAlias = identity.taskAlias; turnAlias = identity.turnAlias; fileGeneration = identity.fileGeneration
        self.phase = phase; self.counted = counted
    }
}
struct DiagnosticTaskSnapshotReference: Codable, Equatable, Sendable {
    let domain: UUID
    let monitoringGeneration: UInt64
    let batch: UInt64
    let snapshotID: UUID
    let runningCount: Int
    let unknownCount: Int
    let memberCount: Int
    let memberPageCount: Int
    let membershipComplete: Bool
    var recordingSessionID: UUID = DiagnosticTaskTraceState.disabled.sessionID
    var recordingGeneration: UInt64 = 0
    var previousSnapshotID: UUID? = nil
}
enum DiagnosticTaskTraceSurface: String, Codable { case coordinator, main, touchBar, menuBar, floating, notch }
enum DiagnosticTaskTraceConsumer: String, Codable {
    case coordinator, main, touchBarPersistent, touchBarResponder, floatingController, floatingView, notchIsland, notchLegacy, menuBar
}
enum DiagnosticTaskConsumptionAction: String, Codable { case received, renderRequested, skipped, presentationRevised }
enum DiagnosticTaskConsumptionReason: String, Codable {
    case update, sameValueSuppressed, staleGeneration, disabled, hidden, noHardware, noContent, sleeping
    case layoutRefresh, quotaRefresh, completionFeedbackExpired, unavailable, notLoaded, noInterface, snapshotMismatch, unknown
}
enum DiagnosticTaskObservationGapReason: String, Codable { case producerBufferLimit, deliveryBufferLimit }
enum DiagnosticTaskCompactRule: String, Codable { case exact, ninePlus, hidden, unknown }
struct DiagnosticTaskConsumption: Codable, Equatable {
    let surface: DiagnosticTaskTraceSurface
    let action: DiagnosticTaskConsumptionAction
    let logicalTaskCount: Int
    let presentation: DiagnosticTaskPresentation
    let compactRule: DiagnosticTaskCompactRule
    let reason: DiagnosticTaskConsumptionReason
    var presentationRevision: UInt64 = 0
    var consumer: DiagnosticTaskTraceConsumer? = nil
}
enum DiagnosticTaskTraceEvent: Codable {
    case observationGap(context: DiagnosticTaskTraceContext, droppedCount: UInt64, reason: DiagnosticTaskObservationGapReason)
    case identity(context: DiagnosticTaskTraceContext, identity: DiagnosticTaskTraceIdentity, continuity: DiagnosticTaskAliasContinuity)
    case read(context: DiagnosticTaskTraceContext, identity: DiagnosticTaskTraceIdentity, metrics: DiagnosticTaskReadMetrics)
    case lifecycle(context: DiagnosticTaskTraceContext, identity: DiagnosticTaskTraceIdentity, transition: DiagnosticTaskLifecycleTransition)
    case member(context: DiagnosticTaskTraceContext, identity: DiagnosticTaskTraceIdentity, countedBefore: Bool, countedAfter: Bool, reason: DiagnosticTaskMemberReason)
    case discovery(context: DiagnosticTaskTraceContext, observation: DiagnosticTaskDiscovery)
    case snapshot(reference: DiagnosticTaskSnapshotReference, presentation: DiagnosticTaskPresentation)
    case snapshotMembers(reference: DiagnosticTaskSnapshotReference, pageIndex: Int, members: [DiagnosticTaskSnapshotMember])
    case snapshotCheckpoint(reference: DiagnosticTaskSnapshotReference, checksum: UInt64)
    case consumption(reference: DiagnosticTaskSnapshotReference, observation: DiagnosticTaskConsumption)
    case aliasGap(context: DiagnosticTaskTraceContext, reason: DiagnosticTaskAliasContinuity)
}

/// Raw keys remain only in this bounded, process-local map. The sink receives safe UUIDs and enums only.
/// Callers pass production decisions; this adapter never computes production task state.
final class DiagnosticTaskTrace {
    static let membersPerPage = 8
    static let maximumSnapshotMembers = 4096
    private enum KeyCategory: Hashable { case task, turn, file }
    private struct Key: Hashable {
        let category: KeyCategory
        let kind: DiagnosticTaskIdentityKind
        let owner: UUID?
        let raw: String
    }
    private struct Entry { let alias: UUID; var current: Bool; var touched: UInt64 }
    private struct SnapshotValue: Equatable {
        let domain: UUID
        let monitoringGeneration: UInt64
        let members: [DiagnosticTaskSnapshotMember]
        let running: Int
        let unknown: Int
        let presentation: DiagnosticTaskPresentation
        let complete: Bool
    }
    private let recorder: DiagnosticRecording
    private let stateProvider: () -> DiagnosticTaskTraceState
    private let maximumAliases: Int
    private let lock = NSLock()
    private var state: DiagnosticTaskTraceState?
    private var domain: UUID?
    private var entries: [Key: Entry] = [:]
    private var keysByAlias: [UUID: Key] = [:]
    private var retainedKeyBytes = 0
    private var retiredKeys: [Key] = []
    private var tick: UInt64 = 0
    private var capacityReported = false
    private var hasEvicted = false
    private var lastSnapshot: (SnapshotValue, DiagnosticTaskSnapshotReference)?
    private var lastDiscovery: (UInt64, DiagnosticTaskDiscovery)?

    init(recorder: DiagnosticRecording, maximumAliases: Int = 4096,
         state: (() -> DiagnosticTaskTraceState)? = nil) {
        self.recorder = recorder; self.maximumAliases = max(1, min(4096, maximumAliases))
        stateProvider = state ?? { recorder.taskTraceState }
    }
    var isEnabled: Bool { stateProvider().enabled }
    var mappedAliasCount: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    func observationGap(context: DiagnosticTaskTraceContext, droppedCount: UInt64, reason: DiagnosticTaskObservationGapReason) {
        _ = active(context: context) { state, _ in
            guard droppedCount > 0 else { return }
            emit(.observationGap(context: context, droppedCount: droppedCount, reason: reason), state: state)
        }
    }

    func identity(taskKey: String, turnKey: String? = nil, fileKey: String? = nil,
                  kind: DiagnosticTaskIdentityKind, correlation: DiagnosticTaskCorrelation = .unknown,
                  isCurrent: Bool = true, context: DiagnosticTaskTraceContext) -> DiagnosticTaskTraceIdentity? {
        active(context: context) { state, domain in
            guard !taskKey.isEmpty, taskKey.utf8.count <= 2048,
                  turnKey.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? true,
                  fileKey.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? true else {
                reportCapacity(context, state: state); return nil
            }
            let key = Key(category: .task, kind: kind, owner: nil, raw: taskKey)
            let existed = entries[key] != nil
            let remapped = retiredKeys.contains(key)
            guard let task = alias(key, current: true, context: context, state: state) else { return nil }
            let newTurn = turnKey.map { entries[Key(category: .turn, kind: kind, owner: task, raw: $0)] == nil } ?? false
            let newFile = fileKey.map { entries[Key(category: .file, kind: kind, owner: task, raw: $0)] == nil } ?? false
            if turnKey != nil || fileKey != nil {
                for child in Array(entries.keys) where child.owner == task { entries[child]?.current = false }
            }
            let turn = turnKey.flatMap { alias(Key(category: .turn, kind: kind, owner: task, raw: $0), current: isCurrent, context: context, state: state) }
            let file = fileKey.flatMap { alias(Key(category: .file, kind: kind, owner: task, raw: $0), current: isCurrent, context: context, state: state) }
            let incomplete = (turnKey != nil && turn == nil) || (fileKey != nil && file == nil)
            entries[key]?.current = isCurrent
            let possibleBreak = !existed && hasEvicted && !remapped
            let value = DiagnosticTaskTraceIdentity(domain: domain, taskAlias: task, turnAlias: turn, fileGeneration: file,
                identityKind: kind, correlation: remapped || incomplete || possibleBreak ? .discontinuous : correlation)
            if !existed || newTurn || newFile {
                let continuity: DiagnosticTaskAliasContinuity = remapped ? .remappedAfterEviction : (possibleBreak ? .possibleDiscontinuity : (existed ? .retained : .allocated))
                emit(.identity(context: context, identity: value, continuity: continuity), state: state)
            }
            return value
        } ?? nil
    }

    func retire(taskKey: String, kind: DiagnosticTaskIdentityKind, context: DiagnosticTaskTraceContext) {
        _ = active(context: context) { _, _ in
            let key = Key(category: .task, kind: kind, owner: nil, raw: taskKey)
            guard let alias = entries[key]?.alias else { return }
            entries[key]?.current = false
            for child in Array(entries.keys) where child.owner == alias { entries[child]?.current = false }
        }
    }
    func read(context: DiagnosticTaskTraceContext, identity: DiagnosticTaskTraceIdentity, metrics: DiagnosticTaskReadMetrics) {
        _ = active(context: context) { state, domain in
            guard identity.domain == domain, identityKnown(identity), metrics.reason != .unchanged else { return }
            // Empty idle polls add no events; actual reads preserve precise before/after boundaries.
            guard metrics.reason != .normalRead || metrics.stateCleared || (metrics.readBytes ?? 0) > 0 else { return }
            emit(.read(context: context, identity: identity, metrics: metrics), state: state)
        }
    }
    func lifecycle(context: DiagnosticTaskTraceContext, identity: DiagnosticTaskTraceIdentity, transition: DiagnosticTaskLifecycleTransition) {
        _ = active(context: context) { state, domain in
            guard identity.domain == domain, identityKnown(identity) else { return }
            emit(.lifecycle(context: context, identity: identity, transition: transition), state: state)
        }
    }
    func member(context: DiagnosticTaskTraceContext, identity: DiagnosticTaskTraceIdentity,
                countedBefore: Bool, countedAfter: Bool, reason: DiagnosticTaskMemberReason) {
        _ = active(context: context) { state, domain in
            guard identity.domain == domain, identityKnown(identity) else { return }
            guard countedBefore != countedAfter || [.inventoryAdded, .leftCurrentQueryResult, .monitorStopped].contains(reason) else { return }
            emit(.member(context: context, identity: identity, countedBefore: countedBefore, countedAfter: countedAfter, reason: reason), state: state)
        }
    }
    func discovery(context: DiagnosticTaskTraceContext, observation: DiagnosticTaskDiscovery) {
        _ = active(context: context) { state, _ in
            guard observation != lastDiscovery?.1 || context.monitoringGeneration != lastDiscovery?.0 else { return }
            lastDiscovery = (context.monitoringGeneration, observation)
            emit(.discovery(context: context, observation: observation), state: state)
        }
    }
    /// Stable inventories reuse the last reference; equal totals with different members create a new checkpoint.
    func snapshot(context: DiagnosticTaskTraceContext, members: [DiagnosticTaskSnapshotMember], runningCount: Int,
                  unknownCount: Int, presentation: DiagnosticTaskPresentation = .running,
                  membershipComplete: Bool = true) -> DiagnosticTaskSnapshotReference? {
        active(context: context) { state, domain in
            let accepted = Array(members.prefix(Self.maximumSnapshotMembers)).filter { memberKnown($0) }
                .sorted(by: Self.memberOrder)
            let complete = membershipComplete && accepted.count == members.count && runningCount >= 0 && unknownCount >= 0
                && Set(accepted.map(\.taskAlias)).count == accepted.count && accepted.filter(\.counted).count == runningCount
            let value = SnapshotValue(domain: domain, monitoringGeneration: context.monitoringGeneration,
                members: accepted, running: max(0, runningCount), unknown: max(0, unknownCount), presentation: presentation, complete: complete)
            if let previous = lastSnapshot, previous.0 == value { return previous.1 }
            let pageCount = max(1, (accepted.count + Self.membersPerPage - 1) / Self.membersPerPage)
            let reference = DiagnosticTaskSnapshotReference(domain: domain, monitoringGeneration: context.monitoringGeneration,
                batch: context.batch, snapshotID: UUID(), runningCount: max(0, runningCount), unknownCount: max(0, unknownCount),
                memberCount: accepted.count, memberPageCount: pageCount, membershipComplete: complete,
                recordingSessionID: state.sessionID, recordingGeneration: state.generation,
                previousSnapshotID: lastSnapshot?.1.monitoringGeneration == context.monitoringGeneration ? lastSnapshot?.1.snapshotID : nil)
            lastSnapshot = (value, reference)
            emit(.snapshot(reference: reference, presentation: presentation), state: state)
            for page in 0..<pageCount {
                let start = page * Self.membersPerPage
                let end = min(accepted.count, start + Self.membersPerPage)
                emit(.snapshotMembers(reference: reference, pageIndex: page, members: Array(accepted[start..<end])), state: state)
            }
            emit(.snapshotCheckpoint(reference: reference, checksum: Self.checksum(accepted)), state: state)
            return reference
        } ?? nil
    }
    /// Consumers need no raw-identity map. References are bound to the recorder session and clear generation.
    func consume(reference: DiagnosticTaskSnapshotReference, observation: DiagnosticTaskConsumption) {
        let latest = stateProvider()
        guard latest.enabled, latest.sessionID == reference.recordingSessionID,
              latest.generation == reference.recordingGeneration else { return }
        recorder.record(.taskTrace(.consumption(reference: reference, observation: observation)), expectedGeneration: latest.generation)
    }

    private func active<T>(context: DiagnosticTaskTraceContext, _ body: (DiagnosticTaskTraceState, UUID) -> T) -> T? {
        guard stateProvider().enabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        let latest = stateProvider()
        guard latest.enabled,
              context.recordingGeneration.map({ $0 == latest.generation }) ?? true,
              context.recordingSessionID.map({ $0 == latest.sessionID }) ?? true else { return nil }
        if state?.generation != latest.generation || state?.sessionID != latest.sessionID {
            entries.removeAll(); keysByAlias.removeAll(); retainedKeyBytes = 0; retiredKeys.removeAll(); tick = 0; capacityReported = false; hasEvicted = false
            lastSnapshot = nil; lastDiscovery = nil; domain = UUID(); state = latest
        }
        guard let domain else { return nil }
        return body(latest, domain)
    }
    private func alias(_ key: Key, current: Bool, context: DiagnosticTaskTraceContext, state: DiagnosticTaskTraceState) -> UUID? {
        tick &+= 1
        if var value = entries[key] {
            value.current = current; value.touched = tick; entries[key] = value; return value.alias
        }
        while entries.count >= maximumAliases || retainedKeyBytes + key.raw.utf8.count > 1024 * 1024 {
            guard let victim = entries.filter({ !$0.value.current }).min(by: { $0.value.touched < $1.value.touched }) else {
                reportCapacity(context, state: state); return nil
            }
            remove(victim.key)
            if victim.key.category == .task {
                for child in Array(entries.keys) where child.owner == victim.value.alias { remove(child) }
            }
        }
        let value = Entry(alias: UUID(), current: current, touched: tick)
        entries[key] = value; keysByAlias[value.alias] = key; retainedKeyBytes += key.raw.utf8.count
        capacityReported = false
        return value.alias
    }
    private func remove(_ key: Key) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        keysByAlias.removeValue(forKey: removed.alias)
        retainedKeyBytes -= key.raw.utf8.count; hasEvicted = true
        // Bounded tombstones explain recently evicted identities without retaining an unbounded identity history.
        if !retiredKeys.contains(key) { retiredKeys.append(key) }
        if retiredKeys.count > 64 { retiredKeys.removeFirst(retiredKeys.count - 64) }
    }
    private func identityKnown(_ identity: DiagnosticTaskTraceIdentity) -> Bool {
        keysByAlias[identity.taskAlias]?.category == .task
            && childKnown(identity.turnAlias, owner: identity.taskAlias, category: .turn)
            && childKnown(identity.fileGeneration, owner: identity.taskAlias, category: .file)
    }
    private func memberKnown(_ member: DiagnosticTaskSnapshotMember) -> Bool {
        keysByAlias[member.taskAlias]?.category == .task
            && childKnown(member.turnAlias, owner: member.taskAlias, category: .turn)
            && childKnown(member.fileGeneration, owner: member.taskAlias, category: .file)
    }
    private func childKnown(_ alias: UUID?, owner: UUID, category: KeyCategory) -> Bool {
        guard let alias else { return true }
        return keysByAlias[alias]?.category == category && keysByAlias[alias]?.owner == owner
    }
    private func reportCapacity(_ context: DiagnosticTaskTraceContext, state: DiagnosticTaskTraceState) {
        guard !capacityReported else { return }; capacityReported = true
        emit(.aliasGap(context: context, reason: .capacityReached), state: state)
    }
    private func emit(_ value: DiagnosticTaskTraceEvent, state: DiagnosticTaskTraceState) {
        recorder.record(.taskTrace(value), expectedGeneration: state.generation)
    }
    fileprivate static func memberOrder(_ lhs: DiagnosticTaskSnapshotMember, _ rhs: DiagnosticTaskSnapshotMember) -> Bool {
        let a = lhs.taskAlias.uuidString + (lhs.turnAlias?.uuidString ?? "") + (lhs.fileGeneration?.uuidString ?? "")
        let b = rhs.taskAlias.uuidString + (rhs.turnAlias?.uuidString ?? "") + (rhs.fileGeneration?.uuidString ?? "")
        return a < b
    }
    /// Hashes only already-random aliases plus closed state, never production identifiers or file paths.
    static func checksum(_ members: [DiagnosticTaskSnapshotMember]) -> UInt64 {
        var result: UInt64 = 14695981039346656037
        for member in members.sorted(by: memberOrder) {
            let token = member.taskAlias.uuidString + ":" + (member.turnAlias?.uuidString ?? "-") + ":"
                + (member.fileGeneration?.uuidString ?? "-") + ":" + member.phase.rawValue + ":" + (member.counted ? "1" : "0") + ";"
            for byte in token.utf8 { result = (result ^ UInt64(byte)) &* 1099511628211 }
        }
        return result
    }
}

enum DiagnosticTaskSnapshotIntegrityReason: String, Codable {
    case complete, producerIncomplete, headerMissing, checkpointMissing, duplicateHeader, duplicateCheckpoint
    case missingPages, duplicatePages, referenceMismatch, invalidPage, memberCountMismatch, duplicateMembers, checksumMismatch
}
struct DiagnosticTaskSnapshotIntegrity: Codable {
    let snapshotID: UUID
    let complete: Bool
    let reason: DiagnosticTaskSnapshotIntegrityReason
    let observedPages: Int
    let expectedPages: Int
    let observedMembers: Int
    static func inspect(reference: DiagnosticTaskSnapshotReference, events: [DiagnosticTaskTraceEvent]) -> Self {
        var headers = 0; var checkpoints: [UInt64] = []; var pages: [Int: [DiagnosticTaskSnapshotMember]] = [:]
        var failure: DiagnosticTaskSnapshotIntegrityReason? = DiagnosticTaskTraceEvent.snapshot(reference: reference, presentation: .unknown).isValid ? nil : .invalidPage
        for event in events {
            switch event {
            case .snapshot(let ref, _) where ref.snapshotID == reference.snapshotID:
                headers += 1; if ref != reference { failure = .referenceMismatch }
            case .snapshotMembers(let ref, let page, let members) where ref.snapshotID == reference.snapshotID:
                if ref != reference { failure = .referenceMismatch }
                guard page >= 0, page < reference.memberPageCount, members.count <= DiagnosticTaskTrace.membersPerPage else { failure = .invalidPage; continue }
                if pages[page] != nil { failure = .duplicatePages }; pages[page] = members
            case .snapshotCheckpoint(let ref, let checksum) where ref.snapshotID == reference.snapshotID:
                if ref != reference { failure = .referenceMismatch }; checkpoints.append(checksum)
            case .consumption(let ref, _) where ref.snapshotID == reference.snapshotID:
                if ref != reference { failure = .referenceMismatch }
            default: break
            }
        }
        let members = pages.keys.sorted().flatMap { pages[$0] ?? [] }
        let reason: DiagnosticTaskSnapshotIntegrityReason
        if let failure { reason = failure }
        else if !reference.membershipComplete { reason = .producerIncomplete }
        else if headers == 0 { reason = .headerMissing }
        else if headers > 1 { reason = .duplicateHeader }
        else if checkpoints.isEmpty { reason = .checkpointMissing }
        else if checkpoints.count > 1 { reason = .duplicateCheckpoint }
        else if pages.count != reference.memberPageCount { reason = .missingPages }
        else if members.count != reference.memberCount || members.filter(\.counted).count != reference.runningCount { reason = .memberCountMismatch }
        else if Set(members.map(\.taskAlias)).count != members.count { reason = .duplicateMembers }
        else if checkpoints.first != DiagnosticTaskTrace.checksum(members) { reason = .checksumMismatch }
        else { reason = .complete }
        return Self(snapshotID: reference.snapshotID, complete: reason == .complete, reason: reason,
            observedPages: pages.count, expectedPages: reference.memberPageCount, observedMembers: members.count)
    }
}


extension DiagnosticTaskTraceEvent {
    /// Defense in depth for stored JSON. Export reconstructs only valid, bounded typed records.
    var isValid: Bool {
        func valid(_ reference: DiagnosticTaskSnapshotReference) -> Bool {
            reference.runningCount >= 0 && reference.unknownCount >= 0 && reference.memberCount >= 0
                && reference.memberCount <= DiagnosticTaskTrace.maximumSnapshotMembers
                && reference.memberPageCount == max(1, (reference.memberCount + DiagnosticTaskTrace.membersPerPage - 1) / DiagnosticTaskTrace.membersPerPage)
        }
        switch self {
        case .observationGap(_, let count, _): return count > 0
        case .discovery(_, let observation):
            return [observation.queryLimit, observation.returnedRows, observation.acceptedRows, observation.rejectedPaths, observation.sourceFilteredRows]
                .allSatisfy { $0.map { $0 >= 0 } ?? true }
        case .snapshot(let reference, _), .snapshotCheckpoint(let reference, _): return valid(reference)
        case .snapshotMembers(let reference, let page, let members):
            return valid(reference) && page >= 0 && page < reference.memberPageCount && members.count <= DiagnosticTaskTrace.membersPerPage
        case .consumption(let reference, let observation): return valid(reference) && observation.logicalTaskCount >= 0
        default: return true
        }
    }
}
