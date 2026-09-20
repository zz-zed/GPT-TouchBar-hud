import AppKit
import CryptoKit

final class GitHubReleaseFetcher: AppReleaseFetching {
    private let session: URLSession
    private let userAgent: String

    init(session: URLSession, version: String) {
        self.session = session
        userAgent = "GPTTouchBarHUD/\(version)"
    }

    func fetchLatest(completion: @escaping (Result<AppRelease, AppUpdateFetchFailure>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppRelease.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            if http?.statusCode == 403 || http?.statusCode == 429 {
                let retryAfter = self.retryDate(from: http)
                self.complete(.failure(AppUpdateFetchFailure("GitHub 暂时限制了更新检查，请稍后重试。", retryAfter: retryAfter)), completion)
                return
            }
            if error == nil, http?.statusCode == 200,
               let data, data.count < 2_000_000,
               let release = try? JSONDecoder().decode(AppRelease.self, from: data),
               !release.draft, !release.prerelease {
                self.complete(.success(release), completion)
                return
            }
            self.fetchReleasePage(completion: completion)
        }.resume()
    }

    private func fetchReleasePage(completion: @escaping (Result<AppRelease, AppUpdateFetchFailure>) -> Void) {
        var request = URLRequest(url: AppRelease.page)
        request.httpMethod = "HEAD"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            if http?.statusCode == 403 || http?.statusCode == 429 {
                let retryAfter = self.retryDate(from: http)
                self.complete(.failure(AppUpdateFetchFailure("GitHub 暂时限制了更新检查，请稍后重试。", retryAfter: retryAfter)), completion)
                return
            }
            guard error == nil, http?.statusCode == 200,
                  let finalURL = response?.url,
                  let release = AppRelease.fromLatestPageURL(finalURL) else {
                self.complete(.failure(AppUpdateFetchFailure("GitHub API 和 Release 页面均无法读取。请检查网络或稍后重试；不会安装任何文件。")), completion)
                return
            }
            self.complete(.success(release), completion)
        }.resume()
    }

    private func retryDate(from response: HTTPURLResponse?) -> Date? {
        guard let response else { return nil }
        if let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init), seconds >= 0 {
            return Date().addingTimeInterval(seconds)
        }
        if let epoch = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init), epoch > 0 {
            return Date(timeIntervalSince1970: epoch)
        }
        return nil
    }

    private func complete(
        _ result: Result<AppRelease, AppUpdateFetchFailure>,
        _ completion: @escaping (Result<AppRelease, AppUpdateFetchFailure>) -> Void
    ) {
        DispatchQueue.main.async { completion(result) }
    }
}

/// Public GitHub releases only; never sends account credentials or task data.
final class AppUpdater: NSObject {
    private let session: URLSession
    private let preferences: AppUpdatePreferences
    private let policy: AppUpdateSchedulePolicy
    private let now: () -> Date
    private let automaticChecksAvailable: Bool
    private let fetcher: AppReleaseFetching
    private var installationInProgress = false
    private var started = false
    private var launchedAt: Date?
    private var scheduledCheck: DispatchWorkItem?
    private var latestRelease: AppRelease?
    private lazy var checker: AppUpdateCheckEngine = {
        let checker = AppUpdateCheckEngine(fetcher: fetcher, currentVersion: Self.version)
        checker.onCompletion = { [weak self] outcome, origins in
            self?.handle(outcome, origins: origins)
        }
        return checker
    }()

