import AppKit

enum HUDDisplayMode: String, CaseIterable {
    case automatic, floating, notch
    static let defaultsKey = "hud.displayMode"
    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .floating
    }
    var title: String {
        switch self { case .automatic: return "自动"; case .floating: return "桌面浮窗"; case .notch: return "刘海融合" }
    }
}

/// User intent survives screen fallback, host restarts, and mode changes.
struct HUDPresentationPreferences {
    static let visibilityKey = "hud.requestedVisible"
    var mode: HUDDisplayMode
    var isVisible: Bool
    init(defaults: UserDefaults = .standard) {
        mode = HUDDisplayMode.load(from: defaults)
        isVisible = defaults.bool(forKey: Self.visibilityKey)
    }
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: HUDDisplayMode.defaultsKey)
        defaults.set(isVisible, forKey: Self.visibilityKey)
    }
    func usesNotch(hasGeometry: Bool) -> Bool { mode != .floating && hasGeometry }
}

enum MenuBarDisplayMode: String, CaseIterable {
    case automatic, icon, single, full
    static let defaultsKey = "menu.displayMode"
    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .automatic
    }
    var title: String {
        switch self { case .automatic: return "自动"; case .icon: return "仅图标"; case .single: return "单额度"; case .full: return "完整额度" }
    }
    func resolved(panelVisible: Bool) -> Self { self == .automatic ? (panelVisible ? .icon : .single) : self }
}

struct HUDMetric {
    let title: String
    let compactTitle: String
    let value: String
    let date: String
    let percent: Double?
    var compact: String { "\(compactTitle) \(value)" }
    var reservedCompact: String { "\(compactTitle) \(percent == nil ? value : "100%")" }

    static func rows(for state: RateLimitDisplayState) -> [Self] {
        var rows: [Self] = []
        if let meter = state.fiveHour {
            rows.append(Self(title: DisplayLanguage.text("5 小时剩余", "5-hour remaining"), compactTitle: "5h", value: meter.remainingText, date: resetDate(meter), percent: meter.remainingPercent))
        } else if let credits = state.resetCredits, credits.availableCount > 0 {
            let date = DisplayLanguage.current == .chinese ? credits.expirationText : (credits.earliestExpirationDate == nil ? "Expires --" : "Expires " + credits.expirationText)
            rows.append(Self(title: DisplayLanguage.text("重置卡", "Reset credits"), compactTitle: DisplayLanguage.text("重置", "Reset"), value: DisplayLanguage.text("\(credits.availableCount) 张", "\(credits.availableCount)"), date: date, percent: nil))
        }
        if let meter = state.weekly {
            rows.append(Self(title: DisplayLanguage.text("周限额剩余", "Weekly remaining"), compactTitle: DisplayLanguage.text("周", "7d"), value: meter.remainingText, date: resetDate(meter), percent: meter.remainingPercent))
        }
        return rows
    }
    private static func resetDate(_ meter: LimitMeter) -> String {
        DisplayLanguage.current == .chinese ? meter.resetText : "Resets " + meter.resetText
    }
}

struct MenuBarPresentation {
    let title: String
    let reservedTitle: String
    init(state: RateLimitDisplayState, mode: MenuBarDisplayMode, panelVisible: Bool) {
        let resolved = mode.resolved(panelVisible: panelVisible)
        let all = HUDMetric.rows(for: state)
        let rows = resolved == .single ? Array(all.prefix(1)) : all
        if resolved == .icon { title = ""; reservedTitle = ""; return }
        let suffix = state.errorMessage == nil ? "" : " !"
        title = " " + (rows.isEmpty ? "--" : rows.map(\.compact).joined(separator: "  ")) + suffix
        // Always reserve the error marker as well as 100%, so refreshes cannot jitter the menu bar.
        reservedTitle = " " + (rows.isEmpty ? "--" : rows.map(\.reservedCompact).joined(separator: "  ")) + " !"
    }
}

/// Screen-space points; auxiliary areas are conservative, not the camera's rounded outline.
struct NotchHUDGeometry {
    let screen: NSRect
    let anchor: NSPoint
    let notchWidth: CGFloat
    init?(screen: NSRect, topInset: CGFloat, leftArea: NSRect, rightArea: NSRect) {
        let gap = rightArea.minX - leftArea.maxX
        let scalars = [screen.minX, screen.minY, screen.width, screen.height, topInset,
                       leftArea.minX, leftArea.minY, leftArea.width, leftArea.height,
                       rightArea.minX, rightArea.minY, rightArea.width, rightArea.height]
        guard scalars.allSatisfy(\.isFinite), screen.width >= 400, screen.height >= 480,
              topInset > 0, topInset < screen.height / 3, gap > 0, gap < screen.width / 2,
              leftArea.width > 0, rightArea.width > 0,
              screen.contains(leftArea), screen.contains(rightArea),
              abs(leftArea.maxY - screen.maxY) < 1, abs(rightArea.maxY - screen.maxY) < 1,
              abs(leftArea.height - topInset) < 1, abs(rightArea.height - topInset) < 1 else { return nil }
        self.screen = screen
        notchWidth = gap
        anchor = NSPoint(x: (leftArea.maxX + rightArea.minX) / 2, y: screen.maxY - topInset)
    }
    func frame(width: CGFloat, height: CGFloat) -> NSRect {
        let w = min(max(notchWidth, width), 2 * min(anchor.x - screen.minX, screen.maxX - anchor.x))
        let h = min(height, anchor.y - screen.minY)
        return NSRect(x: anchor.x - w / 2, y: anchor.y - h, width: w, height: h)
    }
    static func current() -> Self? {
        guard #available(macOS 12.0, *), let screen = NSScreen.screens.first,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        return Self(screen: screen.frame, topInset: screen.safeAreaInsets.top, leftArea: left, rightArea: right)
    }
}
