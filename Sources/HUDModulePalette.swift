import AppKit

/// Module identity stays consistent between the native menu's light and dark appearances.
enum HUDModulePalette {
    static let quota = adaptive(light: 0x245FAE, dark: 0x8BB8FF)
    static let resets = adaptive(light: 0x8A5918, dark: 0xEAC18B)
    static let forecast = adaptive(light: 0x7051A3, dark: 0xC6AEF2)
    static let tokens = adaptive(light: 0x176C70, dark: 0x83D2D5)
    static let api = adaptive(light: 0x386B47, dark: 0xAED1A1)
    private static let quotaWarning = adaptive(light: 0x8A6100, dark: 0xFFD60A)

    static func quotaRemaining(_ percent: Double?) -> NSColor {
        guard let percent, percent.isFinite else { return quota }
        if percent <= 20 { return .systemRed }
        if percent <= 45 { return quotaWarning }
        return quota
    }

    private static func adaptive(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}
