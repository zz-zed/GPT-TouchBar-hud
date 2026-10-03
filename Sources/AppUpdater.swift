import AppKit

/// Public GitHub releases only; never sends account credentials or task data.
final class AppUpdater: NSObject {
    private let session: URLSession
    private let preferences: AppUpdatePreferences
    private let policy: AppUpdateSchedulePolicy
    private let now: () -> Date
    private let automaticChecksAvailable: Bool
    private let fetcher: AppReleaseFetching
    private let notifications: AppUpdateNotificationController
    private var installation: AppUpdateInstallation?
    private var installationInProgress: Bool { installation?.progress.isActive == true }
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
        fetcher: AppReleaseFetching? = nil,
        notifications: AppUpdateNotificationController = AppUpdateNotificationController()
    ) {
        self.session = session
        self.preferences = preferences
        self.policy = policy
        self.now = now
        self.automaticChecksAvailable = automaticChecksAvailable
        self.fetcher = fetcher ?? GitHubReleaseFetcher(session: session, version: Self.version)
        self.notifications = notifications
        super.init()
        reconcilePersistentVersions()
        syncNotifications()
        notifications.onStateChange = { [weak self] in self?.notifyStateChanged() }
        notifications.onOpenRelease = { [weak self] version in
            guard let self, self.viewState.availableVersion == version else { return }
            self.presentAvailableUpdate()
        }
    }

    var onInstall: (() -> Void)?
    var onStateChange: (() -> Void)?
    var onProgressChange: (() -> Void)?
    var canQuit: Bool { !installationInProgress || installation?.progress.canCancel == true || installation?.handedOff == true }

    func presentInstallationProgress() { installation?.showProgress() }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0" }
    static var versionLabel: String {
        "版本 \(version)（构建 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")）"
    }
    var canCheck: Bool { !installationInProgress }
    var isChecking: Bool { checker.isChecking }
    var notificationsEnabled: Bool { notifications.enabled }
    var notificationPermission: ResetNewsNotificationPermission { notifications.permission }

    func setNotificationsEnabled(_ enabled: Bool, userInitiated: Bool) {
        notifications.setEnabled(enabled, userInitiated: userInitiated)
    }

    func refreshNotificationPermission() { notifications.refreshPermission() }

    private func syncNotifications(origins: Set<AppUpdateCheckOrigin> = []) {
        let state = preferences.state
        notifications.update(availableVersion: visibleAvailableVersion(in: state), currentVersion: Self.version,
                             skippedVersion: state.skippedVersion, origins: origins)
    }
    var viewState: AppUpdateViewState {
        let state = preferences.state
        return AppUpdateViewState(
            automaticChecksEnabled: preferences.automaticChecksEnabled,
            automaticChecksAvailable: automaticChecksAvailable,
            availableVersion: visibleAvailableVersion(in: state),
            lastSuccess: state.lastSuccess,
            isChecking: checker.isChecking,
            isInstalling: installationInProgress,
            progress: installation?.progress
        )
    }

    func startAutomaticChecks() {
        guard !started else { return }
        started = true
        launchedAt = now()
        if automaticChecksAvailable { notifications.refreshPermission() }
        scheduleAutomaticCheck()
        notifyStateChanged()
    }

    func stop() {
        installation?.stop()
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
        if installationInProgress { presentInstallationProgress(); return }
        if checker.isChecking {
            request(.manual)
            return
        }
        let expected = viewState.availableVersion
        if let latestRelease, latestRelease.tag_name == expected {
            syncNotifications(origins: [.manual])
            offer(latestRelease)
        } else {
            request(.manual)
        }
    }

    private func request(_ origin: AppUpdateCheckOrigin) {
        guard !installationInProgress else { return }
        if origin == .manual, installation != nil { installation?.dismiss(); installation = nil }
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
            syncNotifications(origins: origins)
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
            syncNotifications(origins: origins)
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
        let notes = release.body.map(AppUpdateReleaseNotes.plainText)
        if let notes, !notes.isEmpty {
            alert.informativeText = String(notes.prefix(1_500))
            if notes.count > 1_500 {
                alert.informativeText += "…\n\n完整版本说明：\n\(release.releasePageURL.absoluteString)"
            }
        } else {
            alert.informativeText = "当前版本 \(Self.version)。完整版本说明：\n\(release.releasePageURL.absoluteString)"
        }
        alert.addButton(withTitle: "安装并重启")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过此版本")
        let response = alert.runModal()
        if response == .alertThirdButtonReturn {
            preferences.state = AppUpdateAvailabilityPolicy.skipping(release.tag_name, in: preferences.state)
            syncNotifications()
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
        scheduledCheck?.cancel()
        scheduledCheck = nil
        notifyStateChanged()
        startInstallation(asset: asset, checksum: checksum, release: release, target: target)
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

    private func startInstallation(asset: AppRelease.Asset, checksum: AppRelease.Asset, release: AppRelease, target: URL) {
        installation?.dismiss()
        do {
            let channel = try AppUpdateProgressChannel.create(target: target, sourceVersion: Self.version,
                                                              targetVersion: release.tag_name)
            let job = AppUpdateInstallation(session: session, release: release, asset: asset, checksum: checksum, channel: channel)
            installation = job
            job.onChange = { [weak self] phaseChanged in
                guard let self, self.installation?.channel.context.sessionID == channel.context.sessionID else { return }
                if phaseChanged {
                    self.notifyStateChanged()
                    if !self.installationInProgress { self.scheduleAutomaticCheck() }
                } else { self.onProgressChange?() }
            }
            job.onInstall = { [weak self] in self?.onInstall?() }
            job.onPresentationFailure = { [weak self] message in self?.message("更新已停止", message) }
            try job.start()
            notifyStateChanged()
        } catch {
            installation?.stop()
            scheduleAutomaticCheck()
            message("更新未开始", error.localizedDescription)
        }
    }
    private func message(_ title: String, _ detail: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "好"); alert.runModal()
    }
}
