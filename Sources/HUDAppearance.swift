import AppKit

struct HUDAppearance: Equatable {
    enum Material: String, CaseIterable {
        case system
        case classic

        var title: String {
            switch self {
            case .system: return DisplayLanguage.text("跟随系统", "Follow system")
            case .classic: return DisplayLanguage.text("经典外观", "Classic")
            }
        }
    }

    enum Surface { case classic, glass, solidSystem }

    static var supportsGlass: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    static func surface(for material: Material, supportsGlass: Bool = supportsGlass,
                        reduceTransparency: Bool = false, increaseContrast: Bool = false) -> Surface {
        guard material == .system, supportsGlass else { return .classic }
        return reduceTransparency || increaseContrast ? .solidSystem : .glass
    }

    enum ColorChoice: String, CaseIterable {
        case black
        case graphite
        case blue
        case green
        case purple

        var title: String {
            switch self {
            case .black:
                return "深黑"
            case .graphite:
                return "石墨"
            case .blue:
                return "深蓝"
            case .green:
                return "深绿"
            case .purple:
                return "紫色"
            }
        }

        var color: NSColor {
            switch self {
            case .black:
                return NSColor(calibratedWhite: 0.04, alpha: 1)
            case .graphite:
                return NSColor(calibratedWhite: 0.18, alpha: 1)
            case .blue:
                return NSColor(calibratedRed: 0.04, green: 0.10, blue: 0.22, alpha: 1)
            case .green:
                return NSColor(calibratedRed: 0.04, green: 0.16, blue: 0.10, alpha: 1)
            case .purple:
                return NSColor(calibratedRed: 0.15, green: 0.08, blue: 0.22, alpha: 1)
            }
        }
    }

    static let opacityChoices: [Double] = [
        0.10,
        0.20,
        0.30,
        0.40,
        0.50,
        0.60,
        0.75,
        0.86,
        1.0
    ]

    private enum DefaultsKey {
        static let material = "hud.material"
        static let color = "hud.color"
        static let backgroundOpacity = "hud.backgroundOpacity"
        static let contentOpacity = "hud.contentOpacity"
        static let legacyOpacity = "hud.opacity"
    }

    var material: Material = .classic
    var colorChoice: ColorChoice
    var backgroundOpacity: Double
    var contentOpacity: Double

    var backgroundColor: NSColor {
        colorChoice.color.withAlphaComponent(backgroundOpacity)
    }

    static func load(from defaults: UserDefaults = .standard) -> HUDAppearance {
        // Previous versions only saved these keys after an explicit appearance edit.
        let hasClassicPreference = [DefaultsKey.color, DefaultsKey.backgroundOpacity,
            DefaultsKey.contentOpacity, DefaultsKey.legacyOpacity].contains { defaults.object(forKey: $0) != nil }
        let material = defaults.string(forKey: DefaultsKey.material).flatMap(Material.init(rawValue:))
            ?? (hasClassicPreference ? .classic : .system)
        let colorName = defaults.string(forKey: DefaultsKey.color) ?? ColorChoice.black.rawValue
        let color = ColorChoice(rawValue: colorName) ?? .black
        let legacyOpacity = defaults.object(forKey: DefaultsKey.legacyOpacity) as? Double
        let backgroundOpacity = defaults.object(forKey: DefaultsKey.backgroundOpacity) as? Double ?? legacyOpacity ?? 0.94
        let contentOpacity = defaults.object(forKey: DefaultsKey.contentOpacity) as? Double ?? legacyOpacity ?? 1.0

        return HUDAppearance(
            material: material,
            colorChoice: color,
            backgroundOpacity: clamped(backgroundOpacity),
            contentOpacity: clamped(contentOpacity)
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(material.rawValue, forKey: DefaultsKey.material)
        defaults.set(colorChoice.rawValue, forKey: DefaultsKey.color)
        defaults.set(backgroundOpacity, forKey: DefaultsKey.backgroundOpacity)
        defaults.set(contentOpacity, forKey: DefaultsKey.contentOpacity)
        defaults.set(backgroundOpacity, forKey: DefaultsKey.legacyOpacity)
    }

    private static func clamped(_ opacity: Double) -> Double {
        max(0.10, min(1.0, opacity))
    }
}
