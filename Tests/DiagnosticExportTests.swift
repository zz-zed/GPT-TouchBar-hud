import AppKit
import CryptoKit
import Darwin

private final class DiagnosticTestClock {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date = date.addingTimeInterval(seconds); lock.unlock() }
}

private final class ExportPrivacyError: LocalizedError {
    var errorDescription: String? { "private@example.com /Users/private-person sk-private-token private-task-title" }
}

private final class ExportWriteGate {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var first = true
    func write() throws {
        lock.lock(); let block = first; first = false; lock.unlock()
        if block {
            entered.signal()
            guard resume.wait(timeout: .now() + 5) == .success else { throw DiagnosticStoreError.ioFailure }
        }
    }
}

@main
enum DiagnosticExportTests {
    private static var checks = 0
    private static let time = Date(timeIntervalSince1970: 1_800_000_000)
    private static func check(_ value: Bool, _ label: String) {
        precondition(value, label)
        checks += 1
    }
    private static func wait<T>(_ operation: (@escaping (T) -> Void) -> Void) -> T {
        var result: T?
        operation { result = $0 }
        let deadline = Date().addingTimeInterval(10)
        while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
        precondition(result != nil, "Callback must finish in bounded time")
        return result!
    }
    private static func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
        precondition(condition(), "UI callback must finish in bounded time")
    }
    private static func environment() -> DiagnosticEnvironmentSnapshot {
        DiagnosticEnvironmentSnapshot(capturedAt: time, appVersion: "0.1.39", appBuild: "43", buildSource: String(repeating: "a", count: 64),
            operatingSystemVersion: "11.7.10", operatingSystemBuild: "20G1427", model: "MacBookPro16,2",
            hardwareArchitecture: .x86_64, processArchitecture: .x86_64, translated: false,
            host: .chatGPT, hostVersion: "1.2026.100", location: .other)
    }
    private static func preview(_ exporter: DiagnosticExportCoordinator, request: DiagnosticExportRequest? = nil,
                                report: ConnectionDiagnosticsReport? = nil) -> Result<DiagnosticExportSnapshot, DiagnosticExportError> {
        wait { exporter.preview(request: request ?? DiagnosticExportRequest(createdAt: time), report: report, completion: $0) }
    }
    private static func save(_ exporter: DiagnosticExportCoordinator, _ snapshot: DiagnosticExportSnapshot,
                             _ url: URL) -> Result<Void, DiagnosticExportError> {
        let result: Result<Void, DiagnosticExportError> = wait { exporter.save(snapshot, to: url, completion: $0) }
        return result
    }
    private static func json(_ file: DiagnosticExportFile) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: file.data) as! [String: Any]
    }
    private static func file(_ snapshot: DiagnosticExportSnapshot, _ name: String) -> DiagnosticExportFile {
        snapshot.files.first { $0.name == name }!
    }
    private static func fails<T>(_ result: Result<T, DiagnosticExportError>, _ error: DiagnosticExportError) -> Bool {
        if case .failure(let actual) = result { return actual == error }
        return false
    }

    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/diagnostic-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = DiagnosticTestClock(time.addingTimeInterval(-120))
        var config = DiagnosticRecorder.Configuration()
        config.flushDelay = 60
        config.aggregationWindow = 0
        let recorder = DiagnosticRecorder(directory: root.appendingPathComponent("events"), configuration: config, now: { clock.now })
        check(!recorder.isEnabled, "Construction performs no implicit recording")
        recorder.start()
        recorder.record(.connection(phase: .initialize, generation: 4, result: .success))
        let exporter = DiagnosticExportCoordinator(recorder: recorder, environment: {
            precondition(!Thread.isMainThread, "Environment must be captured off the UI thread")
            return environment()
        })
        let report = ConnectionDiagnosticsReport(environment: ConnectionDiagnosticsEnvironment(appVersion: "0.1.39",
            operatingSystem: OperatingSystemVersion(majorVersion: 11, minorVersion: 7, patchVersion: 10),
            architecture: .x86_64, host: .chatGPT, hostVersion: "1.2026.100"), startedAt: time.addingTimeInterval(-3),
            finishedAt: time, findings: [.connection: .passed, .tokenUsage: .noData])
        let snapshot = try preview(exporter, report: report).get()
        check(snapshot.files.map(\.name) == DiagnosticExportSnapshot.fileNames, "Exactly five fixed members")
        check(snapshot.hasGaps, "Sparse available history visibly reports incomplete coverage")
        check(file(snapshot, "events.jsonl").text.contains("initialize"), "Preview contains persisted typed events")
        let manifest = try json(file(snapshot, "manifest.json"))
        let members = manifest["files"] as! [[String: Any]]
        check(members.count == 4 && !members.contains { $0["name"] as? String == "manifest.json" }, "Manifest has no self hash")
        for member in members {
            let target = file(snapshot, member["name"] as! String)
            let hash = SHA256.hash(data: target.data).map { String(format: "%02x", $0) }.joined()
            check(member["size"] as? Int == target.data.count && member["sha256"] as? String == hash, "Manifest size and SHA256 match frozen bytes")
        }
        check(try json(file(snapshot, "checks.json"))["status"] as? String == "finished", "Explicit checks are frozen with status and times")
        check(snapshot.suggestedFileName.hasPrefix("GPT-TouchBar-HUD-diagnostics-") && !snapshot.suggestedFileName.contains("private"), "Generated name contains no person or device identifier")
        let frozenBytes = snapshot.files.map(\.data)
        clock.advance(60)
        recorder.record(.task(stage: .aggregate, batch: 777, runningCount: 42))
        let fresh = try preview(exporter).get()
        check(file(fresh, "events.jsonl").text.contains("777"), "A new preview can include later events")
        check(snapshot.files.map(\.data) == frozenBytes && !file(snapshot, "events.jsonl").text.contains("777"), "Earlier preview remains immutable while recording continues")
        check(try json(file(fresh, "checks.json"))["status"] as? String == "notPerformed", "No check is distinctly not performed")
        let zip = root.appendingPathComponent(snapshot.suggestedFileName)
        try save(exporter, snapshot, zip).get()
        let archive = try Data(contentsOf: zip)
        try DiagnosticZIP.validate(archive, files: snapshot.files)
        check(archive.count == snapshot.byteCount + DiagnosticZIP.overhead(snapshot.files), "Stored ZIP predictable size respects reservation")
        let attributes = try FileManager.default.attributesOfItem(atPath: zip.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Saved ZIP is private")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-tq", zip.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run(); unzip.waitUntilExit()
        check(unzip.terminationStatus == 0, "Independent system unzip confirms readable CRC and directory")
        for member in snapshot.files {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", zip.path, member.name]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            check(process.terminationStatus == 0 && data == member.data, "Saved member is exactly the preview bytes")
        }
        var corrupt = archive
        corrupt[40] ^= 0xff
        do { try DiagnosticZIP.validate(corrupt, files: snapshot.files); preconditionFailure("Corruption must fail") }
        catch { check(error as? DiagnosticExportError == .invalidArchive, "Damaged member cannot report readable ZIP") }
        for length in [0, 1, 21, archive.count - 1] {
            do { try DiagnosticZIP.validate(Data(archive.prefix(length)), files: snapshot.files); preconditionFailure("Truncation must fail") }
            catch { check(error as? DiagnosticExportError == .invalidArchive, "Truncated ZIP safely fails bounds checks") }
        }
        let secret = "private@example.com /Users/private-person sk-private-token private-task-title"
        let described = try preview(exporter, request: DiagnosticExportRequest(createdAt: time, problemDescription: secret, problemTime: time)).get()
        check(file(described, "summary.txt").text.contains(secret), "Explicit user description appears in its own preview")
        check(described.files.filter { $0.name != "summary.txt" }.allSatisfy { !$0.text.contains(secret) }, "User text never enters environment/events/checks/manifest")
        check(snapshot.files.allSatisfy { !$0.text.contains(secret) }, "Description never alters previous previews")
        let afterDescription = try preview(exporter).get()
        check(afterDescription.files.allSatisfy { !$0.text.contains(secret) }, "Description is not persisted or carried to another export")
        let malformedEnvironment = DiagnosticEnvironmentSnapshot(capturedAt: time, appVersion: secret, appBuild: secret,
            buildSource: secret, operatingSystemVersion: secret, operatingSystemBuild: secret, model: secret,
            hardwareArchitecture: .unknown, processArchitecture: .unknown, translated: nil,
            host: .unknown, hostVersion: secret, location: .unknown)
        let privacyExporter = DiagnosticExportCoordinator(recorder: recorder, environment: { malformedEnvironment })
        let sanitized = try preview(privacyExporter).get()
        check(sanitized.files.allSatisfy { !$0.text.contains("private@example.com") && !$0.text.contains("sk-private-token") && !$0.text.contains("/Users/") && !$0.text.contains("private-task-title") }, "Malicious environment is allowlisted across all exported files")
        let eventDirectory = root.appendingPathComponent("events")
        let damagedFile = eventDirectory.appendingPathComponent("events-\(UUID().uuidString.lowercased()).jsonl")
        try Data((secret + "\n{\"truncated\":").utf8).write(to: damagedFile)
        try FileManager.default.setAttributes([.modificationDate: clock.now, .posixPermissions: 0o600], ofItemAtPath: damagedFile.path)
        let damaged = try preview(exporter).get()
        check(damaged.hasGaps && file(damaged, "manifest.json").text.contains("corruptedLine"), "Invalid and incomplete lines are visible gaps")
        check(damaged.files.allSatisfy { !$0.text.contains(secret) }, "Corrupt raw input does not escape through export")
        let blocked = root.appendingPathComponent("blocked")
        try Data(secret.utf8).write(to: blocked)
        let failedRecorder = DiagnosticRecorder(directory: blocked)
        let failedExporter = DiagnosticExportCoordinator(recorder: failedRecorder, environment: environment,
            stagingDirectory: root.appendingPathComponent("export-staging", isDirectory: true))
        let partial = try preview(failedExporter).get()
        check(partial.hasGaps && file(partial, "manifest.json").text.contains("eventReadFailed"), "Read failure produces explicitly partial snapshot")
        let partialManifest = try json(file(partial, "manifest.json"))
        check(partialManifest["droppedCount"] is NSNull && partialManifest["eventCount"] is NSNull,
              "Unavailable counts remain JSON null rather than misleading zero")
        check(file(partial, "summary.txt").text.contains("读取失败") && partial.files.allSatisfy { !$0.text.contains(secret) }, "Partial failure is actionable and never includes raw error")
        try save(failedExporter, partial, root.appendingPathComponent("partial.zip")).get()
        checks += 1
        let emptyRecorder = DiagnosticRecorder(directory: root.appendingPathComponent("empty"))
        let emptyExporter = DiagnosticExportCoordinator(recorder: emptyRecorder, environment: environment)
        let empty = try preview(emptyExporter).get()
        check(file(empty, "events.jsonl").data.isEmpty && empty.hasGaps, "Empty history stays empty and coverage is explicitly incomplete")
        let target = root.appendingPathComponent("target.txt")
        try Data("preserve".utf8).write(to: target)
        let link = root.appendingPathComponent("symlink.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        check(fails(save(exporter, snapshot, link), .unsafeDestination), "Destination symlink is rejected")
        check(try String(contentsOf: target, encoding: .utf8) == "preserve", "Symlink target is never changed")
        let linkedParent = root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: root)
        check(fails(save(exporter, snapshot, linkedParent.appendingPathComponent("unsafe.zip")), .unsafeDestination), "Symlink parent is rejected without following it")
        check(fails(save(exporter, snapshot, root.appendingPathComponent("missing/no.zip")), .unsafeDestination), "Missing parent reports failure")
        for _ in 0..<10 {
            let directorySaveResult = save(exporter, snapshot, eventDirectory)
            check(fails(directorySaveResult, .unsafeDestination), "Completed operation releases its slot before callback; directory stays protected: \(directorySaveResult)")
        }
        let tooLarge = DiagnosticExportSnapshot(id: UUID(), createdAt: time, recordingGeneration: recorder.recordingGeneration,
            files: snapshot.files.map { $0.name == "events.jsonl" ? DiagnosticExportFile(name: $0.name, data: Data(count: 13 * 1024 * 1024)) : $0 }, hasGaps: true)
        check(fails(save(exporter, tooLarge, root.appendingPathComponent("too-large.zip")), .budgetExceeded), "Snapshot plus ZIP budget is enforced before packaging")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("too-large.zip").path), "Budget failure never creates output")
        let slowExporter = DiagnosticExportCoordinator(recorder: recorder, environment: {
            Thread.sleep(forTimeInterval: 0.08)
            return environment()
        }, timeout: 0.02)
        check(fails(preview(slowExporter), .timedOut), "Watchdog reports timeout while a source is slow")
        check(fails(preview(slowExporter), .busy), "Timeout reserves slot until previous worker actually exits")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let cancelExporter = DiagnosticExportCoordinator(recorder: recorder, environment: {
            Thread.sleep(forTimeInterval: 0.08)
            return environment()
        })
        let cancelResult: Result<DiagnosticExportSnapshot, DiagnosticExportError> = wait { completion in
            cancelExporter.preview(request: DiagnosticExportRequest(createdAt: time), report: nil, completion: completion)
            cancelExporter.cancel()
        }
        check(fails(cancelResult, .cancelled), "Explicit cancellation reports no success")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let invalidation: Result<DiagnosticExportSnapshot, DiagnosticExportError> = wait { completion in
            cancelExporter.preview(request: DiagnosticExportRequest(createdAt: time), report: nil, completion: completion)
            cancelExporter.invalidate()
        }
        check(fails(invalidation, .invalidated), "Close invalidates in-flight work")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        recorder.setEnabled(false)
        check(fails(save(exporter, snapshot, root.appendingPathComponent("disabled.zip")), .invalidated), "Recording generation change invalidates older preview")
        let retained = try preview(exporter).get()
        check(!file(retained, "events.jsonl").data.isEmpty, "Turning recording off retains historical records")
        let cleared: Result<Void, Error> = wait { callback in recorder.clear { result in DispatchQueue.main.async { callback(result) } } }
        try cleared.get()
        check(fails(save(exporter, retained, root.appendingPathComponent("cleared.zip")), .invalidated), "Clear invalidates any retained preview")
        check(FileManager.default.fileExists(atPath: zip.path), "Clear preserves user-saved ZIP")
        let afterClear = try preview(exporter).get()
        check(file(afterClear, "events.jsonl").data.isEmpty, "Clear cannot resurrect previous event files")
        let temporaryFiles = try FileManager.default.contentsOfDirectory(atPath: recorder.exportStagingDirectory.path).filter { $0.hasPrefix("export-") }
        check(temporaryFiles.isEmpty, "No temporary snapshot material remains after success and failures")
        let staging = recorder.exportStagingDirectory
        let leftover = staging.appendingPathComponent("export-\(UUID().uuidString.lowercased()).tmp")
        try Data(count: DiagnosticExportCoordinator.maximumTemporaryBytes).write(to: leftover)
        check(fails(save(exporter, afterClear, root.appendingPathComponent("leftover-budget.zip")), .budgetExceeded),
              "Owned crash leftovers count toward total staging reservation")
        try FileManager.default.removeItem(at: leftover)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var runtimeLookups = 0
        let uiRunner = ConnectionDiagnosticsRunner(locateRuntime: { runtimeLookups += 1; return nil },
            environment: { _ in report.environment }, now: { time })
        let uiRecorder = DiagnosticRecorder(directory: root.appendingPathComponent("ui-records"), now: { time })
        let uiExporter = DiagnosticExportCoordinator(recorder: uiRecorder, environment: environment)
        let suite = "diagnostic-export-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ConnectionDiagnosticsWindowController(runner: uiRunner, recorder: uiRecorder,
            exporter: uiExporter, defaults: defaults, environment: environment)
        controller.showAndCheck()
        check(runtimeLookups == 0 && uiRunner.report == nil, "Opening window is passive and never starts a check")
        let content = controller.window!.contentView!
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(content)
        let review = controls.compactMap { $0 as? NSTextView }.first!
        let buttons = controls.compactMap { $0 as? NSButton }
        let previewButton = buttons.first { $0.title == "生成导出预览" }!
        let saveButton = buttons.first { $0.title == "保存 ZIP…" }!
        let popup = controls.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles == DiagnosticExportRange.allCases.map(\.title) }!
        check(popup.indexOfSelectedItem == 0 && !saveButton.isEnabled, "Range defaults to thirty minutes with no save before preview")
        previewButton.performClick(nil)
        waitUntil { saveButton.isEnabled }
        check(runtimeLookups == 0 && review.string.contains("本地诊断包"), "Generating preview still performs no current check")
        let membersPopup = controls.compactMap { $0 as? NSPopUpButton }.first { $0 !== popup }!
        check(membersPopup.numberOfItems == 5, "Every frozen text member can be selected for review")
        membersPopup.selectItem(at: 4)
        _ = NSApp.sendAction(membersPopup.action!, to: membersPopup.target, from: membersPopup)
        check(review.string.contains("exportID") && review.string.contains("sha256"), "Manifest receives a full text preview")
        popup.selectItem(at: 1)
        _ = NSApp.sendAction(popup.action!, to: popup.target, from: popup)
        check(!saveButton.isEnabled && membersPopup.numberOfItems == 0, "Range change invalidates previously previewed save")
        controller.startCheck()
        check(runtimeLookups == 1 && uiRunner.report?.isRunning == false, "Current check only runs on explicit action")
        let toggle = buttons.first { $0.title == "基础记录仅保存在本机" }!
        // performClick animates and pumps AppKit's run loop; a fast durable reply can
        // legitimately finish before it returns. Dispatch the action synchronously
        // so this assertion observes the pending state before any main callback.
        toggle.state = .on
        _ = NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle)
        check(!defaults.bool(forKey: DiagnosticRecorder.preferenceKey) && !toggle.isEnabled,
              "Pending cross-process setting does not claim success or save preferences")
        waitUntil { toggle.isEnabled }
        check(defaults.bool(forKey: DiagnosticRecorder.preferenceKey) && uiRecorder.isEnabled,
              "Record control updates only injected defaults and recorder")
        let controlLock = open(uiRecorder.diagnosticDirectory.appendingPathComponent(DiagnosticProcessStore.lockName).path, O_RDWR | O_NOFOLLOW)
        check(controlLock >= 0, "Test holds only its private process-control lock")
        waitUntil { flock(controlLock, LOCK_EX | LOCK_NB) == 0 }
        toggle.performClick(nil)
        let retryRecording = buttons.first { $0.title == "重试记录设置" }!
        waitUntil { !retryRecording.isHidden }
        check(defaults.bool(forKey: DiagnosticRecorder.preferenceKey) && !uiRecorder.isEnabled,
              "Durable disable failure keeps preferences unchanged while stopping this process")
        check(controls.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("尚未确认") },
              "Durable disable failure visibly warns cross-process state is unconfirmed")
        _ = flock(controlLock, LOCK_UN); close(controlLock)
        retryRecording.performClick(nil)
        waitUntil { toggle.isEnabled && retryRecording.isHidden }
        let disabledControl = try DiagnosticProcessStore(directory: uiRecorder.diagnosticDirectory).currentControl()
        check(!defaults.bool(forKey: DiagnosticRecorder.preferenceKey) && !disabledControl.enabled,
              "Retry commits disabled cross-process control before reporting success")
        toggle.performClick(nil)
        waitUntil { toggle.isEnabled }
        previewButton.performClick(nil)
        waitUntil { saveButton.isEnabled }
        content.layoutSubtreeIfNeeded()
        content.wantsLayer = true
        content.effectiveAppearance.performAsCurrentDrawingAppearance { content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let screenshotDirectory = URL(fileURLWithPath: ".build/diagnostic-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: screenshotDirectory, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: screenshotDirectory.appendingPathComponent("diagnostic-window.png"))
        check(review.frame.width > 600 && review.frame.height >= 230, "Window keeps the complete preview readable")
        controller.window?.close()
        check(!saveButton.isEnabled && membersPopup.numberOfItems == 0, "Closing discards old preview and disables saving")
        try generationRaceChecks(root)
        try upgradeCoverageChecks()
        print("PASS: \(checks) diagnostic export checks")
    }
    static func generationRaceChecks(_ root: URL) throws {
        let gate = ExportWriteGate()
        var configuration = DiagnosticRecorder.Configuration()
        configuration.flushDelay = 60
        let recorder = DiagnosticRecorder(directory: root.appendingPathComponent("preview-clear-race"),
            configuration: configuration, now: { time }, beforeWrite: gate.write)
        recorder.start()
        recorder.record(.task(stage: .aggregate, batch: 919191, runningCount: 1))
        let exporter = DiagnosticExportCoordinator(recorder: recorder, environment: environment)
        var clearResult: Result<Void, Error>?
        let result: Result<DiagnosticExportSnapshot, DiagnosticExportError> = wait { completion in
            exporter.preview(request: DiagnosticExportRequest(createdAt: time), report: nil, completion: completion)
            check(gate.entered.wait(timeout: .now() + 5) == .success, "Preview is deterministically paused during its old-generation flush")
            recorder.clear { value in DispatchQueue.main.async { clearResult = value } }
            gate.resume.signal()
        }
        check(fails(result, .invalidated), "Cross-generation cancellation is rejected rather than downgraded to a savable partial package")
        waitUntil { clearResult != nil }
        try clearResult!.get()
        let afterClear = try preview(exporter).get()
        check(!file(afterClear, "events.jsonl").text.contains("919191"), "Clear never restamps old event data as the new generation")
    }
    static func upgradeCoverageChecks() throws {
        let id = UUID(), old = UUID(), installer = UUID(), newer = UUID()
        let source = DiagnosticProcessIdentity(version: DiagnosticVersion(rawValue: "0.1.40"), build: DiagnosticBuild(rawValue: "43"))
        let target = DiagnosticProcessIdentity(version: DiagnosticVersion(rawValue: "0.1.41"), build: DiagnosticBuild(rawValue: "44"))
        func envelope(_ event: DiagnosticEvent, role: DiagnosticWriterRole, session: UUID, seq: UInt64, offset: TimeInterval, mono: UInt64) -> DiagnosticEventEnvelope {
            DiagnosticEventEnvelope(timestamp: time.addingTimeInterval(offset), sessionID: session, sequence: seq, monotonicMilliseconds: mono,
                event: event, updateSessionID: id, writerRole: role, eventID: .init(sessionID: session, sequence: seq),
                processIdentity: role == .newHUD ? target : source, upgradeSourceIdentity: source, upgradeTargetIdentity: target)
        }
        var values = [envelope(.upgrade(stage: .handoffPrepared, result: .success), role: .oldHUD, session: old, seq: 1, offset: -30, mono: 0),
            envelope(.upgrade(stage: .oldProcessExitObserved, result: .success), role: .installer, session: installer, seq: 1, offset: -20, mono: 0),
            envelope(.upgrade(stage: .appStarted, result: .success), role: .newHUD, session: newer, seq: 1, offset: -10, mono: 0),
            envelope(.upgrade(stage: .launchReceiptObserved, result: .success), role: .installer, session: installer, seq: 2, offset: -5, mono: 0),
            envelope(.moduleRecovery(module: .connection, state: .failed, observation: .afterRestart), role: .newHUD, session: newer, seq: 2, offset: -4, mono: 6000)]
        func collect(_ truncated: Set<UUID> = []) throws -> DiagnosticUpgradeCoverage {
            var data = Data()
            for value in values { data.append(try DiagnosticEventEnvelope.encoder().encode(value)); data.append(10) }
            return DiagnosticUpgradeCoverage.collect(events: data, truncated: truncated)[0]
        }
        var coverage = try collect()
        check(coverage.installation == "launchReceiptConfirmed" && coverage.recovery["connection"] == "failed", "install and business failure remain separate")
        check(coverage.source == source && coverage.target == target, "source and target build whitelisted")
        check(coverage.businessGapStart != nil && coverage.businessGapEnd != nil, "two consistent observed boundaries form an explicitly limited gap")
        check(coverage.missingProducers.isEmpty && !coverage.clockDiscontinuity, "observed producer coverage")
        check(try collect([id]).rangeTruncated, "selected range truncation is explicit")
        values.removeFirst(2)
        coverage = try collect()
        check(coverage.businessGapStart == nil, "one boundary cannot imply exact downtime")
        check(coverage.missingProducers.contains("oldHUD"), "missing old capability stays missing")
        values.append(envelope(.moduleRecovery(module: .taskMonitor, state: .success, observation: .indexRead), role: .newHUD, session: newer, seq: 3, offset: -100, mono: 7000))
        coverage = try collect()
        check(coverage.clockDiscontinuity && coverage.businessGapStart == nil, "clock reversal never produces accurate downtime")
        check(!coverage.summary.contains("/Users/") && !coverage.summary.contains("targetPath"), "summary has no raw private channel values")
    }

}
