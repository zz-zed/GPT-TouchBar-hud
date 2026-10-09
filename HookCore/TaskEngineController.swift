import Foundation

/// A replaceable, process-local bridge to the application's diagnostic recorder.
/// It owns no files and does not retain the recorder. Registration is thread safe.
public final class TaskObservationRelay: TaskObservationSink {
    public static let shared = TaskObservationRelay()
    private let lock = NSLock()
    private weak var destination: TaskObservationSink?
    public init() {}
    public func connect(_ sink: TaskObservationSink?) {
        lock.lock(); destination = sink; lock.unlock()
    }
    public func record(_ event: TaskObservation) {
        lock.lock(); let sink = destination; lock.unlock()
        sink?.record(event)
    }
}

/// Only this small cancellation gate crosses the main/worker ownership boundary.
private final class TaskWorkGate {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func advance() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1; return value
    }
    func accepts(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value == token
    }
}

/// Shared production runtime for ordinary logs and optional Hook discovery hints.
/// Public controls and callbacks are main-thread owned. SQLite, parsing, checkpoints,
/// socket handling, and engine mutation are confined to one utility queue.
public final class TaskEngineController {
    public static var defaultHome: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
    }
    public var onUpdate: ((TaskEngineSnapshot) -> Void)?
    public var onMeasurements: ((HookMeasurements) -> Void)?
    // Modes share a checkpoint. One process queue orders old-mode saves before the
    // next mode loads, without blocking the main thread or racing atomic replacements.
    private static let workerQueue = DispatchQueue(label: "GPTTouchBarHUD.task-engine", qos: .utility)
    private let queue = TaskEngineController.workerQueue
    private let gate = TaskWorkGate()
    private var engine: TaskActivityEngine
    private let makeEngine: () -> TaskActivityEngine
    private let directory: URL?
    private let sink: TaskObservationSink
    private var scheduled: DispatchWorkItem?
    private var receiver: HookReceiver?
    private var enabled = false
    private var paused = false
    private var token: UInt64 = 0
    private var measurements = HookMeasurements()
    private var previous: TaskActivitySnapshot?
    private var previousRunning: Set<TaskIdentity> = []
    // Main-owned requested lifecycle, including a start whose worker has not run yet.
    private var desiredEnabled = false

    public init(home: URL = TaskEngineController.defaultHome, mode: TaskSourceMode,
                directory: URL? = nil, checkpointURL: URL? = nil,
                sink: TaskObservationSink = TaskObservationRelay.shared) {
        self.directory = directory; self.sink = sink
        // Both modes share the same minimal metadata checkpoint, including in isolated fixtures.
        let checkpoint = checkpointURL ?? home.appendingPathComponent(".hud-task-state/checkpoint-v1.json")
        let factory = { TaskActivityEngine(home: home, checkpointURL: checkpoint, sink: sink, sourceMode: mode) }
        makeEngine = factory; engine = factory()
    }

    public func start() {
        precondition(Thread.isMainThread)
        desiredEnabled = true
        let current = gate.advance()
        queue.async { [weak self] in
            guard let self, self.gate.accepts(current) else { return }
            if self.enabled { self.engine.stop(now: Date()) }
            self.cancelWork()
            self.engine = self.makeEngine()
            self.token = current; self.enabled = true; self.paused = false
            self.measurements = HookMeasurements(); self.previous = nil; self.previousRunning.removeAll()
            self.engine.begin(now: Date(), generation: current)
            self.startReceiver()
            self.poll()
        }
    }

    public func stop() {
        precondition(Thread.isMainThread)
        desiredEnabled = false
        _ = gate.advance() // Invalidates in-progress reads and main-queue deliveries immediately.
        queue.async { [weak self] in
            guard let self else { return }
            let wasEnabled = self.enabled
            self.enabled = false; self.cancelWork()
            if wasEnabled { self.engine.stop(now: Date()) }
        }
    }
    public func suspend() { change(.sleep, paused: true) }
    public func hostUnavailable() { change(.hostUnavailable, paused: true) }
    public func resume() { change(.resume, paused: false) }

    private func change(_ reason: TaskReconciliationReason, paused: Bool) {
        precondition(Thread.isMainThread)
        guard desiredEnabled else { return }
        let current = gate.advance()
        queue.async { [weak self] in
            guard let self, self.gate.accepts(current) else { return }
            if !self.enabled {
                // A lifecycle event may supersede start before it reaches the worker.
                self.engine = self.makeEngine(); self.enabled = true
                self.previous = nil; self.previousRunning.removeAll()
                self.engine.begin(now: Date(), generation: current)
                self.startReceiver()
            }
            self.scheduled?.cancel(); self.scheduled = nil
            self.token = current; self.paused = paused
            self.engine.reconcile(now: Date(), generation: current, reason: reason)
            self.poll()
        }
    }

    private func cancelWork() {
        scheduled?.cancel(); scheduled = nil
        receiver?.stop(); receiver = nil
    }
    private func startReceiver() {
        guard let directory else { return }
        do {
            try HookPaths.ensurePrivateDirectory(directory)
            let receiver = HookReceiver(directory: directory, queue: queue,
                onEvent: { [weak self] event in
                    guard let self, self.enabled, !self.paused, self.gate.accepts(self.token) else { return }
                    self.measurements.hooksReceived += 1
                    self.engine.receiveHint(event, now: Date(), generation: self.token)
                    self.schedule(after: 0)
                }, onGap: { [weak self] _ in
                    guard let self else { return }
                    self.sink.record(.issue(sequence: TaskObservationSequence.next(), generation: self.token,
                                            alias: nil, reason: .readFailed))
                })
            try receiver.start(); self.receiver = receiver
        } catch {
            // A failed hint channel never disables continuous discovery and log reads.
            sink.record(.issue(sequence: TaskObservationSequence.next(), generation: token,
                               alias: nil, reason: .readFailed))
        }
    }
    private func schedule(after delay: TimeInterval) {
        guard enabled, !paused, gate.accepts(token) else { return }
        scheduled?.cancel()
        let current = token
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.enabled, self.gate.accepts(current) else { return }
            self.scheduled = nil; self.poll()
        }
        scheduled = work; queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func poll() {
        guard enabled, gate.accepts(token) else { return }
        let current = token
        let snapshot = engine.poll(now: Date(), generation: current, cancelled: { [gate] in !gate.accepts(current) })
        measurements.bytesRead += snapshot.bytesRead
        measurements.filesRead += snapshot.filesRead
        measurements.reconciliations += 1
        var comparison = snapshot.activity
        comparison.updatedAt = previous?.updatedAt ?? comparison.updatedAt
        comparison.snapshotSequence = previous?.snapshotSequence ?? comparison.snapshotSequence
        comparison.observationGeneration = previous?.observationGeneration ?? comparison.observationGeneration
        // Member replacements also require delivery even if the displayed number stays constant.
        if comparison != previous || snapshot.runningIDs != previousRunning {
            previous = snapshot.activity
            previousRunning = snapshot.runningIDs
            let measure = measurements
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let accepted = self.gate.accepts(current)
                self.sink.record(.delivery(sequence: snapshot.sequence, generation: current, accepted: accepted))
                guard accepted else { return }
                self.onUpdate?(snapshot); self.onMeasurements?(measure)
            }
        }
        if !paused { schedule(after: snapshot.hasBacklog ? 0.05 : 1.0) }
    }
    deinit {
        _ = gate.advance()
        let scheduled = scheduled; let receiver = receiver
        queue.async { scheduled?.cancel(); receiver?.stop() }
    }
}
