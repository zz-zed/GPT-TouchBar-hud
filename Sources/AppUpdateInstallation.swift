import AppKit
import CryptoKit

/// Main-queue state, with download delegates and package preparation off the UI thread.
final class AppUpdateInstallation {
    let channel: AppUpdateProgressChannel
    private(set) var progress: AppUpdateProgress
    private(set) var handedOff = false
    var onChange: ((Bool) -> Void)?
    var onInstall: (() -> Void)?
    var onPresentationFailure: ((String) -> Void)?
    private let session: URLSession
    private let release: AppRelease
    private let asset: AppRelease.Asset
    private let checksum: AppRelease.Asset
    private let worker = DispatchQueue(label: "GPTTouchBarHUD.update.prepare", qos: .utility)
    private var attemptID = UUID()
    private var request: URLSessionDataTask?
    private var download: AppUpdateDownload?
    private var helper: Process?
    private var commands: Timer?
    private var lastCommandID: String?
    private var lastBytePublish: TimeInterval = 0
    private var lastSpeedBytes: Int64 = 0
    private var lastSpeedTime: TimeInterval = 0

    init(session: URLSession, release: AppRelease, asset: AppRelease.Asset,
         checksum: AppRelease.Asset, channel: AppUpdateProgressChannel) {
        self.session = session; self.release = release; self.asset = asset
        self.checksum = checksum; self.channel = channel
        progress = AppUpdateProgress(sessionID: channel.context.sessionID, phase: .preparing, step: .connecting)
    }

