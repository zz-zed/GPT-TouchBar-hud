import Foundation

public struct TurnRecord: Codable, Sendable {
    public let identity: TurnIdentity
    public var phase: TaskPhase
    public var receivedAt: Date
    public var evidenceAt: Date?
    public var firstPosition: UInt64?
    public var lastPosition: UInt64?
    public var terminalAt: Date?
    public var supersededBy: String? = nil
    public var countedWhileStopping: Bool = false
}

public struct HookDiagnostic: Codable, Sendable {
    public let kind: String
    public let date: Date
}

/// A value reducer: all clocks and evidence are supplied by its caller. No I/O or timers.
public struct TaskStateReducer: Sendable {
    public private(set) var records: [TurnIdentity: TurnRecord] = [:]
    public private(set) var diagnostics: [HookDiagnostic] = []
    public var coverage: TaskCoverage
    public var health = HookSourceHealth(state: .awaitingEvents)
    private var excludedTasks: Set<TaskIdentity> = []
    public init(coverage: TaskCoverage = TaskCoverage()) { self.coverage = coverage }

    public mutating func gap(_ gap: CoverageGap, now: Date) {
        coverage.gaps.insert(gap)
        diagnostics.append(HookDiagnostic(kind: gap.rawValue, date: now))
        if diagnostics.count > HookBudget.diagnostics { diagnostics.removeFirst(diagnostics.count - HookBudget.diagnostics); coverage.gaps.insert(.capacity) }
    }

    public mutating func receive(_ event: HookEvent, now: Date) {
        guard event.isValid else { gap(.protocolError, now: now); return }
        health.state = .connected; health.lastReceipt = now
        let task = TaskIdentity(source: event.source, session: event.session)
        guard !excludedTasks.contains(task) else { return }
        guard let turn = event.turn else {
            for key in records.keys.filter({ $0.task == task }) where !isTerminal(records[key]!.phase) {
                records[key]?.phase = .unknown; records[key]?.countedWhileStopping = false
            }
            return
        }
        let key = TurnIdentity(task: task, turn: turn)
        var record = records[key] ?? TurnRecord(identity: key, phase: .unknown, receivedAt: now)
        switch event.kind {
        case .submitted:
            // Repeated submissions are hints too. They never reactivate without later log evidence.
            if record.phase == .unknown && record.lastPosition == nil { record.phase = .submitted }
        case .stop:
            if !isTerminal(record.phase) {
                let wasCounted = record.phase == .active || record.countedWhileStopping
                if record.phase != .stopping { record.receivedAt = now }
                record.phase = .stopping; record.countedWhileStopping = wasCounted
            }
        case .interrupt:
            // A callback lacks a host sequence. Do not override newer evidence with a late hint.
            record.phase = .unknown; record.countedWhileStopping = false
        case .sessionEnd: break
        }
        records[key] = record
        enforceCapacity(now: now)
    }

    public mutating func exclude(_ task: TaskIdentity) {
        records = records.filter { $0.key.task != task }
        if excludedTasks.count >= HookBudget.turns { excludedTasks.removeAll() }
        excludedTasks.insert(task)
    }

    public mutating func apply(_ evidence: TaskEvidence, now: Date) {
        guard !excludedTasks.contains(evidence.identity.task) else { return }
        if evidence.kind == .started {
            // A Hook must have happened by its receipt time. A different turn's explicitly
            // logged start AFTER that receipt proves the unlogged hint belongs to an older
            // round in this serialized session. Arrival order/opaque IDs alone never suffice.
            for key in Array(records.keys) where key.task == evidence.identity.task && key != evidence.identity {
                if let old = records[key], old.firstPosition == nil, !isTerminal(old.phase), evidence.date > old.receivedAt {
                    records[key]?.supersededBy = evidence.identity.turn
                }
            }
        }
        var record = records[evidence.identity] ?? TurnRecord(identity: evidence.identity, phase: .unknown, receivedAt: now)
        if let previous = record.lastPosition, evidence.position < previous { return }
        if let previous = record.lastPosition, evidence.position == previous {
            // Same terminal can be confirmed by a subsequent stable EOF check, not by a duplicate Hook.
            if evidence.kind == .complete && evidence.settled && record.phase == .stopping {
                record.phase = .completed; record.terminalAt = evidence.date; record.countedWhileStopping = false
                records[evidence.identity] = record
            }
            return
        }
        if record.firstPosition == nil {
            let hasOrderedOther = records.values.contains { $0.identity.task == evidence.identity.task && $0.identity != evidence.identity && $0.firstPosition != nil }
            if evidence.kind == .started || evidence.kind == .execution || !hasOrderedOther {
                record.firstPosition = evidence.position
            } else {
                // A terminal-only turn can be a late old turn or a missed newer turn. Its byte
                // position alone cannot order its start against an already known different turn.
                gap(.orderingConflict, now: now)
            }
        }
        record.lastPosition = evidence.position
        record.evidenceAt = evidence.date
        switch evidence.kind {
        case .started, .execution:
            record.supersededBy = nil
            record.phase = evidence.live ? .active : .unknown
            record.terminalAt = nil; record.countedWhileStopping = false
        case .complete:
            let wasActive = record.phase == .active || record.countedWhileStopping
            record.phase = evidence.settled ? .completed : .stopping
            record.terminalAt = evidence.date; record.receivedAt = now
            record.countedWhileStopping = !evidence.settled && wasActive
        case .aborted:
            record.phase = .interrupted; record.terminalAt = evidence.date; record.countedWhileStopping = false
        }
        records[evidence.identity] = record
        enforceCapacity(now: now)
    }

