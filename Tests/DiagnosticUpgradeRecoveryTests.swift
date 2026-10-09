import Foundation
import Darwin

@main enum DiagnosticUpgradeRecoveryTests {
    static var count = 0
    static func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
    static let source = DiagnosticProcessIdentity(version: DiagnosticVersion(rawValue: "0.1.40"), build: DiagnosticBuild(rawValue: "43"))
    static let target = DiagnosticProcessIdentity(version: DiagnosticVersion(rawValue: "0.1.41"), build: DiagnosticBuild(rawValue: "44"))
    static func wait<T>(_ work: (@escaping (T) -> Void) -> Void) -> T {
        let semaphore = DispatchSemaphore(value: 0); var value: T?
        work { value = $0; semaphore.signal() }
        precondition(semaphore.wait(timeout: .now() + 5) == .success, "bounded worker callback")
        return value!
    }
    static func snapshot(_ recorder: DiagnosticRecorder) throws -> [DiagnosticEventEnvelope] {
        let result: Result<DiagnosticStoreSnapshot, Error> = wait { recorder.captureSnapshot(since: nil, completion: $0) }
        return try result.get().eventsData.split(separator: 10).map { try DiagnosticEventEnvelope.decoder().decode(DiagnosticEventEnvelope.self, from: Data($0)) }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/diagnostic-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostic = root.appendingPathComponent("Diagnostics")
        let recorder = DiagnosticRecorder(directory: diagnostic, processIdentity: target)
        recorder.start()
        let _: DiagnosticFlushResult = wait { recorder.flushReporting(completion: $0) }
        let processStore = DiagnosticProcessStore(directory: diagnostic)
        let control = try processStore.currentControl()
        let app = root.appendingPathComponent("GPT TouchBar HUD.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        func fixture() throws -> (AppUpdateProgressChannel, DiagnosticUpgradeHandoff) {
            let channel = try AppUpdateProgressChannel.create(target: app, sourceVersion: "0.1.40", targetVersion: "0.1.41")
            let handoff = DiagnosticUpgradeHandoff(updateSessionID: UUID(uuidString: channel.context.sessionID)!, sourceSessionID: UUID(),
                sourceIdentity: source, targetIdentity: target, createdAt: Date(), recordingEnabled: true, clearEpoch: control.clearEpoch)
            try DiagnosticInstallerBridge.prepare(handoff: handoff, channel: channel, expectedSourceIdentity: source, diagnosticDirectory: diagnostic)
            try channel.write(AppUpdateProgress(sessionID: channel.context.sessionID, phase: .restarting, step: .launching), name: "install.json")
            return (channel, handoff)
        }
        let (channel, handoff) = try fixture()
        let arguments = ["app", AppUpdateProgressChannel.argument, channel.directory.path, channel.context.sessionID]
        check(app.resolvingSymlinksInPath() == app.standardizedFileURL, "bundle path guard")
        check((try? AppUpdateProgressChannel.load(directory: channel.directory, sessionID: channel.context.sessionID)) != nil, "load guard")
        check(DiagnosticInstallerBridge.protectedBootstrap(channel: channel) != nil, "bootstrap guard")
        check(DiagnosticInstallerBridge.protectedBootstrap(channel: channel)?.handoff.targetIdentity == target, "identity guard")
        let bootstrapWriter = try DiagnosticUpgradeWriter.bootstrapFromProtectedHandoff(handoff, role: .installer, identity: source, directory: diagnostic)
        check(bootstrapWriter.record(stage: .launchRequested) == .persisted, "writer guard")
        let recovery = DiagnosticUpgradeRecovery(directory: diagnostic, identity: target, recorder: recorder)
        let _: Void = wait { done in recovery.start(arguments: arguments, bundleURL: app, bundleIdentifier: AppIdentity.bundleIdentifier, completion: { done(()) }) }
        var events = try snapshot(recorder)
        check(events.contains { if case .upgrade(.continuationAccepted, _) = $0.event { return $0.writerRole == .newHUD }; return false }, "validated explicit continuation")
        check(events.contains { if case .moduleRecovery(.taskRecognition, .notObserved, _) = $0.event { return true }; return false }, "no invented task recognition on launch")
        check(events.allSatisfy { $0.writerRole != .newHUD || $0.processIdentity == target }, "running build captured accurately")
        check(DiagnosticUpgradeRecovery.observations(for: .task(stage: .aggregate, runningCount: 1)).allSatisfy { $0.0 != .taskRecognition }, "running count does not establish new task start")
        check(DiagnosticUpgradeRecovery.observations(for: .task(stage: .read)).allSatisfy { $0.0 != .taskRecognition }, "read success does not establish new task start")
        check(DiagnosticUpgradeRecovery.observations(for: .task(stage: .explicitStart)).first?.1 == .success, "explicit accepted start separately observed")
        check(DiagnosticUpgradeRecovery.observations(for: .connection(source: .check, phase: .initialize, layer: .store)).isEmpty, "active check is not business recovery")
        check(DiagnosticUpgradeRecovery.observations(for: .connection(phase: .retry, result: .failed, layer: .store)).first?.1 == .failed, "business connection failure remains independent from install")
        check(DiagnosticUpgradeRecovery.observations(for: .display(surface: .touchBar, action: .request)).first?.2 == .displaySubmitted, "Touch Bar claim remains request only")
        check(DiagnosticUpgradeRecovery.observations(for: .task(stage: .mode, mode: .disabled)).first?.1 == .disabled, "runtime disabled explicitly reported")
        check(DiagnosticInstallerBridge.uniquePendingChannel(target: app, identity: target, diagnosticDirectory: diagnostic)?.context.sessionID == channel.context.sessionID, "unique no-args protected registry")
        let fallback = DiagnosticUpgradeRecovery(directory: diagnostic, identity: target, recorder: recorder)
        let _: Void = wait { done in fallback.start(arguments: ["app"], bundleURL: app, bundleIdentifier: AppIdentity.bundleIdentifier, completion: { done(()) }) }
        events = try snapshot(recorder)
        check(events.contains { if case .upgrade(.unfinishedHandoffObserved, _) = $0.event { return true }; return false }, "fallback is explicit after-start observation")
        let (second, _) = try fixture()
        check(DiagnosticInstallerBridge.uniquePendingChannel(target: app, identity: target, diagnosticDirectory: diagnostic) == nil, "ambiguous handoffs never choose newest")
        try second.write(AppUpdateProgress(sessionID: second.context.sessionID, phase: .succeeded, step: .finished), name: "install.json")
        check(DiagnosticInstallerBridge.uniquePendingChannel(target: app, identity: target, diagnosticDirectory: diagnostic) != nil, "completed historical handoff excluded")
        let wrong = DiagnosticUpgradeRecovery(directory: diagnostic, identity: source, recorder: recorder)
        let before = try snapshot(recorder).filter { $0.writerRole == .restoredHUD }.count
        let _: Void = wait { done in wrong.start(arguments: arguments, bundleURL: app, bundleIdentifier: AppIdentity.bundleIdentifier, completion: { done(()) }) }
        check(try snapshot(recorder).filter { $0.writerRole == .restoredHUD }.count == before, "source version in target launch phase cannot claim rollback")
        try channel.write(AppUpdateProgress(sessionID: channel.context.sessionID, phase: .failed, step: .restoring, recovery: .restored), name: "install.json")
        let restoredRecorder = DiagnosticRecorder(directory: diagnostic, processIdentity: source)
        restoredRecorder.start()
        let _: DiagnosticFlushResult = wait { restoredRecorder.flushReporting(completion: $0) }
        let restored = DiagnosticUpgradeRecovery(directory: diagnostic, identity: source, recorder: restoredRecorder)
        let _: Void = wait { done in restored.start(arguments: arguments, bundleURL: app, bundleIdentifier: AppIdentity.bundleIdentifier, completion: { done(()) }) }
        check(try snapshot(restoredRecorder).contains { $0.writerRole == .restoredHUD && $0.processIdentity == source }, "restored identity differs from original target")
        let clearResult: Result<Void, Error> = wait { recorder.clear(completion: $0) }; try clearResult.get()
        let cleared = DiagnosticUpgradeRecovery(directory: diagnostic, identity: target, recorder: recorder)
        try channel.write(AppUpdateProgress(sessionID: channel.context.sessionID, phase: .restarting, step: .launching), name: "install.json")
        let _: Void = wait { done in cleared.start(arguments: arguments, bundleURL: app, bundleIdentifier: AppIdentity.bundleIdentifier, completion: { done(()) }) }
        check(try snapshot(recorder).allSatisfy { $0.updateSessionID != handoff.updateSessionID }, "clear invalidates protected-but-old channel too")
        check(FileManager.default.fileExists(atPath: channel.directory.appendingPathComponent("RECOVERY.txt").path), "clear preserves original recovery material")
        let gate = DispatchSemaphore(value: 0)
        let slow = DiagnosticRecorder(directory: root.appendingPathComponent("slow"), beforeWrite: { _ = gate.wait(timeout: .now() + 2) })
        slow.start()
        slow.record(.lifecycle(.launch))
        var terminationReplies = 0
        let began = Date()
        DiagnosticUpgradeRecovery.prepareTermination(deadline: .now() + .milliseconds(50), reason: .manual, recorder: slow) { terminationReplies += 1 }
        while terminationReplies == 0 && Date().timeIntervalSince(began) < 1 { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        check(terminationReplies == 1 && Date().timeIntervalSince(began) < 1, "one shared deadline releases a stalled shutdown writer")
        gate.signal(); gate.signal(); gate.signal()
        let _: DiagnosticFlushResult = wait { slow.flushReporting(completion: $0) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(terminationReplies == 1, "late flush cannot reply to AppKit termination twice")
        print("PASS: \(count) diagnostic recovery checks")
    }
}
