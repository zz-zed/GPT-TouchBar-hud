import AppKit

/// Presentation values exclude diagnostics that do not affect the visible menu.
struct MenuForecastPresentation: Equatable {
    let value: String
    let detail: String
    let canOpen: Bool
    let help: String

    init(_ state: ResetNewsViewState) {
        canOpen = state.forecastCount > 0
        help = state.statusText
        if canOpen {
            value = "\(state.forecastCount)"
            switch state.status {
            case .failure, .partial, .stale: detail = "查看预告 · 缓存"
            default: detail = "查看预告"
            }
        } else {
            switch state.status {
            case .success: value = "0"; detail = "暂无预告"
            case .disabled: value = "—"; detail = "预告已关闭"
            case .checking: value = "—"; detail = "正在检查"
            case .failure: value = "—"; detail = "检查失败"
            case .partial: value = "—"; detail = "部分来源未读取"
            case .stale: value = "—"; detail = "来源已过期"
            case .codexNotRunning: value = "—"; detail = "等待 Codex 启动"
            case .idle: value = "—"; detail = "检查已暂停"
            }
        }
    }
}

private struct MenuMetric: Equatable {
    let id: String
    let title: String
    let symbol: String
    let value: String
    let detail: String
    var unit = ""
    var progress: Double? = nil
    var isQuota = false
    var actionable = false
    var help = ""
}

/// Native menu content. Only refresh and a nonempty forecast are actions.
final class StatusSummaryView: NSView {
    override var isFlipped: Bool { true }
    var onRefresh: (() -> Void)?
    var onForecast: (() -> Void)?
    private let heading = NSTextField(labelWithString: AppIdentity.productName)
    private let refresh = NSButton(title: "刷新", target: nil, action: nil)
    private let updated = NSTextField(labelWithString: "")
    private let tokens = NSTextField(labelWithString: "")
    private let tokenHeading = NSTextField(labelWithString: "Token 用量")
    private let tokenIcon = NSImageView()
    private let tokenNote = NSTextField(labelWithString: "")
    private var taskLabel: NSTextField?
    private var balanceLabel: NSTextField?
    private var cards: [MenuMetricView] = []
    private var lastPresentation: Presentation?
    private var news = ResetNewsViewState()
    private(set) var layoutUpdateCount = 0
    private var separators: [NSRect] = []

    private struct Presentation: Equatable {
        var metrics: [MenuMetric]
        var task: String?
        var taskColor: NSColor
        var balance: String?
        var tokens: String
        var tokenHelp: String
        var tokenNote: String
        var status: String
        var isError: Bool
        var refreshing: Bool
    }

    init(state: RateLimitDisplayState) {
        super.init(frame: .zero)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        refresh.isBordered = false
        refresh.font = .systemFont(ofSize: 11)
        refresh.image = Self.symbol("arrow.clockwise")
        refresh.imagePosition = .imageLeft
        refresh.target = self
        refresh.action = #selector(refreshPressed)
        refresh.toolTip = "刷新额度 ⌘R"
        refresh.setAccessibilityIdentifier("menu.refresh")
        tokenHeading.font = .systemFont(ofSize: 11)
        tokenHeading.textColor = .secondaryLabelColor
        tokenIcon.image = Self.symbol("cpu")
        tokenIcon.contentTintColor = .secondaryLabelColor
        tokens.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        updated.font = .systemFont(ofSize: 10)
        tokenNote.font = .systemFont(ofSize: 10)
        tokenNote.textColor = .secondaryLabelColor
        for view in [heading, refresh, tokenIcon, tokenHeading, tokens, tokenNote, updated] { addSubview(view) }
        update(state)
    }