    override convenience init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration)
        let automaticChecksAvailable = AppUpdateRuntime.allowsAutomaticChecks(
            bundleURL: Bundle.main.bundleURL,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        self.init(
            session: session,
            preferences: AppUpdatePreferences(),
            policy: .standard,
            now: Date.init,
            automaticChecksAvailable: automaticChecksAvailable
        )
    }

    init(
        session: URLSession,
        preferences: AppUpdatePreferences,
        policy: AppUpdateSchedulePolicy,
        now: @escaping () -> Date,
        automaticChecksAvailable: Bool,
        fetcher: AppReleaseFetching? = nil
    ) {
        self.session = session
        self.preferences = preferences
        self.policy = policy
        self.now = now
        self.automaticChecksAvailable = automaticChecksAvailable
        self.fetcher = fetcher ?? GitHubReleaseFetcher(session: session, version: Self.version)
        super.init()
        reconcilePersistentVersions()
    }

    var onInstall: (() -> Void)?
    var onStateChange: (() -> Void)?
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0" }
    static var versionLabel: String {
        "版本 \(version)（构建 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")）"
    }
    var canCheck: Bool { !installationInProgress }
    var isChecking: Bool { checker.isChecking }
    var viewState: AppUpdateViewState {
        let state = preferences.state
        return AppUpdateViewState(
            automaticChecksEnabled: preferences.automaticChecksEnabled,
            automaticChecksAvailable: automaticChecksAvailable,
            availableVersion: visibleAvailableVersion(in: state),
            lastSuccess: state.lastSuccess,
            isChecking: checker.isChecking,
            isInstalling: installationInProgress
        )
    }

    func startAutomaticChecks() {
        guard !started else { return }
        started = true
        launchedAt = now()
        scheduleAutomaticCheck()
        notifyStateChanged()
    }

    func stop() {
        scheduledCheck?.cancel()
        scheduledCheck = nil
        started = false
    }

    func didWake() {
        guard automaticChecksAvailable, preferences.automaticChecksEnabled, !installationInProgress else { return }
        scheduledCheck?.cancel()
        scheduledCheck = nil
        let date = now()
        let shouldCheck = launchedAt.map {
            AppUpdateSchedulePlanner(launchedAt: $0, policy: policy)
                .shouldCheckAfterWake(state: preferences.state, now: date)
        } ?? true
        if shouldCheck {
            request(.automatic)
        } else {
            scheduleAutomaticCheck()
        }
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        preferences.automaticChecksEnabled = enabled
        scheduledCheck?.cancel()
        scheduledCheck = nil
        if enabled { scheduleAutomaticCheck() }
        notifyStateChanged()
    }

    func check() {
        request(.manual)
    }

    func presentAvailableUpdate() {
        if checker.isChecking {
            request(.manual)
            return
        }
        let expected = viewState.availableVersion
        if let latestRelease, latestRelease.tag_name == expected {
            offer(latestRelease)
        } else {
            request(.manual)
        }
    }

    private func request(_ origin: AppUpdateCheckOrigin) {
        guard !installationInProgress else { return }
        let disposition = checker.request(origin)
        if disposition == .started {
            var state = preferences.state
            state.lastAttempt = now()
            preferences.state = state
        }
        notifyStateChanged()
    }

    private func handle(_ outcome: AppUpdateCheckOutcome, origins: Set<AppUpdateCheckOrigin>) {
        let date = now()
        var state = preferences.state
        switch outcome {
        case let .failure(error):
            state = policy.recordingAutomaticFailure(in: state, at: date, serverRetryAfter: error.retryAfter)
            preferences.state = state
            notifyStateChanged()
            scheduleAutomaticCheck()
            if AppUpdatePresentationPolicy.shouldPresentResult(for: origins) {
                message("无法检查更新", error.message)
            }
        case let .upToDate(release):
            latestRelease = release
            state = policy.recordingSuccess(in: state, at: date)
            state.availableVersion = nil
            preferences.state = state
            notifyStateChanged()
            scheduleAutomaticCheck()
            if AppUpdatePresentationPolicy.shouldPresentResult(for: origins) {
                message("无需更新", "当前版本 \(Self.version)，最新正式版 \(release.tag_name)。")
            }
        case let .update(release):
            latestRelease = release
            state = policy.recordingSuccess(in: state, at: date)
            state.availableVersion = AppUpdateAvailabilityPolicy.storedVersion(
                for: release,
                skippedVersion: state.skippedVersion
            )
            preferences.state = state
            notifyStateChanged()
            scheduleAutomaticCheck()
            if AppUpdatePresentationPolicy.shouldPresentResult(for: origins) { offer(release) }
        }
    }

    private func offer(_ release: AppRelease) {
        guard !installationInProgress, !checker.isChecking else { return }
        let alert = NSAlert()
        if let name = release.name, !name.isEmpty {
            alert.messageText = name
        } else {
            alert.messageText = "发现新版本 \(release.tag_name)"
        }
        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let notes, !notes.isEmpty {
            alert.informativeText = String(notes.prefix(1_500))
        } else {
            alert.informativeText = "当前版本 \(Self.version)。完整版本说明：\n\(release.releasePageURL.absoluteString)"
        }
        alert.addButton(withTitle: "安装并重启")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过此版本")
        let response = alert.runModal()
        if response == .alertThirdButtonReturn {
            preferences.state = AppUpdateAvailabilityPolicy.skipping(release.tag_name, in: preferences.state)
            notifyStateChanged()
            return
        }
        guard response == .alertFirstButtonReturn else { return }

        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard let asset = release.installer(architecture: architecture), let checksum = release.checksums else {
            message("新版本 \(release.tag_name) 暂不可自动安装", "缺少匹配架构的安装包或校验文件，请等待发布完成。")
            return
        }
        let target = Bundle.main.bundleURL.standardizedFileURL
        let allowed = [URL(fileURLWithPath: "/Applications/GPT TouchBar HUD.app"),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/GPT TouchBar HUD.app")]
        guard allowed.contains(target), target.resolvingSymlinksInPath() == target,
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            let alert = NSAlert()
            alert.messageText = "发现新版本 \(release.tag_name)"
            alert.informativeText = "开发目录、磁盘映像或不可写目录中的应用不能原地更新。请先安装到 /Applications 或 ~/Applications；本地实验构建不会被覆盖。"
            alert.addButton(withTitle: "打开发布页面"); alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.releasePageURL) }
            return
        }
        installationInProgress = true
        scheduledCheck?.cancel()
        scheduledCheck = nil
        notifyStateChanged()
        download(asset: asset, checksum: checksum, release: release, target: target)
    }

    private func scheduleAutomaticCheck() {
        scheduledCheck?.cancel()
        scheduledCheck = nil
        guard started, automaticChecksAvailable, preferences.automaticChecksEnabled,
              !installationInProgress, !checker.isChecking,
              let launchedAt else { return }
        let date = now()
        let scheduledDate = AppUpdateSchedulePlanner(launchedAt: launchedAt, policy: policy)
            .nextDate(state: preferences.state, now: date)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledCheck = nil
            guard self.preferences.automaticChecksEnabled, !self.installationInProgress else { return }
            let currentDate = self.now()
            if self.policy.isDue(state: self.preferences.state, now: currentDate) {
                self.request(.automatic)
            } else {
                self.scheduleAutomaticCheck()
            }
        }
        scheduledCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, scheduledDate.timeIntervalSince(date)), execute: work)
    }

    private func reconcilePersistentVersions() {
        guard let current = AppVersion(Self.version) else { return }
        var state = preferences.state
        if let availableVersion = state.availableVersion {
            if let available = AppVersion(availableVersion) {
                if available <= current { state.availableVersion = nil }
            } else {
                state.availableVersion = nil
            }
        }
        if let skippedVersion = state.skippedVersion {
            if let skipped = AppVersion(skippedVersion) {
                if skipped <= current { state.skippedVersion = nil }
            } else {
                state.skippedVersion = nil
            }
        }
        preferences.state = state
    }

    private func visibleAvailableVersion(in state: AppUpdatePersistentState) -> String? {
        guard let version = state.availableVersion,
              version != state.skippedVersion,
              let latest = AppVersion(version),
              let current = AppVersion(Self.version), latest > current else { return nil }
        return version
    }

    private func notifyStateChanged() {
        onStateChange?()
    }

    private func download(asset: AppRelease.Asset, checksum: AppRelease.Asset, release: AppRelease, target: URL) {
        resolveSize(for: asset) { [weak self] verifiedSize in
            guard let self else { return }
            guard let verifiedSize else { self.finish(error: "无法确认安装包大小，已拒绝下载。"); return }
            self.downloadVerified(asset: asset, verifiedSize: verifiedSize, checksum: checksum, release: release, target: target)
        }
    }
    private func resolveSize(for asset: AppRelease.Asset, completion: @escaping (Int?) -> Void) {
        if asset.size > 0 {
            completion(asset.size < 400_000_000 ? asset.size : nil)
            return
        }
        var request = URLRequest(url: asset.browser_download_url)
        request.httpMethod = "HEAD"
        session.dataTask(with: request) { _, response, error in
            let size = response?.expectedContentLength ?? -1
            completion(error == nil && (response as? HTTPURLResponse)?.statusCode == 200 && size > 0 && size < 400_000_000 ? Int(size) : nil)
        }.resume()
    }
    private func downloadVerified(asset: AppRelease.Asset, verifiedSize: Int, checksum: AppRelease.Asset, release: AppRelease, target: URL) {
        session.dataTask(with: checksum.browser_download_url) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                  let data, data.count < 65536, let text = String(data: data, encoding: .utf8),
                  let expected = AppRelease.checksum(in: text, filename: asset.name) else {
                self.finish(error: "校验文件下载失败或格式无效。"); return
            }
            self.session.downloadTask(with: asset.browser_download_url) { [weak self] temporary, response, error in
                guard let self else { return }
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let temporary else {
                    self.finish(error: "安装包下载失败。"); return
                }
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
                    guard (attributes[.size] as? NSNumber)?.intValue == verifiedSize else { throw UpdateError.invalid("安装包大小不匹配。") }
                    let handle = try FileHandle(forReadingFrom: temporary)
                    defer { try? handle.close() }
                    var digest = SHA256()
                    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
                    guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
                        throw UpdateError.invalid("SHA-256 校验失败，已拒绝安装。")
                    }
                    try self.prepare(archive: temporary, release: release, target: target)
                } catch { self.finish(error: error.localizedDescription) }
            }.resume()
        }.resume()
    }
    private func prepare(archive: URL, release: AppRelease, target: URL) throws {
        let manager = FileManager.default
        let staging = target.deletingLastPathComponent().appendingPathComponent(".GPTTouchBarHUD-update-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var handedOff = false
        defer { if !handedOff { try? manager.removeItem(at: staging) } }
        let mount = staging.appendingPathComponent("mount")
        try manager.createDirectory(at: mount, withIntermediateDirectories: false)
        try Self.run("/usr/bin/hdiutil", ["attach", archive.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path])
        defer { try? Self.run("/usr/bin/hdiutil", ["detach", mount.path]) }
        let source = mount.appendingPathComponent("GPT TouchBar HUD.app")
        guard source.resolvingSymlinksInPath() == source,
              let bundle = Bundle(url: source), bundle.bundleIdentifier == AppIdentity.bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              AppVersion(version) == AppVersion(release.tag_name) else { throw UpdateError.invalid("应用标识或版本不匹配。") }
        try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path])
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard let executable = bundleExecutable(source) else { throw UpdateError.invalid("安装包缺少主程序。") }
        try Self.run("/usr/bin/lipo", [executable.path, "-verify_arch", architecture])
        if let minimum = Bundle(url: source)?.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
           let required = AppVersion(minimum) {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            guard let current = AppVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"), current >= required else {
                throw UpdateError.invalid("新版本需要更新的 macOS，已取消安装。")
            }
        }
        let payload = staging.appendingPathComponent("new.app")
        try Self.run("/usr/bin/ditto", [source.path, payload.path])
        try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", payload.path])
        guard let helperSource = Bundle.main.url(forResource: "install-update", withExtension: "sh") else { throw UpdateError.invalid("更新助手缺失。") }
        let helper = staging.appendingPathComponent("install-update.sh")
        try manager.copyItem(at: helperSource, to: helper)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier), target.path, staging.path]
        let log = staging.appendingPathComponent("install.log")
        manager.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        process.standardOutput = output; process.standardError = output
        try process.run()
        try? output.close()
        handedOff = true
        DispatchQueue.main.async { [weak self] in self?.onInstall?() }
    }
    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date(timeIntervalSinceNow: 120)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); throw UpdateError.invalid("更新准备超时，原应用未替换。") }
        guard process.terminationStatus == 0 else { throw UpdateError.invalid("更新准备失败（\(URL(fileURLWithPath: executable).lastPathComponent)）。原应用未替换。") }
    }
    private func bundleExecutable(_ url: URL) -> URL? {
        guard let executable = Bundle(url: url)?.executableURL,
              executable.resolvingSymlinksInPath().path.hasPrefix(url.path + "/Contents/MacOS/") else { return nil }
        return executable
    }
    private func finish(error: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.installationInProgress = false
            self.notifyStateChanged()
            self.scheduleAutomaticCheck()
            self.message("更新未完成", error)
        }
    }
    private func message(_ title: String, _ detail: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "好"); alert.runModal()
    }
    private enum UpdateError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
    }
}
