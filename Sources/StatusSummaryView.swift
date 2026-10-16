import AppKit
import ResetNewsCore

/// The public forecast and the account quota have separate freshness and actions.
struct MenuForecastPresentation: Equatable {
    enum Kind: Equatable { case hidden, currentEmpty, checking, paused, unavailable, announced, cached }
    let kind: Kind
    let value: String
    let detail: String
    let canOpen: Bool
    let help: String
    let compactValue: String
    let compactDetail: String
    let isWide: Bool
    let canRetry: Bool

    var isEmpty: Bool { kind == .currentEmpty }

    init(_ state: ResetNewsViewState, now: Date = Date(), calendar: Calendar = .current) {
        canOpen = state.canOpenDetails
        help = state.statusText + (state.forecastCheckedAt.map { "\n预告数据更新于 " + Self.date($0) } ?? "")
        guard state.enabled else {
            kind = .hidden; value = "预告已关闭"; detail = "可在设置中开启"
            compactValue = ""; compactDetail = ""; isWide = false; canRetry = false
            return
        }
        let item = state.items.first { $0.facts.contains(where: { $0.kind == .upcomingReset }) }
        if let item, let fact = item.facts.first(where: { $0.kind == .upcomingReset }) {
            let schedule = ResetForecastHeadline(fact: fact, publishedAt: item.publishedAt, now: now, calendar: calendar)
            kind = state.forecastAvailability == .cached ? .cached : .announced
            value = schedule.summary
            detail = kind == .cached
                ? "上次预告 · " + state.forecastCheckedAt.map { Self.date($0) }.unwrap(or: "时间未知")
                : "查看当前安排"
            canRetry = kind == .cached && [.failure, .partial, .stale].contains(state.status)
            if let window = fact.officialWindow, let start = window.startAt, let end = window.endAt,
               !calendar.isDate(start, inSameDayAs: end) {
                let clock = DateFormatter(); clock.dateFormat = "HH:mm"; clock.timeZone = calendar.timeZone
                let day = DateFormatter(); day.dateFormat = "MM/dd"; day.timeZone = calendar.timeZone
                let startDay = calendar.isDate(start, inSameDayAs: now) ? "今天" : day.string(from: start)
                let endDay = calendar.isDate(end, inSameDayAs: now) ? "今天"
                    : calendar.isDate(end, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
                        ? "明天" : day.string(from: end)
                compactValue = "\(startDay) \(clock.string(from: start)) – \(endDay) \(clock.string(from: end))"
                compactDetail = "预计时段 · \(day.string(from: start))–\(day.string(from: end))"
                isWide = true
            } else if schedule.hasClock {
                compactValue = schedule.headline
                let when = fact.effectiveAt ?? fact.officialWindow?.endAt
                compactDetail = (schedule.lead ?? "预计") + (when.map { " · " + Self.day($0, calendar: calendar) } ?? "")
                isWide = (compactValue as NSString).size(withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)]).width > 135
            } else if schedule.dateText != nil {
                if schedule.summary.hasPrefix("预计今天") { compactValue = "今天" }
                else if schedule.summary.hasPrefix("预计明天") { compactValue = "明天" }
                else { compactValue = schedule.dateText ?? "日期待确认" }
                compactDetail = (schedule.dateText ?? "") + " · 时刻未公布"
                isWide = (compactValue as NSString).size(withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)]).width > 135
            } else {
                compactValue = "时间待定"; compactDetail = "已有公开预告"; isWide = false
            }
            return
        }
        isWide = false
        switch state.forecastAvailability {
        case .current:
            kind = .currentEmpty; value = "当前暂无公开重置预告"; detail = ""
            compactValue = "预告 · 暂无"; compactDetail = ""; canRetry = false
        case .cached:
            kind = .unavailable; value = "预告暂不可用"; detail = "上次结果已过期"
            compactValue = value; compactDetail = ""; canRetry = state.status != .checking
        case .unknown:
            detail = ""; canRetry = [.failure, .partial, .stale].contains(state.status)
            switch state.status {
            case .checking:
                kind = .checking; value = "正在获取预告"
            case .failure, .partial, .stale:
                kind = .unavailable; value = "预告暂不可用"
            case .codexNotRunning:
                kind = .paused; value = "等待 Codex 启动"
            case .idle:
                kind = .paused; value = "预告检查已暂停"
            case .disabled:
                kind = .hidden; value = "预告已关闭"
            case .success:
                kind = .checking; value = "尚未获取预告"
            }
            compactValue = value; compactDetail = ""
        }
    }

    private static func day(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "MM/dd"; formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }
    private static func date(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "MM/dd HH:mm"; formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

private extension Optional where Wrapped == String {
    func unwrap(or fallback: String) -> String { self ?? fallback }
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

    func update(_ state: RateLimitDisplayState, news: ResetNewsViewState? = nil) {
        if let news { self.news = news }
        let forecast = MenuForecastPresentation(self.news)
        let hasQuota = state.fiveHour != nil || state.weekly != nil
        let firstLoad = !hasQuota && state.lastUpdated == nil && state.resetCredits == nil
        var metrics: [MenuMetric] = []
        func quota(_ meter: LimitMeter, id: String, title: String) -> MenuMetric {
            MenuMetric(id: id, title: title, symbol: "gauge.medium", value: meter.remainingText,
                detail: (meter.remainingPercent == 0 ? "已耗尽 · " : "") + "重置 " + Self.date(meter.resetDate),
                style: .quota, progress: meter.remainingPercent)
        }
        if let five = state.fiveHour { metrics.append(quota(five, id: "fiveHour", title: "5小时额度剩余")) }
        if let weekly = state.weekly { metrics.append(quota(weekly, id: "weekly", title: "周额度剩余")) }
        let quotaCount = metrics.count
        if !firstLoad {
            if let credits = state.resetCredits {
                let quiet = credits.availableCount == 0 && !forecast.canOpen
                metrics.append(MenuMetric(id: "reset", title: quiet ? "可用重置" : "可用完整重置",
                    symbol: "arrow.counterclockwise", value: "\(credits.availableCount)",
                    detail: credits.availableCount > 0 ? "最早到期 " + Self.date(credits.earliestExpirationDate) : "",
                    style: quiet ? .quietCredit : .credit, unit: "次"))
            } else {
                metrics.append(MenuMetric(id: "reset", title: "重置", symbol: "arrow.counterclockwise",
                    value: "次数待获取", detail: "", style: .quietCredit))
            }
        }
        if forecast.kind != .hidden {
            let active = forecast.canOpen
            let wide = active && (forecast.isWide || firstLoad)
            metrics.append(MenuMetric(id: "forecast", title: "公开重置预告", symbol: "calendar.badge.clock",
                value: forecast.compactValue,
                detail: active ? (forecast.kind == .cached ? forecast.detail : forecast.compactDetail) : "",
                style: active ? (wide ? .wideForecast : .forecast) : .hint,
                actionable: active, retryable: forecast.canRetry,
                help: forecast.value + "\n" + forecast.help))
        }
        let tokenUnknown = state.tokenUsage == nil ||
            (state.tokenUsage?.yesterdayTokens == nil && state.tokenUsage?.cumulativeTokens == nil)
        let usage = state.tokenUsage
        let quotaMessage = firstLoad ? (state.errorMessage == nil ? "正在读取账号额度…" : "暂时无法读取账号数据") : ""
        let quotaHint = firstLoad ? (state.errorMessage == nil ? "重置次数与 Token 用量也在获取中" : "请确认 Codex 已启动后重试") : ""
        let staleQuota = state.errorMessage != nil && hasQuota && state.lastUpdated != nil
        let note = staleQuota ? "上次数据 · " + Self.date(state.lastUpdated) + " · 额度暂无法更新" : ""
        let status: String
        if firstLoad { status = "" }
        else if state.isRefreshing { status = "正在刷新 · 保留上次数据" }
        else if staleQuota { status = "" }
        else if let lastUpdated = state.lastUpdated { status = "账号数据 · " + Self.time(lastUpdated) }
        else { status = "" }
        let next = Presentation(metrics: metrics, quotaCount: quotaCount, quotaMessage: quotaMessage,
            quotaHint: quotaHint, quotaNote: note, quotaFailed: firstLoad && state.errorMessage != nil,
            task: state.displayedTaskStatus?.label,
            taskColor: state.displayedTaskStatus.map { TaskStatusAppearance($0).color ?? .secondaryLabelColor } ?? .secondaryLabelColor,
            balance: state.creditBalance?.displayText,
            tokens: tokenUnknown ? "" : "\(usage?.yesterdayText ?? "昨日 --")     \(usage?.cumulativeText ?? "累计 --")",
            tokenHelp: usage?.toolTip ?? "账号 Token 统计尚未读取",
            tokenNote: usage?.isStale == true ? "上次数据 · Token 暂无法更新" : "",
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
        tokenHeading.stringValue = tokenUnknown ? "Token 用量待获取" : "Token 用量"
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
        case .forecast: font = .monospacedDigitSystemFont(ofSize: metric.value == "时间待定" ? 14 : 18, weight: metric.value == "时间待定" ? .medium : .semibold)
        case .wideForecast: font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        case .quietCredit, .hint: font = .systemFont(ofSize: 11, weight: .regular)
        }
        value.font = font
        let displayValue: String
        if metric.style == .quietCredit {
            displayValue = metric.value == "次数待获取"
                ? "重置次数待获取" : "\(metric.title) \(metric.value)\(metric.unit)"
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
        detail.textColor = metric.style == .forecast && metric.detail.contains("上次预告") ? .systemOrange : .secondaryLabelColor
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
                title.frame = NSRect(x: 0, y: 9, width: 110, height: 17)
                icon.frame = NSRect(x: 0, y: 9, width: 14, height: 16)
                title.frame.origin.x = 18
                value.frame = NSRect(x: 126, y: 7, width: 35, height: 27)
                detail.frame = NSRect(x: 168, y: 12, width: bounds.width - 168, height: 16)
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
