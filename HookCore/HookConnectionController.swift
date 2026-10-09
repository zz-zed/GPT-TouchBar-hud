import Foundation
import Darwin

private struct HookCache: Codable {
    let version: Int
    let records: [TurnRecord]
}

public struct HookMeasurements: Sendable {
    public init() {}
    public var bytesRead = 0
    public var filesRead = 0
    public var reconciliations = 0
    public var hooksReceived = 0
    public var acceptedLiveStarts = 0
}

/// Public methods and onUpdate are main-thread owned; one serial utility queue owns all I/O/state.
/// DispatchSource is required for socket/vnode readiness and its bounded lifecycle; no task per event.
public final class HookConnectionController {
    public var onUpdate: ((TaskActivitySnapshot) -> Void)?
    public var onTaskStartObserved: (() -> Void)?
    private var observedStarts = 0
    public var onMeasurements: ((HookMeasurements) -> Void)?
    /// Raw observations are worker-queue owned. The application must anonymize before persistence.
    public var onTrace: ((HookTaskTraceBatch) -> Void)?
    /// Main queue, immediately before the matching production update (or its suppressed delivery).
    public var onTraceDelivery: ((UInt64, UInt64, Bool) -> Void)?
    public var onTraceDiscarded: ((UInt64, UInt64) -> Void)?
    /// A lightweight thread-safe application gate, sampled at worker boundaries without I/O.
    public var traceEnabled: (() -> Bool)?
    public var traceEpoch: (() -> UInt64)?
    private let worker: HookWorker
    private var generation = 0
    public init(directory: URL = HookPaths.defaultDirectory, home: URL = URL(fileURLWithPath:
                    ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)) {
        worker = HookWorker(directory: directory, home: home)
    }
    public func start() {
        precondition(Thread.isMainThread)
        generation += 1; observedStarts = 0; let token = generation
        worker.queue.async { [weak self] in
            guard let self else { return }
            self.worker.start(generation: UInt64(token)) { [weak self] snapshot, measurements, trace, delivered in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.generation == token else {
                        if let trace { self.onTraceDiscarded?(trace.0, trace.1) }
                        return
                    }
                    if let trace { self.onTraceDelivery?(trace.0, trace.1, delivered) }
                    guard delivered else { return }
                    if measurements.acceptedLiveStarts > self.observedStarts {
                        self.observedStarts = measurements.acceptedLiveStarts
                        self.onTaskStartObserved?()
                    }
                    // Correlate an accepted start with the snapshot that carries its result.
                    guard self.generation == token else { return }
                    self.onUpdate?(snapshot); self.onMeasurements?(measurements)
                }
            }
        }
    }
    public func setTraceEnabled(_ enabled: Bool) {
        precondition(Thread.isMainThread)
        let handler = enabled ? onTrace : nil
        let gate = traceEnabled
        let epoch = traceEpoch
        let worker = worker
        worker.queue.async { worker.configureTrace(handler, gate: gate, epoch: epoch) }
    }
    public func stop() {
        precondition(Thread.isMainThread); generation += 1
        let worker = worker; worker.queue.async { worker.stop() }
    }
    public func suspend() { let worker = worker; worker.queue.async { worker.suspend() } }
    public func resume() { let worker = worker; worker.queue.async { worker.resume() } }
    public func hostUnavailable() { let worker = worker; worker.queue.async { worker.unavailable() } }
    deinit { let worker = worker; worker.queue.async { worker.stop() } }
}

