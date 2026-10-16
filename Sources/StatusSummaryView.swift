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
    var isWide: Bool {
        forecast.headline?.spansMultipleDays == true || (compactValue as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)]).width > 135
            || (forecast.headline?.kind == .dateOnly && (compactDetail as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width > 151)
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
}

/// Native status menu summary. The rendering rules match the approved 28-scene preview.
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
    private let tokens = NSTextField(labelWithString: "")
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
        refresh.image = Self.symbol("arrow.clockwise"); refresh.imagePosition = .imageLeft
        refresh.target = self; refresh.action = #selector(refreshPressed)
        refresh.toolTip = "刷新数据 ⌘R"; refresh.setAccessibilityIdentifier("menu.refresh")
        for label in [quotaMessage, quotaHint, quotaNote, updated, tokens, tokenHeading, tokenNote] {
            label.lineBreakMode = .byTruncatingTail
        }
        quotaMessage.font = .systemFont(ofSize: 12, weight: .medium)
        quotaHint.font = .systemFont(ofSize: 10); quotaHint.textColor = .secondaryLabelColor
        quotaNote.font = .systemFont(ofSize: 10); quotaNote.textColor = .systemOrange
        quotaRetry.isBordered = false; quotaRetry.font = .systemFont(ofSize: 10)
        quotaRetry.contentTintColor = .controlAccentColor
        quotaRetry.target = self; quotaRetry.action = #selector(quotaRetryPressed)
        quotaRetry.setAccessibilityIdentifier("menu.quota.retry")
        tokenHeading.font = .systemFont(ofSize: 11); tokenHeading.textColor = .secondaryLabelColor
        tokenIcon.image = Self.symbol("cpu"); tokenIcon.contentTintColor = .secondaryLabelColor
        tokens.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        updated.font = .systemFont(ofSize: 10); updated.textColor = .secondaryLabelColor
        tokenNote.font = .systemFont(ofSize: 10); tokenNote.textColor = .systemOrange
        for view in [heading, refresh, quotaMessage, quotaHint, quotaNote, quotaRetry,
                     tokenIcon, tokenHeading, tokens, tokenNote, updated] { addSubview(view) }
        update(state)
    }

    func update(_ state: RateLimitDisplayState, news: ResetNewsViewState? = nil, forecast presentation: ForecastPresentation? = nil) {
        if let news { self.news = news }
        let forecast = presentation.map(MenuForecastPresentation.init) ?? MenuForecastPresentation(self.news)
        let hasQuota = state.fiveHour != nil || state.weekly != nil
        let firstLoad = !hasQuota && state.lastUpdated == nil && state.resetCredits == nil
        var metrics: [MenuMetric] = []
        func quota(_ meter: LimitMeter, id: String, title: String) -> MenuMetric {
            MenuMetric(id: id, title: title, symbol: "gauge.medium", value: meter.remainingText,
                detail: (meter.remainingPercent == 0 ? DisplayLanguage.text("已耗尽 · ", "Exhausted · ") : "")
                    + DisplayLanguage.text("重置 ", "Resets ") + Self.date(meter.resetDate),
                style: .quota, progress: meter.remainingPercent)
        }
        if let five = state.fiveHour {
            metrics.append(quota(five, id: "fiveHour", title: DisplayLanguage.text("5小时额度剩余", "5-hour remaining")))
        }
        if let weekly = state.weekly {
            metrics.append(quota(weekly, id: "weekly", title: DisplayLanguage.text("周额度剩余", "Weekly remaining")))
        }
        let quotaCount = metrics.count
        if !firstLoad {
            if let credits = state.resetCredits {
                let quiet = credits.availableCount == 0 && !forecast.canOpen
                metrics.append(MenuMetric(id: "reset", title: quiet
                    ? DisplayLanguage.text("可用重置", "Available resets")
                    : DisplayLanguage.text("可用完整重置", "Full resets available"),
                    symbol: "arrow.counterclockwise", value: "\(credits.availableCount)",
                    detail: credits.availableCount > 0
                        ? DisplayLanguage.text("最早到期 ", "Expires ") + Self.date(credits.earliestExpirationDate) : "",
                    style: quiet ? .quietCredit : .credit,
                    unit: DisplayLanguage.current == .chinese ? "次" : (quiet ? " left" : "")))
            } else {
                metrics.append(MenuMetric(id: "reset", title: DisplayLanguage.text("重置", "Resets"),
                    symbol: "arrow.counterclockwise", value: DisplayLanguage.text("次数待获取", "Count pending"),
                    detail: "", style: .quietCredit))
            }
        }
        if forecast.kind != .hidden {
            let active = forecast.canOpen
            let wide = active && (forecast.isWide || firstLoad)
            metrics.append(MenuMetric(id: "forecast", title: DisplayLanguage.text("公开重置预告", "Public reset forecast"),
                symbol: "calendar.badge.clock",
                value: forecast.compactValue,
                detail: active ? (forecast.kind == .cached ? forecast.detail : forecast.compactDetail) : "",
                style: active ? (wide ? .wideForecast : .forecast) : .hint,
                actionable: active, retryable: forecast.canRetry,
                isCached: forecast.kind == .cached, hasPendingTime: forecast.forecast.hasPendingTime,
                help: forecast.value + "\n" + forecast.help))
        }
        let tokenUnknown = state.tokenUsage == nil ||
            (state.tokenUsage?.yesterdayTokens == nil && state.tokenUsage?.cumulativeTokens == nil)
        let usage = state.tokenUsage
        let quotaMessage = firstLoad ? (state.errorMessage == nil
            ? DisplayLanguage.text("正在读取账号额度…", "Loading account quota…")
            : DisplayLanguage.text("暂时无法读取账号数据", "Account data unavailable")) : ""
        let quotaHint = firstLoad ? (state.errorMessage == nil
            ? DisplayLanguage.text("重置次数与 Token 用量也在获取中", "Resets and token usage are loading")
            : DisplayLanguage.text("请确认 Codex 已启动后重试", "Check that Codex is running, then retry")) : ""
        let staleQuota = state.errorMessage != nil && hasQuota && state.lastUpdated != nil
        let note = staleQuota ? DisplayLanguage.text("上次数据 · ", "Last data · ") + Self.date(state.lastUpdated)
            + DisplayLanguage.text(" · 额度暂无法更新", " · Quota unavailable") : ""
        let status: String
        if firstLoad { status = "" }
        else if state.isRefreshing { status = DisplayLanguage.text("正在刷新 · 保留上次数据", "Refreshing · Showing last data") }
        else if staleQuota { status = "" }
        else if let lastUpdated = state.lastUpdated {
            status = DisplayLanguage.text("账号数据 · ", "Account data · ") + Self.time(lastUpdated)
        }
        else { status = "" }
        let next = Presentation(metrics: metrics, quotaCount: quotaCount, quotaMessage: quotaMessage,
            quotaHint: quotaHint, quotaNote: note, quotaFailed: firstLoad && state.errorMessage != nil,
            task: state.displayedTaskStatus?.label,
            taskColor: state.displayedTaskStatus.map { TaskStatusAppearance($0).color ?? .secondaryLabelColor } ?? .secondaryLabelColor,
            balance: state.creditBalance?.displayText,
            tokens: tokenUnknown ? "" : "\(usage?.yesterdayText ?? DisplayLanguage.text("昨日 --", "Yday --"))     \(usage?.cumulativeText ?? DisplayLanguage.text("累计 --", "Total --"))",
            tokenHelp: usage?.toolTip ?? DisplayLanguage.text("账号 Token 统计尚未读取", "Account token usage not loaded"),
            tokenNote: usage?.isStale == true
                ? DisplayLanguage.text("上次数据 · Token 暂无法更新", "Last data · Token update failed") : "",
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
        quotaRetry.title = next.quotaFailed ? "重新获取账号数据" : "重试"
        tokenHeading.stringValue = tokenUnknown
            ? DisplayLanguage.text("Token 用量待获取", "Token usage pending")
            : DisplayLanguage.text("Token 用量", "Token usage")
        tokens.stringValue = next.tokens; tokens.toolTip = next.tokenHelp
        tokenNote.stringValue = next.tokenNote
        updated.stringValue = next.status
        refresh.isEnabled = !next.refreshing
        refresh.title = next.refreshing ? "刷新中…" : "刷新数据"
        layoutContent()
    }

    private func updateOptional(_ field: inout NSTextField?, text: String?, color: NSColor) {
        guard let text else { field?.removeFromSuperview(); field = nil; return }
        if field == nil { field = NSTextField(labelWithString: ""); addSubview(field!) }
        field?.stringValue = text; field?.font = .systemFont(ofSize: 11); field?.textColor = color; field?.toolTip = text
    }

    private func layoutContent() {
        let width: CGFloat = 344, left: CGFloat = 14, column: CGFloat = 151, gap: CGFloat = 14
        heading.frame = NSRect(x: left, y: 10, width: 228, height: 20)
        refresh.frame = NSRect(x: 243, y: 8, width: 88, height: 24)
        var y: CGFloat = 38
        separators = []
        guard let presentation = lastPresentation else { return }
        quotaMessage.isHidden = presentation.quotaMessage.isEmpty
        quotaHint.isHidden = presentation.quotaHint.isEmpty
        quotaNote.isHidden = presentation.quotaNote.isEmpty
        quotaRetry.isHidden = !presentation.quotaFailed && presentation.quotaNote.isEmpty
        if presentation.quotaCount > 0 {
            let full = presentation.quotaCount == 1
            for index in 0..<presentation.quotaCount {
                cards[index].frame = NSRect(x: left + (index == 0 ? 0 : column + gap), y: y,
                    width: full ? width - 2 * left : column, height: 94)
                cards[index].layoutContent()
            }
            if !full { separators.append(NSRect(x: width / 2, y: y + 3, width: 0.5, height: 90)) }
            y += 95
            if !presentation.quotaNote.isEmpty {
                quotaNote.frame = NSRect(x: left, y: y + 3, width: 264, height: 28)
                quotaRetry.frame = NSRect(x: 286, y: y + 5, width: 44, height: 20)
                y += 32
            }
            separator(y: y, width: width, left: left)
        } else if !presentation.quotaMessage.isEmpty {
            quotaMessage.frame = NSRect(x: left, y: y + 7, width: width - 2 * left, height: 20)
            quotaHint.frame = NSRect(x: left, y: y + 28, width: width - 2 * left, height: 17)
            if presentation.quotaFailed {
                quotaRetry.frame = NSRect(x: left, y: y + 49, width: 150, height: 20)
                y += 73
            } else { y += 53 }
            separator(y: y, width: width, left: left)
        }
        let credits = cards.first { $0.metricID == "reset" }
        let forecast = cards.first { $0.metricID == "forecast" }
        if let credits, let metric = credits.metric {
            switch metric.style {
            case .quietCredit:
                credits.frame = NSRect(x: left, y: y, width: width - 2 * left, height: 35)
                if forecast != nil { forecast?.frame = NSRect(x: 202, y: y + 2, width: 128, height: 28) }
                y += 36
            case .credit where forecast?.metric?.style == .forecast:
                credits.frame = NSRect(x: left, y: y, width: column, height: 82)
                forecast?.frame = NSRect(x: left + column + gap, y: y, width: column, height: 82)
                separators.append(NSRect(x: width / 2, y: y + 3, width: 0.5, height: 78))
                y += 83
            case .credit where forecast?.metric?.style == .wideForecast:
                credits.frame = NSRect(x: left, y: y, width: width - 2 * left, height: 36)
                y += 37
                separator(y: y, width: width, left: left)
                forecast?.frame = NSRect(x: left, y: y + 5, width: width - 2 * left, height: 66)
                y += 72
            default:
                credits.frame = NSRect(x: left, y: y, width: width - 2 * left, height: 64)
                if forecast != nil { forecast?.frame = NSRect(x: 202, y: y + 2, width: 128, height: 28) }
                y += 65
            }
            credits.layoutContent(); forecast?.layoutContent()
            separator(y: y, width: width, left: left)
        } else if let forecast {
            forecast.frame = NSRect(x: left, y: y + 4, width: width - 2 * left,
                height: forecast.metric?.style == .wideForecast ? 66 : 28)
            forecast.layoutContent()
            y += forecast.frame.height + 5
            separator(y: y, width: width, left: left)
        }
        let showToken = presentation.quotaMessage.isEmpty
        tokenIcon.isHidden = !showToken
        tokenHeading.isHidden = !showToken
        if showToken {
            y += 10
            tokenIcon.frame = NSRect(x: left, y: y, width: 13, height: 14)
            tokenHeading.frame = NSRect(x: left + 18, y: y, width: 170, height: 16)
            if presentation.tokenUnknown {
                tokens.isHidden = true; tokenNote.isHidden = true
                y += 27
            } else {
                tokens.isHidden = false
                tokens.frame = NSRect(x: left, y: y + 23, width: width - 2 * left, height: 19)
                y += 47
                tokenNote.isHidden = tokenNote.stringValue.isEmpty
                if !tokenNote.isHidden { tokenNote.frame = NSRect(x: left, y: y, width: width - 2 * left, height: 16); y += 18 }
            }
        } else {
            tokens.isHidden = true
            tokenNote.isHidden = true
        }
        let labels = [taskLabel, balanceLabel].compactMap { $0 }
        if labels.count == 2 {
            separator(y: y + 2, width: width, left: left)
            y += 9
            taskLabel?.frame = NSRect(x: left, y: y, width: 151, height: 17)
            balanceLabel?.frame = NSRect(x: left + column + gap, y: y, width: 151, height: 17)
            y += 20
        } else {
            for label in labels { label.frame = NSRect(x: left, y: y, width: width - 2 * left, height: 17); y += 19 }
        }
        updated.isHidden = presentation.status.isEmpty
        if !updated.isHidden {
            updated.frame = NSRect(x: left, y: y, width: width - 2 * left, height: 17)
            y += 17
        }
        frame.size = NSSize(width: width, height: y + 10)
        var accessibilityOrder: [NSView] = [heading, refresh]
        if !quotaMessage.isHidden { accessibilityOrder += [quotaMessage, quotaHint] }
        if !quotaRetry.isHidden { accessibilityOrder.append(quotaRetry) }
        accessibilityOrder += cards
        if showToken { accessibilityOrder.append(tokenHeading) }
        if !tokens.isHidden { accessibilityOrder.append(tokens) }
        if !tokenNote.isHidden { accessibilityOrder.append(tokenNote) }
        accessibilityOrder += labels
        if !updated.isHidden { accessibilityOrder.append(updated) }
        setAccessibilityChildren(accessibilityOrder)
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
    private static func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd HH:mm"; formatter.timeZone = .current
        return formatter.string(from: value)
    }
    private static func time(_ value: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"; formatter.timeZone = .current
        return formatter.string(from: value)
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
    private var actionButton: NSButton?
    private var retryButton: NSButton?
    private(set) var metric: MenuMetric?
    var metricID: String? { metric?.id }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [icon, title, value, detail, arrow] { addSubview(view) }
        title.font = .systemFont(ofSize: 11, weight: .medium)
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
        arrow.image = StatusSummaryView.symbol("chevron.right")
        arrow.contentTintColor = .secondaryLabelColor
    }
    func update(_ metric: MenuMetric) {
        self.metric = metric
        title.stringValue = metric.title
        title.isHidden = [.hint, .quietCredit].contains(metric.style)
        icon.image = StatusSummaryView.symbol(metric.symbol)
        icon.contentTintColor = .secondaryLabelColor
        let font: NSFont
        switch metric.style {
        case .quota: font = .monospacedDigitSystemFont(ofSize: 27, weight: .semibold)
        case .credit: font = .monospacedDigitSystemFont(ofSize: 21, weight: metric.value == "0" ? .regular : .semibold)
        case .forecast: font = .monospacedDigitSystemFont(ofSize: metric.hasPendingTime ? 14 : 18,
            weight: metric.hasPendingTime ? .medium : .semibold)
        case .wideForecast: font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        case .quietCredit, .hint: font = .systemFont(ofSize: 11, weight: .regular)
        }
        value.font = font
        let displayValue: String
        if metric.style == .quietCredit {
            displayValue = metric.unit.isEmpty
                ? DisplayLanguage.text("重置次数待获取", "Reset count pending")
                : "\(metric.title) \(metric.value)\(metric.unit)"
        } else {
            displayValue = metric.value
        }
        let text = NSMutableAttributedString(string: displayValue, attributes: [.font: font])
        if metric.style != .quietCredit {
            text.append(NSAttributedString(string: metric.unit, attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        }
        value.attributedStringValue = text
        value.textColor = metric.style == .hint || metric.style == .quietCredit || metric.value == "0"
            ? .secondaryLabelColor : metric.style == .quota && (metric.progress ?? 100) <= 20 ? .systemRed : .labelColor
        detail.stringValue = metric.detail
        detail.textColor = metric.isCached ? .systemOrange : .secondaryLabelColor
        arrow.isHidden = !metric.actionable
        let label = "\(metric.title) \(metric.value)\(metric.unit)\(metric.detail.isEmpty ? "" : "，" + metric.detail)"
        toolTip = metric.help.isEmpty ? label : label + "\n" + metric.help
        setAccessibilityIdentifier("menu." + metric.id)
        setAccessibilityElement(!metric.actionable)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
        if metric.actionable {
            if actionButton == nil {
                let button = MenuMetricButton(title: "", target: self, action: #selector(pressed))
                button.isBordered = false; button.setAccessibilityIdentifier("menu.forecast.open")
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
        layoutContent(); needsDisplay = true
    }
    func layoutContent() {
        guard let metric else { return }
        icon.frame = NSRect(x: 0, y: 8, width: 14, height: 16)
        title.frame = NSRect(x: 18, y: 8, width: bounds.width - 30, height: 17)
        arrow.frame = NSRect(x: bounds.width - 10, y: 10, width: 9, height: 12)
        detail.isHidden = metric.detail.isEmpty || [.hint, .quietCredit].contains(metric.style)
        switch metric.style {
        case .quota:
            value.frame = NSRect(x: 0, y: 30, width: bounds.width, height: 34)
            detail.frame = NSRect(x: 0, y: 77, width: bounds.width, height: 16)
        case .credit:
            let full = bounds.width > 200
            if bounds.height < 45 {
                icon.frame = NSRect(x: 0, y: 9, width: 14, height: 16)
                title.frame = NSRect(x: 18, y: 9, width: 112, height: 17)
                value.frame = NSRect(x: 136, y: 7, width: 35, height: 27)
                detail.frame = NSRect(x: 181, y: 12, width: bounds.width - 181, height: 16)
            } else {
                value.frame = NSRect(x: full ? 18 : 0, y: 30, width: 37, height: 27)
                detail.frame = NSRect(x: full ? 63 : 41, y: 37, width: bounds.width - (full ? 63 : 41), height: 16)
            }
        case .quietCredit:
            value.frame = NSRect(x: 18, y: 8, width: bounds.width - 18, height: 18)
        case .forecast, .wideForecast:
            let wide = metric.style == .wideForecast
            if wide { icon.frame.origin.y = 4; title.frame.origin.y = 4; arrow.frame.origin.y = 4 }
            value.frame = NSRect(x: wide ? 0 : 0, y: wide ? 25 : 30,
                width: bounds.width - 12, height: 26)
            value.lineBreakMode = .byTruncatingTail
            detail.frame = NSRect(x: 0, y: wide ? 50 : 61,
                width: bounds.width - (metric.retryable ? 38 : 0), height: 16)
        case .hint:
            let textWidth = min(bounds.width - 18 - (metric.retryable ? 28 : 0),
                ceil(value.attributedStringValue.size().width) + 4)
            value.frame = NSRect(x: 18, y: 7, width: max(0, textWidth), height: 17)
        }
        actionButton?.frame = bounds
        if let retryButton {
            retryButton.frame = NSRect(x: bounds.width - 32, y: metric.style == .hint ? 5 : bounds.height - 22,
                width: 32, height: 20)
            addSubview(retryButton, positioned: .above, relativeTo: actionButton)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let metric, metric.style == .quota else { return }
        let rect = NSRect(x: 0, y: 69, width: bounds.width, height: 3)
        NSColor.separatorColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        if let percent = metric.progress {
            (percent <= 20 ? NSColor.systemRed : NSColor.controlAccentColor.withAlphaComponent(0.7)).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 69, width: bounds.width * CGFloat(percent / 100), height: 3),
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
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        if hovered || isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            path.fill()
        }
        if window?.firstResponder === self {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
}
