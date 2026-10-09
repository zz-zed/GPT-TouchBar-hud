import Foundation
import Darwin

private final class FakeClock {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    private var tick: UInt64 = 1_000_000_000
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func uptime() -> UInt64 { lock.lock(); defer { lock.unlock() }; return tick }
    func advance(_ seconds: TimeInterval, wallOnly: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        date = date.addingTimeInterval(seconds)
        if !wallOnly { tick += UInt64(max(0, seconds) * 1_000_000_000) }
    }
}

private final class WriteGate {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var pause = false
    private var fail = false
    private var calls = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func configure(pause: Bool = false, fail: Bool = false) {
        lock.lock(); defer { lock.unlock() }; self.pause = pause; self.fail = fail
    }
    func write() throws {
        precondition(!Thread.isMainThread, "I/O hook must never run on main")
        lock.lock(); calls += 1; let paused = pause; let failed = fail; lock.unlock()
        if paused { entered.signal(); precondition(resume.wait(timeout: .now() + 5) == .success) }
        if failed { throw DiagnosticStoreError.ioFailure }
    }
}

@main
enum DiagnosticRecorderTests {
    private static var checks = 0
    private static func check(_ value: Bool, _ message: String) {
        precondition(value, message); checks += 1
    }
    private static func wait(_ work: (@escaping () -> Void) -> Void) {
        let done = DispatchSemaphore(value: 0)
        work { done.signal() }
        check(done.wait(timeout: .now() + 5) == .success, "background callback timeout")
    }
    private static func snapshot(_ recorder: DiagnosticRecorder, since: Date? = nil, until: Date? = nil) throws -> DiagnosticStoreSnapshot {
        let done = DispatchSemaphore(value: 0)
        var result: Result<DiagnosticStoreSnapshot, Error>?
        recorder.captureSnapshot(since: since, until: until) { result = $0; done.signal() }
        check(done.wait(timeout: .now() + 5) == .success, "snapshot timeout")
        return try result!.get()
    }
    private static func events(_ snapshot: DiagnosticStoreSnapshot) throws -> [DiagnosticEventEnvelope] {
        try snapshot.eventsData.split(separator: 10).map { try DiagnosticEventEnvelope.decoder().decode(DiagnosticEventEnvelope.self, from: Data($0)) }
    }
    private static func makeLine(_ clock: FakeClock, _ event: DiagnosticEvent, sequence: UInt64 = 1, session: UUID = UUID()) throws -> Data {
        var data = try DiagnosticEventEnvelope.encoder().encode(DiagnosticEventEnvelope(timestamp: clock.now(), sessionID: session,
            sequence: sequence, monotonicMilliseconds: 0, event: event))
        data.append(10)
        return data
    }
    private static func files(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
    }
    private static func size(_ directory: URL) throws -> Int {
        try files(directory).reduce(0) { $0 + ((try FileManager.default.attributesOfItem(atPath: $1.path)[.size]) as? Int ?? 0) }
    }

