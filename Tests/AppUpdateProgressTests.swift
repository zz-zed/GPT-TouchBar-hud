import AppKit
import Darwin

private final class DownloadObservation {
    let lock = NSLock()
    let finished = DispatchSemaphore(value: 0)
    var samples: [Int64] = []
    var result: Result<URL, Error>?
    var completions = 0
    func received(_ bytes: Int64) { lock.lock(); defer { lock.unlock() }; samples.append(bytes) }
    func complete(_ value: Result<URL, Error>) {
        lock.lock(); result = value; completions += 1; lock.unlock(); finished.signal()
    }
}

@main enum AppUpdateProgressTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message); checks += 1
    }
    static func main() throws {
        // The same entry as the real app permits a private copy to act as the
        // UI/receipt helper, without constructing AppDelegate or any HUD service.
        if AppUpdateProgressHelper.runIfRequested() { return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hud-progress-test-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        testModel()
        try testChannel(in: root.appendingPathComponent("channel"))
        try testDownloads(in: root.appendingPathComponent("downloads"))
        try testWindow()
        try testHelperLifetime(in: root.appendingPathComponent("lifetime"))
        try testInstallation(in: root.appendingPathComponent("installation"))
        try testVerificationFailure(in: root.appendingPathComponent("verification-failure"))
        print("PASS: \(checks) update progress checks (loopback downloads, private helper, native window)")
    }

    static func testModel() {
        var value = AppUpdateProgress(sessionID: "test", phase: .preparing, step: .connecting)
        check(value.canCancel && value.isActive && value.downloadFraction == nil, "Preparation is cancellable without a false percentage")
        value.phase = .downloading; value.step = .download; value.totalBytes = 100
        value.bytesReceived = 40
        check(value.downloadFraction == 0.4 && value.menuTitle.contains("40%"), "Bytes drive the download percentage and menu")
        value.bytesReceived = 100
        check(value.isActive && value.heading == "正在下载新版", "Download 100% is not installation success")
        value.totalBytes = 0
        check(value.downloadFraction == nil, "No verified total means no invented percentage")
        for phase in [AppUpdateProgress.Phase.verifying, .installing, .restarting] {
            value.phase = phase
            check(value.isActive && !value.canCancel && value.downloadFraction == nil, "\(phase) is indeterminate and cannot cancel")
        }
        value.phase = .failed; value.step = .download
        check(value.canRetry, "Failed download may restart")
        for step in [AppUpdateProgress.Step.checksum, .mounting, .validating, .copying, .waitingForExit] {
            value.step = step
            check(!value.canRetry, "Failure at \(step) cannot re-enter download using preparation leftovers")
        }
        value.step = .download; value.recovery = .backupRetained
        check(!value.canRetry, "A replaced installation is not retried as a download")
        for phase in [AppUpdateProgress.Phase.succeeded, .failed, .canceled, .launchUnconfirmed] {
            value.phase = phase
            check(!value.isActive && !value.canCancel, "\(phase) has no duplicate in-flight installation")
        }
        value.phase = .launchUnconfirmed
        check(value.heading != "更新完成", "Unconfirmed launch is not success")
    }

    static func testChannel(in directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("GPT TouchBar HUD.app")
        let channel = try AppUpdateProgressChannel.create(target: target, sourceVersion: "0.1.37", targetVersion: "v0.1.38")
        check(try AppUpdateProgressChannel.load(directory: channel.directory, sessionID: channel.context.sessionID).context == channel.context,
              "Private session context round-trips")
        let attributes = try manager.attributesOfItem(atPath: channel.directory.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Session directory is private")
        check(manager.fileExists(atPath: channel.directory.appendingPathComponent("RECOVERY.txt").path), "Recovery instructions accompany the session")
        var progress = AppUpdateProgress(sessionID: channel.context.sessionID, phase: .downloading, step: .download, bytesReceived: 40, totalBytes: 100)
        try channel.write(progress, name: "progress.json")
        check(channel.progress() == progress, "Download state is readable by the helper")
        // Readers must never observe a partially rewritten JSON record.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for bytes in 1...100 {
                let value = AppUpdateProgress(sessionID: channel.context.sessionID, phase: .downloading, step: .download, bytesReceived: Int64(bytes), totalBytes: 100)
                try! channel.write(value, name: "progress.json")
            }
            group.leave()
        }
        for _ in 1...100 { check(channel.progress() != nil, "Atomic status remains decodable during publication") }
        group.wait()
        check(try manager.contentsOfDirectory(atPath: channel.directory.path).allSatisfy { !$0.hasPrefix(".state-") }, "Atomic publication leaves no temporary file")
        do { try channel.write(progress, name: "../outside.json"); check(false, "Unknown output name must be rejected") }
        catch { check(!manager.fileExists(atPath: directory.appendingPathComponent("outside.json").path), "Status writer cannot escape the session") }
        try channel.send(.cancel)
        let command = channel.readValue("command.json", as: AppUpdateProgressChannel.Command.self)
        check(command?.sessionID == channel.context.sessionID && command?.action == .cancel, "User command carries its session")

        progress.phase = .restarting; progress.step = .launching; progress.recovery = .backupRetained
        try channel.write(progress, name: "install.json")
        let args = ["fixture", AppUpdateProgressChannel.argument, channel.directory.path, channel.context.sessionID]
        for (bundle, identifier, version, arguments) in [
            (target, "unrelated.app", "0.1.38", args),
            (directory.appendingPathComponent("Other.app"), "io.github.zz-zed.GPTTouchBarHUD", "0.1.38", args),
            (target, "io.github.zz-zed.GPTTouchBarHUD", "0.1.37", args),
            (target, "io.github.zz-zed.GPTTouchBarHUD", "0.1.38", args + ["extra"])
        ] {
            AppUpdateProgressChannel.acknowledgeLaunch(arguments: arguments, bundleURL: bundle, bundleIdentifier: identifier, version: version)
            check(!channel.launchMatches(version: "0.1.38"), "Foreign path, identity, version or arguments cannot confirm launch")
        }
        AppUpdateProgressChannel.acknowledgeLaunch(arguments: args, bundleURL: target, bundleIdentifier: "io.github.zz-zed.GPTTouchBarHUD", version: "0.1.38")
        check(channel.progress()?.phase == .succeeded && channel.launchMatches(version: "v0.1.38"), "Expected target and a live receipt confirm success")
        let copiedHelper = channel.directory.appendingPathComponent("progress-helper")
        try manager.copyItem(at: Bundle.main.executableURL!, to: copiedHelper)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: copiedHelper.path)
        check(try run(copiedHelper, ["--check-update-launch", channel.directory.path, channel.context.sessionID, "0.1.38"]) == 0,
              "A naked private executable can validate the actual receipt")
        check(try run(copiedHelper, ["--check-update-launch", channel.directory.path, channel.context.sessionID, "0.1.39"]) != 0,
              "Private receipt CLI rejects a different version")
        try channel.write(AppUpdateProgressChannel.Launch(sessionID: UUID().uuidString, version: "0.1.38", pid: getpid()), name: "launch.json")
        check(channel.progress()?.phase == .restarting, "Another session's receipt cannot finish an update")
        try channel.write(AppUpdateProgressChannel.Launch(sessionID: channel.context.sessionID, version: "0.1.38", pid: 0), name: "launch.json")
        check(!channel.launchMatches(version: "0.1.38") && channel.progress()?.phase == .restarting, "Zero PID is not a launch receipt")
        progress.phase = .launchUnconfirmed
        try channel.write(progress, name: "install.json")
        try channel.write(AppUpdateProgressChannel.Launch(sessionID: channel.context.sessionID, version: "0.1.38", pid: getpid()), name: "launch.json")
        check(channel.progress()?.phase == .succeeded, "A late matching receipt resolves unconfirmed launch")
        try manager.removeItem(at: channel.directory.appendingPathComponent("launch.json"))
        progress.phase = .installing; progress.step = .restoring
        try channel.write(progress, name: "install.json")
        AppUpdateProgressChannel.acknowledgeLaunch(arguments: args, bundleURL: target, bundleIdentifier: "io.github.zz-zed.GPTTouchBarHUD", version: "0.1.37")
        check(channel.progress()?.phase == .failed && channel.progress()?.recovery == .restored, "Old-version launch confirms recovery rather than success")

        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: channel.directory.path)
        check((try? AppUpdateProgressChannel.load(directory: channel.directory, sessionID: channel.context.sessionID)) == nil, "Public session directory is rejected")
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: channel.directory.path)
        let link = directory.appendingPathComponent("linked-session")
        try manager.createSymbolicLink(at: link, withDestinationURL: channel.directory)
        check((try? AppUpdateProgressChannel.load(directory: link, sessionID: channel.context.sessionID)) == nil, "Linked session directory is rejected")
        try manager.removeItem(at: channel.directory.appendingPathComponent("install.json"))
        try manager.removeItem(at: channel.directory.appendingPathComponent("progress.json"))
        let external = directory.appendingPathComponent("external.json")
        try Data(JSONEncoder().encode(progress)).write(to: external)
        try manager.createSymbolicLink(at: channel.directory.appendingPathComponent("progress.json"), withDestinationURL: external)
        check(channel.progress() == nil, "Linked status file is not read")
    }

    static func testDownloads(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let base = ProcessInfo.processInfo.environment["UPDATE_TEST_BASE_URL"], let url = URL(string: base) else {
            preconditionFailure("Run through test-app-update-progress.sh for loopback fixtures")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 10
        let observation = DownloadObservation()
        let download = AppUpdateDownload(configuration: configuration, destination: directory.appendingPathComponent("complete.dmg"),
            onProgress: observation.received, completion: observation.complete)
        download.start(url.appendingPathComponent("good"))
        check(observation.finished.wait(timeout: .now() + 10) == .success, "Streaming download finishes within its fixture deadline")
        observation.lock.lock(); let result = observation.result; let samples = observation.samples; let completions = observation.completions; observation.lock.unlock()
        check(samples.count > 1 && samples.first! < 1_048_576 && samples.last == 1_048_576,
              "URLSession publishes actual bytes before completing the archive")
        check(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }, "Byte callbacks are monotonic")
        check(completions == 1, "Streaming completion is delivered once")
        let received = try result!.get()
        check(try Data(contentsOf: received).count == 1_048_576, "Download preserves all bytes")

        let canceled = DownloadObservation()
        var cancelDownload: AppUpdateDownload!
        cancelDownload = AppUpdateDownload(configuration: configuration, destination: directory.appendingPathComponent("canceled.dmg"),
            onProgress: { bytes in canceled.received(bytes); cancelDownload.cancel() }, completion: canceled.complete)
        cancelDownload.start(url.appendingPathComponent("cancel"))
        check(canceled.finished.wait(timeout: .now() + 10) == .success, "Cancellation resolves the network task")
        canceled.lock.lock(); let cancelResult = canceled.result; let cancelCount = canceled.completions; canceled.lock.unlock()
        if case .failure = cancelResult { check(true, "Canceled archive is rejected") }
        else { check(false, "Canceled archive must not succeed") }
        check(cancelCount == 1 && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("canceled.dmg").path), "Cancellation has no accepted archive or duplicate completion")
        let failed = DownloadObservation()
        let badDownload = AppUpdateDownload(configuration: configuration, destination: directory.appendingPathComponent("bad.dmg"),
            onProgress: failed.received, completion: failed.complete)
        badDownload.start(url.appendingPathComponent("bad"))
        check(failed.finished.wait(timeout: .now() + 10) == .success, "HTTP failure resolves the task")
        if case .failure = failed.result { check(true, "Non-200 archive is rejected") }
        else { check(false, "Non-200 archive must not succeed") }
        check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("bad.dmg").path), "HTTP failure cannot leave an accepted archive")
    }

    static func testWindow() throws {
        let controller = AppUpdateProgressWindowController(sourceVersion: "0.1.37", targetVersion: "v0.1.38")
        let content = controller.window!.contentView!
        let all = descendants(content)
        let primary = all.first { $0.accessibilityIdentifier() == "update-progress.primary" } as! NSButton
        let secondary = all.first { $0.accessibilityIdentifier() == "update-progress.secondary" } as! NSButton
        let bar = all.compactMap { $0 as? NSProgressIndicator }.first!
        var cancels = 0, retries = 0, hides = 0, opens = 0, recoveries = 0
        controller.onCancel = { cancels += 1 }; controller.onRetry = { retries += 1 }
        controller.onHide = { hides += 1 }; controller.onOpenApplication = { opens += 1 }; controller.onRecovery = { recoveries += 1 }
        var value = AppUpdateProgress(sessionID: "window", phase: .downloading, step: .download,
                                      bytesReceived: 419_431, totalBytes: 1_048_576, bytesPerSecond: 300_000)
        controller.update(value)
        check(!bar.isIndeterminate && abs(bar.doubleValue - 0.4) < 0.001 && secondary.title == "取消下载", "Native download displays real percent and cancellation")
        secondary.performClick(nil); check(cancels == 1, "Download cancel emits one user command")
        controller.present(userInitiated: false); primary.performClick(nil)
        check(!controller.window!.isVisible && hides == 1 && cancels == 1, "Hiding does not cancel the update")
        controller.present(userInitiated: false); controller.window!.performClose(nil)
        check(!controller.window!.isVisible && hides == 2 && cancels == 1, "Window close hides ongoing work")
        controller.present(userInitiated: false); controller.window!.cancelOperation(nil)
        check(!controller.window!.isVisible && hides == 3 && cancels == 1, "Escape hides rather than cancels")
        try snapshot(content, name: "download-light")
        value.bytesReceived = value.totalBytes!
        controller.update(value)
        check(primary.title == "后台继续" && bar.doubleValue == 1, "Native download 100% does not offer completed update")
        value.phase = .verifying; value.step = .checksum; controller.update(value)
        check(bar.isIndeterminate && secondary.isHidden, "Verification has stage progress and no cancellation")
        value.phase = .installing; value.step = .replacing; value.recovery = .backupRetained; controller.update(value)
        check(bar.isIndeterminate && secondary.isHidden && primary.title == "后台继续", "Replacement cannot be interrupted by its UI")
        content.appearance = NSAppearance(named: .darkAqua)
        try snapshot(content, name: "install-dark")
        content.appearance = NSAppearance(named: .aqua)
        value.phase = .restarting; value.step = .launching; controller.update(value)
        check(bar.isIndeterminate && primary.title != "完成", "Launching is not a success message")
        value.phase = .launchUnconfirmed; controller.update(value)
        check(primary.title == "打开应用" && secondary.title == "查看恢复说明", "Unconfirmed launch provides explicit follow-up actions")
        primary.performClick(nil); secondary.performClick(nil)
        check(opens == 1 && recoveries == 1, "Unconfirmed launch actions open app and recovery instructions")
        value.phase = .failed; value.step = .download; value.recovery = .untouched; value.message = "网络连接失败。"
        controller.update(value); primary.performClick(nil)
        check(retries == 1 && text(in: content).contains("原应用尚未替换"), "Retry and untouched recovery remain explicit with an error message")
        controller.ownerAvailable = false
        check(primary.title == "打开应用", "A failed session with no owner cannot send an ineffective retry")
        value.recovery = .restored; value.step = .restoring; controller.update(value)
        check(text(in: content).contains("旧版已恢复并完成启动"), "Confirmed restoration is clearly stated")
        value.recovery = .needsRecovery; value.message = String(repeating: "安装中断，请查看恢复说明。", count: 8)
        controller.update(value)
        for view in descendants(content) where !view.isHiddenOrHasHiddenAncestor {
            let frame = view.convert(view.bounds, to: content)
            check(frame.minX >= -1 && frame.maxX <= content.bounds.width + 1 && frame.minY >= -1 && frame.maxY <= content.bounds.height + 1,
                  "Native long-error layout stays within the window")
        }
        value.phase = .succeeded; value.step = .finished; value.message = nil; controller.update(value)
        check(primary.title == "完成" && !bar.isIndeterminate && bar.doubleValue == 1, "Acknowledged success presents completion")
        check(!controller.window!.isVisible, "Background stage changes and success never reopen a hidden window")
        value.phase = .canceled; value.step = .download; value.recovery = .untouched; controller.update(value)
        check(secondary.isHidden && bar.isHidden && text(in: content).contains("已取消下载"), "Cancellation shows its terminal result")
        check(text(in: content).contains("下载已停止") && !text(in: content).contains("安装包下载中"), "Cancellation does not retain an in-flight download label")
    }

    static func testHelperLifetime(in directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("GPT TouchBar HUD.app")
        let channel = try AppUpdateProgressChannel.create(target: target, sourceVersion: "0.1.37", targetVersion: "0.1.38")
        let owner = Process(), installer = Process()
        for process in [owner, installer] { process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["30"]; try process.run() }
        defer { for process in [owner, installer] where process.isRunning { process.terminate(); process.waitUntilExit() } }
        try channel.write(AppUpdateProgressChannel.Context(sessionID: channel.context.sessionID, targetPath: target.path,
            sourceVersion: "0.1.37", targetVersion: "0.1.38", ownerPID: owner.processIdentifier), name: "context.json")
        var value = AppUpdateProgress(sessionID: channel.context.sessionID, phase: .installing, step: .replacing, recovery: .backupRetained)
        try channel.write(value, name: "install.json")
        try channel.write(AppUpdateProgressChannel.Launch(sessionID: channel.context.sessionID, version: "0.1.37", pid: installer.processIdentifier), name: "installer-process.json")
        let executable = channel.directory.appendingPathComponent("progress-helper")
        try manager.copyItem(at: Bundle.main.executableURL!, to: executable)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let helper = Process(); helper.executableURL = executable
        helper.arguments = [AppUpdateProgressHelper.argument, channel.directory.path, channel.context.sessionID]
        helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
        try helper.run()
        defer { if helper.isRunning { helper.terminate(); helper.waitUntilExit() } }
        spin(for: 0.5)
        owner.terminate(); owner.waitUntilExit()
        spin(for: 0.5)
        check(helper.isRunning, "Private update UI survives the old application process exiting")
        value.phase = .launchUnconfirmed; value.step = .launching
        try channel.write(value, name: "install.json")
        try channel.write(AppUpdateProgressChannel.Launch(sessionID: UUID().uuidString, version: "0.1.38", pid: getpid()), name: "launch.json")
        spin(for: 0.5)
        check(helper.isRunning, "Unconfirmed or foreign launch receipt does not close the helper")
        try channel.write(AppUpdateProgressChannel.Launch(sessionID: channel.context.sessionID, version: "0.1.38", pid: getpid()), name: "launch.json")
        check(wait { !helper.isRunning }, "Matching late startup receipt completes and closes the temporary UI")
        check(helper.terminationStatus == 0, "Progress helper finishes without initializing HUD services")
    }

    static func testInstallation(in directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("GPT TouchBar HUD.app")
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: target.appendingPathComponent("marker"))
        let channel = try AppUpdateProgressChannel.create(target: target, sourceVersion: "0.1.37", targetVersion: "v0.1.38")
        let base = URL(string: ProcessInfo.processInfo.environment["UPDATE_TEST_BASE_URL"]!)!
        let asset = AppRelease.Asset(name: "GPT-TouchBar-HUD-0.1.38-arm64.dmg", browser_download_url: base.appendingPathComponent("retry.dmg"), size: 1_048_576)
        let sums = AppRelease.Asset(name: "SHA256SUMS.txt", browser_download_url: base.appendingPathComponent("checksums"), size: 100)
        let release = AppRelease(tag_name: "v0.1.38", draft: false, prerelease: false, assets: [asset, sums])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let job = AppUpdateInstallation(session: session, release: release, asset: asset, checksum: sums, channel: channel)
        defer { job.dismiss(); spin(for: 0.5) }
        var sawReset = false
        job.onChange = { [weak job] changed in
            if changed && job?.progress.phase == .preparing && job?.progress.bytesReceived == 0 { sawReset = true }
        }
        job.onInstall = { preconditionFailure("Fixture download must never install an application") }
        try job.start()
        check(wait { job.progress.phase == .failed }, "First HTTP error is a retryable download failure")
        check(job.progress.canRetry && !job.handedOff, "Download failure has not handed off an installer")
        check(job.isPollingCommands, "A visible failure result retains the retry command channel")
        try channel.send(.dismiss, toHelper: true)
        check(wait { !job.isPollingCommands }, "Helper exit after failure stops command-file polling")
        sawReset = false
        try channel.send(.retry)
        spin(for: 0.4)
        check(job.progress.phase == .failed, "A closed result does not keep reading retry commands")
        job.showProgress()
        check(job.isPollingCommands, "Reopening a result restores command polling")
        check(wait { job.progress.phase == .downloading && job.progress.bytesReceived > 0 }, "Retry starts a new real byte stream")
        check(sawReset && job.progress.bytesReceived < 1_048_576, "Retry begins at zero rather than reusing old progress")
        try channel.write(AppUpdateProgressChannel.Command(sessionID: UUID().uuidString, requestID: UUID().uuidString, action: .cancel), name: "command.json")
        spin(for: 0.3)
        check(job.progress.phase == .downloading, "Another session cannot cancel the active download")
        try channel.send(.cancel)
        check(wait { job.progress.phase == .canceled }, "Native helper command cancels the active attempt")
        spin(for: 0.4)
        check(job.progress.phase == .canceled && !job.handedOff, "A stale task callback cannot overwrite the canceled state")
        check(try String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8) == "original", "Download retry and cancellation never touch the installed application")
        check(try manager.contentsOfDirectory(atPath: channel.directory.path).allSatisfy { !$0.hasPrefix("archive-") }, "Canceled attempts leave no accepted archive")
        try channel.send(.dismiss, toHelper: true)
        check(wait { !job.isPollingCommands }, "Helper exit after cancellation stops command-file polling")
        job.showProgress()
        check(job.isPollingCommands && job.progress.phase == .canceled, "Canceled result can be reopened without restarting a download")
        try channel.send(.dismiss, toHelper: true)
        check(wait { !job.isPollingCommands }, "Reopened canceled result also releases its poller when closed")
    }

    static func testVerificationFailure(in directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("GPT TouchBar HUD.app")
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: target.appendingPathComponent("marker"))
        let channel = try AppUpdateProgressChannel.create(target: target, sourceVersion: "0.1.37", targetVersion: "v0.1.38")
        let base = URL(string: ProcessInfo.processInfo.environment["UPDATE_TEST_BASE_URL"]!)!
        let asset = AppRelease.Asset(name: "GPT-TouchBar-HUD-0.1.38-arm64.dmg", browser_download_url: base.appendingPathComponent("invalid.dmg"), size: 1_048_576)
        let sums = AppRelease.Asset(name: "SHA256SUMS.txt", browser_download_url: base.appendingPathComponent("checksums"), size: 100)
        let release = AppRelease(tag_name: "v0.1.38", draft: false, prerelease: false, assets: [asset, sums])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let job = AppUpdateInstallation(session: session, release: release, asset: asset, checksum: sums, channel: channel)
        defer { job.dismiss(); spin(for: 0.5) }
        job.onInstall = { preconditionFailure("Invalid fixture must never reach application replacement") }
        try job.start()
        check(wait { job.progress.phase == .failed }, "A real downloaded archive fails the injected checksum")
        check(job.progress.step == .checksum && !job.progress.canRetry && !job.handedOff,
              "Preparation failure cannot retry in the same session or skip verification")
        try channel.send(.retry); spin(for: 0.4)
        check(job.progress.phase == .failed && job.progress.step == .checksum,
              "A retry command cannot reuse artifacts after verification failure")
        try channel.send(.dismiss, toHelper: true)
        check(wait { !job.isPollingCommands }, "Verification failure result releases polling when the helper exits")
        check(try String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8) == "original",
              "Failure injection preserves the original application")
    }

    static func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(6)
        while !condition() && Date() < deadline { spin(for: 0.01) }
        return condition()
    }
    static func spin(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    static func run(_ executable: URL, _ args: [String]) throws -> Int32 {
        let process = Process(); process.executableURL = executable; process.arguments = args
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func text(in view: NSView) -> String { descendants(view).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ") }
    static func snapshot(_ view: NSView, name: String) throws {
        view.wantsLayer = true
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let directory = URL(fileURLWithPath: ".build/update-progress-tests/native", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
