import Foundation
import Darwin

@main
enum DiagnosticUpgradeStorageTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) rethrows {
        let passed = try value(); precondition(passed, message); checks += 1
    }
    static let identity = DiagnosticProcessIdentity(version: DiagnosticVersion(rawValue: "0.1.40"), build: DiagnosticBuild(rawValue: "43"))
    static let target = DiagnosticProcessIdentity(version: DiagnosticVersion(rawValue: "0.1.41"), build: DiagnosticBuild(rawValue: "44"))
    static func wait(_ body: (@escaping () -> Void) -> Void) {
        let done = DispatchSemaphore(value: 0); body { done.signal() }
        check(done.wait(timeout: .now() + 5) == .success, "callback bounded")
    }
    static func handoff(_ directory: URL, config: DiagnosticStore.Configuration = .init(), date: Date = Date()) throws -> DiagnosticUpgradeHandoff {
        let control = try DiagnosticProcessStore(directory: directory, configuration: config).currentControl(defaultEnabled: true)
        return DiagnosticUpgradeHandoff(updateSessionID: UUID(), sourceSessionID: UUID(), sourceIdentity: identity,
            targetIdentity: target, createdAt: date, recordingEnabled: control.enabled, clearEpoch: control.clearEpoch)
    }
    static func writer(_ handoff: DiagnosticUpgradeHandoff, _ directory: URL, role: DiagnosticWriterRole = .installer,
                       config: DiagnosticStore.Configuration = .init(), session: UUID? = nil) throws -> DiagnosticUpgradeWriter {
        try DiagnosticUpgradeWriter.bootstrapFromProtectedHandoff(handoff, role: role, identity: identity, directory: directory,
            configuration: config, writerSessionID: session)
    }
    static func events(_ snapshot: DiagnosticStoreSnapshot) throws -> [DiagnosticEventEnvelope] {
        try snapshot.eventsData.split(separator: 10).map { try DiagnosticEventEnvelope.decoder().decode(DiagnosticEventEnvelope.self, from: Data($0)) }
    }
    static func jsonlFiles(_ directory: URL) -> [URL] {
        (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "jsonl" }
    }
    static func bytes(_ directory: URL) throws -> Int {
        try jsonlFiles(directory).reduce(0) { $0 + (try Data(contentsOf: $1)).count }
    }
    static func fixtureLine(_ sequence: UInt64 = 1) throws -> Data {
        var data = try DiagnosticEventEnvelope.encoder().encode(DiagnosticEventEnvelope(timestamp: Date(), sessionID: UUID(),
            sequence: sequence, monotonicMilliseconds: 0, event: .lifecycle(.launch)))
        data.append(10); return data
    }
    static func main() throws {
        if CommandLine.arguments.count > 1 { try worker(); return }
        var canonical = [CChar](repeating: 0, count: Int(PATH_MAX))
        precondition(realpath(FileManager.default.temporaryDirectory.path, &canonical) != nil)
        let root = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent("diagnostic-upgrade-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        print("Testing controls"); fflush(stdout)
        try controls(root.appendingPathComponent("controls"))
        print("Testing locking"); fflush(stdout)
        try locking(root.appendingPathComponent("locking"))
        print("Testing budgets"); fflush(stdout)
        try budgets(root.appendingPathComponent("budgets"))
        print("Testing protocolAndFreeze"); fflush(stdout)
        try protocolAndFreeze(root.appendingPathComponent("protocol"))
        print("Testing safety"); fflush(stdout)
        try safety(root.appendingPathComponent("safety"))
        print("Testing registry"); fflush(stdout)
        try registry(root.appendingPathComponent("registry"))
        print("Testing reporting"); fflush(stdout)
        try reporting(root.appendingPathComponent("reporting"))
        print("Testing producers"); fflush(stdout)
        try producers(root.appendingPathComponent("producers"))
        try concurrentBudgetAndClear(root.appendingPathComponent("concurrent-boundaries"))
        try prepareDuringClear(root.appendingPathComponent("prepare-clear"))
        print("DiagnosticUpgradeStorageTests: \(checks) checks passed")
    }
    static func controls(_ directory: URL) throws {
        let store = DiagnosticStore(directory: directory); _ = try store.startSession(UUID())
        let marker = directory.appendingPathComponent("session-state.json")
        let initialMarker = try Data(contentsOf: marker)
        let context = try handoff(directory); let helper = try writer(context, directory)
        check(helper.record(stage: .backupStarted) == .persisted, "helper append confirmed")
        try check(Data(contentsOf: marker) == initialMarker, "helper never overwrites ordinary session marker")
        _ = try store.setEnabled(false)
        check(helper.record(stage: .backupSucceeded) == .disabled, "live helper sees durable disable")
        let reopened = DiagnosticRecorder(directory: directory); reopened.start(enabled: true)
        wait { reopened.flush(completion: $0) }
        check(!reopened.isEnabled, "restart respects durable disabled even when stale preference says true")
        _ = try store.setEnabled(true)
        check(helper.record(stage: .replaceStarted) == .persisted, "reenable resumes same epoch")
        let oldEpoch = context.clearEpoch
        let other = DiagnosticStore(directory: directory); try other.clear()
        check(helper.record(stage: .replaceSucceeded) == .staleEpoch, "clear rejects live old helper")
        check(jsonlFiles(directory).isEmpty, "old helper cannot resurrect cleared files")
        do { try store.append([fixtureLine()]); preconditionFailure("old HUD appended after clear") }
        catch { check((error as? DiagnosticStoreError) == .staleEpoch, "clear rejects stale ordinary writer too") }
        let state = try other.controlState()
        check(state.clearEpoch != oldEpoch && state.enabled, "clear rotates epoch and retains switch")
        let helper2 = try writer(try handoff(directory), directory)
        check(helper2.record(stage: .handoffPrepared) == .persisted, "fresh epoch can record")
        let stateData = try Data(contentsOf: directory.appendingPathComponent("control.json"))
        check(!String(decoding: stateData, as: UTF8.self).contains("source"), "retained control contains no upgrade business metadata")
    }
    static func locking(_ directory: URL) throws {
        let context = try handoff(directory); let helper = try writer(context, directory)
        let path = directory.appendingPathComponent(DiagnosticProcessStore.lockName)
        let lock = open(path.path, O_RDWR | O_NOFOLLOW); check(lock >= 0, "fixture lock opened")
        defer { close(lock) }
        check(flock(lock, LOCK_EX | LOCK_NB) == 0, "fixture lock held")
        let start = DispatchTime.now().uptimeNanoseconds
        check(helper.record(stage: .backupStarted) == .lockBusy, "lock contention is explicit")
        check(DispatchTime.now().uptimeNanoseconds - start < 100_000_000, "lock busy returns under 100ms")
        _ = flock(lock, LOCK_UN)
        check(helper.record(stage: .backupSucceeded) == .persisted, "writer recovers after lock release")
        let snap = try helper.freezeSnapshot()
        check(snap.gaps.contains { $0.reason == .lockBusy && $0.count == 1 }, "recovered writer explains known skipped event")
    }
    static func budgets(_ directory: URL) throws {
        var config = DiagnosticStore.Configuration(); config.maximumTotalBytes = 5000; config.maximumUpgradeBytes = 2400; config.maximumFileBytes = 1500
        let context = try handoff(directory, config: config); let helper = try writer(context, directory, config: config)
        var stopped = false
        for _ in 0..<20 {
            let result = helper.record(stage: .backupStarted)
            if result == .budgetExceeded { stopped = true; break }
        }
        check(stopped, "per-upgrade 64KiB configurable cap enforced")
        try check(bytes(directory) <= config.maximumUpgradeBytes, "all upgrade writers share session budget")
        let ordinary = DiagnosticStore(directory: directory, configuration: config); _ = try ordinary.startSession(UUID())
        for n in 0..<30 {
            do { try ordinary.append([fixtureLine(UInt64(n + 1))]) }
            catch { check((error as? DiagnosticStoreError) == .budgetExceeded, "full active budget fails closed") }
            try check(bytes(directory) <= config.maximumTotalBytes, "ordinary and upgrade events share global budget")
        }
        var ageConfig = DiagnosticStore.Configuration(); ageConfig.maximumAge = 1
        let expiredDate = Date().addingTimeInterval(-2)
        let expiryDirectory = directory.appendingPathComponent("expiry")
        let old = try handoff(expiryDirectory, config: ageConfig, date: expiredDate)
        do { _ = try writer(old, expiryDirectory, config: ageConfig); preconditionFailure("expired handoff accepted") }
        catch { check((error as? DiagnosticStoreError) == .disabled, "expired handoff cannot create records") }
    }
    static func protocolAndFreeze(_ directory: URL) throws {
        let context = try handoff(directory); let helper = try writer(context, directory)
        check(helper.record(stage: .handoffPrepared) == .persisted, "initial upgraded event")
        let frozen = try helper.freezeSnapshot()
        let before = frozen.eventsData
        check(helper.record(stage: .backupStarted) == .persisted, "post-preview append")
        check(before == frozen.eventsData, "frozen snapshot immutable")
        let file = jsonlFiles(directory).first!
        var data = try Data(contentsOf: file)
        let first = data.split(separator: 10).first!
        var object = try JSONSerialization.jsonObject(with: Data(first)) as! [String: Any]
        object["schemaVersion"] = 99; object["unknownPrivatePath"] = "/Users/private-token"
        data.append(try JSONSerialization.data(withJSONObject: object)); data.append(10)
        object["schemaVersion"] = 1; object["event"] = ["unknownNewProtocolEvent": ["secret": "do-not-export"]]
        data.append(try JSONSerialization.data(withJSONObject: object)); data.append(10)
        data.append(Data(first)); data.append(10) // same upgrade/session/event ID must deduplicate
        data.append(Data("{partial-tail-secret".utf8))
        try data.write(to: file)
        let result = try helper.freezeSnapshot()
        try check(events(result).count == 2, "valid lines retained and duplicates removed")
        check(result.issues.contains(.unknownProtocol), "unknown protocol explicit gap")
        check(result.issues.contains(.unknownEvent), "unknown event explicit gap")
        check(result.issues.contains(.corruptedLine), "incomplete tail explicit gap")
        let exported = String(decoding: result.eventsData, as: UTF8.self)
        check(!exported.contains("secret") && !exported.contains("Users") && !exported.contains("unknownNew"), "unknown JSON never exported")
        try check(events(result).allSatisfy { $0.processIdentity == identity && $0.upgradeTargetIdentity == target }, "identity safely survives roundtrip")
        check(helper.record(stage: .backupSucceeded) == .failed, "uncertain tail never appended")
        var overflow = try JSONSerialization.jsonObject(with: Data(first)) as! [String: Any]
        overflow["sequence"] = UInt64.max
        overflow["eventID"] = ["sessionID": helper.sessionID.uuidString, "sequence": UInt64.max]
        var overflowData = try JSONSerialization.data(withJSONObject: overflow); overflowData.append(10)
        try overflowData.write(to: file)
        check(helper.record(stage: .backupSucceeded) == .failed, "UInt64.max sequence fails without process trap")
        let explicitDirectory = directory.appendingPathComponent("explicit")
        let explicitContext = try handoff(explicitDirectory)
        let explicit = try writer(explicitContext, explicitDirectory)
        check(explicit.record(stage: .backupStarted, sequence: 1) == .persisted, "explicit producer stage one")
        check(explicit.record(stage: .replaceStarted, sequence: 3) == .persisted, "explicit producer resumes after skipped stage")
        try check(explicit.freezeSnapshot().issues.contains(.sequenceGap), "cross-invocation sequence hole explained")
        check(DiagnosticVersion(rawValue: "1.token-secret") == nil && DiagnosticBuild(rawValue: "43/private") == nil, "string wrappers reject free text")
        let invalid = Data("\"1.token-secret\"".utf8)
        check((try? JSONDecoder().decode(DiagnosticVersion.self, from: invalid)) == nil, "decode validates wrapper too")
        let future = Date().addingTimeInterval(20)
        let rangedDirectory = directory.appendingPathComponent("range")
        let ordinary = DiagnosticStore(directory: rangedDirectory); _ = try ordinary.startSession(UUID())
        func line(_ date: Date, _ seq: UInt64) throws -> Data {
            var value = try DiagnosticEventEnvelope.encoder().encode(DiagnosticEventEnvelope(timestamp: date, sessionID: context.sourceSessionID,
                sequence: seq, monotonicMilliseconds: seq, event: .upgrade(stage: .appStarted, result: .success),
                updateSessionID: context.updateSessionID, writerRole: .newHUD,
                eventID: .init(sessionID: context.sourceSessionID, sequence: seq), processIdentity: target))
            value.append(10); return value
        }
        try ordinary.append([line(Date(), 1), line(future, 2)])
        let range = try ordinary.snapshot(since: nil, until: Date().addingTimeInterval(1), generation: 0, isEnabled: true)
        check(range.truncatedUpdateIDs == [context.updateSessionID], "range truncation metadata without outside event")
        try check(events(range).count == 1, "range never silently expands")
    }
    static func safety(_ directory: URL) throws {
        let context = try handoff(directory); let helper = try writer(context, directory)
        _ = helper.record(stage: .backupStarted)
        for path in [directory, directory.appendingPathComponent("updates"), directory.appendingPathComponent("updates/\(context.updateSessionID.uuidString.lowercased())")] {
            let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as! Int
            check(mode & 0o777 == 0o700, "diagnostic directory 0700")
        }
        for path in jsonlFiles(directory) {
            let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as! Int
            check(mode & 0o777 == 0o600, "producer file 0600")
        }
        let regular = directory.appendingPathComponent("outside-evidence")
        try Data("keep-original".utf8).write(to: regular)
        let link = directory.appendingPathComponent("events-\(UUID().uuidString.lowercased()).jsonl")
        try FileManager.default.linkItem(at: regular, to: link)
        let symlink = directory.appendingPathComponent("events-\(UUID().uuidString.lowercased()).jsonl")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: regular)
        let fifo = directory.appendingPathComponent("events-\(UUID().uuidString.lowercased()).jsonl")
        check(mkfifo(fifo.path, 0o600) == 0, "FIFO created")
        let snap = try helper.freezeSnapshot()
        check(snap.issues.contains(.unsafeFile), "links and FIFO reported")
        try DiagnosticStore(directory: directory).clear()
        try check(Data(contentsOf: regular) == Data("keep-original".utf8), "clear cannot touch linked target")
        check(FileManager.default.fileExists(atPath: link.path), "hardlink refused and preserved")
        if geteuid() != 0 {
            do { _ = try DiagnosticProcessStore(directory: URL(fileURLWithPath: "/")).currentControl(defaultEnabled: true); preconditionFailure("foreign owner accepted") }
            catch { check((error as? DiagnosticStoreError) == .unsafePath, "foreign-owned root rejected before mutation") }
        }
    }
    static func registry(_ directory: URL) throws {
        let context = try handoff(directory)
        let process = DiagnosticProcessStore(directory: directory)
        let restore = directory.appendingPathComponent("private-original-recovery")
        try FileManager.default.createDirectory(at: restore, withIntermediateDirectories: true)
        let recovery = restore.appendingPathComponent("install.log"); try Data("preserve recovery".utf8).write(to: recovery)
        try process.saveCandidate(.init(handoff: context, metadata: try .init(channelDirectory: restore, targetPath: restore.appendingPathComponent("previous.app"))))
        let candidates = try process.candidates()
        check(candidates.count == 1 && candidates[0].handoff.updateSessionID == context.updateSessionID, "bounded protected registry roundtrip")
        let helper = try writer(context, directory); _ = helper.record(stage: .launchRequested)
        let snapshot = try helper.freezeSnapshot()
        check(!String(decoding: snapshot.eventsData, as: UTF8.self).contains(restore.path), "private locator excluded from export")
        try DiagnosticStore(directory: directory).clear()
        try check(process.candidates().isEmpty, "clear removes registry")
        try check(Data(contentsOf: recovery) == Data("preserve recovery".utf8), "clear preserves original installer recovery files")
    }
    static func reporting(_ directory: URL) throws {
        let recorder = DiagnosticRecorder(directory: directory)
        var result: DiagnosticFlushResult?
        wait { done in recorder.flushReporting { result = $0; done() } }
        check(result == .disabled, "unstarted flush reports disabled")
        recorder.start(); recorder.record(.lifecycle(.launch))
        wait { done in recorder.flushReporting { result = $0; done() } }
        check(result == .persisted, "successful fsync reports persisted")
        let failed = DiagnosticRecorder(directory: directory.appendingPathComponent("failed"), beforeWrite: { throw DiagnosticStoreError.ioFailure })
        failed.start(); failed.record(.lifecycle(.shutdownRequested))
        wait { done in failed.flushReporting { result = $0; done() } }
        check(result == .failed, "executed callback does not claim successful flush")
        let helperContext = try handoff(directory); let helper = try writer(helperContext, directory)
        let lock = open(directory.appendingPathComponent(DiagnosticProcessStore.lockName).path, O_RDWR | O_NOFOLLOW)
        check(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0, "hold cross-process lock across toggle")
        var toggle: Result<Bool, Error>?
        let begin = Date()
        wait { done in recorder.setEnabledReporting(false) { toggle = $0; done() } }
        if case .failure(let error) = toggle! { check((error as? DiagnosticStoreError) == .lockBusy, "durable toggle lock timeout reported") }
        else { preconditionFailure("busy durable disable falsely confirmed") }
        check(Date().timeIntervalSince(begin) < 1.5 && !recorder.isEnabled, "disable failure bounded and stops local admission")
        _ = flock(lock, LOCK_UN); close(lock)
        check(helper.record(stage: .backupStarted) == .persisted, "failed disable explicitly leaves other producer unconfirmed")
        wait { done in recorder.setEnabledReporting(false) { toggle = $0; done() } }
        if case .success(let enabled) = toggle! { check(!enabled, "retry confirms persisted disable") }
        else { preconditionFailure("unlocked disable failed") }
        check(helper.record(stage: .backupSucceeded) == .disabled, "confirmed disable stops helper")
        wait { done in recorder.setEnabledReporting(true) { _ in done() } }
        let oldHandoff = try handoff(directory)
        wait { done in recorder.clear { _ in done() } }
        var association: Result<Void, Error>?
        wait { done in recorder.associateUpgradeReporting(oldHandoff, role: .newHUD) { association = $0; done() } }
        if case .failure(let error) = association! { check((error as? DiagnosticStoreError) == .staleEpoch, "cleared handoff cannot be associated into new generation") }
        else { preconditionFailure("stale epoch was associated") }
        let newHandoff = try handoff(directory)
        wait { done in recorder.associateUpgradeReporting(newHandoff, role: .newHUD) { association = $0; done() } }
        if case .success = association! { check(true, "fresh valid handoff associated") }
        else { preconditionFailure("fresh epoch association failed") }
        recorder.record(.upgrade(stage: .continuationAccepted, result: .success))
        wait { recorder.flush(completion: $0) }
        let associated = try DiagnosticStore(directory: directory).snapshot(since: nil, generation: 0, isEnabled: true)
        try check(events(associated).contains { $0.updateSessionID == newHandoff.updateSessionID && $0.writerRole == .newHUD }, "ordinary HUD events share validated upgrade association")

    }
    static func prepareDuringClear(_ directory: URL) throws {
        let gateLock = NSLock()
        var pauseNextWrite = false
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let recorder = DiagnosticRecorder(directory: directory, beforeWrite: {
            gateLock.lock(); let pause = pauseNextWrite; pauseNextWrite = false; gateLock.unlock()
            if pause {
                entered.signal()
                precondition(resume.wait(timeout: .now() + 5) == .success, "prepare-clear writer resumed")
            }
        })
        recorder.start(); wait { recorder.flush(completion: $0) }
        gateLock.lock(); pauseNextWrite = true; gateLock.unlock()
        recorder.record(.componentFailure(component: .updateProgress, result: .failed))
        check(entered.wait(timeout: .now() + 5) == .success, "prepare-clear pauses I/O deterministically")
        let obsoleteID = UUID()
        let prepared = DispatchSemaphore(value: 0)
        let cleared = DispatchSemaphore(value: 0)
        var preparation: Result<DiagnosticUpgradeHandoff, Error>?
        var clearing: Result<Void, Error>?
        recorder.prepareUpgradeHandoff(updateSessionID: obsoleteID, targetIdentity: target) {
            preparation = $0; prepared.signal()
        }
        let previousGeneration = recorder.recordingGeneration
        recorder.clear { clearing = $0; cleared.signal() }
        check(recorder.recordingGeneration > previousGeneration, "clear admission boundary precedes blocked disk work")
        resume.signal()
        check(prepared.wait(timeout: .now() + 5) == .success, "obsolete prepare completes within bound")
        check(cleared.wait(timeout: .now() + 5) == .success, "clear completes after rejected prepare")
        if case .failure(let error) = preparation! {
            check((error as? DiagnosticStoreError) == .cancelled, "pre-clear preparation cannot restore stale association")
        } else { preconditionFailure("prepare incorrectly succeeded after clear changed its generation") }
        if case .success = clearing! { check(true, "clear succeeded") }
        else { preconditionFailure("clear failed") }
        recorder.record(.lifecycle(.wake)); wait { recorder.flush(completion: $0) }
        let after = try DiagnosticStore(directory: directory).snapshot(since: nil, generation: recorder.recordingGeneration, isEnabled: true)
        try check(events(after).allSatisfy { $0.updateSessionID == nil }, "post-clear records never inherit obsolete upgrade ID")
    }

    static func producers(_ directory: URL) throws {
        let context = try handoff(directory)
        let contextFile = directory.appendingPathComponent("worker-context.json")
        try DiagnosticEventEnvelope.encoder().encode(context).write(to: contextFile)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var processes: [Process] = []
        for _ in 0..<4 {
            let process = Process(); process.executableURL = executable
            process.arguments = ["--worker", directory.path, contextFile.path]
            try process.run(); processes.append(process)
        }
        for process in processes { process.waitUntilExit(); check(process.terminationStatus == 0, "real child writer succeeded") }
        let snapshot = try DiagnosticStore(directory: directory).snapshot(since: nil, generation: 0, isEnabled: true)
        let upgraded = try events(snapshot).filter { if case .upgrade = $0.event { return true }; return false }
        check(upgraded.count == 32, "all actual producer events present without line mixing")
        check(Set(upgraded.map(\.sessionID)).count == 4, "one random file/session per producer")
        check(jsonlFiles(directory).count == 4, "one file owned by each producer")
        try check(bytes(directory) <= 64 * 1024, "concurrent producers respect combined update cap")
        check(!snapshot.issues.contains(.corruptedLine), "concurrent lines decode completely")
    }
    static func concurrentBudgetAndClear(_ directory: URL) throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let budgetDirectory = directory.appendingPathComponent("budget")
        let context = try handoff(budgetDirectory)
        let contextFile = budgetDirectory.appendingPathComponent("worker-context.json")
        try DiagnosticEventEnvelope.encoder().encode(context).write(to: contextFile)
        var processes: [Process] = []
        for _ in 0..<4 {
            let process = Process(); process.executableURL = executable
            process.arguments = ["--worker-budget", budgetDirectory.path, contextFile.path]
            try process.run(); processes.append(process)
        }
        var budgetNeverExceeded = true
        while processes.contains(where: \.isRunning) {
            // Acquire the common lock before measuring a consistent multi-file total.
            let processStore = DiagnosticProcessStore(directory: budgetDirectory)
            if let total = try? processStore.withLock({ try processStore.totalBytes(processStore.files(includeEarliest: false)) }) {
                budgetNeverExceeded = budgetNeverExceeded && total <= 4000
            }
            usleep(3000)
        }
        check(budgetNeverExceeded, "observed global totals remain strict during actual concurrent writes")
        for process in processes { process.waitUntilExit(); check(process.terminationStatus == 0, "concurrent bounded writer terminates safely") }
        try check(bytes(budgetDirectory) <= 4000, "final budget bounded after all child writers")

        let clearDirectory = directory.appendingPathComponent("clear")
        let clearContext = try handoff(clearDirectory)
        let clearFile = clearDirectory.appendingPathComponent("worker-context.json")
        try DiagnosticEventEnvelope.encoder().encode(clearContext).write(to: clearFile)
        let child = Process(); child.executableURL = executable
        child.arguments = ["--worker-clear", clearDirectory.path, clearFile.path]
        try child.run()
        let ready = clearDirectory.appendingPathComponent("child-ready")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline { usleep(1000) }
        check(FileManager.default.fileExists(atPath: ready.path), "actual old helper started before clear")
        let store = DiagnosticStore(directory: clearDirectory)
        var cleared = false
        while !cleared && Date() < deadline {
            do { try store.clear(); cleared = true }
            catch { guard (error as? DiagnosticStoreError) == .lockBusy else { throw error }; usleep(1000) }
        }
        check(cleared, "clear wins serialized epoch transition")
        try Data().write(to: clearDirectory.appendingPathComponent("child-resume"))
        child.waitUntilExit()
        check(child.terminationStatus == 0, "live child explicitly observed stale epoch")
        check(jsonlFiles(clearDirectory).isEmpty, "actual old process cannot recreate files after clear")
    }

    static func worker() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        let context = try DiagnosticEventEnvelope.decoder().decode(DiagnosticUpgradeHandoff.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
        var configuration = DiagnosticStore.Configuration()
        if CommandLine.arguments[1] == "--worker-budget" { configuration.maximumTotalBytes = 4000 }
        var value: DiagnosticUpgradeWriter?
        let deadline = Date().addingTimeInterval(5)
        while value == nil && Date() < deadline {
            value = try? writer(context, directory, config: configuration)
            if value == nil { usleep(3000) }
        }
        guard let value else { exit(2) }
        if CommandLine.arguments[1] == "--worker-clear" {
            var result = value.record(stage: .backupStarted)
            while result == .lockBusy && Date() < deadline { usleep(3000); result = value.record(stage: .backupStarted) }
            guard result == .persisted else { exit(4) }
            try Data().write(to: directory.appendingPathComponent("child-ready"))
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("child-resume").path) && Date() < deadline { usleep(1000) }
            guard value.record(stage: .backupSucceeded) == .staleEpoch else { exit(5) }
            return
        }
        for _ in 0..<(CommandLine.arguments[1] == "--worker-budget" ? 20 : 8) {
            var result = value.record(stage: .backupStarted)
            while result == .lockBusy && Date() < deadline { usleep(3000); result = value.record(stage: .backupStarted) }
            if CommandLine.arguments[1] == "--worker-budget", result == .budgetExceeded { return }
            guard result == .persisted else { exit(3) }
        }
    }
}
