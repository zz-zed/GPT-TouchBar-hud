import Foundation
import SQLite3
import CryptoKit
import HookCore

/// Bounded, incremental reader. Never persists or publishes conversation contents.
struct TaskLogCursor {
    static let readLimit = 256 * 1024
    static let runningStaleInterval = HookBudget.staleSeconds
    enum ReadBranch: String { case unchanged, initialRead, fileReplaced, fileTruncated, normalRead, readBudgetSkip, firstLineDiscarded, pendingLimitExceeded, readFailure }
    enum LifecycleReason: String { case acceptedStart, acceptedComplete, acceptedAbort, acceptedExecution, turnMismatch, missingStartEvidence, olderTimestamp, historicalBaselineRestricted, terminalLateActivity, staleExecution, invalidTurnIdentity, invalidTimestamp }
    struct ReadObservation {
        let branch: ReadBranch
        let fileBytes: UInt64?
        let offsetBefore: UInt64
        let offsetAfter: UInt64
        let readBytes: Int
        let skippedBytes: UInt64
        let backlogBytes: UInt64?
        let pendingBytes: Int
        let pendingBytesBefore: Int
        let discardedBytes: Int
        let stateCleared: Bool
        let fileGeneration: UInt64
        let phaseBefore: TaskPhase
        let phaseAfter: TaskPhase
        let countedBefore: Bool
        let countedAfter: Bool
    }
    struct LifecycleObservation {
        let kind: EvidenceKind
        let reason: LifecycleReason
        let accepted: Bool
        let phaseBefore: TaskPhase
        let phaseAfter: TaskPhase
        let countedBefore: Bool
        let countedAfter: Bool
        let turnKey: String? // In-memory only. The monitor converts this to an anonymous alias.
        let fileGeneration: UInt64
    }
    enum Observation { case read(ReadObservation), lifecycle(LifecycleObservation), monitored(DiagnosticTaskMemberReason) }
    typealias Observer = (Observation) -> Void
    private(set) var fileGeneration: UInt64 = 0
    var offset: UInt64 = 0
    var pending = Data()
    var identity: UInt64?
    var phase: String?
    var turnID: String?
    var eventDate: Date?
    var activityDate: Date?
    var fileModifiedAt: Date?
    var observedLiveChange = false
    var completionFeedbackEligible = false
    // Observation only: does not participate in lifecycle decisions.
    private(set) var readWasTruncated = false
    private(set) var latestAcceptedLiveStart: Date?
    private let formatter = ISO8601DateFormatter()

