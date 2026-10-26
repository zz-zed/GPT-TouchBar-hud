import AppKit
import ResetNewsCore

/// Menu sizing remains local; semantic fields come from the shared forecast projection.
struct MenuForecastPresentation {
    let forecast: ForecastPresentation
    var kind: ForecastPresentation.Kind { forecast.kind }
    var value: String { forecast.value }
    var detail: String { forecast.detail }
    var canOpen: Bool { forecast.hasForecastDetails }
    var help: String { forecast.help }
    var compactValue: String { forecast.compactValue }
    var compactDetail: String { forecast.compactDetail }
    var canRetry: Bool { forecast.canRetry }
    var isEmpty: Bool { forecast.isEmpty }
    var isWide: Bool { false }

    /// Menu-only formatting; use the same typed resolver without changing other surfaces.
    static func lines(_ state: ResetNewsViewState, context: PresentationContext) -> (String, String) {
        let forecast = ForecastPresentation(state, context: context)
        if forecast.kind == .hidden { return (context.text("预告已关闭", "Forecasts off"), context.text("可在偏好设置中开启", "Enable in Preferences")) }
        guard let item = state.items.first(where: { $0.facts.contains { $0.kind == .upcomingReset } }),
              let fact = item.facts.first(where: { $0.kind == .upcomingReset }),
              let schedule = ResetForecastMenuSchedule(fact: fact, publishedAt: item.publishedAt, now: context.now, calendar: context.calendar, locale: context.locale) else {
            return (forecast.kind == .hidden ? context.text("预告已关闭", "Forecasts off") : forecast.compactValue,
                    forecast.kind == .hidden ? context.text("可在偏好设置中开启", "Enable in Preferences") : forecast.compactDetail)
        }
        var detail = schedule.detail
        let count = state.items.reduce(0) { $0 + $1.facts.filter { $0.kind == .upcomingReset }.count }
        if count > 1 { detail += context.text(" · 另有 \(count - 1) 条", " · \(count - 1) more") }
        return (schedule.value, detail)
    }

    init(_ state: ResetNewsViewState, now: Date = Date(), calendar: Calendar = .current) {
        forecast = ForecastPresentation(state, context: PresentationContext(now: now, calendar: calendar))
    }
    init(_ forecast: ForecastPresentation) { self.forecast = forecast }
}

private enum MenuMetricStyle: Equatable { case quota, credit, quietCredit, forecast, wideForecast, hint }
private struct MenuMetric: Equatable {
    let id: String
    let title: String
    let symbol: String
    let value: String
    let detail: String
    let style: MenuMetricStyle
    var unit = ""
    var progress: Double? = nil
    var actionable = false
    var retryable = false
    var isCached = false
    var hasPendingTime = false
    var help = ""
    var language: DisplayLanguage = .current
}

