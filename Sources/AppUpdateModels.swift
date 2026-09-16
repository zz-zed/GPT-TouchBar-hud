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
    static let repository = "zz-zed/GPT-TouchBar-hud"
    static let page = URL(string: "https://github.com/\(repository)/releases/latest")!
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