    mutating func read(_ url: URL, liveSince: Date? = nil, now: Date = Date(), observer: Observer? = nil) throws {
        readWasTruncated = false
        let originalOffset = offset
        let originalPendingBytes = observer == nil ? 0 : pending.count
        let originalPhase = observer == nil ? TaskPhase.unknown : productionPhase
        let originalCounted = observer == nil ? false : monitoredSummary(now: now).runningCount > 0
        var fileBytes: UInt64?
        var branch = ReadBranch.normalRead
        var actualReadBytes = 0
        var actualSkippedBytes: UInt64 = 0
        var clearedState = false
        var failed = true
        defer {
            if let observer {
                observer(.read(ReadObservation(branch: failed ? .readFailure : branch, fileBytes: fileBytes,
                    offsetBefore: originalOffset, offsetAfter: offset, readBytes: actualReadBytes,
                    skippedBytes: actualSkippedBytes, backlogBytes: fileBytes.map { $0 > offset ? $0 - offset : 0 },
                    pendingBytes: pending.count, pendingBytesBefore: originalPendingBytes,
                    discardedBytes: branch == .readBudgetSkip ? originalPendingBytes : 0, stateCleared: clearedState,
                    fileGeneration: fileGeneration, phaseBefore: originalPhase, phaseAfter: productionPhase,
                    countedBefore: originalCounted, countedAfter: monitoredSummary(now: now).runningCount > 0)))
            }
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        fileBytes = size
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        let reset = identity != inode || size < offset
        let firstDiscovery = identity == nil
        let hadBaseline = identity != nil && !reset
        if reset {
            branch = firstDiscovery ? .initialRead : (identity != inode ? .fileReplaced : .fileTruncated)
            let nextFileGeneration = fileGeneration &+ 1
            clearedState = phase != nil || !pending.isEmpty
            if let observer, !firstDiscovery {
                observer(.read(ReadObservation(branch: branch, fileBytes: size, offsetBefore: offset, offsetAfter: 0,
                    readBytes: 0, skippedBytes: 0, backlogBytes: size, pendingBytes: 0,
                    pendingBytesBefore: originalPendingBytes, discardedBytes: pending.count, stateCleared: clearedState, fileGeneration: nextFileGeneration,
                    phaseBefore: productionPhase, phaseAfter: .unknown, countedBefore: originalCounted, countedAfter: false)))
            }
            self = TaskLogCursor(); identity = inode; fileGeneration = nextFileGeneration
        }
        fileModifiedAt = attrs[.modificationDate] as? Date
        guard size > offset else { branch = .unchanged; failed = false; return }
        if hadBaseline || fileModifiedAt.map({ Date().timeIntervalSince($0) < Self.runningStaleInterval }) == true {
            observedLiveChange = true
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let skipped = size - offset > UInt64(Self.readLimit)
        if skipped {
            branch = .readBudgetSkip
            readWasTruncated = true
            actualSkippedBytes = size - UInt64(Self.readLimit) - offset
            offset = size - UInt64(Self.readLimit)
            let discardedPendingBytes = pending.count
            let beforeSkipPhase = observer == nil ? TaskPhase.unknown : productionPhase
            let beforeSkipCounted = observer == nil ? false : monitoredSummary(now: now).runningCount > 0
            pending.removeAll()
            phase = nil; turnID = nil; eventDate = nil; activityDate = nil
            clearedState = true
            if let observer {
                observer(.read(ReadObservation(branch: .readBudgetSkip, fileBytes: size,
                    offsetBefore: offset - actualSkippedBytes, offsetAfter: offset,
                    readBytes: 0, skippedBytes: actualSkippedBytes, backlogBytes: size - offset,
                    pendingBytes: 0, pendingBytesBefore: discardedPendingBytes, discardedBytes: discardedPendingBytes,
                    stateCleared: true, fileGeneration: fileGeneration, phaseBefore: beforeSkipPhase,
                    phaseAfter: .unknown, countedBefore: beforeSkipCounted, countedAfter: false)))
            }
        }
        try handle.seek(toOffset: offset)
        let bytes = try handle.read(upToCount: Self.readLimit) ?? Data()
        actualReadBytes = bytes.count
        offset += UInt64(bytes.count)
        consume(bytes, discardFirstLine: skipped, allowsCompletionFeedback: hadBaseline,
                allowsRunning: hadBaseline && !skipped, liveSince: firstDiscovery ? liveSince : nil,
                now: now, observer: observer)
        clearedState = clearedState || readWasTruncated
        failed = false
    }

    private var productionPhase: TaskPhase {
        switch phase {
        case "running": return .active
        case "complete": return .completed
        case "idle": return .interrupted
        default: return .unknown
        }
    }

    mutating func consume(
        _ bytes: Data,
        discardFirstLine: Bool = false,
        allowsCompletionFeedback: Bool = true,
        allowsRunning: Bool = true,
        liveSince: Date? = nil,
        now: Date = Date(),
        observer: Observer? = nil
    ) {
        pending.append(bytes)
        var discard = discardFirstLine
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end])
            pending.removeSubrange(...end)
            if discard {
                discard = false
                if let observer {
                    observer(.read(ReadObservation(branch: .firstLineDiscarded, fileBytes: nil,
                        offsetBefore: offset, offsetAfter: offset, readBytes: 0, skippedBytes: 0,
                        backlogBytes: nil, pendingBytes: pending.count, pendingBytesBefore: pending.count + line.count + 1,
                        discardedBytes: line.count + 1,
                        stateCleared: false, fileGeneration: fileGeneration, phaseBefore: productionPhase,
                        phaseAfter: productionPhase, countedBefore: monitoredSummary(now: now).runningCount > 0,
                        countedAfter: monitoredSummary(now: now).runningCount > 0)))
                }
                continue
            }
            guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  root["type"] as? String == "event_msg",
                  let payload = root["payload"] as? [String: Any],
                  let type = payload["type"] as? String,
                  let timestamp = root["timestamp"] as? String else { continue }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var date = formatter.date(from: timestamp)
            if date == nil {
                formatter.formatOptions = [.withInternetDateTime]
                date = formatter.date(from: timestamp)
            }
            guard let kind = TaskLifecyclePolicy.kind(for: type) else { continue }
            let rawTurn = payload["turn_id"] as? String
            let before = observer == nil ? TaskPhase.unknown : productionPhase
            let countedBefore = observer == nil ? false : monitoredSummary(now: now).runningCount > 0
            func rejected(_ reason: LifecycleReason) {
                observer?(.lifecycle(LifecycleObservation(kind: kind, reason: reason, accepted: false,
                    phaseBefore: before, phaseAfter: before, countedBefore: countedBefore, countedAfter: countedBefore,
                    turnKey: rawTurn.flatMap { HookEvent.validID($0) ? $0 : nil }, fileGeneration: fileGeneration)))
            }
            guard let date else { rejected(.invalidTimestamp); continue }
            guard let id = rawTurn, HookEvent.validID(id) else { rejected(.invalidTurnIdentity); continue }
            if kind == .execution, id != turnID { rejected(turnID == nil ? .missingStartEvidence : .turnMismatch); continue }
            if kind == .complete || kind == .aborted, let turnID, id != turnID { rejected(.turnMismatch); continue }
            let current = productionPhase
            let live = allowsRunning || liveSince.map { date >= $0 } == true
            guard let next = TaskLifecyclePolicy.nextPhase(
                for: kind, current: current, date: date, previousDate: activityDate, live: live
            ) else {
                let reason: LifecycleReason
                if activityDate.map({ date < $0 }) == true { reason = .olderTimestamp }
                else if !live { reason = .historicalBaselineRestricted }
                else if [.completed, .interrupted].contains(current) { reason = .terminalLateActivity }
                else if current != .active || activityDate == nil { reason = .missingStartEvidence }
                else { reason = .staleExecution }
                rejected(reason); continue
            }
            switch next {
            case .active: phase = "running"
            case .completed: phase = "complete"
            case .interrupted: phase = "idle"
            default: phase = nil
            }
            if kind == .started && live && next == .active { latestAcceptedLiveStart = date }
            turnID = id; activityDate = date; eventDate = date
            completionFeedbackEligible = next == .completed && allowsCompletionFeedback
            if let observer {
                let reason: LifecycleReason
                switch kind {
                case .started: reason = live ? .acceptedStart : .historicalBaselineRestricted
                case .complete: reason = .acceptedComplete
                case .aborted: reason = .acceptedAbort
                case .execution: reason = .acceptedExecution
                }
                observer(.lifecycle(LifecycleObservation(kind: kind, reason: reason, accepted: true,
                    phaseBefore: before, phaseAfter: productionPhase, countedBefore: countedBefore,
                    countedAfter: monitoredSummary(now: now).runningCount > 0, turnKey: id, fileGeneration: fileGeneration)))
            }
        }
        // A malformed/huge single record must not grow memory without bound.
        if pending.count > Self.readLimit {
            let discardedBytes = pending.count
            let before = observer == nil ? TaskPhase.unknown : productionPhase
            let countedBefore = observer == nil ? false : monitoredSummary(now: now).runningCount > 0
            readWasTruncated = true; pending.removeAll(); phase = nil
            if let observer {
                observer(.read(ReadObservation(branch: .pendingLimitExceeded, fileBytes: nil,
                    offsetBefore: offset, offsetAfter: offset, readBytes: 0, skippedBytes: 0,
                    backlogBytes: nil, pendingBytes: 0, pendingBytesBefore: discardedBytes,
                    discardedBytes: discardedBytes, stateCleared: true,
                    fileGeneration: fileGeneration, phaseBefore: before, phaseAfter: productionPhase,
                    countedBefore: countedBefore, countedAfter: monitoredSummary(now: now).runningCount > 0)))
            }
        }
    }

    func summary(now: Date) -> TaskStatusSummary {
        if phase == "running", let activityDate,
           now.timeIntervalSince(activityDate) >= -5,
           now.timeIntervalSince(activityDate) < Self.runningStaleInterval {
            return TaskStatusSummary(runningCount: 1, legacyHealth: .healthy)
        }
        if phase == "complete", let eventDate,
           now.timeIntervalSince(eventDate) >= -5 {
            return now.timeIntervalSince(eventDate) < 30
                ? TaskStatusSummary(recentlyCompletedCount: 1, legacyHealth: .healthy) : TaskStatusSummary(legacyHealth: .healthy)
        }
        if phase == "idle" { return TaskStatusSummary(legacyHealth: .healthy) }
        let reason: LegacyTaskDiagnosticReason = phase == "running" ? .staleWithoutTerminal : .missingLifecycleEvidence
        let diagnostics = LegacyTaskDiagnostics(
            unknownCount: 1,
            staleCount: phase == "running" ? 1 : 0,
            reasons: [reason]
        )
        return TaskStatusSummary(unknownCount: 1, legacyHealth: .healthy, legacyDiagnostics: diagnostics)
    }

    /// Old unobserved history is outside the live indicator's scope, not proof of idle.
    func monitoredSummary(now: Date, observer: Observer? = nil) -> TaskStatusSummary {
        guard observedLiveChange || fileModifiedAt.map({ now.timeIntervalSince($0) < Self.runningStaleInterval }) == true else {
            observer?(.monitored(.historyOutOfScope))
            return TaskStatusSummary(legacyHealth: .healthy)
        }
        let value = summary(now: now)
        if phase == "running", value.runningCount == 0 { observer?(.monitored(.staleWithoutTerminal)) }
        return value
    }

    func completionID(for path: String, now: Date) -> String? {
        guard completionFeedbackEligible, phase == "complete", summary(now: now).recentlyCompletedCount > 0,
              let eventDate else { return nil }
        let terminalIdentity = turnID.map { "turn:\($0)" } ?? "event:\(eventDate.timeIntervalSince1970)"
        let value = path + "\u{0}" + terminalIdentity
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

final class TaskStatusMonitor {
    var onUpdate: ((TaskStatusSummary) -> Void)?
    // Delivered on main immediately before onUpdate; nil means no new diagnostic trace.
    var onDiagnosticBatch: ((UInt64?) -> Void)?
    /// Independent of UI summary equality; a same-count membership replacement still carries a new snapshot.
    var onDiagnosticTrace: ((DiagnosticTaskSnapshotReference) -> Void)?
    var onDiagnosticTraceDelivery: ((DiagnosticTaskSnapshotReference, Bool) -> Void)?
    struct Scheduling {
        var pollInterval: TimeInterval = 2
        var discoveryInterval: TimeInterval = 10
        var now: () -> Date = Date.init
    }
    private let scheduling: Scheduling
    private let taskTrace: DiagnosticTaskTrace
    private var previousTraceReference: DiagnosticTaskSnapshotReference?
    private struct TraceMember {
        let identity: DiagnosticTaskTraceIdentity
        let counted: Bool
        let phase: DiagnosticTaskTracePhase
    }
    private var traceMembers: [String: TraceMember] = [:]
    private var cursorEpochs: [String: UUID] = [:]
    private var discoveryReturnedRows: Int?
    private var discoveryAcceptedRows: Int?
    private var discoveryTraversalComplete: Bool?
    private let diagnostics: DiagnosticRecording
    private let homeSource: DiagnosticTaskStage
    private var scanBatch: UInt64 = 0
    private var previousEvidence: Evidence?

    private struct Evidence: Equatable {
        let discoveryFailed: Bool
        let candidates: Int
        let readFailures: Int
        let truncated: Int
        let running: Int
        let unknown: Int
        let completed: Int
        let reasons: Set<LegacyTaskDiagnosticReason>
        let rejected: Int?
    }
    private let queue = DispatchQueue(label: "GPTTouchBarHUD.task-status", qos: .utility)
    private let home: URL
    private var timer: DispatchSourceTimer?
    private var cursors: [String: TaskLogCursor] = [:]
    private var nextDiscovery = Date.distantPast
    private var previous: TaskStatusSummary?
    private var discoveryFailed = false
    private var discoveryRejectedCount: Int?
    private var lastSuccessfulCheck: Date?
    private var liveSince = Date.distantFuture
    // Accessed on main only, suppresses queued callbacks after stop/restart.
    private var generation = 0

    init(home: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"]
                        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path),
         diagnostics: DiagnosticRecording = NoopDiagnosticRecorder(),
         trace: DiagnosticTaskTrace? = nil, scheduling: Scheduling = Scheduling()) {
        self.home = home
        self.diagnostics = diagnostics
        self.taskTrace = trace ?? DiagnosticTaskTrace(recorder: diagnostics)
        self.scheduling = scheduling
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
        let standard = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        homeSource = configured == home ? .homeEnvironment : (home == standard ? .homeDefault : .homeCustom)
    }

    func start() {
        stop()
        let currentGeneration = generation
        diagnostics.record(.task(stage: homeSource, mode: .legacy))
        queue.async { [weak self] in
            guard let self else { return }
            self.liveSince = self.scheduling.now()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: self.scheduling.pollInterval, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.poll(generation: currentGeneration) }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        let stoppedGeneration = generation
        let stoppedRecordingState = diagnostics.taskTraceState
        generation += 1
        queue.async { [weak self] in
            self?.timer?.cancel(); self?.timer = nil
            if let self, self.taskTrace.isEnabled {
                let context = DiagnosticTaskTraceContext(monitoringGeneration: UInt64(max(0, stoppedGeneration)), batch: self.scanBatch,
                    recordingGeneration: stoppedRecordingState.generation, recordingSessionID: stoppedRecordingState.sessionID)
                for (path, member) in self.traceMembers {
                    self.taskTrace.member(context: context, identity: member.identity, countedBefore: member.counted,
                        countedAfter: false, reason: .monitorStopped)
                    self.taskTrace.retire(taskKey: path, kind: .file, context: context)
                }
            }
            self?.traceMembers.removeAll(); self?.cursorEpochs.removeAll(); self?.previousTraceReference = nil
            self?.cursors.removeAll(); self?.previous = nil
            self?.nextDiscovery = .distantPast
            self?.discoveryFailed = false
            self?.lastSuccessfulCheck = nil
            self?.previousEvidence = nil
        }
    }

    private func poll(generation: Int) {
        let now = scheduling.now()
        scanBatch &+= 1
        let batch = scanBatch
        let recordingState = diagnostics.taskTraceState
        let traceEnabled = taskTrace.isEnabled && recordingState.enabled
        let traceStillCurrent: () -> Bool = { [diagnostics] in diagnostics.taskTraceState == recordingState }
        let context = DiagnosticTaskTraceContext(monitoringGeneration: UInt64(max(0, generation)), batch: batch,
            recordingGeneration: recordingState.generation, recordingSessionID: recordingState.sessionID)
        if !traceEnabled { traceMembers.removeAll(); previousTraceReference = nil }
        let discoveredThisPoll = now >= nextDiscovery
        if discoveredThisPoll {
            let discovered = recentPaths()
            discoveryFailed = discovered == nil
            if let paths = discovered {
                if traceEnabled {
                    let previousPaths = Set(cursors.keys)
                    let nextPaths = Set(paths)
                    for path in previousPaths.subtracting(nextPaths) {
                        if let member = traceMembers.removeValue(forKey: path) {
                            taskTrace.member(context: context, identity: member.identity, countedBefore: member.counted,
                                countedAfter: false, reason: .leftCurrentQueryResult)
                        }
                        taskTrace.retire(taskKey: path, kind: .file, context: context)
                    }
                    for path in nextPaths.subtracting(previousPaths) {
                        if let identity = taskTrace.identity(taskKey: path, kind: .file, correlation: .fileOnly, context: context) {
                            taskTrace.member(context: context, identity: identity, countedBefore: false, countedAfter: false, reason: .inventoryAdded)
                        }
                    }
                    for path in previousPaths.subtracting(nextPaths) { cursorEpochs.removeValue(forKey: path) }
                    for path in nextPaths.subtracting(previousPaths) { cursorEpochs[path] = UUID() }
                }
                cursors = Dictionary(uniqueKeysWithValues: paths.map { ($0, cursors[$0] ?? TaskLogCursor()) })
            }
            nextDiscovery = now.addingTimeInterval(scheduling.discoveryInterval)
            if traceEnabled {
                var discovery = DiagnosticTaskDiscovery()
                discovery.scope = .latestRollouts; discovery.queryLimit = 32
                discovery.returnedRows = discoveryReturnedRows
                discovery.acceptedRows = discoveryAcceptedRows; discovery.rejectedPaths = discoveryRejectedCount
                discovery.traversalComplete = discoveryTraversalComplete
                discovery.coverage = discovered == nil ? .unknown : .limited
                taskTrace.discovery(context: context, observation: discovery)
            }
        }
        var snapshotMembers: [DiagnosticTaskSnapshotMember] = []
        var membershipComplete = true
        var values: [TaskStatusSummary] = []
        var readFailureCount = 0
        var truncatedCount = 0
        var lifecycleChanges = 0
        var observedStart = false
        for path in Array(cursors.keys) {
            let previousPhase = cursors[path]?.phase
            let previousStart = cursors[path]?.latestAcceptedLiveStart
            var memberReason = DiagnosticTaskMemberReason.lifecycleChanged
            let epoch: UUID
            if traceEnabled {
                epoch = cursorEpochs[path] ?? UUID(); cursorEpochs[path] = epoch
            } else { epoch = Self.disabledCursorEpoch }
            let observer: TaskLogCursor.Observer? = traceEnabled ? { [taskTrace] observation in
                guard traceStillCurrent() else { return }
                Self.observe(observation, path: path, cursorEpoch: epoch, context: context, trace: taskTrace, memberReason: &memberReason)
            } : nil
            do { try cursors[path]?.read(URL(fileURLWithPath: path), liveSince: liveSince, now: now, observer: observer) }
            catch {
                readFailureCount += 1
                if traceEnabled && traceStillCurrent(), let identity = taskTrace.identity(taskKey: path,
                    fileKey: Self.fileKey(path: path, epoch: epoch, generation: cursors[path]?.fileGeneration ?? 0),
                    kind: .file, correlation: .fileOnly, context: context) {
                    let before = traceMembers[path]?.counted ?? false
                    taskTrace.member(context: context, identity: identity, countedBefore: before, countedAfter: false, reason: .readFailure)
                    traceMembers[path] = TraceMember(identity: identity, counted: false, phase: .unknown)
                    snapshotMembers.append(DiagnosticTaskSnapshotMember(identity: identity, phase: .unknown, counted: false))
                } else if traceEnabled { membershipComplete = false }
                continue
            }
            if let date = cursors[path]?.latestAcceptedLiveStart, date != previousStart, date >= liveSince {
                observedStart = true
            }
            if cursors[path]?.readWasTruncated == true { truncatedCount += 1 }
            if cursors[path]?.phase != previousPhase { lifecycleChanges += 1 }
            var value = cursors[path]!.monitoredSummary(now: now, observer: observer)
            if let id = cursors[path]!.completionID(for: path, now: now) {
                value.legacyCompletionIDs.insert(id)
            }
            values.append(value)
            if traceEnabled && traceStillCurrent(), let identity = taskTrace.identity(taskKey: path, turnKey: cursors[path]?.turnID,
                fileKey: Self.fileKey(path: path, epoch: epoch, generation: cursors[path]!.fileGeneration),
                kind: .file, correlation: .fileOnly, context: context) {
                let counted = value.runningCount > 0
                let phase = Self.tracePhase(cursors[path]!.phase)
                let prior = traceMembers[path]
                if prior?.counted != counted || prior?.phase != phase || prior?.identity != identity {
                    if prior?.counted == true && !counted && memberReason == .lifecycleChanged {
                        if cursors[path]!.phase == "running" { memberReason = .staleWithoutTerminal }
                        else if !cursors[path]!.observedLiveChange { memberReason = .historyOutOfScope }
                    }
                    taskTrace.member(context: context, identity: identity, countedBefore: prior?.counted ?? false,
                        countedAfter: counted, reason: memberReason)
                }
                traceMembers[path] = TraceMember(identity: identity, counted: counted, phase: phase)
                snapshotMembers.append(DiagnosticTaskSnapshotMember(identity: identity, phase: phase, counted: counted))
            } else if traceEnabled { membershipComplete = false }
        }
        let hasSuccessfulPoll = !discoveryFailed && (cursors.isEmpty || !values.isEmpty)
        if hasSuccessfulPoll { lastSuccessfulCheck = Self.minuteBucket(now) }
        let result = Self.combinedSummary(
            values: values,
            readFailureCount: readFailureCount,
            discoveryFailed: discoveryFailed,
            lastSuccessfulCheck: lastSuccessfulCheck
        )
        let evidence = Evidence(discoveryFailed: discoveryFailed, candidates: cursors.count,
                                readFailures: readFailureCount, truncated: truncatedCount,
                                running: result.runningCount, unknown: result.unknownCount,
                                completed: result.recentlyCompletedCount,
                                reasons: result.legacyDiagnostics?.reasons ?? [], rejected: discoveryRejectedCount)
        let recordsTrace = evidence != previousEvidence || lifecycleChanges > 0 || observedStart
        if recordsTrace {
            previousEvidence = evidence
            if observedStart { diagnostics.record(.task(stage: .explicitStart, batch: batch, mode: .legacy)) }
            diagnostics.record(.task(stage: discoveredThisPoll ? .index : .indexCached, batch: batch, result: discoveryFailed ? .failed : .success,
                                     candidateCount: discoveryFailed ? nil : cursors.count, mode: .legacy))
            diagnostics.record(.task(stage: .candidates, batch: batch,
                                     result: discoveryFailed ? .unknown : (cursors.isEmpty ? .empty : .success),
                                     candidateCount: discoveryFailed ? nil : cursors.count, mode: .legacy))
            if let rejected = discoveryRejectedCount, rejected > 0 {
                diagnostics.record(.task(stage: .candidateRejected, batch: batch, result: .rejected,
                                         candidateCount: rejected, mode: .legacy))
            }
            let missingLifecycleCount = values.reduce(0) { count, value in
                count + (value.legacyDiagnostics?.reasons.contains(.missingLifecycleEvidence) == true ? value.unknownCount : 0)
            }
            if missingLifecycleCount > 0 {
                diagnostics.record(.task(stage: .missingLifecycleEvidence, batch: batch, result: .unknown,
                                         unknownCount: missingLifecycleCount, mode: .legacy))
            }
            if let count = result.legacyDiagnostics?.staleCount, count > 0 {
                diagnostics.record(.task(stage: .staleWithoutTerminal, batch: batch, result: .stale,
                                         unknownCount: count, mode: .legacy))
            }
            let readUnavailable = discoveryFailed && cursors.isEmpty
            diagnostics.record(.task(stage: .read, batch: batch,
                                     result: readUnavailable ? .unknown : (readFailureCount > 0 ? .failed : (truncatedCount > 0 ? .truncated : .success)),
                                     failureCount: readUnavailable ? nil : readFailureCount,
                                     truncatedCount: readUnavailable ? nil : truncatedCount, mode: .legacy))
            if lifecycleChanges > 0 {
                diagnostics.record(Self.aggregateEvent(result, stage: .lifecycle, batch: batch))
            }
            diagnostics.record(Self.aggregateEvent(result, stage: .aggregate, batch: batch))
        }
        let reference = traceEnabled && traceStillCurrent() ? taskTrace.snapshot(context: context, members: snapshotMembers,
            runningCount: result.runningCount, unknownCount: result.unknownCount,
            presentation: result.runningCount > 0 ? .running : (result.recentlyCompletedCount > 0 ? .completedFeedback : .neutral),
            membershipComplete: membershipComplete && !discoveryFailed) : nil
        let traceChanged = reference != previousTraceReference
        previousTraceReference = reference
        let summaryChanged = result != previous
        guard summaryChanged || traceChanged else { return }
        if summaryChanged { previous = result }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.generation == generation else {
                if let reference {
                    self.taskTrace.consume(reference: reference, observation: DiagnosticTaskConsumption(surface: .main,
                        action: .skipped, logicalTaskCount: result.runningCount, presentation: .unknown,
                        compactRule: .hidden, reason: .staleGeneration))
                }
                if recordsTrace { self.diagnostics.record(.task(stage: .mainDiscarded, batch: batch, result: .stale, mode: .legacy)) }
                return
            }
            if recordsTrace && summaryChanged { self.diagnostics.record(Self.aggregateEvent(result, stage: .mainAccepted, batch: batch)) }
            if traceChanged, let reference, traceStillCurrent() {
                self.onDiagnosticTrace?(reference)
                self.onDiagnosticTraceDelivery?(reference, summaryChanged)
            }
            if summaryChanged {
                self.onDiagnosticBatch?(recordsTrace ? batch : nil)
                self.onUpdate?(result)
            }
        }
    }

    private static let disabledCursorEpoch = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    private static func fileKey(path: String, epoch: UUID, generation: UInt64) -> String {
        path + "\u{0}" + epoch.uuidString + "\u{0}" + String(generation)
    }
    private static func tracePhase(_ value: String?) -> DiagnosticTaskTracePhase {
        switch value { case "running": return .running; case "complete": return .completed; case "idle": return .interrupted; default: return .unknown }
    }
    private static func tracePhase(_ value: TaskPhase) -> DiagnosticTaskTracePhase {
        switch value { case .active, .stopping: return .running; case .completed: return .completed; case .interrupted: return .interrupted; default: return .unknown }
    }
    private static func observe(_ observation: TaskLogCursor.Observation, path: String, cursorEpoch: UUID,
        context: DiagnosticTaskTraceContext, trace: DiagnosticTaskTrace, memberReason: inout DiagnosticTaskMemberReason) {
        switch observation {
        case .read(let read):
            guard read.branch != .unchanged,
                  let identity = trace.identity(taskKey: path, fileKey: fileKey(path: path, epoch: cursorEpoch, generation: read.fileGeneration),
                    kind: .file, correlation: .fileOnly, context: context) else { return }
            var metrics = DiagnosticTaskReadMetrics()
            metrics.fileBytes = read.fileBytes; metrics.offsetBefore = read.offsetBefore; metrics.offsetAfter = read.offsetAfter
            metrics.readBytes = UInt64(read.readBytes); metrics.skippedBytes = read.skippedBytes; metrics.backlogBytes = read.backlogBytes
            metrics.pendingBytesBefore = UInt64(read.pendingBytesBefore); metrics.pendingBytes = UInt64(read.pendingBytes)
            metrics.discardedBytes = UInt64(read.discardedBytes); metrics.stateCleared = read.stateCleared
            metrics.reason = DiagnosticTaskReadReason(rawValue: read.branch.rawValue) ?? .normalRead
            trace.read(context: context, identity: identity, metrics: metrics)
            switch read.branch {
            case .readBudgetSkip: memberReason = .readBudgetSkip
            case .pendingLimitExceeded: memberReason = .pendingLimitExceeded
            case .fileReplaced, .fileTruncated: memberReason = .fileReset
            case .readFailure: memberReason = .readFailure
            default: break
            }
            if read.stateCleared && read.readBytes == 0 {
                let reason = DiagnosticTaskTransitionReason(rawValue: memberReason.rawValue) ?? .unknown
                trace.lifecycle(context: context, identity: identity, transition: DiagnosticTaskLifecycleTransition(
                    before: tracePhase(read.phaseBefore), after: tracePhase(read.phaseAfter), evidence: .unknown,
                    accepted: true, reason: reason))
            }
        case .monitored(let reason): memberReason = reason
        case .lifecycle(let change):
            guard let identity = trace.identity(taskKey: path, turnKey: change.turnKey,
                fileKey: fileKey(path: path, epoch: cursorEpoch, generation: change.fileGeneration),
                kind: .file, correlation: .fileOnly, context: context) else { return }
            trace.lifecycle(context: context, identity: identity, transition: DiagnosticTaskLifecycleTransition(
                before: tracePhase(change.phaseBefore), after: tracePhase(change.phaseAfter),
                evidence: DiagnosticTaskEvidenceKind(rawValue: change.kind.rawValue) ?? .unknown,
                accepted: change.accepted, reason: DiagnosticTaskTransitionReason(rawValue: change.reason.rawValue) ?? .unknown))
        }
    }

    static func aggregateEvent(_ summary: TaskStatusSummary, stage: DiagnosticTaskStage, batch: UInt64) -> DiagnosticEvent {
        let unavailable = summary.legacyHealth?.isUnavailable == true
        let uncertain = unavailable || summary.unknownCount > 0
        return .task(stage: stage, batch: batch, result: uncertain ? .unknown : .success,
                     runningCount: uncertain && summary.runningCount == 0 ? nil : summary.runningCount,
                     unknownCount: unavailable && summary.unknownCount == 0 ? nil : summary.unknownCount, mode: .legacy)
    }

    static func combinedSummary(
        values: [TaskStatusSummary],
        readFailureCount: Int,
        discoveryFailed: Bool,
        lastSuccessfulCheck: Date?
    ) -> TaskStatusSummary {
        var result = TaskStatusSummary(legacyHealth: .healthy)
        var diagnostics = LegacyTaskDiagnostics(lastSuccessfulCheck: lastSuccessfulCheck)
        for value in values {
            result.runningCount += value.runningCount
            result.recentlyCompletedCount += value.recentlyCompletedCount
            result.unknownCount += value.unknownCount
            result.legacyCompletionIDs.formUnion(value.legacyCompletionIDs)
            if let source = value.legacyDiagnostics {
                diagnostics.unknownCount += source.unknownCount
                diagnostics.readFailureCount += source.readFailureCount
                diagnostics.staleCount += source.staleCount
                diagnostics.reasons.formUnion(source.reasons)
            }
        }
        if readFailureCount > 0 {
            result.unknownCount += readFailureCount
            diagnostics.unknownCount += readFailureCount
            diagnostics.readFailureCount += readFailureCount
            diagnostics.reasons.insert(.readFailure)
        }
        if discoveryFailed {
            result.legacyHealth = .unavailable(.discoveryFailure)
            diagnostics.reasons.insert(.discoveryFailure)
        } else if readFailureCount > 0 && values.isEmpty {
            result.legacyHealth = .unavailable(.allCandidatesUnreadable)
            diagnostics.reasons.insert(.allCandidatesUnreadable)
        }
        result.legacyDiagnostics = diagnostics
        return result
    }

    private static func minuteBucket(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    private func recentPaths() -> [String]? {
        discoveryRejectedCount = nil
        discoveryReturnedRows = nil; discoveryAcceptedRows = nil; discoveryTraversalComplete = nil
        var db: OpaquePointer?
        guard sqlite3_open_v2(home.appendingPathComponent("state_5.sqlite").path, &db,
                             SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT rollout_path FROM threads WHERE archived=0 AND source IN ('cli','exec','vscode') ORDER BY updated_at DESC LIMIT 32", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var paths: [String] = []
        var rejected = 0
        var returned = 0
        let root = home.resolvingSymlinksInPath().path + "/sessions/"
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            returned += 1
            defer { step = sqlite3_step(statement) }
            guard let raw = sqlite3_column_text(statement, 0) else { rejected += 1; continue }
            let path = URL(fileURLWithPath: String(cString: raw)).resolvingSymlinksInPath().path
            if path.hasPrefix(root), path.hasSuffix(".jsonl") { paths.append(path) }
            else { rejected += 1 }
        }
        discoveryReturnedRows = returned
        discoveryAcceptedRows = paths.count
        discoveryTraversalComplete = step == SQLITE_DONE
        guard step == SQLITE_DONE else { return nil }
        discoveryRejectedCount = rejected
        return Array(Set(paths))
    }
}
