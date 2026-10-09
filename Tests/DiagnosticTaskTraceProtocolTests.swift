import Foundation
import Darwin

private final class TraceCapture: DiagnosticRecording {
    private let lock = NSLock()
    private var state = DiagnosticTaskTraceState(enabled: true, generation: 1, sessionID: UUID())
    private var values: [DiagnosticEvent] = []
    var invalidateNextAdmission = false
    var taskTraceState: DiagnosticTaskTraceState { lock.lock(); defer { lock.unlock() }; return state }
    func change(enabled: Bool = true, newSession: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        state = .init(enabled: enabled, generation: state.generation + 1, sessionID: newSession ? UUID() : state.sessionID)
    }
    func record(_ event: DiagnosticEvent) { record(event, expectedGeneration: taskTraceState.generation) }
    func record(_ event: DiagnosticEvent, expectedGeneration: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if invalidateNextAdmission {
            invalidateNextAdmission = false
            state = .init(enabled: true, generation: state.generation + 1, sessionID: state.sessionID)
        }
        guard state.enabled, state.generation == expectedGeneration else { return }
        values.append(event)
    }
    var events: [DiagnosticEvent] { lock.lock(); defer { lock.unlock() }; return values }
    var traces: [DiagnosticTaskTraceEvent] { events.compactMap { if case .taskTrace(let value) = $0 { return value }; return nil } }
}

