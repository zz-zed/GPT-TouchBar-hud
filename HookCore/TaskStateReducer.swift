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
    public var traceObserver: (@Sendable (HookTaskTraceObservation) -> Void)?
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
            for key in records.keys.filter({ $0.task == task }) where !isTerminal(records[key]!.phase) && records[key]!.terminalAt == nil {
                let before = traceObserver == nil ? nil : records[key]
                let wasCounted = traceObserver == nil ? false : counted(task, now: now)
                records[key]?.phase = .unknown; records[key]?.countedWhileStopping = false
                if traceObserver != nil { traceDecision(key, kind: nil, before: before, accepted: true,
                    reason: .missingTurnHint, countedBefore: wasCounted, position: nil, now: now) }
            }
            return
        }
        let key = TurnIdentity(task: task, turn: turn)
        let before = traceObserver == nil ? nil : records[key]
        let wasCounted = traceObserver == nil ? false : counted(task, now: now)
        var reason: HookTaskDecisionReason = .terminalHintIgnored
        var record = records[key] ?? TurnRecord(identity: key, phase: .unknown, receivedAt: now)
        switch event.kind {
        case .submitted:
            // Repeated submissions are hints too. They never reactivate without later log evidence.
            if record.phase == .unknown && record.lastPosition == nil { record.phase = .submitted; reason = .submissionHint }
        case .stop:
            if !isTerminal(record.phase) {
                let wasCounted = record.phase == .active || record.countedWhileStopping
                if record.phase != .stopping { record.receivedAt = now }
                record.phase = .stopping; record.countedWhileStopping = wasCounted
                reason = .stopHint
            }
        case .interrupt:
            // A callback lacks a host sequence. Do not override newer evidence with a late hint.
            if !isTerminal(record.phase), record.terminalAt == nil {
                record.phase = .unknown; record.countedWhileStopping = false
                reason = .interruptHint
            }
        case .sessionEnd: break
        }
        records[key] = record
        if traceObserver != nil { traceDecision(key, kind: nil, before: before, accepted: reason != .terminalHintIgnored,
            reason: reason, countedBefore: wasCounted, position: nil, now: now) }
        enforceCapacity(now: now)
    }

    public mutating func exclude(_ task: TaskIdentity) {
        let removed = traceObserver == nil ? [] : records.values.filter { $0.identity.task == task }
        let wasCounted = traceObserver == nil ? false : counted(task, now: Date())
        records = records.filter { $0.key.task != task }
        if excludedTasks.count >= HookBudget.turns { excludedTasks.removeAll() }
        excludedTasks.insert(task)
        for before in removed {
            traceObserver?(.decision(HookTaskDecisionObservation(identity: before.identity, kind: nil,
                phaseBefore: before.phase, phaseAfter: nil, accepted: true, reason: .sourceRemoved,
                countedBefore: wasCounted, countedAfter: false, position: nil)))
        }
    }

    public mutating func apply(_ evidence: TaskEvidence, now: Date) {
        let before = traceObserver == nil ? nil : records[evidence.identity]
        let countedBefore = traceObserver == nil ? false : counted(evidence.identity.task, now: now)
        var accepted = false
        var reason: HookTaskDecisionReason = .missingStart
        defer {
            if traceObserver != nil { traceDecision(evidence.identity, kind: evidence.kind, before: before,
                accepted: accepted, reason: reason, countedBefore: countedBefore, position: evidence.position, now: now) }
        }
        guard !excludedTasks.contains(evidence.identity.task) else { reason = .excludedSource; return }
        var record = records[evidence.identity] ?? TurnRecord(identity: evidence.identity, phase: .unknown, receivedAt: now)
        if let previous = record.lastPosition, evidence.position < previous { reason = .olderPosition; return }
        if let previous = record.lastPosition, evidence.position == previous {
            reason = .duplicatePosition
            // Same terminal can be confirmed by a subsequent stable EOF check, not by a duplicate Hook.
            if evidence.kind == .complete && evidence.settled && record.phase == .stopping {
                record.phase = .completed; record.terminalAt = evidence.date; record.countedWhileStopping = false
                records[evidence.identity] = record
                accepted = true; reason = .settledTerminal
            }
            return
        }
        guard let nextPhase = TaskLifecyclePolicy.nextPhase(
            for: evidence.kind, current: record.phase, date: evidence.date, previousDate: record.evidenceAt,
            live: evidence.live, terminalPending: record.terminalAt != nil,
            countedWhileStopping: record.countedWhileStopping, settled: evidence.settled
        ) else {
            if record.evidenceAt.map({ evidence.date < $0 }) == true { reason = .oldTimestamp }
            else if !evidence.live { reason = .historicalBaseline }
            else if record.terminalAt != nil || isTerminal(record.phase) { reason = .terminalActivity }
            else if record.phase != .active && !(record.phase == .stopping && record.countedWhileStopping) || record.evidenceAt == nil { reason = .missingStart }
            else { reason = .staleActivity }
            return
        }
        accepted = true
        switch evidence.kind {
        case .started: reason = evidence.live ? .acceptedStart : .historicalStart
        case .execution: reason = .acceptedExecution
        case .complete: reason = .acceptedComplete
        case .aborted: reason = .acceptedAbort
        }
        if evidence.kind == .started {
            // Only an explicit start orders a new execution, including a continued turn ID.
            record.firstPosition = evidence.position
            for key in Array(records.keys) where key.task == evidence.identity.task && key != evidence.identity {
                if let old = records[key], old.firstPosition == nil, !isTerminal(old.phase), evidence.date > old.receivedAt {
                    records[key]?.supersededBy = evidence.identity.turn
                }
            }
        }
        if record.firstPosition == nil {
            let hasOrderedOther = records.values.contains { $0.identity.task == evidence.identity.task && $0.identity != evidence.identity && $0.firstPosition != nil }
            if evidence.kind == .started || !hasOrderedOther {
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
            record.phase = nextPhase
            record.terminalAt = nil; record.countedWhileStopping = false
        case .complete:
            let wasActive = record.phase == .active || record.countedWhileStopping
            record.phase = nextPhase
            record.terminalAt = evidence.date; record.receivedAt = now
            record.countedWhileStopping = !evidence.settled && wasActive
        case .aborted:
            record.phase = nextPhase; record.terminalAt = evidence.date; record.countedWhileStopping = false
        }
        records[evidence.identity] = record
        enforceCapacity(now: now)
    }

    public mutating func invalidate(_ reason: CoverageGap, now: Date, task: TaskIdentity? = nil, resetPositions: Bool = false,
                                    traceReason: HookTaskDecisionReason? = nil) {
        gap(reason, now: now)
        for key in Array(records.keys) where task == nil || key.task == task {
            let before = traceObserver == nil ? nil : records[key]
            let wasCounted = traceObserver == nil ? false : counted(key.task, now: now)
            if !isTerminal(records[key]!.phase) { records[key]?.phase = .unknown; records[key]?.countedWhileStopping = false }
            if resetPositions { records[key]?.firstPosition = nil; records[key]?.lastPosition = nil }
            if traceObserver != nil {
                let cause: HookTaskDecisionReason
                switch reason {
                case .truncatedLog: cause = .readBudgetSkip
                case .rotatedLog: cause = .fileReset
                case .sleep: cause = .sleep
                case .disconnected: cause = .hostUnavailable
                case .restart: cause = .restart
                default: cause = .readFailure
                }
                traceDecision(key, kind: nil, before: before, accepted: true, reason: traceReason ?? cause,
                              countedBefore: wasCounted, position: nil, now: now)
            }
        }
    }

    public mutating func tick(now: Date) {
        for key in Array(records.keys) {
            guard var record = records[key] else { continue }
            let before = traceObserver == nil ? nil : record
            let wasCounted = traceObserver == nil ? false : counted(key.task, now: now)
            var cause: HookTaskDecisionReason?
            if [.stopping, .submitted].contains(record.phase), now.timeIntervalSince(record.receivedAt) > HookBudget.verificationSeconds {
                record.phase = .unknown; record.countedWhileStopping = false
                cause = .verificationExpired
            }
            if record.phase == .active, let date = record.evidenceAt, now.timeIntervalSince(date) >= HookBudget.staleSeconds {
                record.phase = .unknown; gap(.staleEvidence, now: now)
                cause = .staleEvidence
            }
            records[key] = record
            if traceObserver != nil, let cause {
                traceDecision(key, kind: nil, before: before, accepted: true, reason: cause,
                              countedBefore: wasCounted, position: nil, now: now)
            }
        }
    }

    public func snapshot(now: Date, onMembers: ((HookTaskMemberSnapshot) -> Void)? = nil) -> TaskActivitySnapshot {
        var result = TaskActivitySnapshot(coverage: coverage, sourceHealth: [health], updatedAt: now)
        var members: [HookTaskMember]? = onMembers == nil ? nil : []
        for entries in Dictionary(grouping: records.values, by: { $0.identity.task }).values {
            let selection = select(entries, now: now)
            if selection.running {
                result.confirmedRunningCount += 1
            }
            if selection.pending {
                result.pendingVerificationCount += 1
                if selection.submitted { result.submittedCount += 1 }
            } else if selection.completed, let latest = selection.latest, let terminal = latest.terminalAt {
                result.recentlyCompletedCount += 1
                result.recentCompletions.append(TaskCompletion(identity: latest.identity, occurredAt: terminal))
            }
            if members != nil, let task = entries.first?.identity.task {
                let visible = Set(selection.visible.map(\.identity))
                members?.append(HookTaskMember(task: task, turns: entries.map {
                    HookTaskVisibleTurn(identity: $0.identity, phase: $0.phase, visible: visible.contains($0.identity))
                }.sorted { $0.identity.turn < $1.identity.turn }, selectedTurn: selection.latest?.identity,
                    countedTurns: selection.visible.filter { $0.phase == .active || ($0.phase == .stopping && $0.countedWhileStopping) }.map(\.identity).sorted { $0.turn < $1.turn }, counted: selection.running,
                    unknown: selection.pending, submitted: selection.submitted, completed: selection.completed))
            }
        }
        result.recentCompletions.sort { $0.occurredAt > $1.occurredAt }
        result.recentCompletions = Array(result.recentCompletions.prefix(32))
        if let members {
            onMembers?(HookTaskMemberSnapshot(members: members.sorted { ($0.task.source, $0.task.session) < ($1.task.source, $1.task.session) },
                runningCount: result.confirmedRunningCount, unknownCount: result.pendingVerificationCount,
                submittedCount: result.submittedCount, completedCount: result.recentlyCompletedCount,
                gaps: coverage.gaps, inventoryLimit: HookBudget.turns))
        }
        return result
    }

    private func select(_ entries: [TurnRecord], now: Date) -> (visible: [TurnRecord], latest: TurnRecord?, running: Bool, pending: Bool, submitted: Bool, completed: Bool) {
        let ordered = entries.filter { $0.firstPosition != nil }
        let latest = ordered.max { $0.firstPosition! < $1.firstPosition! }
        let unresolved = entries.filter { $0.firstPosition == nil && $0.supersededBy == nil && !isTerminal($0.phase) }
        let visible = (latest.map { [$0] } ?? []) + unresolved
        let running = visible.contains { $0.phase == .active || ($0.phase == .stopping && $0.countedWhileStopping) }
        let pending = visible.contains { [.unknown, .submitted, .stopping].contains($0.phase) }
        let completed = !pending && latest.map { $0.phase == .completed && $0.terminalAt.map { (0..<30).contains(now.timeIntervalSince($0)) } == true } == true
        return (visible, latest, running, pending, pending && visible.allSatisfy { $0.phase == .submitted }, completed)
    }
    private func counted(_ task: TaskIdentity, now: Date) -> Bool {
        select(records.values.filter { $0.identity.task == task }, now: now).running
    }
    private func traceDecision(_ identity: TurnIdentity, kind: EvidenceKind?, before: TurnRecord?, accepted: Bool,
                               reason: HookTaskDecisionReason, countedBefore: Bool, position: UInt64?, now: Date) {
        traceObserver?(.decision(HookTaskDecisionObservation(identity: identity, kind: kind,
            phaseBefore: before?.phase, phaseAfter: records[identity]?.phase, accepted: accepted, reason: reason,
            countedBefore: countedBefore, countedAfter: counted(identity.task, now: now), position: position)))
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
            if let oldest = records.min(by: { $0.value.receivedAt < $1.value.receivedAt })?.key {
                let before = traceObserver == nil ? nil : records[oldest]
                let wasCounted = traceObserver == nil ? false : counted(oldest.task, now: now)
                records.removeValue(forKey: oldest)
                if traceObserver != nil { traceDecision(oldest, kind: nil, before: before, accepted: true,
                    reason: .capacityRemoved, countedBefore: wasCounted, position: nil, now: now) }
            }
            gap(.capacity, now: now)
        }
    }
}
