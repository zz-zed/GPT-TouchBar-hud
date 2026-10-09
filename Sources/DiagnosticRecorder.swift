import Foundation

/// The lock protects small in-memory admission state only. Encoding, scans and writes are serial background work.
final class DiagnosticRecorder: DiagnosticRecording {
    static let shared = DiagnosticRecorder(directory: DiagnosticStore.defaultDirectory)
    static let preferenceKey = "diagnosticRecordingEnabled"

    struct Configuration {
        var maximumQueuedEvents = 512
        var maximumQueuedBytes = 1024 * 1024
        var maximumEventBytes = 4 * 1024
        var batchBytes = 32 * 1024
        var flushDelay: TimeInterval = 5
        var aggregationWindow: TimeInterval = 5
        var maximumBackoff: TimeInterval = 60
    }

    private struct Pending {
        let envelope: DiagnosticEventEnvelope
        let generation: UInt64
    }
    private struct ErrorBucket {
        let event: DiagnosticEvent
        let firstUptime: UInt64
        var firstRepeated: Pending?
        var last: Date
        var repetitions: Int
    }

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "GPTTouchBarHUD.diagnostics.io", qos: .utility)
    let diagnosticDirectory: URL
    var exportStagingDirectory: URL { diagnosticDirectory.appendingPathComponent("export-staging", isDirectory: true) }
    private let store: DiagnosticStore
    private let configuration: Configuration
    private let now: () -> Date
    private let uptime: () -> UInt64
    private let sessionID = UUID()
    private let processIdentity: DiagnosticProcessIdentity
    private var upgradeContext: (DiagnosticUpgradeHandoff, DiagnosticWriterRole)?
    private let startUptime: UInt64
    private var started = false
    private var enabled = false
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var pending: [Pending] = []
    private var outstandingCount = 0
    private var outstandingBytes = 0
    private var pumpScheduled = false
    private var gaps: [DiagnosticGapReason: DiagnosticGap] = [:]

    // Accessed exclusively by ioQueue.
    private var buffered: [Pending] = []
    private var bufferedBytes = 0
    private var errorBuckets: [Data: ErrorBucket] = [:]
    private var timerGeneration: UInt64?
    private var workerGeneration: UInt64 = 0
    private var storeStarted = false
    private var retentionAvailable = false
    private var retentionRevision: UInt64 = 0
    private var retentionDeadline: Date?
    private var persistedGapCounts: [DiagnosticGapReason: Int] = [:]
    private var consecutiveFailures = 0
    private var retryUptime: UInt64 = 0

    init(directory: URL, configuration: Configuration = Configuration(),
         storeConfiguration: DiagnosticStore.Configuration = DiagnosticStore.Configuration(),
         now: @escaping () -> Date = Date.init,
         uptime: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         processIdentity: DiagnosticProcessIdentity = .current,
         beforeWrite: (() throws -> Void)? = nil) {
        self.configuration = configuration
        self.processIdentity = processIdentity
        diagnosticDirectory = directory
        self.now = now
        self.uptime = uptime
        startUptime = uptime()
        store = DiagnosticStore(directory: directory, configuration: storeConfiguration,
                                now: now, beforeWrite: beforeWrite)
    }

    var recordingGeneration: UInt64 { locked { generation } }
    var taskTraceState: DiagnosticTaskTraceState { locked { .init(enabled: enabled && started, generation: generation, sessionID: sessionID) } }
    var isEnabled: Bool { locked { enabled && started } }

    /// No implicit disk access from shared's construction or from default-injected recorders.
    func start(enabled: Bool = true) {
        configureEnabled(enabled, initial: true, completion: nil)
    }

    func setEnabled(_ value: Bool, completion: (() -> Void)? = nil) {
        configureEnabled(value, initial: false, completion: completion)
    }

    func setEnabledReporting(_ value: Bool, completion: @escaping (Result<Bool, Error>) -> Void) {
        configureEnabled(value, initial: false, completion: nil, reporting: completion)
    }

    private func configureEnabled(_ value: Bool, initial: Bool, completion: (() -> Void)?,
                                  reporting: ((Result<Bool, Error>) -> Void)? = nil) {
        locked {
            if !value && (enabled || !started) { addGapLocked(.recordingDisabled, count: 1, at: now()) }
            started = true
            enabled = value
            generation &+= 1
            pending.removeAll()
            outstandingCount = 0
            outstandingBytes = 0
            pumpScheduled = false
            let next = generation
            // Enqueue under the admission lock so new-generation events cannot precede this boundary.
            ioQueue.async { [self] in
                resetWorker(to: next)
                applyControl(value, initial: initial, generation: next, attempt: 0, completion: completion, reporting: reporting)
            }
        }
    }

    /// Control changes retry a busy lock for at most 500 ms without blocking any queue thread.
    /// A failed durable disable stops this recorder but is explicitly unconfirmed for other processes.
    private func applyControl(_ value: Bool, initial: Bool, generation expected: UInt64, attempt: Int,
                              completion: (() -> Void)?, reporting: ((Result<Bool, Error>) -> Void)?) {
        guard locked({ generation == expected }) else {
            reporting?(.failure(DiagnosticStoreError.cancelled)); completion?(); return
        }
        var effective = value
        do {
            if value || FileManager.default.fileExists(atPath: diagnosticDirectory.path) {
                let state = try initial ? store.controlState(defaultEnabled: value) : store.setEnabled(value)
                effective = state.enabled
                locked { if generation == expected { enabled = effective } }
            }
        } catch {
            if (error as? DiagnosticStoreError) == .lockBusy && attempt < 20 {
                ioQueue.asyncAfter(deadline: .now() + 0.025) { [self] in
                    applyControl(value, initial: initial, generation: expected, attempt: attempt + 1,
                                 completion: completion, reporting: reporting)
                }
                return
            }
            registerFailure(count: 1, reason: (error as? DiagnosticStoreError) == .lockBusy ? .lockBusy : .storeUnavailable)
            reporting?(.failure(error)); completion?(); return
        }
        if effective { ensureStarted(generation: expected) }
        else {
            do { retentionAvailable = try store.maintainRetentionIfPresent() }
            catch { addGap(.storeUnavailable, count: 1) }
        }
        if retentionAvailable { scheduleRetention() }
        reporting?(.success(effective)); completion?()
    }

    func record(_ event: DiagnosticEvent) { admit(event, expectedGeneration: nil) }

    func record(_ event: DiagnosticEvent, expectedGeneration: UInt64) { admit(event, expectedGeneration: expectedGeneration) }

    private func admit(_ event: DiagnosticEvent, expectedGeneration: UInt64?) {
        let shouldSchedule = locked { () -> Bool in
            guard started, enabled, expectedGeneration.map({ $0 == generation }) ?? true else { return false }
            if case .taskTrace(let trace) = event, !trace.isValid { addGapLocked(.encodingFailure, count: 1, at: now()); return false }
            // Reserving the maximum encoded size keeps the ingress queue bounded without encoding on the caller.
            let reservation = configuration.maximumEventBytes
            guard outstandingCount < configuration.maximumQueuedEvents,
                  reservation > 0, outstandingBytes <= configuration.maximumQueuedBytes - reservation else {
                addGapLocked(.queueFull, count: 1, at: now())
                return false
            }
            sequence &+= 1
            let tick = uptime()
            let elapsed = tick >= startUptime ? (tick - startUptime) / 1_000_000 : 0
            pending.append(Pending(envelope: DiagnosticEventEnvelope(timestamp: now(), sessionID: sessionID,
                sequence: sequence, monotonicMilliseconds: elapsed, event: event,
                updateSessionID: upgradeContext?.0.updateSessionID, writerRole: upgradeContext?.1,
                eventID: DiagnosticEventID(sessionID: sessionID, sequence: sequence), processIdentity: processIdentity,
                upgradeSourceIdentity: upgradeContext?.0.sourceIdentity, upgradeTargetIdentity: upgradeContext?.0.targetIdentity), generation: generation))
            outstandingCount += 1
            outstandingBytes += reservation
            if pumpScheduled { return false }
            pumpScheduled = true
            return true
        }
        if shouldSchedule {
            ioQueue.async { [self] in pump(force: false) }
        }
    }

    /// Callbacks run on the I/O queue. Consumers must dispatch AppKit changes to the main queue.
    func flush(completion: (() -> Void)? = nil) {
        ioQueue.async { [self] in
            pump(force: true)
            completion?()
        }
    }

    /// Reports write confirmation; running a callback alone must never be interpreted as persistence.
    func flushReporting(completion: @escaping (DiagnosticFlushResult) -> Void) {
        ioQueue.async { [self] in
            guard locked({ started && enabled }) else { completion(.disabled); return }
            pump(force: true)
            guard storeStarted else { completion(.failed); return }
            if consecutiveFailures > 0 { completion(.failed); return }
            let uncertain = locked { outstandingCount > 0 || gaps.values.contains { [.writeFailure, .queueFull, .oversizedEvent, .encodingFailure, .lockBusy].contains($0.reason) } }
            completion(uncertain ? .partial : .persisted)
        }
    }

    func prepareUpgradeHandoff(updateSessionID: UUID, targetIdentity: DiagnosticProcessIdentity,
        completion: @escaping (Result<DiagnosticUpgradeHandoff, Error>) -> Void) {
        locked {
            let requestedGeneration = generation
            ioQueue.async { [self] in
                do {
                    let handoff = try store.processStore.withLock(create: false) {
                        let state = try store.processStore.readControl()
                        guard state.enabled else { throw DiagnosticStoreError.disabled }
                        let handoff = DiagnosticUpgradeHandoff(updateSessionID: updateSessionID, sourceSessionID: sessionID,
                            sourceIdentity: processIdentity, targetIdentity: targetIdentity, createdAt: now(),
                            recordingEnabled: state.enabled, clearEpoch: state.clearEpoch)
                        try locked {
                            guard generation == requestedGeneration, started && enabled else { throw DiagnosticStoreError.cancelled }
                            upgradeContext = (handoff, .oldHUD)
                        }
                        return handoff
                    }
                    completion(.success(handoff))
                } catch { completion(.failure(error)) }
            }
        }
    }

    func associateUpgradeReporting(_ handoff: DiagnosticUpgradeHandoff, role: DiagnosticWriterRole,
                                   completion: @escaping (Result<Void, Error>) -> Void) {
        locked {
            let requestedGeneration = generation
            ioQueue.async { [self] in
                do {
                    try store.processStore.withLock(create: false) {
                        guard handoff.protocolVersion == 1 else { throw DiagnosticStoreError.unknownProtocol }
                        guard handoff.recordingEnabled, handoff.createdAt >= now().addingTimeInterval(-72 * 60 * 60),
                              handoff.createdAt <= now().addingTimeInterval(300) else { throw DiagnosticStoreError.disabled }
                        try store.processStore.validateControl(epoch: handoff.clearEpoch)
                        try locked {
                            guard generation == requestedGeneration, started && enabled else { throw DiagnosticStoreError.cancelled }
                            upgradeContext = (handoff, role)
                        }
                    }
                    completion(.success(()))
                } catch { completion(.failure(error)) }
            }
        }
    }

    func clear(completion: ((Result<Void, Error>) -> Void)? = nil) {
        locked {
            generation &+= 1
            pending.removeAll()
            outstandingCount = 0
            outstandingBytes = 0
            pumpScheduled = false
            gaps.removeAll()
            upgradeContext = nil
            let state = (generation, started && enabled)
            ioQueue.async { [self] in
                resetWorker(to: state.0)
                persistedGapCounts.removeAll()
                do {
                    try store.clear()
                    storeStarted = false
                    if state.1 { ensureStarted(generation: state.0) }
                    completion?(.success(()))
                } catch {
                    addGap(.writeFailure, count: 1)
                    completion?(.failure(error))
                }
            }
        }
    }

    func captureSnapshot(since: Date?, until: Date? = nil,
                         completion: @escaping (Result<DiagnosticStoreSnapshot, Error>) -> Void) {
        locked {
            let requestedGeneration = generation
            // Capture and enqueue together: clear cannot stamp old files with its new generation.
            ioQueue.async { [self] in
                guard locked({ generation == requestedGeneration }) else {
                    completion(.failure(DiagnosticStoreError.cancelled)); return
                }
                pump(force: true)
                let state = locked { (generation, enabled && started, unpersistedGapsLocked()) }
                guard state.0 == requestedGeneration else {
                    completion(.failure(DiagnosticStoreError.cancelled)); return
                }
                do {
                    let snapshot = try store.snapshot(since: since, until: until, generation: requestedGeneration,
                        isEnabled: state.1, additionalGaps: state.2)
                    guard locked({ generation == requestedGeneration }) else {
                        completion(.failure(DiagnosticStoreError.cancelled)); return
                    }
                    completion(.success(snapshot))
                } catch { completion(.failure(error)) }
            }
        }
    }

    private func resetWorker(to value: UInt64) {
        workerGeneration = value
        buffered.removeAll()
        bufferedBytes = 0
        errorBuckets.removeAll()
        timerGeneration = nil
        retryUptime = 0
        consecutiveFailures = 0
        retentionRevision &+= 1
        retentionDeadline = nil
    }

    private func ensureStarted(generation expected: UInt64) {
        guard locked({ enabled && generation == expected }) else { return }
        guard !storeStarted else { return }
        let tick = uptime()
        guard tick >= retryUptime else {
            scheduleTimer(generation: expected, delay: Double(retryUptime - tick) / 1_000_000_000)
            return
        }
        do {
            let confirmed = try store.startSession(sessionID)
            storeStarted = true
            retentionAvailable = true
            if locked({ enabled && generation == expected }) {
                record(.lifecycle(confirmed ? .previousShutdownConfirmed : .previousShutdownUnconfirmed))
            }
        } catch {
            if locked({ enabled && generation == expected }) { registerFailure(count: 1, reason: .storeUnavailable) }
        }
    }

    private func pump(force: Bool) {
        let batch = locked { () -> [Pending] in
            pumpScheduled = false
            let items = pending
            pending.removeAll(keepingCapacity: true)
            return items
        }
        let state = locked { (generation, started && enabled) }
        guard state.1 else { return }
        if workerGeneration != state.0 { resetWorker(to: state.0) }
        ensureStarted(generation: state.0)
        var urgent = force
        let encoder = DiagnosticEventEnvelope.encoder()
        for item in batch {
            guard item.generation == state.0 else { continue }
            do {
                let data = try encoder.encode(item.envelope)
                guard data.count + 1 <= configuration.maximumEventBytes else {
                    release(1, generation: state.0)
                    addGap(.oversizedEvent, count: 1)
                    continue
                }
                if item.envelope.event.severity == "error", configuration.aggregationWindow > 0 {
                    let key = try encoder.encode(item.envelope.event.aggregationIdentity)
                    let tick = uptime()
                    if var bucket = errorBuckets[key], tick >= bucket.firstUptime,
                       tick - bucket.firstUptime < nanoseconds(configuration.aggregationWindow) {
                        let alreadyReserved = bucket.firstRepeated != nil
                        if !alreadyReserved { bucket.firstRepeated = item }
                        bucket.last = item.envelope.timestamp
                        bucket.repetitions += 1
                        errorBuckets[key] = bucket
                        if alreadyReserved { release(1, generation: state.0) }
                        scheduleTimer(generation: state.0)
                        continue
                    }
                    if errorBuckets[key]?.firstRepeated != nil {
                        materializeRepetitions(generation: state.0, only: key)
                    }
                    if errorBuckets.count >= configuration.maximumQueuedEvents {
                        materializeRepetitions(generation: state.0)
                        errorBuckets.removeAll()
                    }
                    errorBuckets[key] = ErrorBucket(event: item.envelope.event, firstUptime: tick,
                        firstRepeated: nil, last: item.envelope.timestamp, repetitions: 0)
                }
                buffered.append(item)
                bufferedBytes += data.count + 1
                urgent = urgent || item.envelope.event.flushImmediately
            } catch {
                release(1, generation: state.0)
                addGap(.encodingFailure, count: 1)
            }
        }
        if force { materializeRepetitions(generation: state.0) }
        if urgent || bufferedBytes >= configuration.batchBytes {
            writeBuffered(generation: state.0)
        }
        if !buffered.isEmpty || errorBuckets.values.contains(where: { $0.repetitions > 0 }) {
            scheduleTimer(generation: state.0)
        }
    }

    private func materializeRepetitions(generation expected: UInt64, only selected: Data? = nil) {
        for key in selected.map({ [$0] }) ?? Array(errorBuckets.keys) {
            guard var bucket = errorBuckets[key], let first = bucket.firstRepeated,
                  bucket.repetitions > 0 else { continue }
            let envelope = first.envelope
            let summary = DiagnosticEventEnvelope(timestamp: envelope.timestamp, sessionID: envelope.sessionID,
                sequence: envelope.sequence, monotonicMilliseconds: envelope.monotonicMilliseconds,
                event: bucket.event, repetition: DiagnosticEventRepetition(first: envelope.timestamp,
                    last: bucket.last, count: bucket.repetitions), updateSessionID: envelope.updateSessionID,
                writerRole: envelope.writerRole, eventID: envelope.eventID, processIdentity: envelope.processIdentity,
                upgradeSourceIdentity: envelope.upgradeSourceIdentity, upgradeTargetIdentity: envelope.upgradeTargetIdentity)
            buffered.append(Pending(envelope: summary, generation: expected))
            // The first repeated event retains one admission reservation until this summary is written.
            bufferedBytes += configuration.maximumEventBytes
            bucket.repetitions = 0
            bucket.firstRepeated = nil
            errorBuckets[key] = bucket
        }
    }

    private func writeBuffered(generation expected: UInt64) {
        guard locked({ generation == expected && enabled }), storeStarted else { return }
        let tick = uptime()
        if tick < retryUptime {
            scheduleTimer(generation: expected, delay: Double(retryUptime - tick) / 1_000_000_000)
            return
        }
        let items = buffered
        buffered.removeAll(keepingCapacity: true)
        bufferedBytes = 0
        guard !items.isEmpty else { return }
        do {
            let encoder = DiagnosticEventEnvelope.encoder()
            var lines: [Data] = []
            let recoveredGaps = locked { unpersistedGapsLocked() }
            for gap in recoveredGaps {
                let envelope = DiagnosticEventEnvelope(timestamp: gap.last, sessionID: sessionID,
                    sequence: locked { sequence &+= 1; return sequence },
                    monotonicMilliseconds: uptime() >= startUptime ? (uptime() - startUptime) / 1_000_000 : 0,
                    event: .gap(reason: gap.reason, count: gap.count),
                    repetition: DiagnosticEventRepetition(first: gap.first, last: gap.last, count: gap.count))
                var data = try encoder.encode(envelope)
                if data.count + 1 <= configuration.maximumEventBytes { data.append(10); lines.append(data) }
            }
            for item in items {
                var data = try encoder.encode(item.envelope)
                guard data.count + 1 <= configuration.maximumEventBytes else {
                    addGap(.oversizedEvent, count: 1)
                    continue
                }
                data.append(10)
                lines.append(data)
            }
            try store.append(lines, shouldWrite: { self.locked { self.generation == expected && self.enabled } })
            for gap in recoveredGaps { persistedGapCounts[gap.reason, default: 0] += gap.count }
            consecutiveFailures = 0
            retryUptime = 0
            // This marks completion of an orderly shutdown request, never proof that the process exited.
            if items.contains(where: { if case .lifecycle(.shutdownRequested) = $0.envelope.event { return true }; return false }) {
                try store.markShutdownConfirmed(shouldWrite: { self.locked { self.generation == expected && self.enabled } })
            }
            release(items.count, generation: expected)
            scheduleRetention()
        } catch {
            release(items.count, generation: expected)
            if locked({ generation == expected && enabled }) {
                let reason: DiagnosticGapReason = (error as? DiagnosticStoreError) == .lockBusy ? .lockBusy : .writeFailure
                registerFailure(count: items.count, reason: reason)
            }
        }
    }

    private func registerFailure(count: Int, reason: DiagnosticGapReason = .writeFailure) {
        addGap(reason, count: count)
        consecutiveFailures = min(consecutiveFailures + 1, 7)
        retryUptime = uptime() &+ nanoseconds(min(configuration.maximumBackoff, pow(2, Double(consecutiveFailures - 1))))
    }

    private func scheduleTimer(generation expected: UInt64, delay: TimeInterval? = nil) {
        guard timerGeneration == nil else { return }
        timerGeneration = expected
        ioQueue.asyncAfter(deadline: .now() + max(0.001, delay ?? configuration.flushDelay)) { [self] in
            guard timerGeneration == expected, locked({ generation == expected && enabled }) else { return }
            timerGeneration = nil
            pump(force: true)
        }
    }

    /// One deadline for the oldest retained event, rather than periodic polling during idle time.
    private func scheduleRetention() {
        guard retentionAvailable, let date = try? store.nextRetentionDate() else { return }
        guard retentionDeadline != date else { return }
        retentionDeadline = date
        retentionRevision &+= 1
        let revision = retentionRevision
        ioQueue.asyncAfter(deadline: .now() + max(0.001, date.timeIntervalSince(now()))) { [weak self] in
            guard let self = self, self.retentionRevision == revision else { return }
            self.retentionDeadline = nil
            do {
                try self.store.maintainRetention()
                self.scheduleRetention()
            } catch {
                // An inaccessible store is retried with later explicit activity; never spin to report it.
                self.addGap(.storeUnavailable, count: 1)
            }
        }
    }

    private func release(_ count: Int, generation expected: UInt64) {
        locked {
            guard generation == expected else { return }
            outstandingCount = max(0, outstandingCount - count)
            outstandingBytes = max(0, outstandingBytes - count * configuration.maximumEventBytes)
        }
    }

    private func addGap(_ reason: DiagnosticGapReason, count: Int) {
        locked { addGapLocked(reason, count: count, at: now()) }
    }

    private func unpersistedGapsLocked() -> [DiagnosticGap] {
        gaps.values.compactMap { gap in
            let remaining = gap.count - (persistedGapCounts[gap.reason] ?? 0)
            return remaining > 0 ? DiagnosticGap(reason: gap.reason, count: remaining, first: gap.first, last: gap.last) : nil
        }
    }

    private func addGapLocked(_ reason: DiagnosticGapReason, count: Int, at date: Date) {
        let previous = gaps[reason]
        gaps[reason] = DiagnosticGap(reason: reason, count: (previous?.count ?? 0) + count,
                                     first: previous?.first ?? date, last: date)
    }

    private func locked<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }
    private func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, min(seconds * 1_000_000_000, Double(UInt64.max / 2))))
    }
}
