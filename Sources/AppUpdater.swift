import AppKit
import CryptoKit

/// Public GitHub releases only; never sends account credentials or task data.
final class AppUpdater: NSObject {
    private var busy = false
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()
    var onInstall: (() -> Void)?
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0" }
    static var versionLabel: String {
        "版本 \(version)（构建 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")）"
    }
    var canCheck: Bool { !busy }
    // Only invoked by the explicit menu action; no launch/timer/background checks.
    func check() {
        guard !busy else { return }
        busy = true
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppRelease.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GPTTouchBarHUD/\(Self.version)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, data.count < 2_000_000,
                      let release = try? JSONDecoder().decode(AppRelease.self, from: data),
                      !release.draft, !release.prerelease,
                      let latest = AppVersion(release.tag_name), let current = AppVersion(Self.version) else {
                    self.message("无法检查更新", "请检查网络或稍后重试。GitHub 限流或发布信息不完整时不会安装任何文件。")
                    return
                }
                guard latest > current else {
                    self.message("无需更新", "当前版本 \(Self.version)，最新正式版 \(release.tag_name)。")
                    return
                }
                self.offer(release)
            }
        }.resume()
    }
    private func offer(_ release: AppRelease) {
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
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(AppRelease.page) }
            return
        }
        let alert = NSAlert()
        alert.messageText = "更新到 \(release.tag_name)？"
        alert.informativeText = "当前版本 \(Self.version)。确认后自动下载、校验并安装，完成后重启额度工具；不会退出 ChatGPT。"
        alert.addButton(withTitle: "安装并重启"); alert.addButton(withTitle: "稍后")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        download(asset: asset, checksum: checksum, release: release, target: target)
    }
    private func download(asset: AppRelease.Asset, checksum: AppRelease.Asset, release: AppRelease, target: URL) {
        guard asset.size > 0 && asset.size < 400_000_000 else { finish(error: "安装包大小不符合预期。"); return }
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
                    guard (attributes[.size] as? NSNumber)?.intValue == asset.size else { throw UpdateError.invalid("安装包大小不匹配。") }
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
        DispatchQueue.main.async { [weak self] in self?.busy = false; self?.message("更新未完成", error) }
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