    func start() throws {
        try channel.write(progress, name: "progress.json")
        try launchHelper()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.pollCommands() }
        commands = timer; RunLoop.main.add(timer, forMode: .common)
        beginAttempt()
    }

    func showProgress() {
        do {
            if helper?.isRunning == true { try channel.send(.show, toHelper: true) }
            else { try launchHelper() }
        } catch { NSLog("Could not open update progress: %@", error.localizedDescription) }
    }

    func stop() {
        commands?.invalidate(); commands = nil
        if !handedOff && progress.isActive {
            attemptID = UUID(); request?.cancel(); download?.cancel()
            progress.phase = .failed
            progress.message = "更新已中断，原应用尚未替换。"
            publish(phaseChanged: true)
        }
    }

    func dismiss() {
        stop()
        try? channel.send(.dismiss, toHelper: true)
    }

    private func launchHelper() throws {
        let executable = channel.directory.appendingPathComponent("progress-helper")
        if !FileManager.default.fileExists(atPath: executable.path) {
            guard let source = Bundle.main.executableURL else { throw failure("更新进度助手缺失。") }
            try FileManager.default.copyItem(at: source, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [AppUpdateProgressHelper.argument, channel.directory.path, channel.context.sessionID]
        let log = channel.directory.appendingPathComponent("progress-helper.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let output = try FileHandle(forWritingTo: log)
        try output.seekToEnd()
        process.standardOutput = output; process.standardError = output
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.progress.isActive, !self.handedOff else { return }
                self.fail("更新进度窗口已退出，原应用尚未替换。请重新打开进度后重试。")
                self.onPresentationFailure?(self.progress.detail)
            }
        }
        try process.run(); try? output.close()
        helper = process
    }

    private func pollCommands() {
        guard let command = channel.readValue("command.json", as: AppUpdateProgressChannel.Command.self),
              command.sessionID == channel.context.sessionID, command.requestID != lastCommandID else { return }
        lastCommandID = command.requestID
        switch command.action {
        case .cancel:
            guard progress.canCancel else { return }
            attemptID = UUID(); request?.cancel(); download?.cancel()
            progress.phase = .canceled; progress.message = nil
            publish(phaseChanged: true)
        case .retry:
            guard progress.canRetry, !handedOff else { return }
            beginAttempt()
        case .show, .dismiss: break
        }
    }

    private func beginAttempt() {
        attemptID = UUID()
        let id = attemptID
        request?.cancel(); download?.cancel(); download = nil
        progress = AppUpdateProgress(sessionID: channel.context.sessionID, phase: .preparing, step: .connecting)
        lastBytePublish = 0; lastSpeedBytes = 0; lastSpeedTime = ProcessInfo.processInfo.systemUptime
        publish(phaseChanged: true)
        guard progress.phase == .preparing else { return }
        if asset.size > 0 {
            guard asset.size < 400_000_000 else { fail("无法确认安装包大小，已拒绝下载。"); return }
            fetchChecksum(size: Int64(asset.size), attempt: id)
        } else {
            var head = URLRequest(url: asset.browser_download_url)
            head.httpMethod = "HEAD"
            request = session.dataTask(with: head) { [weak self] _, response, error in
                DispatchQueue.main.async {
                    guard let self, self.accepts(id, phase: .preparing) else { return }
                    let size = response?.expectedContentLength ?? -1
                    guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                          size > 0, size < 400_000_000 else {
                        self.fail("无法确认安装包大小，已拒绝下载。"); return
                    }
                    self.fetchChecksum(size: size, attempt: id)
                }
            }
            request?.resume()
        }
    }

    private func fetchChecksum(size: Int64, attempt id: UUID) {
        progress.totalBytes = size; progress.step = .checksums
        publish(phaseChanged: true)
        guard progress.phase == .preparing else { return }
        request = session.dataTask(with: checksum.browser_download_url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.accepts(id, phase: .preparing) else { return }
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, data.count < 65_536, let text = String(data: data, encoding: .utf8),
                      let expected = AppRelease.checksum(in: text, filename: self.asset.name) else {
                    self.fail("校验文件下载失败或格式无效。"); return
                }
                self.startDownload(size: size, expected: expected, attempt: id)
            }
        }
        request?.resume()
    }

    private func startDownload(size: Int64, expected: String, attempt id: UUID) {
        progress.phase = .downloading; progress.step = .download
        lastSpeedTime = ProcessInfo.processInfo.systemUptime
        publish(phaseChanged: true)
        guard progress.phase == .downloading else { return }
        let download = AppUpdateDownload(configuration: session.configuration,
            destination: channel.directory.appendingPathComponent("archive-\(id.uuidString).dmg"),
            onProgress: { [weak self] bytes in
                DispatchQueue.main.async { self?.received(bytes, expectedSize: size, attempt: id) }
            }, completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.accepts(id, phase: .downloading) else {
                        if case let .success(archive) = result { try? FileManager.default.removeItem(at: archive) }
                        return
                    }
                    switch result {
                    case .failure: self.fail("安装包下载失败。请检查网络后重试。")
                    case let .success(archive):
                        self.progress.phase = .verifying; self.progress.step = .checksum
                        self.progress.bytesPerSecond = nil
                        self.publish(phaseChanged: true)
                        self.prepare(archive: archive, size: size, expected: expected, attempt: id)
                    }
                }
            })
        self.download = download
        download.start(asset.browser_download_url)
    }

    private func received(_ bytes: Int64, expectedSize: Int64, attempt id: UUID) {
        guard accepts(id, phase: .downloading) else { return }
        guard bytes <= expectedSize else { fail("安装包大小超过预期，已停止下载。"); return }
        let time = ProcessInfo.processInfo.systemUptime
        progress.bytesReceived = max(progress.bytesReceived, bytes)
        guard time - lastBytePublish >= 0.25 || bytes == expectedSize else { return }
        if time - lastSpeedTime >= 1 {
            progress.bytesPerSecond = Double(max(0, bytes - lastSpeedBytes)) / (time - lastSpeedTime)
            lastSpeedBytes = bytes; lastSpeedTime = time
        }
        lastBytePublish = time
        publish(phaseChanged: false)
    }

    private func accepts(_ id: UUID, phase: AppUpdateProgress.Phase) -> Bool {
        attemptID == id && progress.phase == phase && !handedOff
    }

    private func publish(phaseChanged: Bool) {
        do { try channel.write(progress, name: "progress.json") }
        catch {
            attemptID = UUID(); request?.cancel(); download?.cancel()
            progress.phase = .failed; progress.message = "无法保存更新进度，原应用尚未替换。"
            onPresentationFailure?(progress.message!)
        }
        onChange?(phaseChanged || progress.phase == .failed)
    }

    private func fail(_ message: String) {
        attemptID = UUID(); request?.cancel(); download?.cancel()
        progress.phase = .failed; progress.message = message
        publish(phaseChanged: true)
    }

    private func prepare(archive: URL, size: Int64, expected: String, attempt id: UUID) {
        let channel = channel, release = release
        worker.async { [weak self] in
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
                guard (attributes[.size] as? NSNumber)?.int64Value == size else { throw Self.failure("安装包大小不匹配。") }
                let handle = try FileHandle(forReadingFrom: archive)
                defer { try? handle.close() }
                var digest = SHA256()
                while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
                guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
                    throw Self.failure("SHA-256 校验失败，已拒绝安装。")
                }
                func report(_ phase: AppUpdateProgress.Phase, _ step: AppUpdateProgress.Step) {
                    DispatchQueue.main.async {
                        guard let self, self.attemptID == id, self.progress.isActive else { return }
                        self.progress.phase = phase; self.progress.step = step
                        self.publish(phaseChanged: true)
                    }
                }
                report(.verifying, .mounting)
                let mount = channel.directory.appendingPathComponent("mount")
                try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
                try Self.run("/usr/bin/hdiutil", ["attach", archive.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path])
                defer { try? Self.run("/usr/bin/hdiutil", ["detach", mount.path]) }
                report(.verifying, .validating)
                let source = mount.appendingPathComponent("GPT TouchBar HUD.app")
                guard source.resolvingSymlinksInPath() == source,
                      let bundle = Bundle(url: source), bundle.bundleIdentifier == AppIdentity.bundleIdentifier,
                      let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                      AppVersion(version) == AppVersion(release.tag_name), let executable = bundle.executableURL,
                      executable.resolvingSymlinksInPath().path.hasPrefix(source.path + "/Contents/MacOS/") else {
                    throw Self.failure("应用标识或版本不匹配。")
                }
                try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path])
                #if arch(arm64)
                let architecture = "arm64"
                #else
                let architecture = "x86_64"
                #endif
                try Self.run("/usr/bin/lipo", [executable.path, "-verify_arch", architecture])
                if let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
                   let required = AppVersion(minimum) {
                    let os = ProcessInfo.processInfo.operatingSystemVersion
                    guard let current = AppVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"), current >= required else {
                        throw Self.failure("新版本需要更新的 macOS，已取消安装。")
                    }
                }
                report(.installing, .copying)
                let payload = channel.directory.appendingPathComponent("new.app")
                try Self.run("/usr/bin/ditto", [source.path, payload.path])
                try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", payload.path])
                guard let helper = Bundle.main.url(forResource: "install-update", withExtension: "sh") else {
                    throw Self.failure("更新助手缺失。")
                }
                try FileManager.default.copyItem(at: helper, to: channel.directory.appendingPathComponent("install-update.sh"))
                DispatchQueue.main.async {
                    guard let self, self.attemptID == id, self.progress.isActive else { return }
                    do { try self.handoff() } catch { self.fail(error.localizedDescription) }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.attemptID == id else { return }
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func handoff() throws {
        guard helper?.isRunning == true else { throw Self.failure("更新进度助手已退出，原应用尚未替换。") }
        progress.phase = .installing; progress.step = .waitingForExit
        publish(phaseChanged: true)
        guard progress.isActive else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [channel.directory.appendingPathComponent("install-update.sh").path,
            String(getpid()), channel.context.targetPath, channel.directory.path, channel.context.sessionID]
        let log = channel.directory.appendingPathComponent("install.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        process.standardOutput = output; process.standardError = output
        try process.run(); try? output.close()
        do {
            try channel.write(AppUpdateProgressChannel.Launch(sessionID: channel.context.sessionID,
                version: channel.context.sourceVersion, pid: process.processIdentifier), name: "installer-process.json")
        } catch { process.terminate(); throw error }
        handedOff = true
        onInstall?()
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date(timeIntervalSinceNow: 120)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); throw failure("更新准备超时，原应用未替换。") }
        guard process.terminationStatus == 0 else { throw failure("更新准备失败，原应用未替换。") }
    }
    private func failure(_ message: String) -> NSError { Self.failure(message) }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "AppUpdateInstallation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