    func update(_ state: RateLimitDisplayState, news: ResetNewsViewState? = nil) {
        if let news { self.news = news }
        var metrics: [MenuMetric] = []
        func quota(_ meter: LimitMeter?, id: String, title: String) -> MenuMetric {
            MenuMetric(id: id, title: title, symbol: "gauge.medium", value: meter?.remainingText ?? "—",
                detail: "重置 " + Self.date(meter?.resetDate), progress: meter?.remainingPercent, isQuota: true)
        }
        if let five = state.fiveHour { metrics.append(quota(five, id: "fiveHour", title: "5小时额度剩余")) }
        if state.weekly != nil || metrics.isEmpty { metrics.append(quota(state.weekly, id: "weekly", title: "周额度剩余")) }
        let credits = state.resetCredits
        metrics.append(MenuMetric(id: "reset", title: "可用完整重置", symbol: "arrow.counterclockwise",
            value: credits.map { "\($0.availableCount)" } ?? "—",
            detail: credits?.availableCount == 0 ? "无可用次数" : "最早到期 " + Self.date(credits?.earliestExpirationDate), unit: "次"))
        let forecast = MenuForecastPresentation(self.news)
        metrics.append(MenuMetric(id: "forecast", title: "重置预告", symbol: "calendar.badge.clock",
            value: forecast.value, detail: forecast.detail, unit: forecast.value == "—" ? "" : "条",
            actionable: forecast.canOpen, help: forecast.help))
        let usage = state.tokenUsage
        let next = Presentation(metrics: metrics, task: state.displayedTaskStatus?.label,
            taskColor: state.displayedTaskStatus.map { TaskStatusAppearance($0).color ?? .secondaryLabelColor } ?? .secondaryLabelColor,
            balance: state.creditBalance?.displayText,
            tokens: "\(usage?.yesterdayText ?? "昨日 —")     \(usage?.cumulativeText ?? "累计 —")",
            tokenHelp: usage?.toolTip ?? "账号 Token 统计尚未读取",
            tokenNote: usage?.isStale == true ? "* 上次成功数据 · Token 刷新失败" : "",
            status: state.statusText, isError: state.errorMessage != nil, refreshing: state.isRefreshing)
        guard lastPresentation != next else { return }
        lastPresentation = next
        layoutUpdateCount += 1
        while cards.count > metrics.count { cards.removeLast().removeFromSuperview() }
        while cards.count < metrics.count {
            let card = MenuMetricView()
            card.onPress = { [weak self] in self?.onForecast?() }
            cards.append(card); addSubview(card)
        }
        for (card, metric) in zip(cards, metrics) { card.update(metric) }
        updateOptional(&taskLabel, text: next.task, color: next.taskColor)
        updateOptional(&balanceLabel, text: next.balance, color: .secondaryLabelColor)
        tokens.stringValue = next.tokens; tokens.toolTip = next.tokenHelp
        tokenNote.stringValue = next.tokenNote
        updated.stringValue = next.status; updated.toolTip = next.status
        updated.textColor = next.isError ? .systemOrange : .secondaryLabelColor
        refresh.isEnabled = !next.refreshing
        refresh.title = next.refreshing ? "刷新中…" : "刷新"
        layoutContent()
    }

    private func updateOptional(_ field: inout NSTextField?, text: String?, color: NSColor) {
        guard let text else { field?.removeFromSuperview(); field = nil; return }
        if field == nil { field = NSTextField(labelWithString: ""); addSubview(field!) }
        field?.stringValue = text; field?.font = .systemFont(ofSize: 11); field?.textColor = color; field?.toolTip = text
    }

    private func layoutContent() {
        let width: CGFloat = 344, left: CGFloat = 14, column: CGFloat = 151, gap: CGFloat = 14
        heading.frame = NSRect(x: left, y: 10, width: 232, height: 20)
        refresh.frame = NSRect(x: 257, y: 8, width: 74, height: 24)
        var y: CGFloat = 38
        separators = []
        for index in cards.indices {
            let full = cards.count % 2 == 1 && index == cards.count - 1
            let rowHeight: CGFloat = index < 2 ? 94 : 82
            cards[index].frame = NSRect(x: left + (index % 2 == 0 ? 0 : column + gap), y: y,
                width: full ? width - 2 * left : column, height: full ? 70 : rowHeight)
            cards[index].layoutContent()
            if index % 2 == 1 || full {
                let bottom = y + (full ? 70 : rowHeight)
                separators.append(NSRect(x: left, y: bottom, width: width - 2 * left, height: 0.5))
                if !full { separators.append(NSRect(x: width / 2, y: y + 3, width: 0.5, height: rowHeight - 4)) }
                y = bottom + 1
            }
        }
        y += 10
        tokenIcon.frame = NSRect(x: left, y: y, width: 13, height: 14)
        tokenHeading.frame = NSRect(x: left + 18, y: y, width: 150, height: 16)
        tokens.frame = NSRect(x: left, y: y + 23, width: width - 2 * left, height: 19)
        y += 47
        tokenNote.isHidden = tokenNote.stringValue.isEmpty
        if !tokenNote.isHidden { tokenNote.frame = NSRect(x: left, y: y, width: width - 2 * left, height: 16); y += 18 }
        for label in [taskLabel, balanceLabel].compactMap({ $0 }) {
            label.frame = NSRect(x: left, y: y, width: width - 2 * left, height: 17); y += 19
        }
        updated.frame = NSRect(x: left, y: y, width: width - 2 * left, height: 17)
        frame.size = NSSize(width: width, height: y + 26)
        // Match VoiceOver traversal to the visual reading order, independent of view reuse.
        var accessibilityOrder: [NSView] = [heading, refresh] + cards + [tokenHeading, tokens]
        if !tokenNote.isHidden { accessibilityOrder.append(tokenNote) }
        accessibilityOrder += [taskLabel, balanceLabel].compactMap { $0 }
        accessibilityOrder.append(updated)
        setAccessibilityChildren(accessibilityOrder)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        for rect in separators { rect.fill() }
    }