private final class HookWorker {
    let queue = DispatchQueue(label: "GPTTouchBarHUD.hooks", qos: .utility)
    private let directory: URL
    private let resolver: TaskEvidenceResolver
    private var reducer = TaskStateReducer()
    private var receiver: HookReceiver?
    private var observer: ((TaskActivitySnapshot, HookMeasurements, (UInt64, UInt64)?, Bool) -> Void)?
    private var traceHandler: ((HookTaskTraceBatch) -> Void)?
    private var traceGate: (() -> Bool)?
    private var traceEpochProvider: (() -> UInt64)?
    private var currentTraceEpoch: UInt64 = 0
    private var traceCaptureEnabled = false
    private var traceGeneration: UInt64 = 0
    private var traceSequence: UInt64 = 0
    private var tracePending: [HookTaskTraceObservation] = []
    private var traceDropped = 0
    private var previousMembers: HookTaskMemberSnapshot?
    private var watches: [TaskIdentity: DispatchSourceFileSystemObject] = [:]
    private var scheduled: [TaskIdentity: DispatchWorkItem] = [:]
    private var scheduleState = HookVerificationSchedule()
    private var submitTimes: [TaskIdentity: Date] = [:]
    private var healthTimer: DispatchSourceTimer?
    private var persistWork: DispatchWorkItem?
    private var enabled = false
    private var suspended = false
    private var hostAvailable = true
    private var measurements = HookMeasurements()
    private var epoch = 0
    private var lastPersistedData: Data?
    private var previous: TaskActivitySnapshot?
    private var liveSince = Date.distantFuture
    private var publishedStarts = 0
    init(directory: URL, home: URL) { self.directory = directory; resolver = TaskEvidenceResolver(home: home) }
    func configureTrace(_ handler: ((HookTaskTraceBatch) -> Void)?, gate: (() -> Bool)?, epoch: (() -> UInt64)?) {
        traceHandler = handler; traceGate = gate; traceEpochProvider = epoch
        tracePending.removeAll(); traceDropped = 0; previousMembers = nil
        refreshTraceGate()
        if enabled { publish() }
    }
    private func refreshTraceGate() {
        let active = traceHandler != nil && (traceGate?() ?? true)
        let epoch = traceEpochProvider?() ?? 0
        if active != traceCaptureEnabled || epoch != currentTraceEpoch {
            traceCaptureEnabled = active
            currentTraceEpoch = epoch
            tracePending.removeAll(); traceDropped = 0; previousMembers = nil
        }
        installTraceObservers()
    }
    private func installTraceObservers() {
        guard traceCaptureEnabled else { reducer.traceObserver = nil; resolver.traceObserver = nil; return }
        let capture: @Sendable (HookTaskTraceObservation) -> Void = { [weak self] observation in
            guard let self, self.traceCaptureEnabled, self.traceGate?() ?? true,
                  self.traceEpochProvider?() ?? 0 == self.currentTraceEpoch else { return }
            if self.tracePending.count < 2_048 { self.tracePending.append(observation) }
            else { self.traceDropped += 1 }
        }
        reducer.traceObserver = capture; resolver.traceObserver = capture
    }
    func start(generation: UInt64, observer: @escaping (TaskActivitySnapshot, HookMeasurements, (UInt64, UInt64)?, Bool) -> Void) {
        stop(); liveSince = Date(); publishedStarts = 0; enabled = true; hostAvailable = true; self.observer = observer
        reducer = TaskStateReducer(); measurements = HookMeasurements(); previous = nil; lastPersistedData = nil
        traceGeneration = generation; traceSequence = 0; installTraceObservers()
        do {
            try HookPaths.ensurePrivateDirectory(directory)
            let cacheURL = directory.appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                do {
                    let cache = try JSONDecoder().decode(HookCache.self, from: HookPaths.read(cacheURL, maximum: HookBudget.cacheBytes, privateOnly: true))
                    guard cache.version == 1 else { throw HookFailure.malformed }
                    reducer.restore(cache.records, now: Date())
                } catch { reducer.gap(.restart, now: Date()) }
            }
            let receiver = HookReceiver(directory: directory, queue: queue, onEvent: { [weak self] event in self?.receive(event) },
                                        onGap: { [weak self] gap in self?.reducer.gap(gap, now: Date()); self?.reducer.health.state = .degraded; self?.publish() })
            try receiver.start(); self.receiver = receiver
            reconcileRecovery()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in
                guard let self, !self.suspended else { return }
                // Aging only: no candidate discovery or full-file scan on this timer.
                self.refreshTraceGate()
                self.reducer.tick(now: Date()); self.publish()
            }
            healthTimer = timer; timer.resume()
        } catch { reducer.health.state = .unavailable; reducer.gap(.disconnected, now: Date()) }
        publish()
    }
    func stop() {
        epoch += 1; enabled = false; suspended = false
        healthTimer?.cancel(); healthTimer = nil
        persistWork?.cancel(); persistWork = nil
        for work in scheduled.values { work.cancel() }; scheduled.removeAll(); scheduleState.clear()
        for watch in watches.values { watch.cancel() }; watches.removeAll()
        receiver?.stop(); receiver = nil; resolver.reset(); submitTimes.removeAll(); observer = nil
        tracePending.removeAll(); traceDropped = 0; previousMembers = nil
    }
    func suspend() {
        refreshTraceGate()
        guard enabled else { return }; suspended = true
        reducer.invalidate(.sleep, now: Date()); reducer.health.state = .suspended
        for work in scheduled.values { work.cancel() }; scheduled.removeAll(); scheduleState.clear(); submitTimes.removeAll()
        for watch in watches.values { watch.cancel() }; watches.removeAll()
        resolver.reset(); publish()
    }
    func resume() {
        refreshTraceGate()
        guard enabled else { return }; suspended = false; hostAvailable = true
        reducer.health.state = .awaitingEvents; reconcileRecovery(); publish()
    }
    func unavailable() {
        refreshTraceGate()
        guard enabled else { return }
        hostAvailable = false; epoch += 1
        for work in scheduled.values { work.cancel() }; scheduled.removeAll(); scheduleState.clear()
        for watch in watches.values { watch.cancel() }; watches.removeAll()
        submitTimes.removeAll(); resolver.reset()
        reducer.invalidate(.disconnected, now: Date()); reducer.health.state = .unavailable
        // No delayed callback or old file append may revive active until explicit host recovery.
        publish()
    }
    private func reconcileRecovery() {
        refreshTraceGate()
        let tasks = Array(Set(reducer.records.keys.map(\.task))).sorted { $0.session < $1.session }
        consume(resolver.recover(tasks: tasks, now: Date()))
        for task in resolver.observedFiles.keys { schedule(task, delay: 0.12, restart: true) }
    }
    private func receive(_ event: HookEvent) {
        refreshTraceGate()
        guard enabled else { return }
        measurements.hooksReceived += 1
        let now = Date(); let task = TaskIdentity(source: event.source, session: event.session)
        guard hostAvailable else { reducer.gap(.disconnected, now: now); publish(); return }
        reducer.receive(event, now: now)
        if event.kind == .submitted {
            // Only a short-lived receipt-to-log correlation is retained, never prompt content.
            submitTimes[task] = now
            if submitTimes.count > HookBudget.turns { submitTimes.removeValue(forKey: submitTimes.keys.first!); reducer.gap(.capacity, now: now) }
        }
        if !suspended { schedule(task, delay: 0, restart: true) }
        publish()
    }
    private func schedule(_ task: TaskIdentity, delay: TimeInterval, restart: Bool = false) {
        guard enabled, !suspended, hostAvailable else { return }
        switch scheduleState.reserve(task, due: Date().addingTimeInterval(delay), restart: restart) {
        case .coalesced: return
        case .rejected:
            submitTimes.removeValue(forKey: task)
            reducer.gap(.capacity, now: Date()); publish(); return
        case .enqueue: scheduled.removeValue(forKey: task)?.cancel()
        }
        let token = epoch
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.enabled, !self.suspended, self.hostAvailable, self.epoch == token else { return }
            self.scheduled.removeValue(forKey: task)
            self.scheduleState.didRun(task)
            self.reconcile(task)
        }
        scheduled[task] = work; queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func reconcile(_ task: TaskIdentity) {
        refreshTraceGate()
        let now = Date()
        let report = resolver.resolve(task: task, now: now, liveSince: submitTimes[task])
        if let failure = report.gaps.intersection([.missingLog, .invalidPath, .malformedLog]).first {
            reducer.invalidate(failure, now: now, task: task)
        }
        consume(report)
        reducer.tick(now: now); publish()
        if let delay = scheduleState.nextDelay(task) { schedule(task, delay: delay) }
        else { submitTimes.removeValue(forKey: task) }
    }
    private func consume(_ report: EvidenceReport) {
        measurements.bytesRead += report.bytesRead; measurements.filesRead += report.filesRead; measurements.reconciliations += 1
        let now = Date()
        for task in report.resetTasks { reducer.invalidate(.rotatedLog, now: now, task: task, resetPositions: true,
                                                          traceReason: report.traceResetReasons[task]) }
        for gap in report.gaps { reducer.gap(gap, now: now) }
        for task in report.excluded { reducer.exclude(task); resolver.forget(task) }
        for evidence in report.evidence {
            let previous = reducer.records[evidence.identity]
            reducer.apply(evidence, now: now)
            if evidence.kind == .started, evidence.live, evidence.date >= liveSince,
               previous?.lastPosition != evidence.position,
               let accepted = reducer.records[evidence.identity], accepted.lastPosition == evidence.position,
               accepted.phase == .active {
                measurements.acceptedLiveStarts += 1
            }
        }
        updateWatches()
    }
    private func updateWatches() {
        let files = resolver.observedFiles
        for task in Array(watches.keys) where files[task] == nil { watches.removeValue(forKey: task)?.cancel() }
        for (task, url) in files where watches[task] == nil {
            do {
                let fd = try HookPaths.openRegular(url)
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                    eventMask: [.write, .extend, .rename, .delete, .revoke], queue: queue)
                source.setEventHandler { [weak self, weak source] in
                    guard let self, let source else { return }
                    if !source.data.intersection([.rename, .delete, .revoke]).isEmpty {
                        self.reducer.invalidate(.rotatedLog, now: Date(), task: task, resetPositions: true)
                        self.watches.removeValue(forKey: task)?.cancel()
                        self.resolver.forget(task)
                    }
                    self.schedule(task, delay: 0.1, restart: true)
                }
                source.setCancelHandler { close(fd) }
                watches[task] = source; source.resume()
            } catch { reducer.gap(.invalidPath, now: Date()) }
        }
    }
    private func publish() {
        guard enabled else { return }
        refreshTraceGate()
        var members: HookTaskMemberSnapshot?
        let snapshot = reducer.snapshot(now: Date(), onMembers: traceCaptureEnabled ? { members = $0 } : nil)
        // Ignore timestamp-only updates, while preserving changed counts/coverage/completion IDs.
        var comparison = snapshot; comparison.updatedAt = previous?.updatedAt ?? snapshot.updatedAt
        let delivered = comparison != previous || publishedStarts != measurements.acceptedLiveStarts
        if delivered { previous = snapshot; publishedStarts = measurements.acceptedLiveStarts }
        deliver(snapshot, members: members, businessDelivery: delivered)
        guard persistWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.enabled else { return }; self.persistWork = nil
            do {
                let records = self.reducer.records.values.sorted {
                    ($0.identity.task.source, $0.identity.task.session, $0.identity.turn) < ($1.identity.task.source, $1.identity.task.session, $1.identity.turn)
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                let data = try encoder.encode(HookCache(version: 1, records: records))
                guard data != self.lastPersistedData else { return }
                guard data.count <= HookBudget.cacheBytes else { throw HookFailure.budget }
                try HookPaths.atomicWrite(data, to: self.directory.appendingPathComponent("state.json"))
                self.lastPersistedData = data
            } catch {
                self.reducer.gap(.disconnected, now: Date()); self.reducer.health.state = .degraded
                var members: HookTaskMemberSnapshot?
                self.refreshTraceGate()
                let snapshot = self.reducer.snapshot(now: Date(), onMembers: self.traceCaptureEnabled ? { members = $0 } : nil)
                self.deliver(snapshot, members: members, businessDelivery: true)
            }
        }
        persistWork = work; queue.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
    private func deliver(_ snapshot: TaskActivitySnapshot, members: HookTaskMemberSnapshot?, businessDelivery: Bool) {
        var trace: (UInt64, UInt64)?
        if let members, let traceHandler,
           !tracePending.isEmpty || traceDropped > 0 || members != previousMembers || businessDelivery {
            traceSequence &+= 1
            let batch = HookTaskTraceBatch(generation: traceGeneration, traceEpoch: currentTraceEpoch, sequence: traceSequence,
                observations: tracePending, observationsDropped: traceDropped, members: members,
                activity: snapshot, businessDelivery: businessDelivery)
            tracePending.removeAll(keepingCapacity: true); traceDropped = 0; previousMembers = members
            traceHandler(batch); trace = (batch.generation, batch.sequence)
        }
        if businessDelivery || trace != nil { observer?(snapshot, measurements, trace, businessDelivery) }
    }
}
