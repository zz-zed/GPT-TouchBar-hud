import Foundation

struct AppVersion: Comparable {
    let parts: [Int]
    init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(fields.count), fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              fields.allSatisfy({ Int($0) != nil }) else { return nil }
        var numbers = fields.map { Int($0)! }
        while numbers.last == 0 && numbers.count > 1 { numbers.removeLast() }
        parts = numbers
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0
            let b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}

struct AppRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    let name: String?
    let body: String?
    let html_url: URL?

    init(tag_name: String, draft: Bool, prerelease: Bool, assets: [Asset], name: String? = nil, body: String? = nil, html_url: URL? = nil) {
        self.tag_name = tag_name
        self.draft = draft
        self.prerelease = prerelease
        self.assets = assets
        self.name = name
        self.body = body
        self.html_url = html_url
    }
    static let repository = "zz-zed/GPT-TouchBar-hud"
    static let page = URL(string: "https://github.com/\(repository)/releases/latest")!
    static let api = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    var isStableVersion: Bool { !draft && !prerelease && AppVersion(tag_name) != nil }

    static func isTrustedURL(_ url: URL, host: String = "github.com") -> Bool {
        url.scheme == "https" && url.host == host && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443) && url.query == nil && url.fragment == nil
    }

    static func fromLatestPageURL(_ url: URL) -> AppRelease? {
        guard isTrustedURL(url) else { return nil }
        let prefix = "/\(repository)/releases/tag/"
        guard url.path.hasPrefix(prefix) else { return nil }
        let tag = String(url.path.dropFirst(prefix.count))
        guard tag.hasPrefix("v"), !tag.contains("/"), AppVersion(tag) != nil else { return nil }
        let version = String(tag.dropFirst())
        let base = "https://github.com/\(repository)/releases/download/\(tag)/"
        guard let arm = URL(string: base + "GPT-TouchBar-HUD-\(version)-arm64.dmg"),
              let intel = URL(string: base + "GPT-TouchBar-HUD-\(version)-x86_64.dmg"),
              let sums = URL(string: base + "SHA256SUMS.txt") else { return nil }
        return AppRelease(tag_name: tag, draft: false, prerelease: false, assets: [
            Asset(name: "GPT-TouchBar-HUD-\(version)-arm64.dmg", browser_download_url: arm, size: 0),
            Asset(name: "GPT-TouchBar-HUD-\(version)-x86_64.dmg", browser_download_url: intel, size: 0),
            Asset(name: "SHA256SUMS.txt", browser_download_url: sums, size: 0)
        ], html_url: url)
    }
    func installer(architecture: String) -> Asset? {
        let version = tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name
        return assets.first { $0.name == "GPT-TouchBar-HUD-\(version)-\(architecture).dmg" && trusted($0) }
    }
    var checksums: Asset? { assets.first { $0.name == "SHA256SUMS.txt" && trusted($0) } }
    private func trusted(_ asset: Asset) -> Bool {
        let url = asset.browser_download_url
        return Self.isTrustedURL(url)
            && url.path == "/\(Self.repository)/releases/download/\(tag_name)/\(asset.name)"
    }

    var releasePageURL: URL {
        guard let html_url,
              Self.isTrustedURL(html_url),
              html_url.path == "/\(Self.repository)/releases/tag/\(tag_name)" else {
            return URL(string: "https://github.com/\(Self.repository)/releases/tag/\(tag_name)")!
        }
        return html_url
    }
    static func checksum(in text: String, filename: String) -> String? {
        let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { return nil }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            guard name == filename || name == "*" + filename else { return nil }
            let hash = String(parts[0]).lowercased()
            return hash.count == 64 && hash.allSatisfy { $0.isASCII && $0.isHexDigit } ? hash : nil
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

enum AppUpdateCheckOrigin: Hashable {
    case automatic
    case manual
}

struct AppUpdateFetchFailure: Error, Equatable {
    let message: String
    let retryAfter: Date?

    init(_ message: String, retryAfter: Date? = nil) {
        self.message = message
        self.retryAfter = retryAfter
    }
}

enum AppUpdateCheckOutcome {
    case update(AppRelease)
    case upToDate(AppRelease)
    case failure(AppUpdateFetchFailure)
}

struct AppUpdatePersistentState: Equatable {
    var lastAttempt: Date?
    var lastSuccess: Date?
    var availableVersion: String?
    var skippedVersion: String?
    var consecutiveAutomaticFailures: Int
    var retryNotBefore: Date?

    static let empty = AppUpdatePersistentState(
        lastAttempt: nil,
        lastSuccess: nil,
        availableVersion: nil,
        skippedVersion: nil,
        consecutiveAutomaticFailures: 0,
        retryNotBefore: nil
    )
}

final class AppUpdatePreferences {
    private enum Key {
        static let automaticChecksEnabled = "appUpdate.automaticChecksEnabled"
        static let lastAttempt = "appUpdate.lastAttempt"
        static let lastSuccess = "appUpdate.lastSuccess"
        static let availableVersion = "appUpdate.availableVersion"
        static let skippedVersion = "appUpdate.skippedVersion"
        static let consecutiveAutomaticFailures = "appUpdate.consecutiveAutomaticFailures"
        static let retryNotBefore = "appUpdate.retryNotBefore"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var automaticChecksEnabled: Bool {
        get {
            guard defaults.object(forKey: Key.automaticChecksEnabled) != nil else { return true }
            return defaults.bool(forKey: Key.automaticChecksEnabled)
        }
        set { defaults.set(newValue, forKey: Key.automaticChecksEnabled) }
    }

    var state: AppUpdatePersistentState {
        get {
            AppUpdatePersistentState(
                lastAttempt: date(forKey: Key.lastAttempt),
                lastSuccess: date(forKey: Key.lastSuccess),
                availableVersion: defaults.string(forKey: Key.availableVersion),
                skippedVersion: defaults.string(forKey: Key.skippedVersion),
                consecutiveAutomaticFailures: defaults.integer(forKey: Key.consecutiveAutomaticFailures),
                retryNotBefore: date(forKey: Key.retryNotBefore)
            )
        }
        set {
            set(newValue.lastAttempt, forKey: Key.lastAttempt)
            set(newValue.lastSuccess, forKey: Key.lastSuccess)
            set(newValue.availableVersion, forKey: Key.availableVersion)
            set(newValue.skippedVersion, forKey: Key.skippedVersion)
            defaults.set(max(0, newValue.consecutiveAutomaticFailures), forKey: Key.consecutiveAutomaticFailures)
            set(newValue.retryNotBefore, forKey: Key.retryNotBefore)
        }
    }

    private func date(forKey key: String) -> Date? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: key))
    }

    private func set(_ value: Date?, forKey key: String) {
        if let value { defaults.set(value.timeIntervalSince1970, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    private func set(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}

struct AppUpdateViewState {
    let automaticChecksEnabled: Bool
    let automaticChecksAvailable: Bool
    let availableVersion: String?
    let lastSuccess: Date?
    let isChecking: Bool
    let isInstalling: Bool
    var progress: AppUpdateProgress? = nil
}

/// Download percentages describe the archive only; all later work uses named steps.
struct AppUpdateProgress: Codable, Equatable {
    enum Phase: String, Codable {
        case preparing, downloading, verifying, installing, restarting
        case succeeded, failed, canceled, launchUnconfirmed
    }
    enum Step: String, Codable {
        case connecting, checksums, download, checksum, mounting, validating, copying
        case waitingForExit, backingUp, replacing, launching, restoring, finished

        var title: String {
            switch self {
            case .connecting: return "正在连接下载服务"
            case .checksums: return "正在获取校验信息"
            case .download: return "安装包下载中"
            case .checksum: return "正在校验安装包完整性"
            case .mounting: return "正在读取安装包"
            case .validating: return "正在检查应用与签名"
            case .copying: return "正在准备新版应用"
            case .waitingForExit: return "等待本工具退出"
            case .backingUp: return "正在保留旧版应用"
            case .replacing: return "正在替换应用"
            case .launching: return "等待新版启动确认"
            case .restoring: return "正在恢复旧版应用"
            case .finished: return "新版已完成启动"
            }
        }
        var stage: Int {
            switch self {
            case .connecting, .checksums, .download: return 0
            case .checksum, .mounting, .validating: return 1
            case .copying, .waitingForExit, .backingUp, .replacing, .restoring: return 2
            case .launching: return 3
            case .finished: return 4
            }
        }
    }
    enum Recovery: String, Codable { case untouched, backupRetained, restored, needsRecovery }

    let sessionID: String
    var phase: Phase
    var step: Step
    var bytesReceived: Int64 = 0
    var totalBytes: Int64? = nil
    var bytesPerSecond: Double? = nil
    var message: String? = nil
    var recovery: Recovery = .untouched

    var isActive: Bool {
        switch phase {
        case .preparing, .downloading, .verifying, .installing, .restarting: return true
        case .succeeded, .failed, .canceled, .launchUnconfirmed: return false
        }
    }
    var canCancel: Bool { phase == .preparing || phase == .downloading }
    var canRetry: Bool { phase == .failed && recovery == .untouched && step.stage == 0 }
    var downloadFraction: Double? {
        guard phase == .downloading, let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(bytesReceived) / Double(totalBytes)))
    }
    var heading: String {
        switch phase {
        case .preparing: return "正在准备下载"
        case .downloading: return "正在下载新版"
        case .verifying: return "正在检查安装包"
        case .installing: return "正在安装新版"
        case .restarting: return "正在启动新版"
        case .succeeded: return "更新完成"
        case .failed: return "更新未完成"
        case .canceled: return "已取消下载"
        case .launchUnconfirmed: return "尚未确认新版启动"
        }
    }
    var menuTitle: String {
        if let fraction = downloadFraction { return "更新进度：下载 \(Int(fraction * 100))%…" }
        return "更新进度：\(heading)…"
    }
    var detail: String {
        if phase == .downloading {
            let received = ByteCountFormatter.string(fromByteCount: max(0, bytesReceived), countStyle: .file)
            guard let totalBytes, totalBytes > 0 else { return "已下载 \(received)" }
            return received + " / " + ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        }
        if let message { return message }
        switch phase {
        case .preparing: return "下载前正在确认安装包与校验信息。"
        case .verifying: return "下载已完成，正在检查完整性与兼容性。"
        case .installing: return "本工具会短暂退出，更新窗口会继续显示。"
        case .restarting: return "应用已替换，正在等待新版完成启动。"
        case .succeeded: return "新版已启动，你可以继续使用本工具。"
        case .canceled: return "本次更新已停止，原应用尚未替换。"
        case .launchUnconfirmed: return "应用已替换，但尚未确认新版启动。旧版备份已保留。"
        case .failed:
            switch recovery {
            case .untouched: return "原应用尚未替换，可重试或稍后处理。"
            case .restored: return "旧版已恢复并完成启动，可稍后重试更新。"
            case .backupRetained: return "旧版备份已保留，请查看恢复说明。"
            case .needsRecovery: return "请查看本次更新日志与应用，确认安装状态。"
            }
        case .downloading: return ""
        }
    }
}