    static func main() throws {
        var canonical = [CChar](repeating: 0, count: Int(PATH_MAX))
        precondition(realpath(FileManager.default.temporaryDirectory.path, &canonical) != nil)
        let root = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent("hud-diagnostics-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        print("Testing noImplicitIO")
        try noImplicitIO(root)
        print("Testing whitelistAndCorruption")
        try whitelistAndCorruption(root)
        print("Testing retentionAndBudgets")
        try retentionAndBudgets(root)
        print("Testing queueAndFailure")
        try queueAndFailure(root)
        print("Testing boundaries")
        try boundaries(root)
        print("Testing aggregationAndClock")
        try aggregationAndClock(root)
        print("Testing shutdownMarker")
        try shutdownMarker(root)
        try startupFailure(root)
        try clearDuringWrite(root)
        try oversizedAndTimer(root)
        try adversarialCounts(root)
        try stagingCleanup(root)
        try dynamicAggregation(root)
        try idleRetention(root)
        try partialTailRecovery(root)
        try fifoSubstitution(root)
        try initiallyDisabledRetention(root)
        print("DiagnosticRecorderTests: \(checks) checks passed")
    }

    private static func noImplicitIO(_ root: URL) throws {
        let directory = root.appendingPathComponent("not-started")
        let recorder = DiagnosticRecorder(directory: directory)
        recorder.record(.lifecycle(.launch))
        wait { recorder.flush(completion: $0) }
        check(!FileManager.default.fileExists(atPath: directory.path), "unstarted recorder must not create files")
        NoopDiagnosticRecorder().record(.lifecycle(.launch))
        check(!recorder.isEnabled, "initial state disabled")
    }

    private static func whitelistAndCorruption(_ root: URL) throws {
        let clock = FakeClock()
        let directory = root.appendingPathComponent("whitelist")
        let store = DiagnosticStore(directory: directory, now: clock.now)
        _ = try store.startSession(UUID())
        var object = try JSONSerialization.jsonObject(with: makeLine(clock, .lifecycle(.launch))) as! [String: Any]
        object["module"] = "/Users/private/sensitive"
        object["severity"] = "credential@example.com"
        object["response"] = "secret-server-body"
        var event = object["event"] as! [String: Any]
        var lifecycle = event["lifecycle"] as! [String: Any]
        lifecycle["unapproved"] = "secret-title"
        event["lifecycle"] = lifecycle
        object["event"] = event
        var malicious = try JSONSerialization.data(withJSONObject: object)
        malicious.append(10)
        malicious.append(Data("{\"broken\":true}".utf8))
        let file = directory.appendingPathComponent("events-\(UUID().uuidString.lowercased()).jsonl")
        try malicious.write(to: file)
        let result = try store.snapshot(since: nil, generation: 2, isEnabled: false)
        let output = String(data: result.eventsData, encoding: .utf8)!
        for forbidden in ["sensitive", "credential@example.com", "secret-server-body", "secret-title", "unapproved"] {
            check(!output.contains(forbidden), "stored unknown fields must be discarded")
        }
        check(try events(result).count == 1, "valid line survives bad tail")
        check(result.issues.contains(.corruptedLine), "corrupt tail reported")
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as! Int
        check(permissions & 0o777 == 0o700, "directory permission 0700")
        let filePermissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! Int
        check(filePermissions & 0o777 == 0o600, "file permission 0600")
        let outside = root.appendingPathComponent("outside-secret")
        try Data("do-not-touch".utf8).write(to: outside)
        let linked = directory.appendingPathComponent("events-\(UUID().uuidString.lowercased()).jsonl")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        let linkedSnapshot = try store.snapshot(since: nil, generation: 2, isEnabled: false)
        check(linkedSnapshot.issues.contains(.unsafeFile), "symlink reported and ignored")
        try store.clear()
        check(try String(contentsOf: outside) == "do-not-touch", "clear preserves symlink target")
        check(FileManager.default.fileExists(atPath: linked.path), "untrusted links are not deleted")
        let symlinkRoot = root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: directory)
        do { _ = try DiagnosticStore(directory: symlinkRoot).startSession(UUID()); preconditionFailure("linked directory accepted") }
        catch { check((error as? DiagnosticStoreError) == .unsafePath, "directory links refused") }
    }

    private static func retentionAndBudgets(_ root: URL) throws {
        let clock = FakeClock()
        let directory = root.appendingPathComponent("retention")
        var config = DiagnosticStore.Configuration()
        config.maximumFileBytes = 900; config.maximumTotalBytes = 1700; config.maximumAge = 30
        let store = DiagnosticStore(directory: directory, configuration: config, now: clock.now)
        _ = try store.startSession(UUID())
        for index in 1...20 {
            try store.append([makeLine(clock, .task(stage: .aggregate, batch: UInt64(index), runningCount: index), sequence: UInt64(index))])
            check(try size(directory) <= config.maximumTotalBytes, "total budget enforced before every append")
            for file in try files(directory) { check(try Data(contentsOf: file).count <= 900, "single file budget") }
        }
        let retained = try store.snapshot(since: nil, generation: 1, isEnabled: true)
        check(retained.issues.contains(.retentionLimit), "retention coverage gap reported")
        clock.advance(31)
        try store.append([makeLine(clock, .lifecycle(.wake), sequence: 100)])
        let current = try store.snapshot(since: nil, generation: 1, isEnabled: true)
        check(try events(current).count == 1, "expiration applies to physical files even with continued writes")
        check(try files(directory).count == 1, "expired file physically removed")
        let futureCutoff = clock.now().addingTimeInterval(-1)
        check(try store.snapshot(since: futureCutoff, until: futureCutoff, generation: 1, isEnabled: true).eventsData.isEmpty,
              "snapshot upper bound applied")
        let arbitrary = directory.appendingPathComponent("user-notes.txt")
        try Data("preserve".utf8).write(to: arbitrary)
        try store.clear()
        check(FileManager.default.fileExists(atPath: arbitrary.path), "clear only owns recognized files")
    }

