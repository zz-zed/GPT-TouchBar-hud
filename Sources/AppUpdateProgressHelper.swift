import AppKit

/// Runs a copy of the executable as a temporary UI process, before the HUD's instance gate.
/// It only displays state / sends user commands; it never replaces application files.
final class AppUpdateProgressHelper: NSObject, NSApplicationDelegate {
    static let argument = "--update-progress-helper"
    private let channel: AppUpdateProgressChannel
    private let controller: AppUpdateProgressWindowController
    private var timer: Timer?
    private var lastCommandID: String?
    private var lastProgress: AppUpdateProgress?
    private var successSince: Date?
    private var lostInstallerSince: Date?
    private var statusItem: NSStatusItem?

    static func runIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        if arguments.count > 1, arguments[1] == "--check-update-launch" {
            guard arguments.count == 5,
                  let channel = try? AppUpdateProgressChannel.load(directory: URL(fileURLWithPath: arguments[2]), sessionID: arguments[3]),
                  Bundle.main.executableURL?.standardizedFileURL == channel.directory.appendingPathComponent("progress-helper"),
                  AppVersion(arguments[4]) != nil else { exit(EXIT_FAILURE) }
            exit(channel.launchMatches(version: arguments[4]) ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        guard arguments.contains(argument) else { return false }
        guard arguments.count == 4, arguments[1] == argument,
              let channel = try? AppUpdateProgressChannel.load(directory: URL(fileURLWithPath: arguments[2]), sessionID: arguments[3]),
              Bundle.main.executableURL?.standardizedFileURL == channel.directory.appendingPathComponent("progress-helper") else {
            return true
        }
        let helper = AppUpdateProgressHelper(channel: channel)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = helper
        withExtendedLifetime(helper) { app.run() }
        return true
    }

    init(channel: AppUpdateProgressChannel) {
        self.channel = channel
        controller = AppUpdateProgressWindowController(sourceVersion: channel.context.sourceVersion,
                                                       targetVersion: channel.context.targetVersion)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.onCancel = { [weak self] in self?.send(.cancel) }
        controller.onRetry = { [weak self] in self?.send(.retry) }
        controller.onOpenApplication = { [weak self] in self?.openApplication() }
        controller.onRecovery = { [weak self] in
            guard let self else { return }
            let note = self.channel.directory.appendingPathComponent("RECOVERY.txt")
            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: note.path) ? note : self.channel.directory)
        }
        controller.onHide = { [weak self] in
            guard let self, let progress = self.lastProgress, !progress.isActive,
                  progress.phase != .launchUnconfirmed else { return }
            NSApp.terminate(nil)
        }
        poll()
        controller.present(userInitiated: true)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func send(_ action: AppUpdateProgressChannel.Command.Action) {
        do { try channel.send(action) }
        catch {
            var value = lastProgress ?? AppUpdateProgress(sessionID: channel.context.sessionID, phase: .failed, step: .connecting)
            value.message = "无法提交更新操作，请从菜单栏重新打开进度。"
            controller.update(value)
        }
    }

    private func openApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        if channel.progress()?.recovery != .untouched {
            configuration.arguments = [AppUpdateProgressChannel.argument, channel.directory.path, channel.context.sessionID]
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: channel.context.targetPath), configuration: configuration)
    }

    private func poll() {
        if let command = channel.readValue("helper-command.json", as: AppUpdateProgressChannel.Command.self),
           command.sessionID == channel.context.sessionID, command.requestID != lastCommandID {
            lastCommandID = command.requestID
            if command.action == .show { controller.present(userInitiated: true) }
            if command.action == .dismiss { NSApp.terminate(nil); return }
        }
        guard var progress = channel.progress() else { return }
        let ownerAlive = kill(channel.context.ownerPID, 0) == 0
        controller.ownerAvailable = ownerAlive
        if !ownerAlive && statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "↑"
            item.button?.contentTintColor = .systemBlue
            let menu = NSMenu()
            let entry = NSMenuItem(title: "查看更新进度…", action: #selector(showProgress), keyEquivalent: "")
            entry.target = self; menu.addItem(entry)
            item.menu = menu; statusItem = item
        }
        statusItem?.button?.toolTip = progress.heading
        statusItem?.menu?.items.first?.title = progress.menuTitle
        if progress.isActive, channel.readValue("install.json", as: AppUpdateProgress.self) == nil,
           !ownerAlive {
            progress.phase = .failed
            progress.message = "更新已中断，原应用尚未替换。请重新打开本工具后重试。"
        } else if progress.isActive, !ownerAlive {
            let installer = channel.readValue("installer-process.json", as: AppUpdateProgressChannel.Launch.self)
            let installerAlive = installer.map { $0.sessionID == channel.context.sessionID && $0.pid > 0 && kill($0.pid, 0) == 0 } ?? false
            if installerAlive { lostInstallerSince = nil }
            else if let since = lostInstallerSince, Date().timeIntervalSince(since) >= 2 {
                progress.phase = .failed; progress.recovery = .needsRecovery
                progress.message = "安装已中断，请查看本次更新日志和应用，确认安装状态。"
            } else if lostInstallerSince == nil { lostInstallerSince = Date() }
        } else { lostInstallerSince = nil }
        if !ownerAlive, progress.isActive || progress.phase == .launchUnconfirmed {
            // The temporary menu also remains available while a late launch receipt is possible.
            statusItem?.button?.toolTip = progress.heading
        }
        if progress != lastProgress { lastProgress = progress; controller.update(progress) }
        if progress.phase == .succeeded {
            if let since = successSince {
                if Date().timeIntervalSince(since) >= 3 { NSApp.terminate(nil) }
            } else { successSince = Date() }
        } else { successSince = nil }
    }

    @objc private func showProgress() { controller.present(userInitiated: true) }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}
