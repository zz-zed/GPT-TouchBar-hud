import AppKit

enum HUDDisplayMode: String, CaseIterable {
    case automatic, floating, notch
    static let defaultsKey = "hud.displayMode"
    static func load(from defaults: UserDefaults = .standard) -> Self {
        // Screen detection resolves automatic at presentation time; never persist
        // a detected form over a user's saved floating/notch preference.
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .automatic
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
    mutating func applyStartupVisibility(hasGeometry: Bool, defaults: UserDefaults = .standard) {
        // Only initialize an absent visibility choice. A saved false is an
        // explicit hide and must survive relaunch, wake and screen changes.
        guard defaults.object(forKey: Self.visibilityKey) == nil,
              usesNotch(hasGeometry: hasGeometry) else { return }
        isVisible = true
        defaults.set(true, forKey: Self.visibilityKey)
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
    let topInset: CGFloat
    let backingScale: CGFloat
    let cameraEnclosure: NSRect
    init?(screen: NSRect, topInset: CGFloat, leftArea: NSRect, rightArea: NSRect, backingScale: CGFloat = 2) {
        let gap = rightArea.minX - leftArea.maxX
        let scalars = [screen.minX, screen.minY, screen.width, screen.height, topInset,
                       leftArea.minX, leftArea.minY, leftArea.width, leftArea.height,
                       rightArea.minX, rightArea.minY, rightArea.width, rightArea.height, backingScale]
        guard scalars.allSatisfy(\.isFinite), screen.width >= 400, screen.height >= 480,
              backingScale >= 1, topInset > 0, topInset < screen.height / 3, gap > 0, gap < screen.width / 2,
              leftArea.width > 0, rightArea.width > 0,
              screen.contains(leftArea), screen.contains(rightArea),
              abs(leftArea.maxY - screen.maxY) < 1, abs(rightArea.maxY - screen.maxY) < 1,
              abs(leftArea.height - topInset) < 1, abs(rightArea.height - topInset) < 1 else { return nil }
        self.screen = screen
        self.backingScale = backingScale
        self.topInset = ceil(topInset * backingScale) / backingScale
        // Round inward so antialiased edges never paint into either auxiliary menu area.
        let left = ceil(leftArea.maxX * backingScale) / backingScale
        let right = floor(rightArea.minX * backingScale) / backingScale
        guard right > left else { return nil }
        notchWidth = right - left
        cameraEnclosure = NSRect(x: left, y: screen.maxY - self.topInset, width: notchWidth, height: self.topInset)
        // NSWindow aligns origins to whole points. Choose the hardware center once,
        // then use even widths so animated resize cannot move it by half a point.
        anchor = NSPoint(x: ((left + right) / 2).rounded(), y: screen.maxY)
    }
    var contentTop: CGFloat { anchor.y - topInset }
    /// Height is the content budget below the camera; the decoration is added once.
    func frame(width: CGFloat, height: CGFloat) -> NSRect {
        let enclosureWidth = 2 * max(anchor.x - cameraEnclosure.minX, cameraEnclosure.maxX - anchor.x)
        let halfWidth = min(ceil(max(enclosureWidth, width) / 2), floor(min(anchor.x - screen.minX, screen.maxX - anchor.x)))
        let w = halfWidth * 2
        let h = min(ceil(topInset + height), anchor.y - screen.minY)
        return NSRect(x: anchor.x - w / 2, y: anchor.y - h, width: w, height: h)
    }
    func enclosure(in frame: NSRect) -> NSRect {
        NSRect(x: cameraEnclosure.minX - frame.minX, y: 0, width: notchWidth, height: topInset)
    }
    static func transitionFraction(_ progress: Double) -> CGFloat {
        CGFloat(1 - pow(1 - max(0, min(1, progress)), 3))
    }
    func transitionFrame(from start: NSRect, to target: NSRect, progress: Double) -> NSRect {
        let eased = Self.transitionFraction(progress)
        return frame(width: start.width + (target.width - start.width) * eased,
                     height: start.height + (target.height - start.height) * eased - topInset)
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
                                                  leftArea: left, rightArea: right, backingScale: screen.backingScaleFactor) else { return nil }
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
        appearance = TaskStatusAppearance(summary)
        if summary.runningCount > 0 {
            badge = String(max(0, summary.runningCount)) + (summary.legacyCompletionFeedbackVisible ? " ✓" : "")
        } else {
            badge = summary.legacyCompletionFeedbackVisible ? "✓" : "0"
        }
        title = summary.label
        note = nil
    }
}

/// Ordered-on-screen is not equivalent to visible on the current Space.
struct NotchVisibility: Equatable {
    var requested = false
    var onActiveSpace = false
    var unoccluded = false
    var isVisible: Bool { requested && onActiveSpace && unoccluded }
}
