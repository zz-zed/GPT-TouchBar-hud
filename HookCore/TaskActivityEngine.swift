import Foundation

public struct TaskEngineBudget: Sendable {
    public var perFileBytes: Int
    public var totalBytes: Int
    public var filesPerPoll: Int
    public var secondsPerPoll: TimeInterval
    public init(perFileBytes: Int = 256 * 1024, totalBytes: Int = 2 * 1024 * 1024, filesPerPoll: Int = 32, secondsPerPoll: TimeInterval = 0.1) {
        self.perFileBytes = max(1, perFileBytes); self.totalBytes = max(1, totalBytes)
        self.filesPerPoll = max(1, filesPerPoll); self.secondsPerPoll = max(0.001, secondsPerPoll)
    }
}
public struct TaskEngineSnapshot: Sendable {
    public var sequence: UInt64
    public var generation: UInt64
    public var activity: TaskActivitySnapshot
    public var records: [TaskIdentity: TaskEngineRecord]
    public var runningIDs: Set<TaskIdentity> { Set(records.values.filter(\.isRunning).map(\.identity)) }
    public var recentCompletions: [TaskCompletion] { activity.recentCompletions }
    public var backlogBytes: UInt64
    public var inventoryComplete: Bool
    public var capability: TaskSourceCapability = .continuousLogsOnly
    public var readFailureCount: Int
    public var discoveryFailed: Bool
    public var lastSuccessfulCheck: Date?
    public var bytesRead: Int
    public var filesRead: Int
    public var hasBacklog: Bool
}

/// Serial-worker owned. Both production modes supply hints to this same state machine;
/// the engine alone computes the visible task identity set and aggregate count.
public final class TaskActivityEngine {
    private final class Node {
        var entry: TaskInventoryEntry
        var reader: TaskJournalReader
        var published: TaskEngineRecord
        var candidate: TaskEngineRecord
        var targetEOF: UInt64?
        var backlogBytes: UInt64 = 0
        var lastFetched: UInt64 = 0
        var lastReadFailed = false
        var lastDecodeFailed = false
        var excluded = false
        var unsupportedSessionSource = false
        var needsRead = true
        var historicalThrough: UInt64 = 0
        var replacementPending = false
        var checkpointOffset: UInt64 = 0
        init(entry: TaskInventoryEntry, home: URL, saved: TaskCheckpointEntry? = nil) {
            self.entry = entry
            reader = TaskJournalReader(home: home, path: entry.path, expectedSessionID: entry.identity.session, resume: saved?.journal)
            published = saved?.published ?? TaskEngineRecord(identity: entry.identity)
            candidate = saved?.candidate ?? published
            lastDecodeFailed = candidate.hasUnresolvedGap
            targetEOF = saved?.targetEOF
            checkpointOffset = saved?.journal?.committedOffset ?? 0
        }
    }
    public let home: URL
    public let sourceMode: TaskSourceMode
    public let observationSink: TaskObservationSink?
    public let inventory: TaskInventory
    public var budget: TaskEngineBudget
    private let store: TaskCheckpointStore?
    private var nodes: [TaskIdentity: Node] = [:]
    private var generation: UInt64 = 0
    private var observationStarted = Date.distantFuture
    private var enabled = false
    private var paused = false
    private var pauseGap: CoverageGap = .disconnected
    private var didRestore = false
    private var roundRobinIndex = 0
    private var priorityIndex = 0
    private var urgentIndex = 0
    private var schedulingSlot = 0
    private var lastCheckpointData: Data?
    private var completionIDs: [String: Date] = [:]
    private var recentCompletions: [TaskCompletion] = []
    private let aliasScope = TaskObservationSequence.next()
    private var lastSequence: UInt64 = 0
    private var lastSuccessfulCheck: Date?
    private var checkpointFailed = false
    private var checkpointDirty = false
    private var lastCoverage: TaskInventoryCoverage = .partial
    private var latest: TaskEngineSnapshot?

