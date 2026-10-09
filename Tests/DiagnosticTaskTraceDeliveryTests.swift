import Foundation
import SQLite3
import HookCore

private final class DeliveryTraceCapture: DiagnosticRecording {
    var taskTraceState = DiagnosticTaskTraceState(enabled: true, generation: 1, sessionID: UUID())
    private(set) var events: [DiagnosticEvent] = []
    func record(_ event: DiagnosticEvent) { record(event, expectedGeneration: taskTraceState.generation) }
    func record(_ event: DiagnosticEvent, expectedGeneration: UInt64) {
        guard taskTraceState.enabled, taskTraceState.generation == expectedGeneration else { return }
        events.append(event)
    }
    var consumptions: [(DiagnosticTaskSnapshotReference, DiagnosticTaskConsumption)] {
        events.compactMap {
            if case let .taskTrace(.consumption(reference, observation)) = $0 { return (reference, observation) }
            return nil
        }
    }
}

/// The first scenario uses a real SQLite/rollout source and production coordinator/UI consumers.
/// Only its missing-delivery callback is fault-injected. It is not a task-count truth fixture.
#if !DIAGNOSTIC_TRACE_BUNDLE
@main
#endif
enum DiagnosticTaskTraceDeliveryTests {
    private static var checks = 0
    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        let value = try condition(); precondition(value, message); checks += 1
    }

    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/td-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try missingDelivery(root: root)
        actualConsumptionAndReferenceGate()
        try typedObservationGaps(root: root)
        try gapOnlyExport(root: root)
        print("PASS: \(checks) task trace delivery checks (missing delivery uses controlled callback fault injection)")
    }

    private static func missingDelivery(root: URL) throws {
        let harness = try TracePipelineHarness(root: root.appendingPathComponent("flow"))
        let file = try fixture(home: harness.home)
        harness.start(hooks: true)
        defer { harness.stop(); harness.pump(0.05) }
        var observedGeneration: UInt64?
        let delivery = harness.hooks.onTraceDelivery
        harness.hooks.onTraceDelivery = { generation, sequence, delivered in
            observedGeneration = generation
            delivery?(generation, sequence, delivered)
        }
        harness.pump(0.2)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let event: [String: Any] = ["timestamp": formatter.string(from: Date()), "type": "event_msg",
            "payload": ["type": "task_started", "turn_id": "PRIVATE_DELIVERY_TURN"]]
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: event) + Data([10]))
        try handle.close()
        let deadline = Date().addingTimeInterval(4)
        while (harness.latest?.activity?.confirmedRunningCount != 1 || harness.latest?.diagnosticSnapshot?.membershipComplete != true)
                && Date() < deadline { harness.pump(0.02) }
        check(harness.latest?.activity?.confirmedRunningCount == 1, "Real Hook source establishes an actual running task")
        let old = try require(harness.latest?.diagnosticSnapshot, "Real source must deliver a snapshot reference")
        check(old.runningCount == 1 && old.membershipComplete, "Old reference describes the real source's counted member")
        check(harness.coordinator.currentDiagnosticSnapshot == old, "Coordinator accepts the same production snapshot")
        check(harness.state.taskTrace.reference == old, "Actual consumer state receives the old reference before fault injection")
        let generation = try require(observedGeneration, "At least one real Hook trace delivery must precede injection")
        let exported = try harness.export(name: "delivery-established")
        let zeroConsumptions = exported.events.compactMap { envelope -> DiagnosticTaskConsumption? in
            guard case let .taskTrace(.consumption(reference, observation)) = envelope.event,
                  reference.runningCount == 0, observation.consumer == .coordinator else { return nil }
            return observation
        }
        check(!zeroConsumptions.isEmpty, "Initial unavailable boundary has an actual coordinator observation")
        check(zeroConsumptions.allSatisfy { $0.presentation == .unknown }, "Zero count alone never invents neutral coordinator presentation")
        let zeroPresentations = exported.events.compactMap { envelope -> DiagnosticTaskPresentation? in
            if case .taskTrace(.snapshot(let reference, let presentation)) = envelope.event, reference.runningCount == 0 { return presentation }
            return nil
        }
        check(!zeroPresentations.isEmpty && zeroPresentations.allSatisfy { $0 == .unknown },
              "Actual startup Hook snapshot preserves unknown coverage instead of deriving neutral from zero")
        check(exported.events.contains {
            if case let .taskTrace(.consumption(reference, observation)) = $0.event {
                return reference.snapshotID == old.snapshotID && observation.consumer == .main && observation.logicalTaskCount == 1
            }
            return false
        }, "Real source reaches the main display consumer before injecting a delivery failure")

        // Unknown sequence simulates a mailbox entry lost to its fixed-capacity eviction.
        // These callbacks do not run the reducer or claim a production count transition.
        harness.hooks.onTraceDelivery?(generation, UInt64.max, true)
        check(harness.coordinator.currentDiagnosticSnapshot == nil, "Missing accepted delivery clears the coordinator reference")
        check(harness.latest?.diagnosticSnapshot == nil, "Optional side channel clears the app's existing summary reference")
        harness.render(reason: .quotaRefresh)
        check(harness.state.taskTrace.reference == nil, "Quota refresh cannot resurrect the old fallback reference")
        let deliveries = harness.deliveries
        harness.hooks.onUpdate?(TaskActivitySnapshot(confirmedRunningCount: 0,
            sourceHealth: [HookSourceHealth(state: .connected)]))
        check(harness.deliveries == deliveries + 1, "Missing diagnostics do not suppress the independent business callback")
        check(harness.latest?.activity?.confirmedRunningCount == 0, "Injected business callback retains its supplied count")
        check(harness.latest?.diagnosticSnapshot == nil, "New business summary cannot borrow the preceding reference")
        check(harness.state.taskTrace.reference == nil && harness.state.taskStatus?.diagnosticSnapshot == nil,
              "Neither consumer reference path can label new state with the old snapshot")
        harness.render(reason: .layoutRefresh)
        check(harness.state.taskTrace.reference == nil, "Subsequent layout refresh preserves missing-delivery evidence")
    }

    private static func actualConsumptionAndReferenceGate() {
        let capture = DeliveryTraceCapture()
        let producer = DiagnosticTaskTrace(recorder: capture)
        let context = DiagnosticTaskTraceContext(monitoringGeneration: 1, batch: 1)
        let identity = producer.identity(taskKey: "PRIVATE_UNIT_TASK", kind: .file, context: context)!
        let reference = producer.snapshot(context: context, members: [.init(identity: identity, phase: .running, counted: true)],
            runningCount: 1, unknownCount: 0)!
        let consumer = DiagnosticTaskDisplayObserver(capture, surface: .main, consumer: .main)
        var state = RateLimitDisplayState.initial
        state.taskTrace = .init(reference: reference)
        state.taskStatus = TaskStatusSummary(activity: TaskActivitySnapshot(confirmedRunningCount: 3), runningCount: 99)
        consumer.record(state, action: .received)
        check(capture.consumptions.last?.1.logicalTaskCount == 3, "Hooks consumption count comes from actual activity, not reference or legacy fallback")
        check(capture.consumptions.last?.1.reason == .snapshotMismatch, "Mismatched reference is an explicit closed reason")
        state.taskStatus = TaskStatusSummary(runningCount: 2)
        consumer.record(state, action: .renderRequested)
        check(capture.consumptions.last?.1.logicalTaskCount == 2, "Legacy consumption independently uses its actual count")
        check(capture.consumptions.last?.1.reason == .snapshotMismatch, "Legacy mismatch cannot claim an ordinary render association")
        state.taskStatus = TaskStatusSummary(runningCount: 1)
        consumer.record(state, action: .received)
        check(capture.consumptions.last?.1.reason == .update, "Matching state preserves the real consumption reason")
        state.taskTrace.tasksEnabled = false
        state.taskStatus = nil
        consumer.record(state, action: .received)
        check(capture.consumptions.last?.1.logicalTaskCount == 0 && capture.consumptions.last?.1.presentation == .disabled,
              "Disabled task UI reports its actual empty state")
        check(capture.consumptions.last?.1.reason != .snapshotMismatch, "Intentionally disabled UI is not a false count mismatch")
        let count = capture.consumptions.count
        let original = capture.taskTraceState
        capture.taskTraceState = .init(enabled: true, generation: original.generation + 1, sessionID: original.sessionID)
        state.taskTrace.tasksEnabled = true; state.taskStatus = TaskStatusSummary(runningCount: 1)
        consumer.record(state, action: .received)
        check(capture.consumptions.count == count, "Clear generation refuses every old UI reference")
        capture.taskTraceState = .init(enabled: true, generation: original.generation, sessionID: UUID())
        consumer.record(state, action: .renderRequested)
        check(capture.consumptions.count == count, "Different session refuses a reference even with equal numeric generation")
        capture.taskTraceState = .init(enabled: false, generation: original.generation, sessionID: original.sessionID)
        consumer.record(state, action: .received)
        check(capture.consumptions.count == count, "Disabled recording refuses otherwise valid UI references")
    }

    private static func typedObservationGaps(root: URL) throws {
        let capture = DeliveryTraceCapture(); let producer = DiagnosticTaskTrace(recorder: capture)
        let gate = capture.taskTraceState
        let context = DiagnosticTaskTraceContext(monitoringGeneration: 4, batch: 9,
            recordingGeneration: gate.generation, recordingSessionID: gate.sessionID)
        producer.observationGap(context: context, droppedCount: 0, reason: .producerBufferLimit)
        check(capture.events.isEmpty, "Zero producer drops allocate no diagnostic event")
        producer.observationGap(context: context, droppedCount: 7, reason: .producerBufferLimit)
        producer.observationGap(context: context, droppedCount: 32, reason: .deliveryBufferLimit)
        check(capture.events.count == 2, "Producer and delivery drops have distinct typed events")
        for (event, expectedCount, expectedReason) in [(capture.events[0], UInt64(7), DiagnosticTaskObservationGapReason.producerBufferLimit),
                                                      (capture.events[1], UInt64(32), .deliveryBufferLimit)] {
            let data = try DiagnosticEventEnvelope.encoder().encode(event)
            let decoded = try DiagnosticEventEnvelope.decoder().decode(DiagnosticEvent.self, from: data)
            guard case let .taskTrace(.observationGap(decodedContext, count, reason)) = decoded else { preconditionFailure("Typed gap did not decode") }
            check(decodedContext == context && count == expectedCount && reason == expectedReason, "Typed gap preserves exact count, context and closed reason")
            check(data.count < 4096 && !String(decoding: data, as: UTF8.self).contains("PRIVATE_"), "Gap remains bounded and contains no raw fixture identity")
        }
        check(!DiagnosticTaskTraceEvent.observationGap(context: context, droppedCount: 0, reason: .deliveryBufferLimit).isValid,
              "Stored zero-count gaps fail safe event validation")
        capture.taskTraceState = .init(enabled: true, generation: gate.generation + 1, sessionID: gate.sessionID)
        producer.observationGap(context: context, droppedCount: 12, reason: .producerBufferLimit)
        check(capture.events.count == 2, "Old producer context cannot report a gap after clear")

        let store = DiagnosticStore(directory: root.appendingPathComponent("gaps"))
        let session = UUID(); _ = try store.startSession(session)
        var lines: [Data] = []
        for (index, event) in (capture.events + [.taskTrace(.observationGap(context: context, droppedCount: 0, reason: .producerBufferLimit))]).enumerated() {
            let envelope = DiagnosticEventEnvelope(timestamp: Date(), sessionID: session, sequence: UInt64(index + 1),
                monotonicMilliseconds: 0, event: event)
            let encoded = try DiagnosticEventEnvelope.encoder().encode(envelope)
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            object["rawPath"] = "/PRIVATE_GAP_PATH"
            lines.append(try JSONSerialization.data(withJSONObject: object) + Data([10]))
        }
        // Future/unknown reasons must fail decoding rather than accepting arbitrary string payloads.
        let unknown = String(decoding: lines[0], as: UTF8.self).replacingOccurrences(of: "producerBufferLimit", with: "PRIVATE_UNKNOWN_REASON")
        lines.append(Data(unknown.utf8))
        try store.append(lines)
        let snapshot = try store.snapshot(since: nil, generation: 1, isEnabled: true)
        let decoded = try snapshot.eventsData.split(separator: 10).map { try DiagnosticEventEnvelope.decoder().decode(DiagnosticEventEnvelope.self, from: Data($0)) }
        let gaps = decoded.compactMap { envelope -> UInt64? in
            if case let .taskTrace(.observationGap(_, count, _)) = envelope.event { return count }; return nil
        }
        check(gaps.sorted() == [7, 32], "Safe storage retains only positive, known typed drop records")
        let bytes = String(decoding: snapshot.eventsData, as: UTF8.self)
        check(!bytes.contains("PRIVATE_") && !bytes.contains("rawPath"), "Safe reconstruction strips unknown envelope fields and unknown reason text")
        check(!snapshot.gaps.isEmpty, "Rejected stored trace records produce an explicit export gap")
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { preconditionFailure(message) }; checks += 1; return value
    }
    private static func gapOnlyExport(root: URL) throws {
        let harness = try TracePipelineHarness(root: root.appendingPathComponent("gap-only"))
        let trace = DiagnosticTaskTrace(recorder: harness.recorder)
        trace.observationGap(context: .init(monitoringGeneration: 1, batch: 1), droppedCount: 32, reason: .deliveryBufferLimit)
        let exported = try harness.export(name: "gap-only")
        let manifest = try JSONSerialization.jsonObject(with: TracePipelineHarness.extract(exported.zip, member: "manifest.json")) as! [String: Any]
        let coverage = manifest["taskTraceCoverage"] as! [String: Any]
        check((coverage["snapshots"] as? [Any])?.isEmpty == true, "Fixture deliberately contains no snapshot")
        check(coverage["eventCount"] as? Int == 1 && coverage["deliveryEvidenceIncomplete"] as? Bool == true,
              "Frozen gap-only export preserves explicit delivery loss")
        check(manifest["coverageIncomplete"] as? Bool == true && exported.snapshot.hasGaps,
              "Absence of snapshots cannot turn a recorded delivery gap into complete coverage")
        let summary = try TracePipelineHarness.extract(exported.zip, member: "summary.txt")
        check(String(decoding: summary, as: UTF8.self).contains("deliveryBufferLimit"), "Gap-only summary explains the actual loss reason")
    }
    private static func fixture(home: URL) throws -> URL {
        let session = "PRIVATE_DELIVERY_SESSION"
        let file = home.appendingPathComponent("sessions/" + session + ".jsonl")
        let header: [String: Any] = ["type": "session_meta", "payload": ["id": session, "source": "vscode"]]
        try (JSONSerialization.data(withJSONObject: header) + Data([10])).write(to: file)
        var db: OpaquePointer?
        precondition(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, source TEXT, archived INT, updated_at INT)", nil, nil, nil) == SQLITE_OK)
        var statement: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, "INSERT INTO threads VALUES (?,?,'vscode',0,?)", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        precondition(sqlite3_bind_text(statement, 1, session, -1, transient) == SQLITE_OK)
        precondition(sqlite3_bind_text(statement, 2, file.path, -1, transient) == SQLITE_OK)
        precondition(sqlite3_bind_int64(statement, 3, Int64(Date().timeIntervalSince1970)) == SQLITE_OK)
        precondition(sqlite3_step(statement) == SQLITE_DONE)
        return file
    }
}