    private static func queueAndFailure(_ root: URL) throws {
        let clock = FakeClock(); let gate = WriteGate()
        let directory = root.appendingPathComponent("queue")
        var config = DiagnosticRecorder.Configuration()
        config.maximumQueuedEvents = 4; config.maximumQueuedBytes = 4 * 4096; config.flushDelay = 30
        let recorder = DiagnosticRecorder(directory: directory, configuration: config, now: clock.now,
            uptime: clock.uptime, beforeWrite: gate.write)
        recorder.start()
        wait { recorder.flush(completion: $0) }
        gate.configure(pause: true)
        recorder.record(.componentFailure(component: .autoLauncher, result: .failed))
        check(gate.entered.wait(timeout: .now() + 5) == .success, "writer paused")
        let tick = DispatchTime.now().uptimeNanoseconds
        for batch in 0..<1000 { recorder.record(.task(stage: .aggregate, batch: UInt64(batch), runningCount: 1)) }
        check(DispatchTime.now().uptimeNanoseconds - tick < 500_000_000, "producer does not wait for slow I/O")
        gate.configure(); gate.resume.signal()
        let storm = try snapshot(recorder)
        check(storm.issues.contains(.queueFull), "bounded queue reports dropped events")
        check(storm.droppedCount >= 995, "storm drop count aggregated")
        check(storm.eventsData.count < 15_000, "storm remains bounded")
        let persistedDrops = try events(storm).reduce(0) { total, envelope in
            if case .gap(let reason, let count) = envelope.event, reason.unit == .droppedEvents { return total + count }
            return total
        }
        check(storm.droppedCount == persistedDrops, "persisted gap delta is not counted twice")
        gate.configure(fail: true)
        recorder.record(.componentFailure(component: .quitMarker, result: .failed))
        wait { recorder.flush(completion: $0) }
        let failedCalls = gate.callCount
        for _ in 0..<20 { recorder.record(.lifecycle(.wake)); wait { recorder.flush(completion: $0) } }
        check(gate.callCount == failedCalls, "write failure backoff prevents tight retry")
        gate.configure(); clock.advance(65)
        let recovered = try snapshot(recorder)
        check(recovered.issues.contains(.writeFailure), "recovered write failure gap visible")
        let reopened = DiagnosticStore(directory: directory, now: clock.now)
        check(try reopened.snapshot(since: nil, generation: 5, isEnabled: false).issues.contains(.writeFailure),
              "gap summary persists across recorder restart")
    }

