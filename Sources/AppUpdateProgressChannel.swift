import Foundation
import Darwin

/// A private, per-update directory; each writer owns a separate atomic JSON file.
struct AppUpdateProgressChannel {
    struct Context: Codable, Equatable {
        let sessionID: String
        let targetPath: String
        let sourceVersion: String
        let targetVersion: String
        let ownerPID: Int32
    }
    struct Command: Codable {
        let sessionID: String
        let requestID: String
        let action: Action
        enum Action: String, Codable { case show, cancel, retry, dismiss }
    }
    struct Launch: Codable {
        let sessionID: String
        let version: String
        let pid: Int32
    }

    let directory: URL
    let context: Context
    static let argument = "--hud-update-session"

    init(directory: URL, context: Context) {
        self.directory = directory.standardizedFileURL
        self.context = context
    }

    static func create(target: URL, sourceVersion: String, targetVersion: String) throws -> Self {
        let id = UUID().uuidString
        let directory = target.deletingLastPathComponent().appendingPathComponent(".GPTTouchBarHUD-update-" + id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let channel = Self(directory: directory, context: Context(sessionID: id, targetPath: target.path,
            sourceVersion: sourceVersion, targetVersion: targetVersion, ownerPID: getpid()))
        try channel.write(channel.context, name: "context.json")
        let note = """
        GPT TouchBar HUD 更新与恢复

        本次更新：\(sourceVersion) → \(targetVersion)
        安装位置：\(target.path)
        本次更新目录：\(directory.path)

        请先查看进度窗口与 install.log。progress-helper.log 是进度窗口日志。
        下载或校验失败时，原应用尚未替换，直接从应用菜单重试即可。

        进入替换阶段后，previous.app 是保留的旧版；failed.app（如有）是无法打开的新版。
        “尚未确认新版启动”不等于新版已崩溃，请先尝试打开安装位置中的应用。
        仅在需要手动恢复时：退出本工具，保留异常版本与日志，将 previous.app 复制回上述安装位置，命名为 GPT TouchBar HUD.app 后打开。
        若没有 previous.app，先确认当前应用位置与日志，再从仓库 Release 重新下载。

        安装仍在进行时，不要移动应用或清理此目录。确认新版本正常运行、无需回滚后，可在 Finder 中逐一审阅并移除此目录。
        Release：https://github.com/zz-zed/GPT-TouchBar-hud/releases/latest
        """
        let recovery = directory.appendingPathComponent("RECOVERY.txt")
        try Data(note.utf8).write(to: recovery, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recovery.path)
        return channel
    }

    /// Do not follow linked directories or status files, or read another user's session.
    static func load(directory: URL, sessionID: String) throws -> Self {
        let directory = directory.standardizedFileURL
        guard UUID(uuidString: sessionID) != nil,
              directory.lastPathComponent == ".GPTTouchBarHUD-update-" + sessionID,
              directory.resolvingSymlinksInPath() == directory else { throw ChannelError.invalid }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw ChannelError.invalid }
        let file = directory.appendingPathComponent("context.json")
        let context: Context = try read(file)
        guard context.sessionID == sessionID, context.ownerPID > 0,
              AppVersion(context.sourceVersion) != nil, AppVersion(context.targetVersion) != nil,
              URL(fileURLWithPath: context.targetPath).standardizedFileURL ==
                directory.deletingLastPathComponent().appendingPathComponent("GPT TouchBar HUD.app") else {
            throw ChannelError.invalid
        }
        return Self(directory: directory, context: context)
    }

    func write<T: Encodable>(_ value: T, name: String) throws {
        guard Self.fileNames.contains(name) else { throw ChannelError.invalid }
        let data = try JSONEncoder().encode(value)
        let temporary = directory.appendingPathComponent(".state-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, directory.appendingPathComponent(name).path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func readValue<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard Self.fileNames.contains(name) else { return nil }
        return try? Self.read(directory.appendingPathComponent(name))
    }

    func progress() -> AppUpdateProgress? {
        let install = readValue("install.json", as: AppUpdateProgress.self)
        let download = readValue("progress.json", as: AppUpdateProgress.self)
        guard var value = install ?? download, value.sessionID == context.sessionID else { return nil }
        if let launch = readValue("launch.json", as: Launch.self), launch.sessionID == context.sessionID,
           launch.pid > 0, kill(launch.pid, 0) == 0 {
            if [.restarting, .launchUnconfirmed].contains(value.phase),
               AppVersion(launch.version) == AppVersion(context.targetVersion) {
                value.phase = .succeeded; value.step = .finished; value.message = nil
            } else if value.step == .restoring,
                      AppVersion(launch.version) == AppVersion(context.sourceVersion) {
                value.phase = .failed; value.recovery = .restored
                value.message = "更新未完成，旧版已恢复并完成启动。"
            }
        }
        return value
    }

    func send(_ action: Command.Action, toHelper: Bool = false) throws {
        try write(Command(sessionID: context.sessionID, requestID: UUID().uuidString, action: action),
                  name: toHelper ? "helper-command.json" : "command.json")
    }

    func launchMatches(version: String) -> Bool {
        guard let launch = readValue("launch.json", as: Launch.self), launch.sessionID == context.sessionID,
              AppVersion(launch.version) == AppVersion(version), launch.pid > 0 else { return false }
        return kill(launch.pid, 0) == 0
    }

    static func acknowledgeLaunch(arguments: [String], bundleURL: URL, bundleIdentifier: String?, version: String) {
        guard let index = arguments.firstIndex(of: argument), arguments.count == index + 3,
              bundleIdentifier == "io.github.zz-zed.GPTTouchBarHUD",
              let channel = try? load(directory: URL(fileURLWithPath: arguments[index + 1]), sessionID: arguments[index + 2]),
              bundleURL.standardizedFileURL.path == channel.context.targetPath,
              bundleURL.resolvingSymlinksInPath() == bundleURL.standardizedFileURL,
              let progress = channel.readValue("install.json", as: AppUpdateProgress.self),
              progress.sessionID == channel.context.sessionID,
              (progress.step == .launching && AppVersion(version) == AppVersion(channel.context.targetVersion)) ||
              (progress.step == .restoring && AppVersion(version) == AppVersion(channel.context.sourceVersion)) else { return }
        try? channel.write(Launch(sessionID: channel.context.sessionID, version: version, pid: getpid()), name: "launch.json")
    }

    private static let fileNames: Set<String> = ["context.json", "progress.json", "install.json", "launch.json", "command.json", "helper-command.json", "installer-process.json", "diagnostic-handoff.json"]
    private static func read<T: Decodable>(_ file: URL) throws -> T {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) < 65_536 else { throw ChannelError.invalid }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
    }
    enum ChannelError: Error { case invalid }
}