    public init(home: URL, checkpointURL: URL? = nil, sink: TaskObservationSink? = nil,
                sourceMode: TaskSourceMode = .legacy, budget: TaskEngineBudget = TaskEngineBudget()) {
        self.home = home; self.sourceMode = sourceMode; self.observationSink = sink; self.budget = budget
        inventory = TaskInventory(home: home)
        store = checkpointURL.map(TaskCheckpointStore.init)
    }
    deinit { TaskObservationAliases.release(scope: aliasScope) }
    public func begin(now: Date, generation: UInt64) {
        self.generation = generation; observationStarted = now; enabled = true; paused = false
        if !didRestore {
            didRestore = true
            restore(now: now)
        }
        TaskObservationAliases.protect(scope: aliasScope, home: home, identities: Set(nodes.keys))
        demote(reason: .resumed)
        inventory.requestFullReconciliation()
    }
    public func stop(now: Date) {
        TaskObservationAliases.release(scope: aliasScope)
        enabled = false; paused = false; observationStarted = .distantFuture
        demote(reason: .disabled)
        recentCompletions.removeAll()
        // Stop is called on the same worker; save only, no new source discovery/read work.
        persist(now: now)
    }
    public func reconcile(now: Date, generation: UInt64, reason: TaskReconciliationReason) {
        self.generation = generation
        switch reason {
        case .sleep, .hostUnavailable:
            paused = true; pauseGap = reason == .sleep ? .sleep : .disconnected
            observationStarted = .distantFuture
            demote(reason: reason == .sleep ? .suspended : .hostUnavailable)
            recentCompletions.removeAll(); persist(now: now)
        default: begin(now: now, generation: generation)
        }
    }
    public func receiveHint(_ event: HookEvent, now: Date, generation: UInt64) {
        guard enabled, !paused, generation == self.generation, event.isValid else { return }
        let identity = TaskIdentity(source: event.source, session: event.session)
        inventory.hint(identity)
        nodes[identity]?.needsRead = true
        // Hooks have no comparable host ordering and cannot establish execution or success.
        observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: alias(identity), reason: .hintOnly))
    }

    public func poll(now: Date, generation: UInt64, cancelled: () -> Bool = { false }) -> TaskEngineSnapshot {
        guard generation == self.generation else {
            observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: nil, reason: .staleGeneration))
            return latest ?? snapshot(now: now, bytesRead: 0, filesRead: 0, discoveryFailed: false)
        }
        lastSequence = TaskObservationSequence.next()
        guard enabled, !paused, !cancelled() else {
            let value = snapshot(now: now, bytesRead: 0, filesRead: 0, discoveryFailed: false)
            latest = value; return value
        }
        expireSilentEvidence(now: now)
        let deadline = ProcessInfo.processInfo.systemUptime + budget.secondsPerPoll
        let evictable = Set(nodes.values.filter { node in
            !node.needsRead && node.targetEOF == nil && node.backlogBytes == 0 && !node.lastReadFailed
                && (([TaskPhase.completed, .interrupted].contains(node.published.phase)
                     && [TaskPhase.completed, .interrupted].contains(node.candidate.phase))
                    || (node.published.turnID == nil && node.candidate.turnID == nil))
        }.map { $0.entry.identity })
        let found = inventory.discover(now: now, evictable: evictable, timeBudget: min(0.05, budget.secondsPerPoll / 2), cancelled: cancelled)
        for identity in found.evicted { nodes.removeValue(forKey: identity); checkpointDirty = true }
        lastCoverage = found.coverage
        if found.malformedRowCount > 0 {
            observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: nil, reason: .malformedIndex))
        }
        for entry in found.entries {
            if entry.isSubagent || !entry.isSupported {
                if nodes.removeValue(forKey: entry.identity) != nil { checkpointDirty = true }
                observationSink?.record(.excluded(sequence: lastSequence, generation: generation, alias: alias(entry.identity), mode: sourceMode,
                    reason: entry.isSubagent ? .excludedSubagent : .unsupportedSource))
                continue
            }
            if let existing = nodes[entry.identity] {
                if existing.entry.path != entry.path {
                    existing.reader = TaskJournalReader(home: home, path: entry.path, expectedSessionID: entry.identity.session)
                    existing.targetEOF = nil; existing.replacementPending = true; existing.candidate = TaskEngineRecord(identity: entry.identity)
                    invalidate(existing, reason: .fileReset)
                    existing.published.firstPosition = nil; existing.published.lastPosition = nil; existing.published.fileGeneration = 0
                }
                existing.entry = entry
            } else { nodes[entry.identity] = Node(entry: entry, home: home) }
        }
        TaskObservationAliases.protect(scope: aliasScope, home: home, identities: Set(nodes.keys))
        observationSink?.record(.inventory(sequence: lastSequence, generation: generation, coverage: found.coverage, discovered: found.entries.count, retained: nodes.count))
        var bytesRead = 0
        var filesRead = 0
        // Rotate through the whole retained inventory. A workload limit is never an inventory cap.
        let ordered = nodes.keys.sorted { $0.session < $1.session }
        let priority = ordered.filter { identity in
            guard let node = nodes[identity], !node.excluded else { return false }
            return node.published.isRunning || node.targetEOF != nil || node.needsRead
                || node.entry.updatedAt >= Int64(max(observationStarted.timeIntervalSince1970, now.addingTimeInterval(-120).timeIntervalSince1970))
        }
        let urgent = ordered.filter { identity in
            guard let node = nodes[identity], !node.excluded else { return false }
            return node.published.isRunning || (node.published.isPending && node.published.lastKnownPhase == .active)
        }
        var processed: Set<TaskIdentity> = []
        if !ordered.isEmpty {
            var visited = 0
            while visited < ordered.count * 4, processed.count < ordered.count, filesRead < budget.filesPerPoll, bytesRead < budget.totalBytes,
                  ProcessInfo.processInfo.systemUptime < deadline, !cancelled() {
                let identity: TaskIdentity
                if !urgent.isEmpty && schedulingSlot % 4 < 2 {
                    identity = urgent[urgentIndex % urgent.count]
                    urgentIndex = (urgentIndex + 1) % urgent.count
                } else if !priority.isEmpty && schedulingSlot % 4 != 3 {
                    identity = priority[priorityIndex % priority.count]
                    priorityIndex = (priorityIndex + 1) % priority.count
                } else {
                    identity = ordered[roundRobinIndex % ordered.count]
                    roundRobinIndex = (roundRobinIndex + 1) % ordered.count
                }
                schedulingSlot += 1
                visited += 1
                guard processed.insert(identity).inserted, let node = nodes[identity] else { continue }
                if node.entry.isSubagent || !node.entry.isSupported {
                    node.excluded = true
                    observationSink?.record(.excluded(sequence: lastSequence, generation: generation, alias: alias(node.entry.identity), mode: sourceMode,
                                                       reason: node.entry.isSubagent ? .excludedSubagent : .unsupportedSource))
                    continue
                }
                let count = read(node, now: now, byteBudget: min(budget.perFileBytes, budget.totalBytes - bytesRead), cancelled: { cancelled() || ProcessInfo.processInfo.systemUptime >= deadline })
                bytesRead += count; filesRead += 1
            }
        }
        if !cancelled() { persist(now: now) }
        if !found.failed, nodes.values.allSatisfy({ !$0.lastReadFailed }) { lastSuccessfulCheck = now }
        let supportedCompletionIDs = Set(nodes.values.compactMap { node -> String? in
            guard node.published.phase == .completed, let turn = node.published.turnID, let terminal = node.published.terminalAt else { return nil }
            return TaskCompletion(identity: TurnIdentity(task: node.entry.identity, turn: turn), occurredAt: terminal).id
        })
        recentCompletions.removeAll { now.timeIntervalSince($0.occurredAt) >= 30 || !supportedCompletionIDs.contains($0.id) }
        let value = snapshot(now: now, bytesRead: bytesRead, filesRead: filesRead, discoveryFailed: found.failed)
        latest = value
        return value
    }

    private func read(_ node: Node, now: Date, byteBudget: Int, cancelled: () -> Bool) -> Int {
        let identity = node.entry.identity
        let previousPublished = node.published, previousCandidate = node.candidate
        let wasReadUnavailable = node.lastReadFailed
        defer {
            if previousPublished != node.published || previousCandidate != node.candidate || node.checkpointOffset != node.reader.committedOffset {
                checkpointDirty = true; node.checkpointOffset = node.reader.committedOffset
            }
        }
        do {
            let batch = try node.reader.read(byteBudget: byteBudget, targetEOF: node.targetEOF, cancelled: cancelled)
            // Cancellation may occur after complete records were consumed. Always stage those
            // records with the reader offset; the coordinator suppresses cancelled callbacks.
            if batch.resetReason != nil || node.replacementPending {
                node.replacementPending = false
                node.candidate = TaskEngineRecord(identity: identity)
                node.historicalThrough = batch.targetEOF
                invalidate(node, reason: .fileReset)
                node.candidate.lastKnownPhase = node.published.lastKnownPhase
                node.published.firstPosition = nil; node.published.lastPosition = nil; node.published.fileGeneration = batch.generation
                node.lastDecodeFailed = false
            }
            node.lastReadFailed = false
            node.needsRead = false
            node.lastFetched = batch.fetchedOffset
            node.backlogBytes = batch.backlogBytes
            node.targetEOF = batch.reachedTarget ? nil : batch.targetEOF
            observationSink?.record(.read(sequence: lastSequence, generation: generation, mode: sourceMode,
                boundary: TaskReadObservation(alias: alias(identity), fileGeneration: batch.generation, before: batch.fetchedOffset - UInt64(batch.bytesRead),
                    fetched: batch.fetchedOffset, committed: batch.committedOffset, target: batch.targetEOF,
                    bytesRead: batch.bytesRead, backlogBytes: batch.backlogBytes)))
            if batch.session?.isSubagent == true {
                node.excluded = true
                observationSink?.record(.excluded(sequence: lastSequence, generation: generation, alias: alias(identity), mode: sourceMode, reason: .excludedSubagent))
                return batch.bytesRead
            }
            if let session = batch.session, !["cli", "exec", "vscode"].contains(session.source ?? "") {
                node.excluded = true; node.unsupportedSessionSource = true
                invalidate(node, reason: .unsupportedSource)
                observationSink?.record(.excluded(sequence: lastSequence, generation: generation, alias: alias(identity), mode: sourceMode, reason: .unsupportedSource))
                return batch.bytesRead
            }
            node.excluded = false; node.unsupportedSessionSource = false
            for record in batch.records {
                if record.issue != nil {
                    node.lastDecodeFailed = true
                    node.candidate.hasUnresolvedGap = true
                    if node.candidate.phase != .unknown { node.candidate.lastKnownPhase = node.candidate.phase }
                    node.candidate.phase = .unknown; node.candidate.confirmedGeneration = nil
                    observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: alias(identity), reason: .malformedRecord))
                    continue
                }
                if let event = record.event {
                    apply(event, position: record.endOffset, fileGeneration: batch.generation, to: node, now: now)
                    node.lastDecodeFailed = node.candidate.hasUnresolvedGap
                }
            }
            node.candidate.fileGeneration = batch.generation
            if batch.reachedTarget && !batch.cancelled && !cancelled() {
                var pendingReason: TaskObservationReason? = node.candidate.hasUnresolvedGap ? .malformedRecord
                    : (node.candidate.orderingCapacityLimited ? .capacity : nil)
                if node.candidate.phase == .active, let evidence = node.candidate.evidenceAt,
                   now.timeIntervalSince(evidence) >= HookBudget.staleSeconds {
                    node.candidate.phase = .unknown; node.candidate.lastKnownPhase = .active
                    node.candidate.confirmedGeneration = nil
                    pendingReason = .staleEvidence
                }
                let previous = node.published
                node.candidate.freshness = node.candidate.phase == .unknown ? .pendingReconciliation : .current
                node.published = node.candidate
                if previous.phase != node.published.phase || previous.turnID != node.published.turnID {
                    let reason: TaskObservationReason
                    switch node.published.phase {
                    case .active: reason = wasReadUnavailable ? .continuityRevalidated : .liveStart
                    case .completed: reason = .matchingTerminal
                    case .interrupted: reason = .matchingInterrupt
                    default: reason = pendingReason ?? .historicalStart
                    }
                    observationSink?.record(.transition(sequence: lastSequence, generation: generation, alias: alias(identity), mode: sourceMode,
                        before: previous.phase, after: node.published.phase, reason: reason))
                }
                if node.published.phase == .completed, node.published.confirmedGeneration == generation,
                   let turn = node.published.turnID, let terminal = node.published.terminalAt,
                   terminal >= observationStarted {
                    let completion = TaskCompletion(identity: TurnIdentity(task: identity, turn: turn), occurredAt: terminal)
                    if completionIDs[completion.id] == nil {
                        completionIDs[completion.id] = terminal
                        recentCompletions.append(completion)
                    }
                }
            } else {
                node.published.freshness = .catchingUp
                observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: alias(identity), reason: .budgetBacklog))
            }
            return batch.bytesRead
        } catch {
            node.lastReadFailed = true
            invalidate(node, reason: .readFailed)
            node.published.freshness = .unavailable
            observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: alias(identity), reason: .readFailed))
            return 0
        }
    }

    private func apply(_ event: JournalEvent, position: UInt64, fileGeneration: UInt64, to node: Node, now: Date) {
        guard let kind = TaskLifecyclePolicy.kind(for: event.type) else { return }
        let identity = node.entry.identity
        var record = node.candidate
        guard event.timestamp <= now.addingTimeInterval(5),
              record.lastPosition.map({ position > $0 }) ?? true,
              record.evidenceAt.map({ event.timestamp >= $0 }) ?? true else {
            observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: alias(identity), reason: .lateOrDuplicate)); return
        }
        if kind == .started {
            guard !record.retiredTurnIDs.contains(event.turnID) else {
                observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: alias(identity), reason: .turnMismatch)); return
            }
            if let previousTurn = record.turnID, previousTurn != event.turnID {
                guard record.retiredTurnIDs.count < 512 else {
                    record.orderingCapacityLimited = true
                    record.lastKnownPhase = record.phase == .unknown ? record.lastKnownPhase : record.phase
                    record.phase = .unknown; record.confirmedGeneration = nil
                    node.candidate = record
                    observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: alias(identity), reason: .capacity)); return
                }
                record.retiredTurnIDs.insert(previousTurn)
            }
            if record.evidenceAt == event.timestamp && record.startsAtEvidenceTime.contains(event.turnID) {
                observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: alias(identity), reason: .lateOrDuplicate)); return
            }
            if record.evidenceAt != event.timestamp { record.startsAtEvidenceTime.removeAll() }
            guard record.startsAtEvidenceTime.count < 64 else {
                observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: alias(identity), reason: .capacity)); return
            }
            record.startsAtEvidenceTime.insert(event.turnID)
            record.turnID = event.turnID; record.firstPosition = position
            record.hasUnresolvedGap = false
            record.lastKnownPhase = .active
            let live = event.timestamp >= observationStarted && position > node.historicalThrough
            record.phase = live ? .active : .unknown
            record.confirmedGeneration = live ? generation : nil
            record.terminalAt = nil
        } else {
            guard record.turnID == nil || record.turnID == event.turnID else {
                observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: alias(identity), reason: .turnMismatch)); return
            }
            switch kind {
            case .execution:
                guard record.phase == .active, record.confirmedGeneration == generation, record.turnID == event.turnID else {
                    observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: alias(identity), reason: .weakEventIgnored)); return
                }
                // Weak events refresh an already confirmed turn; they never establish one.
            case .complete, .aborted:
                if record.phase == .completed || record.phase == .interrupted {
                    observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: alias(identity), reason: .lateOrDuplicate)); return
                }
                record.turnID = event.turnID
                record.hasUnresolvedGap = false
                record.phase = kind == .complete ? .completed : .interrupted
                record.lastKnownPhase = record.phase; record.terminalAt = event.timestamp
            case .started: break
            }
        }
        if kind != .started && record.evidenceAt != event.timestamp { record.startsAtEvidenceTime.removeAll() }
        record.lastPosition = position; record.evidenceAt = event.timestamp; record.fileGeneration = fileGeneration
        node.candidate = record
    }

    private func expireSilentEvidence(now: Date) {
        for node in nodes.values where node.targetEOF == nil && node.backlogBytes == 0 {
            guard node.published.phase == .active, let evidence = node.published.evidenceAt,
                  now.timeIntervalSince(evidence) >= HookBudget.staleSeconds else { continue }
            invalidate(node, reason: .staleEvidence)
            node.candidate.phase = .unknown; node.candidate.lastKnownPhase = .active
            node.candidate.confirmedGeneration = nil; node.candidate.freshness = .pendingReconciliation
        }
    }
    private func invalidate(_ node: Node, reason: TaskObservationReason) {
        checkpointDirty = true
        let before = node.published.phase
        if node.published.phase == .active || node.published.isPending {
            node.published.lastKnownPhase = node.published.phase == .unknown ? node.published.lastKnownPhase : node.published.phase
            node.published.phase = .unknown
        }
        node.published.confirmedGeneration = nil; node.published.freshness = .pendingReconciliation
        observationSink?.record(.transition(sequence: lastSequence, generation: generation, alias: alias(node.entry.identity), mode: sourceMode,
            before: before, after: node.published.phase, reason: reason))
    }
    private func demote(reason: TaskObservationReason) {
        for node in nodes.values {
            invalidate(node, reason: reason)
            if node.candidate.phase == .active || node.candidate.isPending {
                if node.candidate.phase != .unknown { node.candidate.lastKnownPhase = node.candidate.phase }
                node.candidate.phase = .unknown
            }
            node.candidate.confirmedGeneration = nil; node.candidate.freshness = .pendingReconciliation
        }
    }
    private func alias(_ identity: TaskIdentity) -> UInt64 {
        let value = TaskObservationAliases.lookup(home: home, identity: identity)
        if let retired = value.retired {
            observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: retired, reason: .aliasRetired))
        }
        if value.overflow {
            observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: value.alias, reason: .aliasCapacity))
        }
        return value.alias
    }
    private func restore(now: Date) {
        guard let store else { return }
        do {
            let value = try store.load()
            inventory.restore(value.entries.map(\.inventory))
            for saved in value.entries {
                nodes[saved.inventory.identity] = Node(entry: saved.inventory, home: home, saved: saved)
            }
            completionIDs = value.completionIDs
        } catch {
            // Missing/corrupt/unsupported snapshots all rebuild from independently verified journals.
            observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: nil, reason: .checkpointInvalid))
        }
    }
    private func persist(now: Date) {
        guard let store, checkpointDirty else { return }
        do {
            var saved: [TaskCheckpointEntry] = []
            for node in nodes.values where !node.excluded || node.unsupportedSessionSource {
                let journal = try node.reader.checkpoint()
                if let journal {
                    saved.append(TaskCheckpointEntry(inventory: node.entry, journal: journal, published: node.published,
                        candidate: node.candidate, targetEOF: node.targetEOF))
                } else {
                    // A known task survives rotation with an incomplete/unverified header.
                    // No byte position or current claim may survive without a verified journal.
                    var known = node.published
                    if known.phase != .unknown { known.lastKnownPhase = known.phase }
                    known.phase = .unknown; known.confirmedGeneration = nil
                    known.firstPosition = nil; known.lastPosition = nil; known.fileGeneration = 0
                    known.freshness = .pendingReconciliation
                    var rebuilding = TaskEngineRecord(identity: node.entry.identity)
                    rebuilding.lastKnownPhase = known.lastKnownPhase
                    rebuilding.hasUnresolvedGap = known.hasUnresolvedGap || node.candidate.hasUnresolvedGap
                    saved.append(TaskCheckpointEntry(inventory: node.entry, journal: nil, published: known,
                        candidate: rebuilding, targetEOF: nil))
                }
            }
            if completionIDs.count > 4096 {
                let ordered = completionIDs.sorted { $0.value > $1.value }
                completionIDs = Dictionary(uniqueKeysWithValues: ordered.prefix(4096).map { ($0.key, $0.value) })
            }
            saved.sort { $0.inventory.identity.session < $1.inventory.identity.session }
            let comparable = TaskEngineCheckpoint(savedAt: .distantPast, entries: saved, completionIDs: completionIDs)
            try TaskCheckpointStore.validateEncodingBudget(comparable)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(comparable)
            if encoded != lastCheckpointData {
                try store.save(TaskEngineCheckpoint(savedAt: now, entries: saved, completionIDs: completionIDs))
                lastCheckpointData = encoded
            }
            checkpointFailed = false; checkpointDirty = false
        } catch {
            checkpointFailed = true
            observationSink?.record(.issue(sequence: lastSequence, generation: generation, alias: nil, reason: .checkpointFailed))
        }
    }
    private func snapshot(now: Date, bytesRead: Int, filesRead: Int, discoveryFailed: Bool) -> TaskEngineSnapshot {
        let included = nodes.values.filter { !$0.excluded }
        let records = Dictionary(uniqueKeysWithValues: included.map { ($0.entry.identity, $0.published) })
        let running = records.values.filter(\.isRunning).count
        let pending = records.values.filter(\.isPending).count
        let backlog = included.reduce(UInt64(0)) { $0 + $1.backlogBytes }
        let failures = included.filter(\.lastReadFailed).count
        var gaps: Set<CoverageGap> = [.initialCoverageUnknown]
        if lastCoverage != .complete { gaps.insert(.recoveryBudget) }
        if lastCoverage == .malformedRows || nodes.values.contains(where: \.unsupportedSessionSource) { gaps.insert(.protocolError) }
        if discoveryFailed || failures > 0 { gaps.insert(.missingLog) }
        if included.contains(where: \.lastDecodeFailed) { gaps.insert(.malformedLog) }
        if checkpointFailed { gaps.insert(.restart) }
        if included.contains(where: { $0.candidate.orderingCapacityLimited }) { gaps.insert(.capacity) }
        if paused { gaps.insert(pauseGap) }
        if !enabled { gaps.insert(.disconnected) }
        let health: HookHealthState = !enabled ? .disabled : (paused ? (pauseGap == .sleep ? .suspended : .unavailable) : ((discoveryFailed || failures > 0) ? .degraded : .connected))
        var activity = TaskActivitySnapshot(confirmedRunningCount: running, pendingVerificationCount: pending,
            recentlyCompletedCount: recentCompletions.count, coverage: TaskCoverage(scope: "localJournalEvidence", gaps: gaps),
            sourceHealth: [HookSourceHealth(state: health, lastReceipt: lastSuccessfulCheck)], updatedAt: now)
        activity.recentCompletions = recentCompletions.sorted { $0.occurredAt > $1.occurredAt }
        activity.snapshotSequence = lastSequence; activity.observationGeneration = generation
        let hasBacklog = backlog > 0 || lastCoverage == .partial || included.contains(where: { $0.needsRead })
        let freshness: TaskEvidenceFreshness = paused || !enabled ? .pendingReconciliation : (hasBacklog ? .catchingUp : (failures > 0 ? .unavailable : .current))
        observationSink?.record(.snapshot(sequence: lastSequence, generation: generation, mode: sourceMode, running: running, pending: pending,
            freshness: freshness, coverage: lastCoverage, backlogBytes: backlog))
        let members = records.values.filter(\.isRunning).map { alias($0.identity) }.sorted()
        for start in stride(from: 0, to: max(1, members.count), by: 128) {
            observationSink?.record(.members(sequence: lastSequence, generation: generation, mode: sourceMode,
                aliases: members.isEmpty ? [] : Array(members[start..<min(start + 128, members.count)]),
                pageIndex: start / 128, pageCount: max(1, (members.count + 127) / 128), memberCount: members.count))
        }
        return TaskEngineSnapshot(sequence: lastSequence, generation: generation, activity: activity, records: records,
            backlogBytes: backlog, inventoryComplete: lastCoverage == .complete, readFailureCount: failures,
            discoveryFailed: discoveryFailed, lastSuccessfulCheck: lastSuccessfulCheck, bytesRead: bytesRead, filesRead: filesRead, hasBacklog: hasBacklog)
    }
}
