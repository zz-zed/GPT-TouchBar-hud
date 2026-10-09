import Foundation
import Darwin

/// Executes the production installation functions against disposable fake bundles.
/// Only OS operations are replaced; every diagnostic CLI is the actual copied bridge.
@main enum DiagnosticUpgradeInstallerTests {
    static var checks = 0
    static let source = DiagnosticProcessIdentity(version: DiagnosticVersion(rawValue: "0.1.40"), build: DiagnosticBuild(rawValue: "41"))
    static let target = DiagnosticProcessIdentity(version: DiagnosticVersion(rawValue: "0.1.41"), build: DiagnosticBuild(rawValue: "42"))
    static func check(_ value: Bool, _ label: String) {
        precondition(value, label); checks += 1
    }

    static func main() throws {
        let args = ProcessInfo.processInfo.arguments
        if args.count > 1, args[1] == DiagnosticInstallerBridge.argument {
            // Fault injection lives only in this test executable; production has no such switch.
            if ProcessInfo.processInfo.environment["DIAGNOSTIC_TEST_FAULT"] == "failure" { exit(42) }
            if ProcessInfo.processInfo.environment["DIAGNOSTIC_TEST_FAULT"] == "hang" { Thread.sleep(forTimeInterval: 10); exit(43) }
            guard args.count == 6 else { exit(44) }
            let directory = URL(fileURLWithPath: args[2]).deletingLastPathComponent().appendingPathComponent("Diagnostics")
            _ = DiagnosticInstallerBridge.recordIfRequested(arguments: args, diagnosticDirectory: directory)
            return
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/diagnostic-upgrade-installer-tests/fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for scenario in ["success", "owner-alive", "backup-failure", "replace-failure", "launch-failure", "launch-timeout", "restore-failure", "restore-unconfirmed", "failed-retention", "diagnostic-failure", "diagnostic-hang", "no-handoff"] {
            do { try scenarioTest(scenario, root: root) } catch { fputs("FAIL: \(scenario) \(error)\n", stderr); throw error }
        }
        try securityTests(root: root)
        try registryTests(root: root)
        print("PASS: \(checks) diagnostic installer checks across 12 actual-script scenarios")
    }

    static func fixture(_ name: String, root: URL) throws -> (AppUpdateProgressChannel, DiagnosticRecorder) {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let installed = directory.appendingPathComponent("GPT TouchBar HUD.app")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: false)
        try Data("old-build-41".utf8).write(to: installed.appendingPathComponent("marker"))
        let channel = try AppUpdateProgressChannel.create(target: installed, sourceVersion: "0.1.40", targetVersion: "v0.1.41")
        let payload = channel.directory.appendingPathComponent("new.app")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        try Data("new-build-42".utf8).write(to: payload.appendingPathComponent("marker"))
        let copied = channel.directory.appendingPathComponent("progress-helper")
        try FileManager.default.copyItem(at: Bundle.main.executableURL!, to: copied)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: copied.path)
        let recorder = DiagnosticRecorder(directory: directory.appendingPathComponent("Diagnostics"))
        recorder.start(enabled: true)
        let ready = DispatchSemaphore(value: 0)
        var result: Result<DiagnosticUpgradeHandoff, Error>?
        recorder.prepareUpgradeHandoff(updateSessionID: UUID(uuidString: channel.context.sessionID)!, targetIdentity: target) { value in result = value; ready.signal() }
        check(ready.wait(timeout: .now() + 5) == .success, "Fixture handoff has a bounded preparation")
        let prepared: DiagnosticUpgradeHandoff
        do { prepared = try result!.get() } catch { fputs("FAIL: prepare\n", stderr); throw error }
        let handoff = DiagnosticUpgradeHandoff(updateSessionID: prepared.updateSessionID, sourceSessionID: prepared.sourceSessionID,
            sourceIdentity: source, targetIdentity: target, createdAt: prepared.createdAt,
            recordingEnabled: prepared.recordingEnabled, clearEpoch: prepared.clearEpoch)
        do { try DiagnosticInstallerBridge.prepare(handoff: handoff, channel: channel, expectedSourceIdentity: source, diagnosticDirectory: recorder.diagnosticDirectory) } catch { fputs("FAIL: protected write\n", stderr); throw error }
        return (channel, recorder)
    }

    static func events(recorder: DiagnosticRecorder) throws -> [DiagnosticEventEnvelope] {
        let done = DispatchSemaphore(value: 0)
        var value: Result<DiagnosticStoreSnapshot, Error>?
        recorder.captureSnapshot(since: nil) { value = $0; done.signal() }
        check(done.wait(timeout: .now() + 5) == .success, "Fixture snapshot is bounded")
        let snapshot: DiagnosticStoreSnapshot
        do { snapshot = try value!.get() } catch { fputs("FAIL: snapshot\n", stderr); throw error }
        return try snapshot.eventsData.split(separator: 10).map { try DiagnosticEventEnvelope.decoder().decode(DiagnosticEventEnvelope.self, from: Data($0)) }
    }

    static func scenarioTest(_ scenario: String, root: URL) throws {
        let (channel, recorder) = try fixture(scenario, root: root)
        if scenario == "no-handoff" { try FileManager.default.removeItem(at: channel.directory.appendingPathComponent("diagnostic-handoff.json")) }
        check(DiagnosticInstallerBridge.protectedBootstrap(channel: channel) != nil || scenario == "no-handoff", "Fixture bootstrap is readable")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script, "fixture", URL(fileURLWithPath: "Resources/install-update.sh").standardizedFileURL.path,
                             channel.context.targetPath, channel.directory.path, channel.context.sessionID, scenario]
        var environment = ProcessInfo.processInfo.environment
        if scenario == "diagnostic-failure" { environment["DIAGNOSTIC_TEST_FAULT"] = "failure" }
        if scenario == "diagnostic-hang" { environment["DIAGNOSTIC_TEST_FAULT"] = "hang" }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let start = Date()
        try process.run(); process.waitUntilExit()
        check(Date().timeIntervalSince(start) < 8, "\(scenario): diagnostics cannot hold installation indefinitely")
        let expected: Int32
        switch scenario {
        case "owner-alive": expected = 3
        case "backup-failure", "replace-failure", "launch-failure", "restore-unconfirmed": expected = 4
        case "restore-failure": expected = 6
        case "failed-retention": expected = 5
        case "launch-timeout": expected = 9
        default: expected = 0
        }
        check(process.terminationStatus == expected, "\(scenario): original installation exit code")
        let all = try events(recorder: recorder)
        let installer = all.filter { $0.writerRole == .installer }
        let stages = installer.compactMap { event -> DiagnosticUpgradeStage? in if case .upgrade(let stage, _) = event.event { return stage }; return nil }
        if ["diagnostic-failure", "diagnostic-hang", "no-handoff"].contains(scenario) {
            check(installer.isEmpty, "\(scenario): failure or missing capability is never invented as history")
            check(try String(contentsOf: URL(fileURLWithPath: channel.context.targetPath).appendingPathComponent("marker"), encoding: .utf8) == "new-build-42", "\(scenario): new bundle still installed")
            return
        }
        check(!installer.isEmpty, "\(scenario): script events survive without a new HUD")
        check(Set(installer.map(\.sessionID)).count == 1, "\(scenario): shell producer identity remains stable across CLI calls")
        check(installer.map(\.sequence) == installer.map(\.sequence).sorted() && Set(installer.map(\.sequence)).count == installer.count, "\(scenario): producer sequence is unique and ordered")
        check(installer.allSatisfy { $0.processIdentity == source && $0.updateSessionID?.uuidString == channel.context.sessionID }, "\(scenario): source build survives target bundle replacement")
        let expectedStages: [DiagnosticUpgradeStage]
        switch scenario {
        case "owner-alive": expectedStages = [.oldProcessExitTimedOut]
        case "backup-failure": expectedStages = [.oldProcessExitObserved, .backupStarted, .backupFailed]
        case "replace-failure": expectedStages = [.replaceFailed, .rollbackStarted, .rollbackRestoreSucceeded, .rollbackLaunchRequested, .rollbackLaunchReceiptObserved]
        case "launch-failure": expectedStages = [.launchFailed, .rollbackStarted, .rollbackRestoreSucceeded, .rollbackLaunchReceiptObserved]
        case "launch-timeout": expectedStages = [.replaceSucceeded, .launchRequested, .launchTimedOut]
        case "restore-failure": expectedStages = [.replaceFailed, .rollbackStarted, .rollbackRestoreFailed]
        case "restore-unconfirmed": expectedStages = [.replaceFailed, .rollbackRestoreSucceeded, .rollbackLaunchTimedOut]
        case "failed-retention": expectedStages = [.launchFailed, .rollbackFailed]
        default: expectedStages = [.oldProcessExitObserved, .backupStarted, .backupSucceeded, .replaceStarted, .replaceSucceeded, .launchRequested, .launchReceiptObserved]
        }
        if !expectedStages.allSatisfy(stages.contains) { fputs("FAIL: stages \(stages.map(\.rawValue).joined(separator: ","))\n", stderr) }
        check(expectedStages.allSatisfy(stages.contains), "\(scenario): actual execution stages recorded")
        if scenario == "launch-timeout" {
            check(!stages.contains(.launchReceiptObserved) && !stages.contains(.rollbackStarted), "Timeout neither invents receipt nor rolls back a potentially running new app")
            try channel.write(AppUpdateProgressChannel.Launch(sessionID: channel.context.sessionID, version: "0.1.41", pid: getpid()), name: "launch.json")
            check(channel.progress()?.phase == .succeeded, "A late real receipt resolves the existing progress protocol")
            check(try events(recorder: recorder).filter { $0.writerRole == .installer }.count == installer.count, "Late receipt cannot rewrite past installer observations")
        }
        let encoded = String(data: try DiagnosticEventEnvelope.encoder().encode(installer), encoding: .utf8)!
        check(!encoded.contains(root.path) && !encoded.contains("targetPath") && !encoded.contains("old-build"), "\(scenario): diagnostics contain no fixture path or raw operation output")
    }

    static func securityTests(root: URL) throws {
        let (channel, recorder) = try fixture("security", root: root)
        let executable = channel.directory.appendingPathComponent("progress-helper")
        var args = [executable.path, DiagnosticInstallerBridge.argument, channel.directory.path, channel.context.sessionID, "backupStarted", "1"]
        _ = DiagnosticInstallerBridge.recordIfRequested(arguments: args, executableURL: URL(fileURLWithPath: "/tmp/foreign-helper"), diagnosticDirectory: recorder.diagnosticDirectory)
        check(try events(recorder: recorder).allSatisfy { $0.writerRole != .installer }, "Foreign CLI executable cannot append")
        args[4] = "../../private-path"
        _ = DiagnosticInstallerBridge.recordIfRequested(arguments: args, executableURL: executable, diagnosticDirectory: recorder.diagnosticDirectory)
        check(try events(recorder: recorder).allSatisfy { $0.writerRole != .installer }, "Free-form stages cannot become diagnostics")
        args[4] = "backupStarted"
        let file = channel.directory.appendingPathComponent("diagnostic-handoff.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        _ = DiagnosticInstallerBridge.recordIfRequested(arguments: args, executableURL: executable, diagnosticDirectory: recorder.diagnosticDirectory)
        check(try events(recorder: recorder).allSatisfy { $0.writerRole != .installer }, "Non-private bootstrap cannot append")
    }

    static func registryTests(root: URL) throws {
        let (channel, recorder) = try fixture("registry", root: root)
        let installed = URL(fileURLWithPath: channel.context.targetPath)
        let state = AppUpdateProgress(sessionID: channel.context.sessionID, phase: .launchUnconfirmed, step: .launching)
        try channel.write(state, name: "install.json")
        check(DiagnosticInstallerBridge.uniquePendingChannel(target: installed, identity: target,
            diagnosticDirectory: recorder.diagnosticDirectory)?.context.sessionID == channel.context.sessionID,
            "A single registered protected handoff is found without launch arguments")
        let otherBuild = DiagnosticProcessIdentity(version: target.version, build: DiagnosticBuild(rawValue: "43"))
        check(DiagnosticInstallerBridge.uniquePendingChannel(target: installed, identity: otherBuild,
            diagnosticDirectory: recorder.diagnosticDirectory) == nil, "Same version with a different build is rejected")
        try channel.write(AppUpdateProgress(sessionID: channel.context.sessionID, phase: .succeeded, step: .finished), name: "install.json")
        check(DiagnosticInstallerBridge.uniquePendingChannel(target: installed, identity: target,
            diagnosticDirectory: recorder.diagnosticDirectory) == nil, "A completed installer is not treated as a pending handoff")
        try channel.write(state, name: "install.json")
        let second = try AppUpdateProgressChannel.create(target: installed, sourceVersion: "0.1.40", targetVersion: "0.1.41")
        let original = DiagnosticInstallerBridge.protectedBootstrap(channel: channel)!.handoff
        let secondHandoff = DiagnosticUpgradeHandoff(updateSessionID: UUID(uuidString: second.context.sessionID)!,
            sourceSessionID: UUID(), sourceIdentity: source, targetIdentity: target, createdAt: Date(),
            recordingEnabled: original.recordingEnabled, clearEpoch: original.clearEpoch)
        try DiagnosticInstallerBridge.prepare(handoff: secondHandoff, channel: second, expectedSourceIdentity: source,
            diagnosticDirectory: recorder.diagnosticDirectory)
        try second.write(AppUpdateProgress(sessionID: second.context.sessionID, phase: .launchUnconfirmed, step: .launching), name: "install.json")
        check(DiagnosticInstallerBridge.uniquePendingChannel(target: installed, identity: target,
            diagnosticDirectory: recorder.diagnosticDirectory) == nil, "Multiple trustworthy handoffs remain ambiguous")
        try FileManager.default.removeItem(at: second.directory.appendingPathComponent("diagnostic-handoff.json"))
        check(DiagnosticInstallerBridge.uniquePendingChannel(target: installed, identity: target,
            diagnosticDirectory: recorder.diagnosticDirectory)?.context.sessionID == channel.context.sessionID,
            "An unprotected candidate cannot create a false ambiguity or association")
        check(DiagnosticInstallerBridge.uniquePendingChannel(target: installed, identity: target, now: Date().addingTimeInterval(72 * 60 * 60 + 2),
            diagnosticDirectory: recorder.diagnosticDirectory) == nil, "Expired registered handoffs cannot associate")
    }

    static let script = #"""
    set -eu
    source "$1"
    hud_target="$2" hud_stage="$3" hud_session="$4" hud_case="$5"
    hud_install_pause() { :; }
    hud_install_alive() { [[ "$hud_case" == owner-alive ]]; }
    hud_install_open() {
        if [[ "$hud_case" == launch-failure || "$hud_case" == failed-retention ]]; then
            [[ -d "$hud_stage/failed.app" ]] || return 1
        fi
        return 0
    }
    hud_install_confirmed() { [[ "$hud_case" != launch-timeout && "$hud_case" != restore-unconfirmed ]]; }
    hud_install_move() {
        [[ "$hud_case" != backup-failure || "$2" != "$hud_backup" ]] || return 1
        if [[ "$hud_case" == replace-failure || "$hud_case" == restore-failure || "$hud_case" == restore-unconfirmed ]]; then
            [[ "$1" != "$hud_stage/new.app" ]] || return 1
        fi
        [[ "$hud_case" != restore-failure || "$1" != "$hud_backup" ]] || return 1
        [[ "$hud_case" != failed-retention || "$2" != "$hud_stage/failed.app" ]] || return 1
        /bin/mv "$1" "$2"
    }
    if hud_install_execute 999999 "$hud_target" "$hud_stage" "$hud_session"; then exit 0; else exit $?; fi
    """#
}
