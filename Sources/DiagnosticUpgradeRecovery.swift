import Foundation

/// Observation-only adapter; the bounded utility queue never participates in business decisions.
final class DiagnosticRuntimeRecorder: DiagnosticRecording {
    static let shared = DiagnosticRuntimeRecorder()
    let recovery = DiagnosticUpgradeRecovery()
    var taskTraceState: DiagnosticTaskTraceState { DiagnosticRecorder.shared.taskTraceState }
    func record(_ event: DiagnosticEvent, expectedGeneration: UInt64) {
        DiagnosticRecorder.shared.record(event, expectedGeneration: expectedGeneration)
        // Task observations do not participate in upgrade recovery inference.
    }
    func record(_ event: DiagnosticEvent) {
        DiagnosticRecorder.shared.record(event)
        recovery.observe(event)
    }
}

final class DiagnosticUpgradeRecovery {
    private let queue = DispatchQueue(label: "GPTTouchBarHUD.upgrade-recovery", qos: .utility)
    private let admission = NSLock()
    private var pending = 0
    private var active = false
    private var resolving = false
    private var bufferedObservations: [DiagnosticEvent] = []
    private var states: [String: DiagnosticRecoveryState] = [:]
    private var observationCount = 0
    private let directory: URL
    private let identity: DiagnosticProcessIdentity
    private let now: () -> Date
    private let recorder: DiagnosticRecorder

    init(directory: URL = DiagnosticStore.defaultDirectory, identity: DiagnosticProcessIdentity = .current,
         now: @escaping () -> Date = Date.init, recorder: DiagnosticRecorder = .shared) {
        self.directory = directory; self.identity = identity; self.now = now; self.recorder = recorder
    }

    /// Enqueued before services start, so their first observations follow validation.
    func start(arguments: [String], bundleURL: URL, bundleIdentifier: String?, completion: (() -> Void)? = nil) {
        queue.async { [self] in
            guard bundleIdentifier == AppIdentity.bundleIdentifier else { completion?(); return }
            let explicit = arguments.firstIndex(of: AppUpdateProgressChannel.argument)
            var channel: AppUpdateProgressChannel?
            var fallback = false
            if let index = explicit, arguments.count == index + 3 {
                channel = try? AppUpdateProgressChannel.load(directory: URL(fileURLWithPath: arguments[index + 1]), sessionID: arguments[index + 2])
            } else if explicit == nil {
                channel = DiagnosticInstallerBridge.uniquePendingChannel(target: bundleURL, identity: identity, now: now(), diagnosticDirectory: directory)
                fallback = channel != nil
                if channel == nil, let candidates = try? DiagnosticProcessStore(directory: directory).candidates(), !candidates.isEmpty {
                    recorder.record(.upgrade(stage: .continuationRejected, result: .unknown))
                }
            }
            guard let channel,
                  URL(fileURLWithPath: channel.context.targetPath).standardizedFileURL.path == bundleURL.standardizedFileURL.path,
                  bundleURL.resolvingSymlinksInPath() == bundleURL.standardizedFileURL,
                  let bootstrap = DiagnosticInstallerBridge.protectedBootstrap(channel: channel) else {
                if explicit != nil { recorder.record(.upgrade(stage: .continuationRejected, result: .rejected)) }
                completion?(); return
            }
            accept(handoff: bootstrap.handoff, channel: channel, fallback: fallback, completion: completion)
        }
    }

    private func accept(handoff: DiagnosticUpgradeHandoff, channel: AppUpdateProgressChannel, fallback: Bool, completion: (() -> Void)?) {
        let age = now().timeIntervalSince(handoff.createdAt)
        guard age >= 0, age <= 72 * 3_600 else { completion?(); return }
        let progress = channel.readValue("install.json", as: AppUpdateProgress.self)
        guard progress?.sessionID == channel.context.sessionID else { completion?(); return }
        let step = progress?.step
        let role: DiagnosticWriterRole
        if identity.version != nil, identity == handoff.targetIdentity, [AppUpdateProgress.Step.launching, .finished].contains(where: { $0 == step }) { role = .newHUD }
        else if identity.version != nil, identity == handoff.sourceIdentity, step == .restoring { role = .restoredHUD }
        else {
            recorder.record(.upgrade(stage: .continuationRejected, result: .incompatible)); completion?(); return
        }
        resolving = true
        recorder.associateUpgradeReporting(handoff, role: role) { [self] result in
            queue.async { [self] in
                resolving = false
                if case .success = result {
                    active = true
                    if fallback { recorder.record(.upgrade(stage: .unfinishedHandoffObserved, result: .unknown)) }
                    recorder.record(.upgrade(stage: .appStarted, result: .success))
                    recorder.record(.upgrade(stage: .continuationAccepted, result: .success))
                    for module in [DiagnosticRecoveryModule.connection, .taskMonitor, .taskRecognition, .taskAggregation,
                                   .mainDelivery, .touchBar, .notch, .floating] { record(module, .notObserved, .afterRestart) }
                    record(.host, .unknown, .hostUnknown)
                    for event in bufferedObservations { process(event) }
                }
                bufferedObservations.removeAll()
                completion?()
            }
        }
    }