    private static func boundaries(_ root: URL) throws {
        let clock = FakeClock(); let gate = WriteGate()
        let directory = root.appendingPathComponent("boundary")
        let recorder = DiagnosticRecorder(directory: directory, now: clock.now, uptime: clock.uptime, beforeWrite: gate.write)
        recorder.start(); wait { recorder.flush(completion: $0) }
        gate.configure(pause: true)
        recorder.record(.componentFailure(component: .instanceLock, result: .failed))
        check(gate.entered.wait(timeout: .now() + 5) == .success, "old writer waiting")
        let old = recorder.recordingGeneration
        recorder.setEnabled(false)
        gate.configure(); gate.resume.signal()
        let disabled = try snapshot(recorder)
        check(disabled.generation > old && !disabled.isEnabled, "disable changes generation immediately")
        check(!(try events(disabled)).contains { if case .componentFailure(component: .instanceLock, _) = $0.event { return true }; return false },
              "blocked old-generation write rejected before disk")
        recorder.record(.lifecycle(.screenLocked))
        check((try snapshot(recorder)).eventsData == disabled.eventsData, "disabled recorder accepts no events")
        let clearDone = DispatchSemaphore(value: 0)
        recorder.clear { result in if case .failure = result { preconditionFailure("clear failed") }; clearDone.signal() }
        check(clearDone.wait(timeout: .now() + 5) == .success, "clear finishes asynchronously")
        check(try snapshot(recorder).eventsData.isEmpty, "clear removes retained events")
        wait { recorder.setEnabled(true, completion: $0) }
        recorder.record(.lifecycle(.screenUnlocked))
        check(!(try snapshot(recorder)).eventsData.isEmpty, "recording can resume after clear")
    }

    private static func aggregationAndClock(_ root: URL) throws {
        let clock = FakeClock()
        let recorder = DiagnosticRecorder(directory: root.appendingPathComponent("aggregation"), now: clock.now, uptime: clock.uptime)
        recorder.start(); wait { recorder.flush(completion: $0) }
        for _ in 0..<30 { recorder.record(.componentFailure(component: .autoLauncher, result: .failed)) }
        let aggregate = try events(snapshot(recorder))
        let errors = aggregate.filter { if case .componentFailure = $0.event { return true }; return false }
        check(errors.count == 2, "first error plus one fixed-window repetition summary")
        check(errors.compactMap(\.repetition).reduce(1) { $0 + $1.count } == 30, "repetitions preserve total count")
        check(errors.last?.repetition?.first == clock.now(), "aggregation first timestamp preserved")
        clock.advance(-3600, wallOnly: true)
        recorder.record(.lifecycle(.wake))
        let changed = try events(snapshot(recorder))
        check(changed.last?.monotonicMilliseconds == 0, "wall clock rollback does not create negative uptime")
        check(changed.map(\.sequence) == changed.map(\.sequence).sorted(), "session sequence survives clock rollback")
        let frozen = try snapshot(recorder)
        recorder.record(.lifecycle(.sleep)); wait { recorder.flush(completion: $0) }
        let frozenCopy = frozen.eventsData
        check(frozen.eventsData == frozenCopy, "snapshot is immutable Data")
        check(try snapshot(recorder).eventsData != frozen.eventsData, "new events require a new snapshot")
    }

    private static func fifoSubstitution(_ root: URL) throws {
        let clock = FakeClock(); let directory = root.appendingPathComponent("fifo-substitution")
        let store = DiagnosticStore(directory: directory, now: clock.now)
        _ = try store.startSession(UUID())
        try store.append([makeLine(clock, .lifecycle(.launch))])
        let current = try files(directory).first!
        try FileManager.default.removeItem(at: current)
        check(mkfifo(current.path, 0o600) == 0, "replace current owned event file with FIFO")
        let done = DispatchSemaphore(value: 0)
        var rejected = false
        DispatchQueue.global(qos: .utility).async {
            do { try store.append([makeLine(clock, .lifecycle(.wake))]) }
            catch { rejected = true }
            done.signal()
        }
        check(done.wait(timeout: .now() + 1) == .success, "FIFO append must not block the I/O queue")
        check(rejected, "FIFO cannot be appended as an event file")
        try store.append([makeLine(clock, .lifecycle(.sleep))])
        let recovered = try store.snapshot(since: nil, generation: 1, isEnabled: true)
        check(try events(recovered).count == 1, "writer recovers after rejecting FIFO")
        check(recovered.issues.contains(.unsafeFile), "FIFO reported as unsafe evidence")
    }

