import Foundation
import Darwin

enum HostAutoLauncher {
    private static let manualQuitLockName = "manual-quit.lock"
    private static let service = HostAutoLaunchService { manager }

    static var isEnabled: Bool { HostAutoLaunchPreferences().isEnabled }

    static func setEnabled(_ enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        service.setEnabled(enabled, completion: completion)
    }

    static func installOrUpdate(completion: @escaping (Result<Void, Error>) -> Void) {
        service.installOrUpdate { result in
            if case .failure = result {
                DiagnosticRecorder.shared.record(.componentFailure(component: .autoLauncher, result: .failed))
            }
            completion(result)

        }
    }

    private static var manager: HostAutoLaunchManager {
        HostAutoLaunchManager(
            preferences: HostAutoLaunchPreferences(),
            appBundleURL: Bundle.main.bundleURLIfApp,
            launchAgentsDirectory: launchAgentsDirectory,
            userID: getuid()
        )
    }

    static func clearManualQuitLock() {
        manualQuitLockURLs.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    static func markManualQuit() {
        do {
            for lockURL in manualQuitLockURLs {
                try FileManager.default.createDirectory(
                    at: lockURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try "manual quit\n".write(to: lockURL, atomically: true, encoding: .utf8)
            }
        } catch {
            DiagnosticRecorder.shared.record(.componentFailure(component: .quitMarker, result: .ioFailure))
        }
    }

    private static var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private static var appSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(AppIdentity.appSupportDirectoryName, isDirectory: true)
    }

    private static var legacyAppSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(AppIdentity.legacyAppSupportDirectoryName, isDirectory: true)
    }

    private static var manualQuitLockURLs: [URL] {
        [appSupportDirectory, legacyAppSupportDirectory].map {
            $0.appendingPathComponent(manualQuitLockName, isDirectory: false)
        }
    }

}

/// Serializes registration changes off the UI thread, including their preference commits.
final class HostAutoLaunchService {
    private let queue = DispatchQueue(label: "io.github.zz-zed.GPTTouchBarHUD.auto-launch", qos: .utility)
    private let makeManager: () -> HostAutoLaunchManager

    init(makeManager: @escaping () -> HostAutoLaunchManager) { self.makeManager = makeManager }

    func setEnabled(_ enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        perform({ $0.setEnabled(enabled) }, completion: completion)
    }

    func installOrUpdate(completion: @escaping (Result<Void, Error>) -> Void) {
        perform({ $0.installOrUpdate() }, completion: completion)
    }