    func observe(_ event: DiagnosticEvent) {
        admission.lock()
        guard pending < 256 else { admission.unlock(); return }
        pending += 1; admission.unlock()
        queue.async { [self] in
            defer { admission.lock(); pending -= 1; admission.unlock() }
            if resolving {
                if bufferedObservations.count < 256 { bufferedObservations.append(event) }
            } else { process(event) }
        }
    }

    private func process(_ event: DiagnosticEvent) {
        guard active, observationCount < 80 else { return }
        for observation in Self.observations(for: event) { record(observation.0, observation.1, observation.2) }
    }

    static func observations(for event: DiagnosticEvent) -> [(DiagnosticRecoveryModule, DiagnosticRecoveryState, DiagnosticRecoveryObservation)] {
        switch event {
        case .moduleRecovery(let module, let state, let observation): return [(module, state, observation)]
        case .connection(let source, let phase, _, _, let result, _, _, _, _, let layer)
            where source == .business && layer == .store && [.initialize, .recovered, .retry].contains(phase):
            return [(.connection, result == .success ? .success : .failed, .afterRestart)]
        case .task(let stage, _, let result, _, _, _, _, _, let mode):
            let state: DiagnosticRecoveryState = result == .success ? .success : (result == .failed ? .failed : .unknown)
            switch stage {
            case .mode where mode == .disabled: return [(.taskMonitor, .disabled, .afterRestart), (.taskRecognition, .disabled, .afterRestart)]
            case .monitorStarted: return [(.taskMonitor, .success, .monitoringStarted)]
            case .monitorStopped: return [(.taskMonitor, .unknown, .afterRestart)]
            case .index, .indexCached, .read, .hooks: return [(.taskMonitor, state, .indexRead)]
            case .explicitStart: return [(.taskRecognition, .success, .taskStartObserved)]
            case .aggregate: return [(.taskAggregation, state, .aggregateProduced)]
            case .mainAccepted: return [(.mainDelivery, state, .mainAccepted)]
            default: return []
            }
        case .display(let surface, let action, let result, let mode, _, let reason):
            let module: DiagnosticRecoveryModule = surface == .touchBar ? .touchBar : (surface == .notch ? .notch : .floating)
            if mode == .disabled || reason == .disabled || reason == .noHardware { return [(module, .disabled, .afterRestart)] }
            if action == .request { return [(module, result == .success ? .success : .failed, .displaySubmitted)] }
            if action == .skipped { return [(module, .unknown, .afterRestart)] }
            return []
        default: return []
        }
    }

    private func record(_ module: DiagnosticRecoveryModule, _ state: DiagnosticRecoveryState, _ observation: DiagnosticRecoveryObservation) {
        let key = module.rawValue + ":" + observation.rawValue
        guard states[key] != state else { return }
        recorder.record(.moduleRecovery(module: module, state: state, observation: observation))
        states[key] = state; observationCount += 1
    }

    /// One shared deadline can contain diagnostics and future asynchronous shutdown participants.
    /// Completion is on main, at most once; a stalled writer cannot extend the deadline.
    static func prepareTermination(deadline: DispatchTime, reason: DiagnosticExitReason = .system, recorder: DiagnosticRecorder = .shared,
                                   completion: @escaping () -> Void) {
        var completed = false // Main queue owns this gate.
        let finish = { if !completed { completed = true; completion() } }
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: finish)
        recorder.record(.lifecycle(.shutdownRequested))
        recorder.record(.exitRequested(reason: reason))
        if DiagnosticInstallerBridge.preparedHandoff != nil {
            recorder.record(.upgrade(stage: .exitRequested, result: .success))
        }
        recorder.flushReporting { result in
            if DiagnosticInstallerBridge.preparedHandoff != nil {
                recorder.record(.upgrade(stage: .exitFlushCompleted,
                    result: result == .persisted ? .success : (result == .disabled ? .skipped : .ioFailure)))
                recorder.flushReporting { _ in DispatchQueue.main.async(execute: finish) }
            } else { DispatchQueue.main.async(execute: finish) }
        }
    }
}