    private static func initiallyDisabledRetention(_ root: URL) throws {
        let clock = FakeClock(); let directory = root.appendingPathComponent("disabled-existing")
        var config = DiagnosticStore.Configuration(); config.maximumAge = 2
        let previous = DiagnosticStore(directory: directory, configuration: config, now: clock.now)
        _ = try previous.startSession(UUID())
        try previous.append([makeLine(clock, .lifecycle(.launch))])
        try previous.markShutdownConfirmed()
        let marker = directory.appendingPathComponent("session-state.json")
        let oldMarker = try Data(contentsOf: marker)
        clock.advance(3)
        let disabled = DiagnosticRecorder(directory: directory, storeConfiguration: config, now: clock.now, uptime: clock.uptime)
        disabled.start(enabled: false)
        wait { disabled.setEnabled(false, completion: $0) }
        check(try files(directory).isEmpty, "fresh disabled startup physically prunes expired existing records")
        check(try Data(contentsOf: marker) == oldMarker, "disabled startup writes no new session marker")
        check(!disabled.isEnabled, "maintenance does not enable recording")

        config.maximumAge = 0.03
        let recent = DiagnosticStore(directory: directory, configuration: config, now: clock.now)
        _ = try recent.setEnabled(true)
        _ = try recent.startSession(UUID())
        try recent.append([makeLine(clock, .lifecycle(.wake))])
        let recentMarker = try Data(contentsOf: marker)
        let disabledTimer = DiagnosticRecorder(directory: directory, storeConfiguration: config, now: clock.now, uptime: clock.uptime)
        disabledTimer.start(enabled: false)
        wait { disabledTimer.setEnabled(false, completion: $0) }
        check(try !files(directory).isEmpty, "disabled startup initially preserves unexpired files")
        clock.advance(0.04)
        let deadline = Date().addingTimeInterval(1)
        while !(try files(directory)).isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        check(try files(directory).isEmpty, "fresh disabled recorder schedules idle expiry for existing files")
        check(try Data(contentsOf: marker) == recentMarker, "disabled expiry preserves existing marker")

        let absent = root.appendingPathComponent("disabled-absent")
        let empty = DiagnosticRecorder(directory: absent)
        empty.start(enabled: false)
        wait { empty.setEnabled(false, completion: $0) }
        check(!FileManager.default.fileExists(atPath: absent.path), "disabled startup does not create absent diagnostic storage")
    }

    private static func partialTailRecovery(_ root: URL) throws {
        let clock = FakeClock(); let directory = root.appendingPathComponent("partial-tail")
        let store = DiagnosticStore(directory: directory, now: clock.now)
        _ = try store.startSession(UUID())
        try store.append([makeLine(clock, .lifecycle(.launch))])
        let file = try files(directory).first!
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile(); handle.write(Data("{partial-interrupted".utf8)); handle.closeFile()
        do {
            try store.append([makeLine(clock, .lifecycle(.wake), sequence: 2)])
            preconditionFailure("uncertain current tail accepted")
        } catch { check((error as? DiagnosticStoreError) == .unsafePath, "uncertain append detected") }
        try store.append([makeLine(clock, .lifecycle(.wake), sequence: 3)])
        try store.append([makeLine(clock, .lifecycle(.sleep), sequence: 4)])
        let recovered = try store.snapshot(since: nil, generation: 1, isEnabled: true)
        check(try events(recovered).count == 3, "writing recovers into a new file after an interrupted tail")
        check(recovered.issues.contains(.corruptedLine), "interrupted tail remains a visible coverage gap")
        check(try files(directory).count == 2, "uncertain file retained and new file used")
    }

    private static func dynamicAggregation(_ root: URL) throws {
        let clock = FakeClock()
        let recorder = DiagnosticRecorder(directory: root.appendingPathComponent("dynamic-aggregation"), now: clock.now, uptime: clock.uptime)
        recorder.start(); wait { recorder.flush(completion: $0) }
        for index in 1...30 {
            recorder.record(.connection(phase: .request, generation: UInt64(index), request: .rateLimitsRead,
                result: .timedOut, durationMilliseconds: index * 10, retryCount: index))
        }
        let result = try events(snapshot(recorder)).filter { if case .connection = $0.event { return true }; return false }
        check(result.count == 2, "changing duration, generation and attempt still aggregate by fixed cause")
        check(result.compactMap(\.repetition).reduce(1) { $0 + $1.count } == 30, "dynamic metadata preserves repetition count")
        recorder.record(.connection(source: .check, phase: .request, request: .rateLimitsRead, result: .timedOut))
        recorder.record(.connection(phase: .request, request: .rateLimitsRead, result: .timedOut, layer: .store))
        let all = try events(snapshot(recorder)).filter { if case .connection = $0.event { return true }; return false }
        check(all.count == 4, "business/check and transport/store never aggregate together")
    }