/// Compact native summary matching the approved V8 layout.
final class StatusSummaryView: NSView {
    override var isFlipped: Bool { true }
    var onRefresh: (() -> Void)?
    var onForecast: (() -> Void)?
    var onForecastRetry: (() -> Void)?
    var onQuotaRetry: (() -> Void)?
    private let heading = NSTextField(labelWithString: AppIdentity.productName)
    private let refresh = NSButton(title: "刷新数据", target: nil, action: nil)
    private let quotaMessage = NSTextField(labelWithString: "")
    private let quotaHint = NSTextField(labelWithString: "")
    private let quotaNote = NSTextField(labelWithString: "")
    private let quotaRetry = NSButton(title: "重试", target: nil, action: nil)
    private let updated = NSTextField(labelWithString: "")
    private let tokens = MenuTokenUsageField(labelWithString: "")
    private let tokenTotal = MenuTokenUsageField(labelWithString: "")
    private let tokenHeading = NSTextField(labelWithString: "")
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
        var quotaCount: Int
        var quotaMessage: String
        var quotaHint: String
        var quotaNote: String
        var quotaFailed: Bool
        var task: String?
        var taskColor: NSColor
        var balance: String?
        var tokens: String
        var tokenHelp: String
        var tokenNote: String
        var tokenUnknown: Bool
        var status: String
        var refreshing: Bool
    }

    init(state: RateLimitDisplayState) {
        super.init(frame: .zero)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        refresh.isBordered = false; refresh.font = .systemFont(ofSize: 11)
        refresh.image = Self.symbol("arrow.clockwise"); refresh.imagePosition = .imageLeft; refresh.imageHugsTitle = true
        refresh.target = self; refresh.action = #selector(refreshPressed)
        refresh.toolTip = "刷新数据 ⌘R"; refresh.setAccessibilityIdentifier("menu.refresh")
        for label in [quotaMessage, quotaHint, quotaNote, updated, tokens, tokenTotal, tokenHeading, tokenNote] {
            label.lineBreakMode = .byTruncatingTail
        }
        quotaMessage.font = .systemFont(ofSize: 12, weight: .medium)
        quotaHint.font = .systemFont(ofSize: 10); quotaHint.textColor = .secondaryLabelColor
        quotaNote.font = .systemFont(ofSize: 10); quotaNote.textColor = .systemOrange
        quotaNote.lineBreakMode = .byWordWrapping
        quotaNote.cell?.usesSingleLineMode = false; quotaNote.cell?.wraps = true
        quotaRetry.isBordered = false; quotaRetry.font = .systemFont(ofSize: 10)
        quotaRetry.contentTintColor = .controlAccentColor
        quotaRetry.target = self; quotaRetry.action = #selector(quotaRetryPressed)
        quotaRetry.setAccessibilityIdentifier("menu.quota.retry")
        tokenHeading.font = .systemFont(ofSize: 11); tokenHeading.textColor = .secondaryLabelColor
        tokenIcon.image = Self.symbol("cpu"); tokenIcon.contentTintColor = .secondaryLabelColor
        tokens.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        tokenTotal.font = tokens.font
        updated.font = .systemFont(ofSize: 10); updated.textColor = .secondaryLabelColor
        tokenNote.font = .systemFont(ofSize: 10); tokenNote.textColor = .systemOrange
        for view in [heading, refresh, quotaMessage, quotaHint, quotaNote, quotaRetry,
                     tokenIcon, tokenHeading, tokens, tokenTotal, tokenNote, updated] { addSubview(view) }
        update(state)
    }

    func update(_ state: RateLimitDisplayState, news: ResetNewsViewState? = nil, forecast presentation: ForecastPresentation? = nil,
                context: PresentationContext = PresentationContext()) {
        func date(_ value: Date?) -> String { value.map { context.date($0) } ?? "—" }
        if let news { self.news = news }
        let forecast = presentation.map(MenuForecastPresentation.init) ?? MenuForecastPresentation(ForecastPresentation(self.news, context: context))
        let hasQuota = state.fiveHour != nil || state.weekly != nil
        let firstLoad = !hasQuota && state.lastUpdated == nil && state.resetCredits == nil
        var metrics: [MenuMetric] = []
        func quota(_ meter: LimitMeter, id: String, title: String) -> MenuMetric {
            MenuMetric(id: id, title: title, symbol: "gauge.medium", value: meter.remainingText,
                detail: (meter.remainingPercent == 0 ? context.text("已耗尽 · ", "Exhausted · ") : "")
                    + context.text("重置 ", "Resets ") + date(meter.resetDate),
                style: .quota, progress: meter.remainingPercent)
        }
        if let five = state.fiveHour {
            metrics.append(quota(five, id: "fiveHour", title: context.text("5小时额度剩余", "5-hour remaining")))
        }
        if let weekly = state.weekly {
            metrics.append(quota(weekly, id: "weekly", title: context.text("周额度剩余", "Weekly remaining")))
        }
        let quotaCount = metrics.count
        do {
            if let credits = state.resetCredits {
                metrics.append(MenuMetric(id: "reset", title: context.text("可用完整重置", "Full resets available"),
                    symbol: "arrow.counterclockwise", value: "\(credits.availableCount)",
                    detail: credits.availableCount > 0
                        ? (credits.earliestExpirationDate.map { context.text("最早到期\n", "Earliest expiry\n") + date($0) } ?? context.text("到期未提供", "Expiry unavailable")) : context.text("当前无可用次数", "No resets available"),
                    style: .credit,
                    unit: context.language == .chinese ? " 次" : " left"))
            } else {
                metrics.append(MenuMetric(id: "reset", title: context.text("可用重置", "Available resets"),
                    symbol: "arrow.counterclockwise", value: context.text("次数待获取", "Count pending"),
                    detail: "", style: .quietCredit))
            }
        }
        do {
            let active = forecast.canOpen && forecast.kind != .hidden
            let lines = MenuForecastPresentation.lines(self.news, context: context)
            metrics.append(MenuMetric(id: "forecast", title: context.text("公开重置预告", "Public reset forecast"),
                symbol: "calendar.badge.clock", value: lines.0, detail: lines.1,
                style: active ? .forecast : .hint,
                actionable: active, retryable: forecast.canRetry,
                isCached: forecast.kind == .cached, hasPendingTime: forecast.forecast.hasPendingTime,
                help: forecast.value + "\n" + forecast.help))
        }
        let tokenUnknown = state.tokenUsage == nil ||
            (state.tokenUsage?.yesterdayTokens == nil && state.tokenUsage?.cumulativeTokens == nil)
        let usage = state.tokenUsage
        let quotaMessage = firstLoad ? (state.errorMessage == nil
            ? context.text("正在读取账号额度…", "Loading account quota…")
            : context.text("暂时无法读取账号数据", "Account data unavailable")) : (!hasQuota ? context.text("账号未提供额度窗口", "No quota windows provided") : "")
        let quotaHint = firstLoad ? (state.errorMessage == nil
            ? context.text("重置次数与 Token 用量也在获取中", "Resets and token usage are loading")
            : context.text("请确认 Codex 已启动后重试", "Check that Codex is running, then retry")) : ""
        let staleAccount = state.errorMessage != nil && !firstLoad
        let note = staleAccount && !state.isRefreshing ? context.text("账号未更新 · ", "Account not updated · ")
            + (state.lastUpdated.map { context.date($0, format: "HH:mm") } ?? "—") : ""
        let status: String
        if firstLoad { status = "" }
        else if state.isRefreshing { status = context.text("正在刷新 · 保留上次数据", "Refreshing · Showing last data") }
        else if staleAccount { status = "" }
        else if let lastUpdated = state.lastUpdated {
            status = context.text("账号数据 · ", "Account data · ") + context.date(lastUpdated, format: "HH:mm")
        }
        else { status = "" }
        metrics = metrics.map { var metric = $0; metric.language = context.language; return metric }
        let next = Presentation(metrics: metrics, quotaCount: quotaCount, quotaMessage: quotaMessage,
            quotaHint: quotaHint, quotaNote: note, quotaFailed: firstLoad && state.errorMessage != nil,
            task: state.displayedTaskStatus?.label(language: context.language),
            taskColor: state.displayedTaskStatus.map { TaskStatusAppearance($0).color ?? .secondaryLabelColor } ?? .secondaryLabelColor,
            balance: state.creditBalance.map { context.text("剩余点数 ", "Credits ") + ($0.displayText.components(separatedBy: "：").last ?? "") },
            tokens: "\(usage?.yesterdayText(language: context.language) ?? context.text("昨日 —", "Yday —"))     \(usage?.cumulativeText(language: context.language) ?? context.text("累计 —", "Total —"))",
            tokenHelp: usage?.toolTip(context: context) ?? context.text("账号 Token 统计尚未读取", "Account token usage not loaded"),
            tokenNote: usage?.isStale == true
                ? context.text("* 已保存数值 · Token 暂未更新", "* Saved values · Token update failed") : (tokenUnknown ? context.text("Token 用量尚未读取", "Token usage not received") : context.text("账号 Token 统计", "Account token usage")),
            tokenUnknown: tokenUnknown, status: status,
            refreshing: state.isRefreshing || self.news.status == .checking)
        guard lastPresentation != next else { return }
        lastPresentation = next; layoutUpdateCount += 1
        while cards.count > metrics.count { cards.removeLast().removeFromSuperview() }
        while cards.count < metrics.count {
            let card = MenuMetricView()
            card.onPress = { [weak self] in self?.onForecast?() }
            card.onRetry = { [weak self] in self?.onForecastRetry?() }
            cards.append(card); addSubview(card)
        }
        for (card, metric) in zip(cards, metrics) { card.update(metric) }
        updateOptional(&taskLabel, text: next.task, color: next.taskColor)
        updateOptional(&balanceLabel, text: next.balance, color: .secondaryLabelColor)
        self.quotaMessage.stringValue = next.quotaMessage; self.quotaMessage.toolTip = state.errorMessage
        self.quotaHint.stringValue = next.quotaHint
        quotaNote.stringValue = next.quotaNote; quotaNote.toolTip = state.errorMessage
        quotaRetry.title = context.text("重试", "Retry")
        quotaRetry.isEnabled = !state.isRefreshing
        tokenHeading.stringValue = context.text("Token 用量", "Token usage")
        let tokenParts = next.tokens.components(separatedBy: "     ")
        tokens.stringValue = tokenParts.first ?? ""; tokens.usageHelp = next.tokenHelp
        tokenTotal.stringValue = tokenParts.last ?? ""; tokenTotal.usageHelp = next.tokenHelp
        tokenNote.stringValue = next.tokenNote
        tokenNote.textColor = usage?.isStale == true ? .systemOrange : .secondaryLabelColor
        updated.stringValue = next.status
        refresh.isEnabled = !next.refreshing
        refresh.title = next.refreshing ? context.text("刷新中…", "Refreshing…") : context.text("刷新", "Refresh")
        layoutContent()
    }

    private func updateOptional(_ field: inout NSTextField?, text: String?, color: NSColor) {
        guard let text else { field?.removeFromSuperview(); field = nil; return }
        if field == nil { field = NSTextField(labelWithString: ""); addSubview(field!) }
        field?.stringValue = text; field?.font = .systemFont(ofSize: 11); field?.textColor = color; field?.toolTip = text
    }

    private func layoutContent() {
        let width: CGFloat = 344, left: CGFloat = 14, column: CGFloat = 151
        guard let presentation = lastPresentation else { return }
        heading.frame = NSRect(x: left, y: 8, width: 62, height: 18)
        refresh.sizeToFit()
        let refreshWidth = ceil(refresh.frame.width)
        refresh.frame = NSRect(x: 330 - refreshWidth, y: 5, width: refreshWidth, height: 24)
        taskLabel?.frame = NSRect(x: 79, y: 9, width: max(0, refresh.frame.minX - 83), height: 17)
        taskLabel?.setAccessibilityIdentifier("menu.task")
        separators = []
        quotaMessage.isHidden = presentation.quotaMessage.isEmpty
        quotaHint.isHidden = presentation.quotaHint.isEmpty
        quotaNote.isHidden = presentation.quotaNote.isEmpty
        quotaRetry.isHidden = !presentation.quotaFailed && presentation.quotaNote.isEmpty
        quotaMessage.frame = NSRect(x: left, y: 42, width: 316, height: 20)
        quotaHint.frame = NSRect(x: left, y: 66, width: 316, height: 17)
        for index in 0..<presentation.quotaCount {
            cards[index].frame = NSRect(x: left + CGFloat(index) * 165, y: 32,
                width: presentation.quotaCount == 1 ? 316 : column, height: 76)
            cards[index].layoutContent()
        }
        if presentation.quotaCount == 2 { separators.append(NSRect(x: 172, y: 37, width: 0.5, height: 68)) }
        updated.isHidden = !presentation.quotaNote.isEmpty || presentation.status.isEmpty
        updated.frame = NSRect(x: left, y: 110, width: 270, height: 16)
        quotaNote.frame = NSRect(x: left, y: 110, width: 270, height: 16)
        quotaRetry.frame = NSRect(x: 292, y: 107, width: 38, height: 20)
        separator(y: 128, width: width, left: left)
        for (id, x) in [("reset", left), ("forecast", left + 165)] {
            if let card = cards.first(where: { $0.metricID == id }) {
                card.frame = NSRect(x: x, y: 128, width: column, height: 88)
                card.layoutContent()
            }
        }
        separators.append(NSRect(x: 172, y: 135, width: 0.5, height: 74))
        separator(y: 216, width: width, left: left)
        tokenIcon.frame = NSRect(x: left, y: 222, width: 13, height: 14)
        tokenHeading.frame = NSRect(x: left + 18, y: 221, width: 90, height: 16)
        balanceLabel?.frame = NSRect(x: 126, y: 222, width: 204, height: 16)
        balanceLabel?.alignment = .right
        balanceLabel?.font = .systemFont(ofSize: 10)
        tokens.frame = NSRect(x: left, y: 240, width: 151, height: 19)
        tokenTotal.frame = NSRect(x: 179, y: 240, width: 151, height: 19)
        tokenNote.frame = NSRect(x: left, y: 260, width: 316, height: 15)
        tokens.isHidden = false; tokenNote.isHidden = false
        frame.size = NSSize(width: width, height: 280)
        // Register after the flipped summary and its labels have their final geometry.
        tokens.refreshTooltipRegion(); tokenTotal.refreshTooltipRegion()
        var order: [NSView] = [heading]
        if let taskLabel { order.append(taskLabel) }
        order.append(refresh)
        if !quotaMessage.isHidden { order += [quotaMessage, quotaHint] }
        order += Array(cards.prefix(presentation.quotaCount))
        if !quotaNote.isHidden { order.append(quotaNote) }
        if !updated.isHidden { order.append(updated) }
        if !quotaRetry.isHidden { order.append(quotaRetry) }
        order += Array(cards.dropFirst(presentation.quotaCount))
        order.append(tokenHeading)
        if let balanceLabel { order.append(balanceLabel) }
        order += [tokens, tokenTotal, tokenNote]
        setAccessibilityChildren(order)
        needsDisplay = true
    }

    private func separator(y: CGFloat, width: CGFloat, left: CGFloat) {
        separators.append(NSRect(x: left, y: y - 1, width: width - 2 * left, height: 0.5))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        for rect in separators { rect.fill() }
    }
    @objc private func refreshPressed() { onRefresh?() }
    @objc private func quotaRetryPressed() { onQuotaRetry?() }
    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class MenuMetricView: NSView {
    override var isFlipped: Bool { true }
    var onPress: (() -> Void)?
    var onRetry: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let arrow = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private var actionButton: NSButton?
    private var retryButton: NSButton?
    private(set) var metric: MenuMetric?
    var metricID: String? { metric?.id }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [icon, title, value, detail, arrow, badge] { addSubview(view) }
        title.font = .systemFont(ofSize: 10, weight: .medium)
        badge.font = .systemFont(ofSize: 9, weight: .medium); badge.textColor = .systemOrange
        for field in [value, detail] {
            field.lineBreakMode = .byWordWrapping; field.maximumNumberOfLines = 2
            field.cell?.usesSingleLineMode = false; field.cell?.wraps = true
        }
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
        arrow.image = StatusSummaryView.symbol("chevron.right")
        arrow.contentTintColor = .secondaryLabelColor
    }
    func update(_ metric: MenuMetric) {
        self.metric = metric
        title.stringValue = metric.title
        title.isHidden = false
        badge.stringValue = metric.language.text("待更新", "Not updated"); badge.isHidden = !metric.isCached
        icon.image = StatusSummaryView.symbol(metric.symbol)
        icon.contentTintColor = .secondaryLabelColor
        let font: NSFont
        switch metric.style {
        case .quota: font = .monospacedDigitSystemFont(ofSize: 27, weight: .semibold)
        case .credit: font = .monospacedDigitSystemFont(ofSize: 21, weight: metric.value == "0" ? .regular : .semibold)
        case .forecast: font = .systemFont(ofSize: 16, weight: .semibold)
        case .wideForecast: font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        case .quietCredit, .hint: font = .systemFont(ofSize: 11, weight: .regular)
        }
        value.font = font
        let text = NSMutableAttributedString(string: metric.value, attributes: [.font: font])
        text.append(NSAttributedString(string: metric.unit, attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        value.attributedStringValue = text
        value.textColor = metric.style == .hint || metric.style == .quietCredit || metric.value == "0"
            ? .secondaryLabelColor : metric.style == .forecast ? .systemBlue : metric.style == .quota && (metric.progress ?? 100) <= 20 ? .systemRed : .labelColor
        detail.stringValue = metric.detail
        detail.textColor = .secondaryLabelColor
        arrow.isHidden = !metric.actionable
        let label = "\(metric.title) \(metric.value)\(metric.unit)\(metric.detail.isEmpty ? "" : "，" + metric.detail)"
            + (metric.isCached ? metric.language.text("，待更新；尚未获取最新预告，当前显示已保存的安排", "; not updated; latest forecast unavailable, showing the saved schedule") : "")
        toolTip = metric.help.isEmpty ? label : label + "\n" + metric.help
        setAccessibilityIdentifier("menu." + metric.id)
        setAccessibilityElement(!metric.actionable)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
        if metric.actionable {
            if actionButton == nil {
                let button = MenuMetricButton(title: "", target: self, action: #selector(pressed))
                button.isBordered = false; button.focusRingType = .none; button.setAccessibilityIdentifier("menu.forecast.open")
                actionButton = button; addSubview(button)
            }
            actionButton?.setAccessibilityLabel(label)
            actionButton?.toolTip = (toolTip ?? "") + "\n查看预告 ⌘⇧P"
        } else { actionButton?.removeFromSuperview(); actionButton = nil }
        if metric.retryable {
            if retryButton == nil {
                let button = NSButton(title: "重试", target: self, action: #selector(retryPressed))
                button.isBordered = false; button.font = .systemFont(ofSize: 10)
                button.setAccessibilityIdentifier("menu.forecast.retry")
                retryButton = button; addSubview(button)
            }
            retryButton?.toolTip = "重新检查公开重置预告"
        } else { retryButton?.removeFromSuperview(); retryButton = nil }
        retryButton?.title = metric.language.text("重试", "Retry")
        layoutContent(); needsDisplay = true
    }
    func layoutContent() {
        guard let metric else { return }
        icon.frame = NSRect(x: 0, y: 6, width: 12, height: 14)
        title.frame = NSRect(x: 16, y: 5, width: bounds.width - 22, height: 13)
        arrow.frame = NSRect(x: bounds.width - 6, y: 8, width: 6, height: 9)
        detail.isHidden = metric.detail.isEmpty
        if metric.style == .quota {
            value.frame = NSRect(x: 0, y: 21, width: bounds.width, height: 32)
            detail.frame = NSRect(x: 0, y: 60, width: bounds.width, height: 16)
        } else if metric.id == "reset" {
            value.frame = NSRect(x: 0, y: 27, width: bounds.width, height: 27)
            detail.frame = NSRect(x: 0, y: 55, width: bounds.width, height: 30)
        } else {
            value.frame = NSRect(x: 0, y: 29, width: bounds.width, height: 38)
            // Cached state occupies the spare line directly under the title.
            badge.frame = NSRect(x: 0, y: 18, width: bounds.width, height: 11)
            if !metric.isCached { value.frame.origin.y = 26 }
            detail.frame = NSRect(x: 0, y: 68, width: bounds.width - (metric.retryable ? 32 : 0), height: 20)
            detail.font = .systemFont(ofSize: 9)
        }
        actionButton?.frame = bounds
        if let retryButton {
            retryButton.frame = NSRect(x: bounds.width - 32, y: 66, width: 32, height: 20)
            addSubview(retryButton, positioned: .above, relativeTo: actionButton)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let metric, metric.style == .quota else { return }
        let rect = NSRect(x: 0, y: 55, width: bounds.width, height: 3)
        NSColor.separatorColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        if let percent = metric.progress {
            (percent <= 20 ? NSColor.systemRed : NSColor.controlAccentColor.withAlphaComponent(0.7)).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 55, width: bounds.width * CGFloat(percent / 100), height: 3),
                xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
    @objc private func pressed() { onPress?() }
    @objc private func retryPressed() { onRetry?() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class MenuMetricButton: NSButton {
    private var tracking: NSTrackingArea?
    private var hovered = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted || window?.firstResponder === self {
            NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.12 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { performClick(nil) } else { super.keyDown(with: event) }
    }
}

/// Menu windows reuse views while their geometry changes. Keep the tooltip's region local,
/// rebuild it after layout/attachment, and reject callbacks if the pointer has left the label.
final class MenuTokenUsageField: NSTextField {
    var usageHelp = "" {
        didSet { setAccessibilityHelp(usageHelp); refreshTooltipRegion() }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshTooltipRegion() }
    override func updateTrackingAreas() { super.updateTrackingAreas(); refreshTooltipRegion() }
    func refreshTooltipRegion() {
        removeAllToolTips()
        guard window != nil, !usageHelp.isEmpty, !bounds.isEmpty else { return }
        addToolTip(bounds, owner: self, userData: nil)
    }
    func tooltipText(atWindowPoint point: NSPoint) -> String? {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return nil }
        let local = convert(point, from: nil)
        guard bounds.contains(local), visibleRect.contains(local) else { return nil }
        return usageHelp.isEmpty ? nil : usageHelp
    }
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                    point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        guard let window else { return "" }
        // The callback's point may belong to an earlier registered rect. Use the live pointer.
        return tooltipText(atWindowPoint: window.mouseLocationOutsideOfEventStream) ?? ""
    }
}
