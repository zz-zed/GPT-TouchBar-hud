import AppKit
import SQLite3

private final class TraceUnavailablePresenter: SystemTouchBarPresenting {
    let isAvailable = false
    func present(_ touchBar: NSTouchBar) { preconditionFailure("Test must never present hardware UI") }
    func dismiss(_ touchBar: NSTouchBar) {}
}

#if !DIAGNOSTIC_TRACE_BUNDLE
@main
#endif
enum DiagnosticTaskTraceDisplayTests {
    private static var checks = 0
    private static func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/diagnostic-task-trace-tests/display-" + UUID().uuidString)
        let harness = try TracePipelineHarness(root: root)
        var db: OpaquePointer?
        check(sqlite3_open(harness.home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK, "Isolated index")
        check(sqlite3_exec(db, "CREATE TABLE threads(rollout_path TEXT,source TEXT,archived INTEGER,updated_at INTEGER)", nil, nil, nil) == SQLITE_OK, "Fixture schema")
        var paths: [URL] = []
        for i in 0..<10 {
            let path = harness.home.appendingPathComponent("sessions/fixture-\(i).jsonl"); paths.append(path)
            try Data().write(to: path)
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO threads VALUES (?,'cli',0,1)", -1, &statement, nil)
            sqlite3_bind_text(statement, 1, path.path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            check(sqlite3_step(statement) == SQLITE_DONE, "Fixture row"); sqlite3_finalize(statement)
        }
        sqlite3_close(db)
        harness.start(hooks: false); harness.pump()
        for path in paths { try append("task_started", to: path) }; harness.pump()
        check(harness.latest?.runningCount == 10, "Real pipeline reaches ten running tasks")
        let runningReference = harness.latest!.diagnosticSnapshot!
        harness.render(); harness.render()
        let beforeIdle = try harness.export(name: "before-idle")
        harness.pump(0.4)
        let afterIdle = try harness.export(name: "after-idle")
        check(beforeIdle.events.count == afterIdle.events.count, "Stable real timer polling adds no records")

        let hidden = CompactHUDViewController(initialAppearance: .load(), onRefresh: {}, onClose: {},
            onPresentTouchBar: { false }, contextMenuProvider: { NSMenu() }, diagnostics: harness.recorder)
        hidden.update(with: harness.state)
        let panel = NSPanel(contentViewController: hidden)
        panel.orderOut(nil)
        hidden.update(with: harness.state)
        let suite = "task-trace-ui-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistent = PersistentTouchBarController(presenter: TraceUnavailablePresenter(), defaults: defaults,
            notifications: NotificationCenter(), diagnostics: harness.recorder)
        persistent.update(with: harness.state)
        let legacyNotch = LegacyNotchHUDController(diagnostics: harness.recorder)
        legacyNotch.update(harness.state)
        harness.tasksEnabled = false; harness.render(reason: .disabled)
        harness.tasksEnabled = true; harness.render(reason: .layoutRefresh)
        for path in paths { try append("task_complete", to: path) }; harness.pump()
        let completionReference = harness.latest!.diagnosticSnapshot!
        harness.pump(TaskCompletionFeedbackController.duration + 0.3)
        let completed = try harness.export(name: "display-controls")
        let observations = completed.events.compactMap { value -> (DiagnosticTaskSnapshotReference, DiagnosticTaskConsumption)? in
            if case .taskTrace(.consumption(let reference, let observation)) = value.event { return (reference, observation) }; return nil
        }
        check(observations.contains { $0.0 == runningReference && $0.1.consumer == .touchBarPersistent && $0.1.logicalTaskCount == 10 && $0.1.compactRule == .ninePlus }, "Actual Touch Bar uses compact 9+ while logical count stays ten")
        check(observations.contains { $0.0 == runningReference && $0.1.consumer == .notchIsland && $0.1.compactRule == .exact }, "Legacy-source notch keeps exact ten, does not falsely claim 9+")
        check(observations.contains { $0.1.consumer == .floatingController && $0.1.reason == .notLoaded }, "Unloaded floating controller skips without forcing a window")
        check(observations.contains { $0.1.consumer == .floatingController && $0.1.reason == .hidden }, "Hidden floating controller records its actual skip")
        check(observations.contains { $0.1.consumer == .touchBarPersistent && $0.1.reason == .noInterface && $0.1.action == .skipped }, "Unavailable Touch Bar interface is not a render success")
        check(observations.contains { $0.1.consumer == .notchLegacy && $0.1.action == .received }, "Legacy notch records actual consumption")
        check(observations.contains { $0.0 == runningReference && $0.1.presentation == .disabled }, "Display-disabled presentation preserves prior source snapshot")
        check(observations.contains { $0.0 == completionReference && $0.1.action == .presentationRevised
            && $0.1.reason == .completionFeedbackExpired && $0.1.presentationRevision > 0 }, "Real completion timer revises presentation without inventing a source snapshot")
        check(!panel.isVisible && !legacyNotch.panel.isVisible, "No diagnostic test forced hidden windows visible")
        harness.stop(); harness.pump(0.1)
        let baseline = try harness.export(name: "before-gap")
        try verifyMissingEvidence(harness: harness, baseline: baseline.events, reference: runningReference)
        let coverage = DiagnosticTaskTraceCoverage.collect(events: completed.snapshot.files.first { $0.name == "events.jsonl" }!.data, globalRecordingGap: true)
        check(!coverage.evidenceComplete && coverage.snapshots.allSatisfy { !$0.evidenceComplete && $0.countedMembers == nil }, "Queue/drop metadata forbids claiming complete member evidence")
        let report: [String: Any] = ["schemaVersion": 1, "checks": checks, "diagnosticAcceptance": "passed",
            "scope": "actual timer, main callback, four consumers and frozen ZIP; missing pages/identities/predecessor plus global drops",
            "physicalVisibility": "unverified; test windows never presented", "zipDirectory": root.path]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.deletingLastPathComponent().appendingPathComponent("display-evidence.json"))
        print("PASS: \(checks) display and frozen task-evidence integrity assertions")
    }
    private static func append(_ kind: String, to url: URL) throws {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "{\"timestamp\":\"\(formatter.string(from: Date()))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(kind)\",\"turn_id\":\"PRIVATE_UI_TURN\"}}\n"
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(line.utf8))
    }
    private static func verifyMissingEvidence(harness: TracePipelineHarness, baseline: [DiagnosticEventEnvelope],
                                              reference: DiagnosticTaskSnapshotReference) throws {
        let encoder = DiagnosticEventEnvelope.encoder()
        func data(_ records: [DiagnosticEventEnvelope]) throws -> Data {
            var result = Data()
            for record in records { result.append(try encoder.encode(record)); result.append(10) }
            return result
        }
        let missingPage = baseline.filter { event in
            if case .taskTrace(.snapshotMembers(let ref, let page, _)) = event.event, ref.snapshotID == reference.snapshotID, page == 1 { return false }
            return true
        }
        let pageCoverage = DiagnosticTaskTraceCoverage.collect(events: try data(missingPage), globalRecordingGap: false)
        let page = pageCoverage.snapshots.first { $0.reference.snapshotID == reference.snapshotID }!
        check(!page.evidenceComplete && page.countedMembers == nil && page.integrity.reason == .missingPages, "Missing a production snapshot page never reconstructs a full member list")
        let missingIdentity = baseline.filter { event in
            if case .taskTrace(.identity(_, let identity, _)) = event.event, identity.turnAlias != nil { return false }; return true
        }
        let identityCoverage = DiagnosticTaskTraceCoverage.collect(events: try data(missingIdentity), globalRecordingGap: false)
        check(identityCoverage.snapshots.contains { $0.identityMissing && !$0.evidenceComplete && $0.countedMembers == nil }, "Missing turn identity is a real evidence gap even if task alias is known")
        let noPredecessor = baseline.filter { event in
            switch event.event {
            case .taskTrace(.snapshot(let ref, _)), .taskTrace(.snapshotMembers(let ref, _, _)), .taskTrace(.snapshotCheckpoint(let ref, _)):
                return ref.snapshotID != reference.previousSnapshotID
            default: return true
            }
        }
        let predecessorCoverage = DiagnosticTaskTraceCoverage.collect(events: try data(noPredecessor), globalRecordingGap: false)
        check(predecessorCoverage.snapshots.contains { !$0.evidenceComplete && $0.addedCountedMembers == nil }, "A truncated predecessor does not support member differences")
        // Simulate loss in an isolated recorder's persisted production file, then export again.
        let files = FileManager.default.enumerator(at: harness.recorder.diagnosticDirectory, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        var removed = false
        for file in files {
            let original = try Data(contentsOf: file)
            let decoder = DiagnosticEventEnvelope.decoder()
            var filtered = Data()
            for line in original.split(separator: 10) {
                let envelope = try decoder.decode(DiagnosticEventEnvelope.self, from: Data(line))
                if case .taskTrace(.snapshotMembers(let ref, let index, _)) = envelope.event, ref.snapshotID == reference.snapshotID, index == 1 { removed = true; continue }
                filtered.append(contentsOf: line); filtered.append(10)
            }
            if filtered != original { try filtered.write(to: file) }
        }
        check(removed, "Fault injection removes an actual saved production member page")
        let exported = try harness.export(name: "missing-page")
        let manifest = try JSONSerialization.jsonObject(with: TracePipelineHarness.extract(exported.zip, member: "manifest.json")) as! [String: Any]
        let taskCoverage = manifest["taskTraceCoverage"] as! [String: Any]
        check(taskCoverage["evidenceComplete"] as? Bool == false && manifest["coverageIncomplete"] as? Bool == true, "Actual frozen ZIP manifest reports missing production evidence")
    }
}