    private static func idleRetention(_ root: URL) throws {
        let clock = FakeClock(); let directory = root.appendingPathComponent("idle-retention")
        var config = DiagnosticStore.Configuration(); config.maximumAge = 0.03
        let recorder = DiagnosticRecorder(directory: directory, storeConfiguration: config, now: clock.now, uptime: clock.uptime)
        recorder.start(); wait { recorder.flush(completion: $0) }
        check(try !files(directory).isEmpty, "idle deadline starts with retained records")
        wait { recorder.setEnabled(false, completion: $0) }
        clock.advance(0.04)
        let deadline = Date().addingTimeInterval(1)
        while !(try files(directory)).isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        check(try files(directory).isEmpty, "one-shot expiry physically removes records without a new event, even while disabled")
    }

    private static func startupFailure(_ root: URL) throws {
        let directory = root.appendingPathComponent("blocked-startup")
        try Data("blocked".utf8).write(to: directory)
        let clock = FakeClock()
        let recorder = DiagnosticRecorder(directory: directory, now: clock.now, uptime: clock.uptime)
        recorder.start(); wait { recorder.flush(completion: $0) }
        try FileManager.default.removeItem(at: directory)
        for _ in 0..<20 { recorder.record(.lifecycle(.wake)); wait { recorder.flush(completion: $0) } }
        check(!FileManager.default.fileExists(atPath: directory.path), "startup failure honors retry backoff")
        clock.advance(2); wait { recorder.flush(completion: $0) }
        check(FileManager.default.fileExists(atPath: directory.path), "startup retry recovers after backoff")
        check(try snapshot(recorder).issues.contains(.storeUnavailable), "startup failure gap survives recovery")
    }

    private static func clearDuringWrite(_ root: URL) throws {
        let clock = FakeClock(); let gate = WriteGate()
        let recorder = DiagnosticRecorder(directory: root.appendingPathComponent("clear-race"), now: clock.now,
            uptime: clock.uptime, beforeWrite: gate.write)
        recorder.start(); wait { recorder.flush(completion: $0) }
        gate.configure(pause: true)
        recorder.record(.componentFailure(component: .updateProgress, result: .failed))
        check(gate.entered.wait(timeout: .now() + 5) == .success, "clear race writer paused")
        let old = recorder.recordingGeneration
        let snapshotDone = DispatchSemaphore(value: 0)
        var staleSnapshotResult: Result<DiagnosticStoreSnapshot, Error>?
        recorder.captureSnapshot(since: nil) { staleSnapshotResult = $0; snapshotDone.signal() }
        let done = DispatchSemaphore(value: 0)
        recorder.clear { result in if case .failure = result { preconditionFailure("clear race failure") }; done.signal() }
        check(recorder.recordingGeneration > old, "clear invalidates open previews immediately")
        gate.configure(); gate.resume.signal()
        check(done.wait(timeout: .now() + 5) == .success, "clear race completion")
        check(snapshotDone.wait(timeout: .now() + 5) == .success, "old snapshot request completed")
        if case .failure(let error) = staleSnapshotResult! {
            check((error as? DiagnosticStoreError) == .cancelled, "old snapshot cannot inherit clear's new generation")
        } else { preconditionFailure("old snapshot survived generation boundary") }
        let after = try snapshot(recorder)
        check(!(try events(after)).contains { if case .componentFailure(component: .updateProgress, _) = $0.event { return true }; return false },
              "clear does not revive old-generation paused writer")
        check(!after.issues.contains(.writeFailure), "cancelled old write does not pollute new generation")
    }