    @objc private func refreshPressed() { onRefresh?() }
    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
    }
    private static func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd HH:mm"; formatter.timeZone = .current
        return formatter.string(from: value)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class MenuMetricView: NSView {
    override var isFlipped: Bool { true }
    var onPress: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let arrow = NSImageView()
    private var metric: MenuMetric?
    private(set) var actionButton: NSButton?
    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [icon, title, value, detail, arrow] { addSubview(view) }
        title.font = .systemFont(ofSize: 11, weight: .medium)
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
        arrow.image = StatusSummaryView.symbol("chevron.right"); arrow.contentTintColor = .secondaryLabelColor
    }
    func update(_ metric: MenuMetric) {
        self.metric = metric
        title.stringValue = metric.title
        icon.image = StatusSummaryView.symbol(metric.symbol)
        icon.contentTintColor = .secondaryLabelColor
        let text = NSMutableAttributedString(string: metric.value, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: metric.isQuota ? 27 : 21, weight: .semibold)])
        text.append(NSAttributedString(string: metric.unit, attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        value.attributedStringValue = text
        value.textColor = metric.isQuota && (metric.progress ?? 100) <= 20 ? .systemRed : (metric.actionable ? .controlAccentColor : .labelColor)
        detail.stringValue = metric.detail
        arrow.isHidden = !metric.actionable
        let label = "\(metric.title) \(metric.value)\(metric.unit)，\(metric.detail)"
        toolTip = metric.help.isEmpty ? label : label + "\n" + metric.help
        setAccessibilityIdentifier("menu." + metric.id)
        setAccessibilityElement(!metric.actionable)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
        if metric.actionable {
            if actionButton == nil {
                let button = MenuMetricButton(title: "", target: self, action: #selector(pressed))
                button.isBordered = false
                button.setAccessibilityIdentifier("menu.forecast.open")
                actionButton = button; addSubview(button)
            }
            actionButton?.setAccessibilityLabel(label)
            actionButton?.toolTip = (toolTip ?? "") + "\n查看预告 ⌘⇧P"
        } else { actionButton?.removeFromSuperview(); actionButton = nil }
        layoutContent(); needsDisplay = true
    }
    func layoutContent() {
        guard let metric else { return }
        icon.frame = NSRect(x: 0, y: 8, width: 14, height: 16)
        title.frame = NSRect(x: 18, y: 8, width: bounds.width - 30, height: 17)
        arrow.frame = NSRect(x: bounds.width - 10, y: 10, width: 9, height: 12)
        value.frame = NSRect(x: 0, y: 30, width: bounds.width, height: metric.isQuota ? 34 : 27)
        detail.frame = NSRect(x: 0, y: metric.isQuota ? 77 : 61, width: bounds.width, height: 16)
        if bounds.height == 70 { value.frame.origin.y = 26; detail.frame.origin.y = 52 }
        actionButton?.frame = bounds
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let metric, metric.isQuota else { return }
        let rect = NSRect(x: 0, y: 69, width: bounds.width, height: 3)
        NSColor.separatorColor.setFill(); NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        if let percent = metric.progress {
            (percent <= 20 ? NSColor.systemRed : NSColor.controlAccentColor.withAlphaComponent(0.7)).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 69, width: bounds.width * CGFloat(percent / 100), height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
    @objc private func pressed() { onPress?() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class MenuMetricButton: NSButton {
    private var tracking: NSTrackingArea?
    private var hovered = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4)
            path.lineWidth = 2; path.stroke()
        }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
}