@main
enum DiagnosticTaskTraceProtocolTests {
    static var checks = 0
    static let context = DiagnosticTaskTraceContext(monitoringGeneration: 10, batch: 100)
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        let value = try condition(); precondition(value, message); checks += 1
    }
    static func identity(_ trace: DiagnosticTaskTrace, _ key: String, turn: String? = nil, file: String? = nil) -> DiagnosticTaskTraceIdentity {
        guard let value = trace.identity(taskKey: key, turnKey: turn, fileKey: file, kind: .file, correlation: .fileOnly, context: context) else {
            preconditionFailure("fixture identity unexpectedly unavailable")
        }
        return value
    }
    static func main() throws {
        try privacyAndGenerations()
        try mappingBounds()
        try snapshotsAndIntegrity()
        try consumptionAndAdmission()
        try normalBoundariesAndIdle()
        try storedRebuilding()
        print("DiagnosticTaskTraceProtocolTests: \(checks) checks passed")
    }
    static func privacyAndGenerations() throws {
        let capture = TraceCapture(); let trace = DiagnosticTaskTrace(recorder: capture)
        let rawTask = "/Users/private/raw-task-9aef"
        let rawTurn = "raw-turn-credential-6dfa"
        let rawFile = rawTask + "-inode-987654"
        let first = identity(trace, rawTask, turn: rawTurn, file: rawFile)
        check(first == identity(trace, rawTask, turn: rawTurn, file: rawFile), "same raw keys stable within session and clear generation")
        check(first.identityKind == .file && first.correlation == .fileOnly, "file identity is not claimed to be a confirmed chat")
        check(capture.traces.count == 1, "stable identity lookup adds no event")
        let newTurn = identity(trace, rawTask, turn: "other-private-turn", file: rawFile)
        check(newTurn.taskAlias == first.taskAlias && newTurn.turnAlias != first.turnAlias && newTurn.fileGeneration == first.fileGeneration, "turn change preserves task and file")
        let rotated = identity(trace, rawTask, turn: "other-private-turn", file: rawFile + "-rotation")
        check(rotated.taskAlias == first.taskAlias && rotated.fileGeneration != first.fileGeneration, "file generation random and independent")
        check(capture.traces.count == 3, "turn and file changes each emit retained identity metadata")
        let encoded = try DiagnosticEventEnvelope.encoder().encode(capture.events)
        let text = String(decoding: encoded, as: UTF8.self)
        for forbidden in [rawTask, rawTurn, rawFile, "inode", "credential", "private", "other-private-turn"] {
            check(!text.contains(forbidden), "raw identity or path never encoded")
        }
        capture.change()
        let cleared = identity(trace, rawTask, turn: rawTurn, file: rawFile)
        check(cleared.domain != first.domain && cleared.taskAlias != first.taskAlias && cleared.turnAlias != first.turnAlias, "clear gets a new anonymous domain")
        let eventCount = capture.events.count
        trace.member(context: context, identity: first, countedBefore: true, countedAfter: false, reason: .readBudgetSkip)
        check(capture.events.count == eventCount, "old identity cannot enter new clear generation")
        capture.change(newSession: true)
        let restarted = identity(trace, rawTask)
        check(restarted.domain != cleared.domain && restarted.taskAlias != cleared.taskAlias, "restart never persists raw identity correlation")
        capture.change(enabled: false)
        let before = trace.mappedAliasCount
        check(trace.identity(taskKey: "disabled-never-store", kind: .thread, context: context) == nil, "disabled identity lookup refused")
        check(trace.mappedAliasCount == before && !trace.isEnabled, "disabled lookup allocates no mapping")
        let noop = DiagnosticTaskTrace(recorder: NoopDiagnosticRecorder())
        check(!noop.isEnabled && noop.mappedAliasCount == 0, "default no-op trace disabled")
    }
    static func mappingBounds() throws {
        let capture = TraceCapture(); let trace = DiagnosticTaskTrace(recorder: capture, maximumAliases: 3)
        let a = identity(trace, "A"); let b = identity(trace, "B"); let c = identity(trace, "C")
        check(trace.identity(taskKey: "D", kind: .file, context: context) == nil && trace.mappedAliasCount == 3, "current inventory retained when mapping full")
        let count = capture.events.count
        _ = trace.identity(taskKey: "D", kind: .file, context: context)
        check(capture.events.count == count, "repeated map capacity warnings bounded")
        trace.retire(taskKey: "A", kind: .file, context: context)
        let d = identity(trace, "D")
        check(trace.mappedAliasCount == 3 && d.taskAlias != a.taskAlias, "evicted alias never reused for another task")
        check(identity(trace, "B").taskAlias == b.taskAlias && identity(trace, "C").taskAlias == c.taskAlias, "current identities protected ahead of retired identities")
        trace.retire(taskKey: "B", kind: .file, context: context)
        let again = identity(trace, "A")
        check(again.taskAlias != a.taskAlias && again.correlation == .discontinuous, "reappearing evicted task gets new alias and discontinuity")
        let single = DiagnosticTaskTrace(recorder: TraceCapture(), maximumAliases: 1)
        for index in 0..<70 {
            _ = identity(single, "item-\(index)")
            single.retire(taskKey: "item-\(index)", kind: .file, context: context)
        }
        check(identity(single, "item-0").correlation == .discontinuous, "expired tombstones never imply certain fresh identity")
        let full = DiagnosticTaskTrace(recorder: TraceCapture(), maximumAliases: 9000)
        for index in 0..<4096 { _ = identity(full, "bounded-\(index)") }
        check(full.mappedAliasCount == 4096, "hard mapping maximum is 4096")
        check(full.identity(taskKey: "over-limit", kind: .file, context: context) == nil, "caller cannot enlarge hard map budget")
        let tooLong = String(repeating: "x", count: 2049)
        check(full.identity(taskKey: tooLong, kind: .thread, context: context) == nil, "single raw identity memory bounded")
    }
    static func snapshotsAndIntegrity() throws {
        let capture = TraceCapture(); let trace = DiagnosticTaskTrace(recorder: capture)
        let identities = (0..<17).map { identity(trace, "task-\($0)", turn: "turn-\($0)", file: "file-\($0)") }
        let members = identities.map { DiagnosticTaskSnapshotMember(identity: $0, phase: .running, counted: true) }
        let first = trace.snapshot(context: context, members: members, runningCount: 17, unknownCount: 0)!
        check(first.memberCount == 17 && first.memberPageCount == 3, "large membership split into bounded pages")
        check(DiagnosticTaskSnapshotIntegrity.inspect(reference: first, events: capture.traces).complete, "all pages and checkpoint verify complete")
        let count = capture.events.count
        let nextBatch = DiagnosticTaskTraceContext(monitoringGeneration: 10, batch: 101)
        let same = trace.snapshot(context: nextBatch, members: members.reversed(), runningCount: 17, unknownCount: 0)!
        check(same == first && capture.events.count == count, "stable members ignore ordering and idle batch changes")
        var replacement = members
        let other = identity(trace, "replacement", turn: "replacement-turn", file: "replacement-file")
        replacement[0] = .init(identity: other, phase: .running, counted: true)
        let second = trace.snapshot(context: nextBatch, members: replacement, runningCount: 17, unknownCount: 0)!
        check(second.snapshotID != first.snapshotID && second.runningCount == first.runningCount, "same total with changed members produces new snapshot")
        check(second.previousSnapshotID == first.snapshotID, "snapshot chain points to prior membership checkpoint")
        let presentation = trace.snapshot(context: nextBatch, members: replacement, runningCount: 17, unknownCount: 0, presentation: .completedFeedback)!
        check(presentation.snapshotID != second.snapshotID, "presentation change gets separate snapshot")
        let restarted = trace.snapshot(context: .init(monitoringGeneration: 11, batch: 1), members: replacement, runningCount: 17, unknownCount: 0)!
        check(restarted.previousSnapshotID == nil && restarted.monitoringGeneration == 11, "monitor restart begins independent checkpoint chain")

        for event in capture.events {
            let envelope = DiagnosticEventEnvelope(timestamp: Date(), sessionID: UUID(), sequence: UInt64.max,
                monotonicMilliseconds: UInt64.max, event: event, updateSessionID: UUID(), writerRole: .newHUD,
                eventID: .init(sessionID: UUID(), sequence: UInt64.max),
                processIdentity: .init(version: .init(rawValue: "99999999.99999999.99999999.99999999"), build: .init(rawValue: "9999999999999999")),
                upgradeSourceIdentity: .init(version: .init(rawValue: "99999999.99999999.99999999.99999999"), build: .init(rawValue: "9999999999999999")),
                upgradeTargetIdentity: .init(version: .init(rawValue: "99999999.99999999.99999999.99999999"), build: .init(rawValue: "9999999999999999")))
            try check(DiagnosticEventEnvelope.encoder().encode(envelope).count + 1 < 4096, "worst-envelope trace event strictly below 4KiB")
        }
        var withoutPage = capture.traces
        withoutPage.removeAll { if case .snapshotMembers(let ref, let page, _) = $0 { return ref.snapshotID == first.snapshotID && page == 1 }; return false }
        check(!DiagnosticTaskSnapshotIntegrity.inspect(reference: first, events: withoutPage).complete, "missing page never becomes a complete member list")
        var withoutCheckpoint = capture.traces
        withoutCheckpoint.removeAll { if case .snapshotCheckpoint(let ref, _) = $0 { return ref.snapshotID == first.snapshotID }; return false }
        check(DiagnosticTaskSnapshotIntegrity.inspect(reference: first, events: withoutCheckpoint).reason == .checkpointMissing, "missing terminal checkpoint explained")
        var duplicated = capture.traces
        let page = duplicated.first { if case .snapshotMembers(let ref, _, _) = $0 { return ref.snapshotID == first.snapshotID }; return false }!
        duplicated.append(page)
        check(DiagnosticTaskSnapshotIntegrity.inspect(reference: first, events: duplicated).reason == .duplicatePages, "duplicate pages are not silently treated complete")
        let incomplete = trace.snapshot(context: nextBatch, members: replacement, runningCount: 18, unknownCount: 0)!
        check(!incomplete.membershipComplete && !DiagnosticTaskSnapshotIntegrity.inspect(reference: incomplete, events: capture.traces).complete, "member total mismatch retains production count and declares evidence incomplete")
    }
    static func consumptionAndAdmission() throws {
        let capture = TraceCapture(); let producer = DiagnosticTaskTrace(recorder: capture)
        let item = identity(producer, "safe-consumption")
        let reference = producer.snapshot(context: context, members: [.init(identity: item, phase: .running, counted: true)], runningCount: 1, unknownCount: 0)!
        let consumer = DiagnosticTaskTrace(recorder: capture)
        let observation = DiagnosticTaskConsumption(surface: .touchBar, action: .received, logicalTaskCount: 1,
            presentation: .running, compactRule: .exact, reason: .update, consumer: .touchBarPersistent)
        let count = capture.events.count
        consumer.consume(reference: reference, observation: observation)
        check(capture.events.count == count + 1 && consumer.mappedAliasCount == 0, "separate UI adapter consumes same safe reference without allocating map")
        capture.change()
        consumer.consume(reference: reference, observation: observation)
        check(capture.events.count == count + 1, "clear invalidates prior UI references")
        let raceCapture = TraceCapture(); let raceTrace = DiagnosticTaskTrace(recorder: raceCapture)
        raceCapture.invalidateNextAdmission = true
        _ = identity(raceTrace, "admission-race")
        check(raceCapture.events.isEmpty, "generation checked again at event admission")
        let current = identity(raceTrace, "admission-race")
        check(raceCapture.events.count == 1 && current.domain != reference.domain, "race recovers in new alias domain")
        let observedState = raceCapture.taskTraceState
        let oldRead = DiagnosticTaskTraceContext(monitoringGeneration: 20, batch: 30,
            recordingGeneration: observedState.generation, recordingSessionID: observedState.sessionID)
        raceCapture.change()
        let countBefore = raceCapture.events.count
        let aliasesBefore = raceTrace.mappedAliasCount
        check(raceTrace.identity(taskKey: "arrived-after-clear", kind: .thread, context: oldRead) == nil, "stale read context rejected before alias allocation")
        raceTrace.read(context: oldRead, identity: current, metrics: .init(readBytes: 30))
        raceTrace.lifecycle(context: oldRead, identity: current, transition: .init(before: .running, after: .unknown,
            evidence: .execution, accepted: false, reason: .missingStartEvidence))
        raceTrace.member(context: oldRead, identity: current, countedBefore: true, countedAfter: false, reason: .readBudgetSkip)
        raceTrace.discovery(context: oldRead, observation: .init(scope: .latestRollouts, queryLimit: 32, coverage: .limited))
        check(raceTrace.snapshot(context: oldRead, members: [], runningCount: 0, unknownCount: 0) == nil, "stale production result cannot create snapshot")
        check(raceTrace.mappedAliasCount == aliasesBefore && raceCapture.events.count == countBefore, "all stale observation kinds allocate and emit nothing")

    }
    static func normalBoundariesAndIdle() throws {
        let capture = TraceCapture(); let trace = DiagnosticTaskTrace(recorder: capture)
        let item = identity(trace, "normal-reader")
        let before = capture.events.count
        trace.read(context: context, identity: item, metrics: .init(readBytes: 0))
        check(capture.events.count == before, "idle zero-byte normal reads suppressed")
        for size: UInt64 in [262143, 262144, 262145, 601826, 2 * 1024 * 1024] {
            trace.read(context: context, identity: item, metrics: .init(fileBytes: size, offsetBefore: 0, offsetAfter: size, readBytes: size))
        }
        let metrics = capture.traces.compactMap { value -> DiagnosticTaskReadMetrics? in if case .read(_, _, let metrics) = value { return metrics }; return nil }
        check(metrics.map(\.readBytes) == [262143, 262144, 262145, 601826, 2097152], "normal boundary byte observations preserved exactly")
        let discovery = DiagnosticTaskDiscovery(scope: .latestRollouts, queryLimit: 32, returnedRows: 32, acceptedRows: 31,
            rejectedPaths: 1, traversalComplete: true, coverage: .limited)
        trace.discovery(context: context, observation: discovery)
        let count = capture.events.count
        trace.discovery(context: .init(monitoringGeneration: 10, batch: 102), observation: discovery)
        check(capture.events.count == count, "same discovery coverage does not log on every idle poll")
        trace.discovery(context: .init(monitoringGeneration: 11, batch: 103), observation: discovery)
        check(capture.events.count == count + 1, "new monitor generation reestablishes discovery evidence")
        check(discovery.sourceFilteredRows == nil && discovery.coverage == .limited, "unobserved exclusions remain unknown; SQL done does not imply complete inventory")
    }
    static func storedRebuilding() throws {
        var canonical = [CChar](repeating: 0, count: Int(PATH_MAX))
        precondition(realpath(FileManager.default.temporaryDirectory.path, &canonical) != nil)
        let directory = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent("trace-protocol-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticStore(directory: directory); _ = try store.startSession(UUID())
        let capture = TraceCapture(); let trace = DiagnosticTaskTrace(recorder: capture)
        _ = identity(trace, "/Users/raw-private-path")
        var line = try DiagnosticEventEnvelope.encoder().encode(DiagnosticEventEnvelope(timestamp: Date(), sessionID: UUID(),
            sequence: 1, monotonicMilliseconds: 0, event: capture.events[0]))
        var object = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        object["rawPath"] = "/Users/secret-path"
        line = try JSONSerialization.data(withJSONObject: object); line.append(10)
        try store.append([line])
        let snapshot = try store.snapshot(since: nil, generation: 1, isEnabled: true)
        let text = String(decoding: snapshot.eventsData, as: UTF8.self)
        check(!text.contains("secret") && !text.contains("rawPath") && !text.contains("raw-private"), "safe store rebuilding strips all unknown fields")
        try check(DiagnosticEventEnvelope.decoder().decode(DiagnosticEventEnvelope.self, from: Data(snapshot.eventsData.dropLast())).event.module == "task", "task trace survives validated store roundtrip")
        let invalid = DiagnosticTaskDiscovery(queryLimit: -1)
        check(!DiagnosticTaskTraceEvent.discovery(context: context, observation: invalid).isValid, "negative typed counts invalid")
    }
}
