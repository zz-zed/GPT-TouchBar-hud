import AppKit

final class FixtureFetcher: AppReleaseFetching {
    let release: AppRelease
    init(_ release: AppRelease) { self.release = release }
    func fetchLatest(completion: @escaping (Result<AppRelease, AppUpdateFetchFailure>) -> Void) { completion(.success(release)) }
}

@main struct Harness {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "--receipt-boundaries" {
            try receiptBoundaries(directory: URL(fileURLWithPath: args[2]), version: args[3])
            return
        }
        guard args.count == 6 else { fatalError("caseDirectory releaseJSON transportBase expectedOutcome transportSize") }
        let directory = URL(fileURLWithPath: args[1]).standardizedFileURL
        let release = try JSONDecoder().decode(AppRelease.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let engine = AppUpdateCheckEngine(fetcher: FixtureFetcher(release), currentVersion: "0.1.38")
        var discovered = false
        engine.onCompletion = { outcome, _ in
            if case .update(let candidate) = outcome { discovered = candidate.tag_name == release.tag_name && candidate.isStableVersion }
        }
        engine.request(.manual)
        guard discovered, let selected = release.installer(architecture: architecture), let checksum = release.checksums else {
            fatalError("historical discovery or trusted release asset selection failed")
        }
        let base = URL(string: args[3])!
        // Test transport boundary only: trusted discovery/selection above is untouched.
        let transported = AppRelease.Asset(name: selected.name, browser_download_url: base.appendingPathComponent("package.dmg"), size: Int(args[5])!)
        let transportedChecksum = AppRelease.Asset(name: checksum.name, browser_download_url: base.appendingPathComponent("SHA256SUMS.txt"), size: 0)
        let target = directory.appendingPathComponent("Applications/GPT TouchBar HUD.app")
        let channel = try AppUpdateProgressChannel.create(target: target, sourceVersion: "0.1.38", targetVersion: release.tag_name)
        let helper = channel.directory.appendingPathComponent("progress-helper")
        // Darwin Process starts children in a fresh group. Rejoin our dedicated
        // wrapper-owned group so its timeout cleanup also owns this sleep helper.
        let helperScript = """
        #!/usr/bin/env python3
        import os, pathlib, sys
        os.setpgid(0, os.getpgid(os.getppid()))
        pathlib.Path(sys.argv[2], "helper-fixture.pid").write_text(str(os.getpid()))
        os.execv("/bin/sleep", ["sleep", "600"])

        """
        try Data(helperScript.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        defer {
            // The wrapper creates a dedicated process group and also cleans it on timeout.
            if let text = try? String(contentsOf: channel.directory.appendingPathComponent("helper-fixture.pid"), encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
               pid != getpid(), getpgid(pid) == getpgrp() {
                kill(pid, SIGTERM)
            }
        }
        let job = AppUpdateInstallation(session: URLSession(configuration: .ephemeral), release: release, asset: transported,
                                        checksum: transportedChecksum, channel: channel)
        var reachedHandoff = false
        var phases: [String] = []
        job.onChange = { _ in
            let phase = job.progress.phase.rawValue + "/" + job.progress.step.rawValue
            if phases.last != phase { phases.append(phase); print(phase); fflush(stdout) }
            if job.progress.phase == .installing && job.progress.step == .waitingForExit {
                reachedHandoff = true
                job.stop() // Original handoff() checks progress.isActive immediately after publish().
            }
        }
        try job.start()
        let deadline = Date(timeIntervalSinceNow: 240)
        while job.progress.isActive && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1)) }
        let manager = FileManager.default
        let payload = channel.directory.appendingPathComponent("new.app")
        let absent = ["installer-process.json", "install.log", "installer-lock", "previous.app"].allSatisfy {
            !manager.fileExists(atPath: channel.directory.appendingPathComponent($0).path)
        }
        let success = args[4] == "prepared"
        let valid = !job.handedOff && absent && !job.progress.isActive && (success ? reachedHandoff && manager.fileExists(atPath: payload.path) : !reachedHandoff && !manager.fileExists(atPath: payload.path))
        let report: [String: Any] = ["architecture": architecture, "release": release.tag_name, "trustedSelectedAsset": selected.name,
            "discoveredAsUpdate": discovered, "reachedHandoff": reachedHandoff, "handedOff": job.handedOff,
            "installerArtifactsAbsent": absent, "preparedPayload": payload.path, "channel": channel.directory.path,
            "phase": job.progress.phase.rawValue, "step": job.progress.step.rawValue,
            "message": job.progress.message ?? "", "phases": phases, "passed": valid]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("result.json"))
        guard valid else { throw NSError(domain: "LegacyCompatibilityFixture", code: 1) }
    }

    // Exercise original receipt primitives directly; this is not a real app launch.
    static func receiptBoundaries(directory: URL, version: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldTarget = directory.appendingPathComponent("GPT TouchBar HUD.app")
        let channel = try AppUpdateProgressChannel.create(target: oldTarget, sourceVersion: "0.1.38", targetVersion: version)
        var progress = AppUpdateProgress(sessionID: channel.context.sessionID, phase: .restarting, step: .launching)
        try channel.write(progress, name: "install.json")
        let arguments = ["fixture", AppUpdateProgressChannel.argument, channel.directory.path, channel.context.sessionID]
        let receipt = channel.directory.appendingPathComponent("launch.json")
        let identifier = "io.github.zz-zed.GPTTouchBarHUD"
        func acknowledge(_ target: URL, _ id: String = identifier, _ candidate: String? = nil) {
            AppUpdateProgressChannel.acknowledgeLaunch(arguments: arguments, bundleURL: target,
                bundleIdentifier: id, version: candidate ?? version)
        }
        acknowledge(directory.appendingPathComponent("GPT HUD.app"))
        guard !manager.fileExists(atPath: receipt.path) else { fatalError("renamed target incorrectly acknowledged") }
        acknowledge(oldTarget, "fixture.wrong.identifier")
        acknowledge(oldTarget, identifier, "0.1.38")
        guard !manager.fileExists(atPath: receipt.path) else { fatalError("wrong identity/version acknowledged") }
        acknowledge(oldTarget)
        guard channel.launchMatches(version: version), channel.progress()?.phase == .succeeded else {
            fatalError("old target receipt was not accepted")
        }
        try manager.removeItem(at: receipt)
        progress.phase = .installing; progress.step = .restoring
        try channel.write(progress, name: "install.json")
        acknowledge(oldTarget, identifier, "0.1.38")
        guard channel.launchMatches(version: "0.1.38"), channel.progress()?.recovery == .restored else {
            fatalError("old version restoration receipt was not accepted")
        }
        let renamedDirectory = directory.appendingPathComponent("renamed-install")
        try manager.createDirectory(at: renamedDirectory, withIntermediateDirectories: false)
        let renamed = try AppUpdateProgressChannel.create(target: renamedDirectory.appendingPathComponent("GPT HUD.app"),
            sourceVersion: "0.1.38", targetVersion: version)
        do {
            _ = try AppUpdateProgressChannel.load(directory: renamed.directory, sessionID: renamed.context.sessionID)
            fatalError("historical path whitelist unexpectedly accepted GPT HUD.app")
        } catch AppUpdateProgressChannel.ChannelError.invalid { }
        print("PASS historical receipt: retained target, identity, version, restoration, renamed target rejection")
    }
}