    private static func oversizedAndTimer(_ root: URL) throws {
        var config = DiagnosticRecorder.Configuration(); config.maximumEventBytes = 64
        let small = DiagnosticRecorder(directory: root.appendingPathComponent("oversized"), configuration: config)
        small.start(); small.record(.lifecycle(.launch))
        check(try snapshot(small).issues.contains(.oversizedEvent), "oversized encoding reported as bounded gap")
        var timerConfig = DiagnosticRecorder.Configuration(); timerConfig.flushDelay = 0.02
        let gate = WriteGate()
        let timer = DiagnosticRecorder(directory: root.appendingPathComponent("timer"), configuration: timerConfig, beforeWrite: gate.write)
        timer.start(); wait { timer.flush(completion: $0) }
        let previous = gate.callCount
        timer.record(.lifecycle(.wake))
        let deadline = Date().addingTimeInterval(1)
        while gate.callCount == previous && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        check(gate.callCount > previous, "normal event flushes on one-shot deadline")
    }

    private static func adversarialCounts(_ root: URL) throws {
        let clock = FakeClock(); let directory = root.appendingPathComponent("adversarial")
        let store = DiagnosticStore(directory: directory, now: clock.now)
        _ = try store.startSession(UUID())
        try store.append([makeLine(clock, .gap(reason: .queueFull, count: Int.max)),
                          makeLine(clock, .gap(reason: .encodingFailure, count: Int.max))])
        check(try store.snapshot(since: nil, generation: 1, isEnabled: true).droppedCount == Int.max,
              "malicious typed gap counts saturate safely")
        let sparse = directory.appendingPathComponent("events-\(UUID().uuidString.lowercased()).jsonl")
        let fd = open(sparse.path, O_CREAT | O_WRONLY, 0o600)
        check(fd >= 0, "create owned sparse file")
        check(ftruncate(fd, 64 * 1024 * 1024) == 0, "sparse oversized evidence")
        close(fd)
        _ = try store.snapshot(since: nil, generation: 1, isEnabled: true)
        check(!FileManager.default.fileExists(atPath: sparse.path), "oversized recognized file physically pruned")
    }

    private static func stagingCleanup(_ root: URL) throws {
        let clock = FakeClock(); let directory = root.appendingPathComponent("staging")
        let staging = directory.appendingPathComponent("export-staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let old = staging.appendingPathComponent("export-\(UUID().uuidString.lowercased()).tmp")
        let fresh = staging.appendingPathComponent("export-\(UUID().uuidString.lowercased()).tmp")
        let unknown = staging.appendingPathComponent("keep.txt")
        for file in [old, fresh, unknown] { try Data("fixture".utf8).write(to: file) }
        try FileManager.default.setAttributes([.modificationDate: clock.now().addingTimeInterval(-7200)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: clock.now()], ofItemAtPath: fresh.path)
        let store = DiagnosticStore(directory: directory, now: clock.now)
        _ = try store.startSession(UUID())
        check(!FileManager.default.fileExists(atPath: old.path), "startup deletes stale owned export material")
        check(FileManager.default.fileExists(atPath: fresh.path), "startup preserves recent export material")
        try store.clear()
        check(!FileManager.default.fileExists(atPath: fresh.path), "clear deletes owned export snapshots")
        check(FileManager.default.fileExists(atPath: unknown.path), "clear preserves unknown staging contents")
    }

    private static func shutdownMarker(_ root: URL) throws {
        let clock = FakeClock(); let directory = root.appendingPathComponent("shutdown")
        let first = DiagnosticStore(directory: directory, now: clock.now)
        check(try !first.startSession(UUID()), "missing marker is unconfirmed, never a crash claim")
        try first.markShutdownConfirmed()
        let second = DiagnosticStore(directory: directory, now: clock.now)
        check(try second.startSession(UUID()), "completed orderly request marker recognized")
        let third = DiagnosticStore(directory: directory, now: clock.now)
        check(try !third.startSession(UUID()), "new session marks normal ending unconfirmed")
    }
}