    private func perform(_ operation: @escaping (HostAutoLaunchManager) -> Result<Void, Error>,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result = operation(self.makeManager())
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// Keeps the preference change conditional on a verified launchd operation.
/// Filesystem paths and command execution are injectable for isolated tests.
struct HostAutoLaunchManager {
    let preferences: HostAutoLaunchPreferences
    let appBundleURL: URL?
    let launchAgentsDirectory: URL
    let userID: uid_t
    var fileManager: FileManager = .default
    var runLaunchctl: ([String]) throws -> HostLaunchctlResult = { try HostLaunchctlResult.run(arguments: $0) }

    func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        Result {
            if enabled {
                try install()
            } else {
                try removeCurrentRegistration()
                try removeOwnedLegacyRegistration()
            }
            preferences.saveEnabled(enabled)
        }
    }

    func installOrUpdate() -> Result<Void, Error> {
        // A manual launch must never re-register an explicitly disabled agent.
        guard preferences.isEnabled, appBundleURL != nil else { return .success(()) }
        return Result { try install() }
    }

    private var domain: String { "gui/\(userID)" }

    private func plistURL(label: String) -> URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    private func install() throws {
        guard let appBundleURL = appBundleURL else {
            throw HostAutoLaunchError.notAnApplication
        }
        let scriptURL = appBundleURL.appendingPathComponent("Contents/Resources/gpt-touchbar-hud-launcher.sh")
        guard fileManager.fileExists(atPath: scriptURL.path) else {
            throw HostAutoLaunchError.missingLauncher
        }
        let destination = plistURL(label: AppIdentity.launchAgentLabel)
        try validateCurrentPlistIfPresent(at: destination)
        try removeOwnedLegacyRegistration()
        try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try unload(label: AppIdentity.launchAgentLabel)
        try Self.launchAgentPlist(scriptPath: scriptURL.path, appPath: appBundleURL.path)
            .write(to: destination, atomically: true, encoding: .utf8)
        try requireSuccess(["bootstrap", domain, destination.path])
        try requireSuccess(["print", "\(domain)/\(AppIdentity.launchAgentLabel)"])
    }

    private func removeCurrentRegistration() throws {
        let destination = plistURL(label: AppIdentity.launchAgentLabel)
        try validateCurrentPlistIfPresent(at: destination)
        try unload(label: AppIdentity.launchAgentLabel)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
    }

    private func removeOwnedLegacyRegistration() throws {
        let destination = plistURL(label: AppIdentity.legacyLaunchAgentLabel)
        // A genuinely separate legacy installation belongs to the user. Only
        // migrate an old label that demonstrably launches this current app.
        guard let plist = try readPlistIfPresent(at: destination),
              Self.isOwned(plist, label: AppIdentity.legacyLaunchAgentLabel),
              let arguments = plist["ProgramArguments"] as? [String],
              let targetBundle = Bundle(url: URL(fileURLWithPath: arguments[2])),
              targetBundle.bundleIdentifier == AppIdentity.bundleIdentifier else { return }
        try unload(label: AppIdentity.legacyLaunchAgentLabel)
        try fileManager.removeItem(at: destination)
    }

    private func validateCurrentPlistIfPresent(at url: URL) throws {
        guard let plist = try readPlistIfPresent(at: url) else { return }
        guard Self.isOwned(plist, label: AppIdentity.launchAgentLabel) else {
            throw HostAutoLaunchError.unrecognizedRegistration(url.path)
        }
    }

    private func readPlistIfPresent(at url: URL) throws -> [String: Any]? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw HostAutoLaunchError.unrecognizedRegistration(url.path)
        }
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw HostAutoLaunchError.unrecognizedRegistration(url.path)
        }
        return plist
    }

    private static func isOwned(_ plist: [String: Any], label: String) -> Bool {
        guard plist["Label"] as? String == label,
              let arguments = plist["ProgramArguments"] as? [String], arguments.count == 3,
              arguments[0] == "/bin/zsh",
              URL(fileURLWithPath: arguments[2]).pathExtension == "app" else { return false }
        return arguments[1] == URL(fileURLWithPath: arguments[2])
            .appendingPathComponent("Contents/Resources/gpt-touchbar-hud-launcher.sh").path
    }

    private func unload(label: String) throws {
        let target = "\(domain)/\(label)"
        let removal = try runLaunchctl(["bootout", target])
        let verification = try runLaunchctl(["print", target])
        // An arbitrary launchctl failure is not evidence that the job is gone.
        guard verification.isMissingService else {
            if removal.status != 0 { throw HostAutoLaunchError.commandFailed("bootout", removal.status) }
            throw HostAutoLaunchError.unloadNotVerified
        }
    }

    private func requireSuccess(_ arguments: [String]) throws {
        let result = try runLaunchctl(arguments)
        guard result.status == 0 else {
            throw HostAutoLaunchError.commandFailed(arguments[0], result.status)
        }
    }

    static func launchAgentPlist(scriptPath: String, appPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(AppIdentity.launchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/zsh</string>
                <string>\(scriptPath.xmlEscaped)</string>
                <string>\(appPath.xmlEscaped)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>StartInterval</key>
            <integer>5</integer>
        </dict>
        </plist>
        """
    }

}

struct HostLaunchctlResult {
    let status: Int32
    let output: String

    var isMissingService: Bool {
        status == 113 && output.contains("Could not find service")
    }

    /// Blocking only on the service's worker queue. Every command has a finite deadline.
    static func run(arguments: [String], executableURL: URL = URL(fileURLWithPath: "/bin/launchctl"),
                    timeout: TimeInterval = 5) throws -> HostLaunchctlResult {
        precondition(timeout > 0 && timeout.isFinite)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        // A file avoids both pipe-capacity deadlocks and inherited pipes delaying EOF.
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("hud-launchctl-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 0.25) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            throw HostAutoLaunchError.commandTimedOut(arguments.first ?? executableURL.lastPathComponent)
        }
        let reader = try FileHandle(forReadingFrom: outputURL)
        defer { try? reader.close() }
        let data = reader.readData(ofLength: 64 * 1024)
        return HostLaunchctlResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

enum HostAutoLaunchError: LocalizedError {
    case notAnApplication
    case missingLauncher
    case unrecognizedRegistration(String)
    case commandFailed(String, Int32)
    case commandTimedOut(String)
    case unloadNotVerified

    var errorDescription: String? {
        switch self {
        case .notAnApplication:
            return "请从已安装的 GPT TouchBar HUD 应用中更改随客户端启动设置。"
        case .missingLauncher:
            return "应用中的自动启动脚本缺失，请重新安装应用后重试。"
        case .unrecognizedRegistration(let path):
            return "自动启动文件已被修改或无法确认归属，未覆盖或删除：\(path)"
        case .commandFailed(let operation, let status):
            return "无法完成自动启动设置（launchctl \(operation)，状态 \(status)）。设置未保存，请稍后重试。"
        case .commandTimedOut(let operation):
            return "自动启动设置操作超时（launchctl \(operation)）。设置未保存，请稍后重试。"
        case .unloadNotVerified:
            return "尚未确认自动启动项已停止，关闭设置未保存，请稍后重试。"
        }
    }
}

private extension Bundle {
    var bundleURLIfApp: URL? {
        let url = bundleURL
        return url.pathExtension == "app" ? url : nil
    }
}

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
