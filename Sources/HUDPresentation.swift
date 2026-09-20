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
        if DisplayLanguage.current == .chinese { return meter.resetText }
        return meter.resetDate == nil ? "Resets —" : "Resets " + meter.resetText
    }
}

struct MenuBarPresentation {
    let title: String
    let statusItemLength: CGFloat

    init(state: RateLimitDisplayState, mode: MenuBarDisplayMode, panelVisible: Bool) {
        let resolved = mode.resolved(panelVisible: panelVisible)
        let all = HUDMetric.rows(for: state)
        let rows = resolved == .single ? Array(all.prefix(1)) : all
        if resolved == .icon {
            title = ""
            statusItemLength = NSStatusItem.squareLength
            return
        }
        let suffix = state.errorMessage == nil ? "" : " !"
        title = " " + (rows.isEmpty ? "--" : rows.map(\.compact).joined(separator: "  ")) + suffix
        statusItemLength = NSStatusItem.variableLength
    }

    func apply(to statusItem: NSStatusItem) {
        statusItem.length = statusItemLength
        statusItem.button?.title = title
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
        // NSWindow aligns origins to whole points. Choose the hardware center once,
        // then use even widths so animated resize cannot move it by half a point.
        anchor = NSPoint(x: ((leftArea.maxX + rightArea.minX) / 2).rounded(), y: screen.maxY - topInset)
    }
    func frame(width: CGFloat, height: CGFloat) -> NSRect {
        let halfWidth = min(ceil(max(notchWidth, width) / 2), floor(min(anchor.x - screen.minX, screen.maxX - anchor.x)))
        let w = halfWidth * 2
        let h = min(ceil(height), anchor.y - screen.minY)
        return NSRect(x: anchor.x - w / 2, y: anchor.y - h, width: w, height: h)
    }
    static func current() -> Self? {
        DisplayTargetResolver.candidates().first?.geometry
    }
}

/// Selection is independent of main screen, pointer and frontmost application.
struct DisplayTargetResolver {
    struct Candidate {
        let id: UInt32
        let geometry: NotchHUDGeometry
    }
    private(set) var selectedID: UInt32?

    mutating func resolve(_ candidates: [Candidate]) -> NotchHUDGeometry? {
        let selected = candidates.first { $0.id == selectedID } ?? candidates.first
        selectedID = selected?.id
        return selected?.geometry
    }

    static func candidates() -> [Candidate] {
        guard #available(macOS 12.0, *) else { return [] }
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
                  let geometry = NotchHUDGeometry(screen: screen.frame, topInset: screen.safeAreaInsets.top,
                                                  leftArea: left, rightArea: right) else { return nil }
            return Candidate(id: number.uint32Value, geometry: geometry)
        }
    }
}

/// Display adapter only. The legacy source reports local observations, not complete coverage.
/// A future activity snapshot must supply coverage/health here, never through UI inference.
struct NotchTaskPresentation {
    let badge: String
    let title: String
    let note: String?
    let appearance: TaskStatusAppearance

    init(_ summary: TaskStatusSummary?, enabled: Bool = true) {
        guard enabled else {
            badge = ""
            title = DisplayLanguage.text("额度概览", "Quota overview")
            note = nil
            appearance = .idle
            return
        }
        if let activity = summary?.activityPresentation {
            badge = activity.badge + (activity.hasRunningTasks && summary?.completionFeedbackVisible == true ? " ✓" : "")
            title = activity.label
            appearance = TaskStatusAppearance(summary)
            // Keep scope/uncertainty and its reason visible; the full counts/health diagnostic is in the tooltip.
            let needsHealth = activity.snapshot.sourceHealth.contains { $0.state != .connected }
            note = [activity.coverageDetail, needsHealth ? activity.sourceHealthDetail : ""].filter { !$0.isEmpty }.joined(separator: "\n")
            return
        }
        guard let summary else {
            badge = "—"
            title = DisplayLanguage.text("任务状态不可用", "Task status unavailable")
            note = DisplayLanguage.text("监测尚未就绪，任务数量未知。", "Monitoring is unavailable. Task count is unknown.")
            appearance = .unknown
            return
        }
        let running = max(0, summary.runningCount)
        let unknown = max(0, summary.unknownCount)
        let completed = max(0, summary.recentlyCompletedCount)
        appearance = running > 0 ? .running : (unknown > 0 ? .unknown : (completed > 0 ? .completed : .idle))
        if running > 0 {
            badge = String(running) + (unknown > 0 ? " ?" : "") + (completed > 0 ? " ✓" : "")
            title = DisplayLanguage.text("\(running) 个任务执行中", "\(running) tasks running")
        } else if unknown > 0 {
            badge = "?"
            title = DisplayLanguage.text("任务状态未知", "Task status unknown")
        } else if completed > 0 {
            badge = "✓"
            title = DisplayLanguage.text("近期本轮完成", "Recent turn completed")
        } else {
            badge = "0"
            title = DisplayLanguage.text("本地近期无活动", "No recent local activity")
        }
        note = unknown > 0
            ? DisplayLanguage.text("本地监测覆盖不完整，部分任务状态无法确认。", "Local monitoring is incomplete; some task states cannot be confirmed.")
            : nil
    }
}

/// Ordered-on-screen is not equivalent to visible on the current Space.
struct NotchVisibility: Equatable {
    var requested = false
    var onActiveSpace = false
    var unoccluded = false
    var isVisible: Bool { requested && onActiveSpace && unoccluded }
}
