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
    static func fromLatestPageURL(_ url: URL) -> AppRelease? {
        guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil else { return nil }
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
        return url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
            && url.path == "/\(Self.repository)/releases/download/\(tag_name)/\(asset.name)"
    }

    var releasePageURL: URL {
        guard let html_url,
              html_url.scheme == "https", html_url.host == "github.com",
              html_url.user == nil, html_url.password == nil,
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
}