    public mutating func invalidate(_ reason: CoverageGap, now: Date, task: TaskIdentity? = nil, resetPositions: Bool = false) {
        gap(reason, now: now)
        for key in Array(records.keys) where task == nil || key.task == task {
            if !isTerminal(records[key]!.phase) { records[key]?.phase = .unknown; records[key]?.countedWhileStopping = false }
            if resetPositions { records[key]?.firstPosition = nil; records[key]?.lastPosition = nil }
        }
    }

    public mutating func tick(now: Date) {
        for key in Array(records.keys) {
            guard var record = records[key] else { continue }
            if [.stopping, .submitted].contains(record.phase), now.timeIntervalSince(record.receivedAt) > HookBudget.verificationSeconds {
                record.phase = .unknown; record.countedWhileStopping = false
            }
            if record.phase == .active, let date = record.evidenceAt, now.timeIntervalSince(date) > HookBudget.staleSeconds {
                record.phase = .unknown; gap(.staleEvidence, now: now)
            }
            records[key] = record
        }
    }

    public func snapshot(now: Date) -> TaskActivitySnapshot {
        var result = TaskActivitySnapshot(coverage: coverage, sourceHealth: [health], updatedAt: now)
        for entries in Dictionary(grouping: records.values, by: { $0.identity.task }).values {
            let ordered = entries.filter { $0.firstPosition != nil }
            let latest = ordered.max { $0.firstPosition! < $1.firstPosition! }
            // A turn with no ordering evidence may be newer. Do not silently discard it.
            let unresolved = entries.filter { $0.firstPosition == nil && $0.supersededBy == nil && !isTerminal($0.phase) }
            let candidates = latest.map { [$0] } ?? []
            let visible = candidates + unresolved
            if visible.contains(where: { $0.phase == .active || ($0.phase == .stopping && $0.countedWhileStopping) }) {
                result.confirmedRunningCount += 1
            }
            if visible.contains(where: { [.unknown, .submitted, .stopping].contains($0.phase) }) {
                result.pendingVerificationCount += 1
                if visible.allSatisfy({ $0.phase == .submitted }) { result.submittedCount += 1 }
            } else if let latest, latest.phase == .completed, let terminal = latest.terminalAt,
                      (0..<30).contains(now.timeIntervalSince(terminal)) { result.recentlyCompletedCount += 1
                result.recentCompletions.append(TaskCompletion(identity: latest.identity, occurredAt: terminal))
            }
        }
        result.recentCompletions.sort { $0.occurredAt > $1.occurredAt }
        result.recentCompletions = Array(result.recentCompletions.prefix(32))
        return result
    }

    public mutating func restore(_ saved: [TurnRecord], now: Date) {
        for record in saved.prefix(HookBudget.turns) {
            guard HookEvent.validID(record.identity.task.session), HookEvent.validID(record.identity.turn), record.identity.task.source == "codexLocal",
                  record.supersededBy.map(HookEvent.validID) ?? true else { continue }
            var recovered = record
            if !isTerminal(recovered.phase) { recovered.phase = .unknown }
            recovered.countedWhileStopping = false
            // Evidence positions only mean something within the resolver's current file generation.
            recovered.firstPosition = nil; recovered.lastPosition = nil
            records[record.identity] = recovered
        }
        invalidate(.restart, now: now)
        if saved.count >= HookBudget.turns { gap(.capacity, now: now) }
    }
    private func isTerminal(_ phase: TaskPhase) -> Bool { phase == .completed || phase == .interrupted }
    private mutating func enforceCapacity(now: Date) {
        while records.count > HookBudget.turns {
            if let oldest = records.min(by: { $0.value.receivedAt < $1.value.receivedAt })?.key { records.removeValue(forKey: oldest) }
            gap(.capacity, now: now)
        }
    }
}
