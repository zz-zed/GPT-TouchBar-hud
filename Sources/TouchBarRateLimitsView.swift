import AppKit

final class TouchBarRateLimitsView: NSView {
    static let contentWidth: CGFloat = 600
    private let chatGPTIconView = NSImageView()
    private let fiveHourRow = TouchBarLimitRow(title: "5 小时")
    private let weeklyRow = TouchBarLimitRow(title: "周限额")
    private let creditBalanceRow = TouchBarCreditBalanceRow()

    init() {
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with state: RateLimitDisplayState) {
        fiveHourRow.toolTip = state.tokenUsage?.toolTip
        weeklyRow.toolTip = state.tokenUsage?.toolTip
        var hasLeadingLimitRow = false

        if let fiveHour = state.fiveHour {
            fiveHourRow.isHidden = false
            hasLeadingLimitRow = true
            fiveHourRow.updateLimit(
                title: "5 小时",
                meter: fiveHour,
                usageText: state.tokenUsage?.yesterdayText ?? "昨日 --"
            )
        } else if let resetCredits = state.resetCredits, resetCredits.availableCount > 0 {
            fiveHourRow.isHidden = false
            hasLeadingLimitRow = true
            fiveHourRow.updateResetCredits(
                resetCredits,
                usageText: state.tokenUsage?.yesterdayText ?? "昨日 --"
            )
        } else if state.lastUpdated != nil {
            fiveHourRow.isHidden = true
        } else {
            fiveHourRow.isHidden = false
            fiveHourRow.updatePlaceholder(title: "5 小时", usageText: "昨日 --")
        }

        creditBalanceRow.isHidden = true

        if let weekly = state.weekly {
            weeklyRow.isHidden = false
            weeklyRow.updateLimit(
                title: "周限额",
                meter: weekly,
                usageText: state.tokenUsage?.cumulativeText ?? "累计 --",
                creditBalanceText: hasLeadingLimitRow ? state.creditBalance?.displayText : nil
            )

            if !hasLeadingLimitRow, let balanceText = state.creditBalance?.displayText {
                creditBalanceRow.update(text: balanceText)
                creditBalanceRow.isHidden = false
            }
        } else if state.lastUpdated != nil {
            weeklyRow.isHidden = true
            if let balanceText = state.creditBalance?.displayText {
                creditBalanceRow.update(text: balanceText)
                creditBalanceRow.isHidden = false
            }
        } else {
            weeklyRow.isHidden = false
            weeklyRow.updatePlaceholder(title: "周限额", usageText: "累计 --")
        }
        // Optional USD balance shares the second row. Reclaim decorative progress
        // space in both rows while keeping percentages, dates and tokens aligned.
        let hasInlineBalance = hasLeadingLimitRow && state.weekly != nil && state.creditBalance != nil
        fiveHourRow.setCompactLayout(hasInlineBalance)
        weeklyRow.setCompactLayout(hasInlineBalance)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false

        chatGPTIconView.image = Self.chatGPTIcon()
        chatGPTIconView.imageAlignment = .alignCenter
        chatGPTIconView.imageScaling = .scaleProportionallyUpOrDown
        chatGPTIconView.translatesAutoresizingMaskIntoConstraints = false
        chatGPTIconView.toolTip = "ChatGPT"

        let rows = NSStackView(views: [fiveHourRow, weeklyRow, creditBalanceRow])
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.distribution = .fill
        rows.spacing = 1
        creditBalanceRow.isHidden = true

        let content = NSStackView(views: [chatGPTIconView, rows])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 6
        content.setCustomSpacing(2, after: chatGPTIconView)

        addSubview(content)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.contentWidth),
            heightAnchor.constraint(equalToConstant: 30),
            chatGPTIconView.widthAnchor.constraint(equalToConstant: 24),
            chatGPTIconView.heightAnchor.constraint(equalToConstant: 30),
            fiveHourRow.widthAnchor.constraint(equalToConstant: 574),
            weeklyRow.widthAnchor.constraint(equalToConstant: 574),
            creditBalanceRow.widthAnchor.constraint(equalToConstant: 574),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private static func chatGPTIcon() -> NSImage {
        let iconPaths = [
            "/Applications/ChatGPT.app/Contents/Resources/icon-chatgpt.png",
            "/Applications/ChatGPT.app/Contents/Resources/icon-chatgpt.icns",
            "/Applications/GPT.app/Contents/Resources/icon-chatgpt.png",
            "/Applications/GPT.app/Contents/Resources/icon-chatgpt.icns"
        ]

        for path in iconPaths {
            if let image = NSImage(contentsOfFile: path) {
                image.size = NSSize(width: 30, height: 30)
                return image
            }
        }

        let appPaths = ["/Applications/ChatGPT.app", "/Applications/GPT.app"]
        for path in appPaths where FileManager.default.fileExists(atPath: path) {
            let image = NSWorkspace.shared.icon(forFile: path)
            image.size = NSSize(width: 30, height: 30)
            return image
        }

        let bundledIconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns")
        let image = bundledIconPath.flatMap(NSImage.init(contentsOfFile:))
            ?? NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: "ChatGPT")
            ?? NSImage(size: NSSize(width: 30, height: 30))
        image.size = NSSize(width: 30, height: 30)
        return image
    }
}

private final class TouchBarCreditBalanceRow: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(text: String) {
        label.stringValue = text
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byClipping
        addSubview(label)

        let preferredHeight = heightAnchor.constraint(equalToConstant: 13)
        preferredHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            preferredHeight,
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

private final class TouchBarLimitRow: NSView {
    private let statusContainer = NSView()
    private let titleLabel: NSTextField
    private let batteryBar = SegmentedBatteryBar()
    private let creditsIndicatorLabel = NSTextField(labelWithString: "")
    private let remainingLabel = NSTextField(labelWithString: "剩余 --")
    private let resetLabel = NSTextField(labelWithString: "-- 重置")
    private let separatorLabel = NSTextField(labelWithString: "|")
    private let usageLabel = NSTextField(labelWithString: "--")
    private let creditSeparatorLabel = NSTextField(labelWithString: "|")
    private let creditBalanceLabel = NSTextField(labelWithString: "")

    init(title: String) {
        self.titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateLimit(
        title: String,
        meter: LimitMeter,
        usageText: String,
        creditBalanceText: String? = nil
    ) {
        titleLabel.stringValue = title
        batteryBar.isHidden = false
        creditsIndicatorLabel.isHidden = true
        batteryBar.remainingPercent = meter.remainingPercent
        batteryBar.isDimmed = false
        remainingLabel.stringValue = "剩余 \(meter.remainingText)"
        resetLabel.stringValue = meter.resetText
        usageLabel.stringValue = usageText
        updateCreditBalance(creditBalanceText)
    }

    func updateResetCredits(_ resetCredits: ResetCreditSummary, usageText: String) {
        titleLabel.stringValue = "重置券"
        batteryBar.isHidden = true
        creditsIndicatorLabel.isHidden = false
        creditsIndicatorLabel.stringValue = Self.creditIndicator(count: resetCredits.availableCount)
        remainingLabel.stringValue = resetCredits.availableText
        resetLabel.stringValue = resetCredits.expirationText
        usageLabel.stringValue = usageText
        updateCreditBalance(nil)
    }

    func updatePlaceholder(title: String, usageText: String) {
        titleLabel.stringValue = title
        batteryBar.isHidden = false
        creditsIndicatorLabel.isHidden = true
        batteryBar.remainingPercent = 0
        batteryBar.isDimmed = true
        remainingLabel.stringValue = "剩余 --"
        resetLabel.stringValue = "-- 重置"
        usageLabel.stringValue = usageText
        updateCreditBalance(nil)
    }

    func setCompactLayout(_ compact: Bool) {
        statusContainer.isHidden = compact
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .left

        creditsIndicatorLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        creditsIndicatorLabel.textColor = .systemTeal
        creditsIndicatorLabel.alignment = .left
        creditsIndicatorLabel.lineBreakMode = .byClipping
        creditsIndicatorLabel.isHidden = true

        remainingLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        remainingLabel.textColor = .labelColor
        remainingLabel.lineBreakMode = .byTruncatingTail

        resetLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        resetLabel.textColor = .labelColor
        resetLabel.lineBreakMode = .byTruncatingTail

        separatorLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        separatorLabel.textColor = .labelColor
        separatorLabel.alignment = .center

        usageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        usageLabel.textColor = .labelColor
        usageLabel.lineBreakMode = .byClipping
        usageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        creditSeparatorLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        creditSeparatorLabel.textColor = .labelColor
        creditSeparatorLabel.alignment = .center
        creditSeparatorLabel.isHidden = true

        creditBalanceLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        creditBalanceLabel.textColor = .labelColor
        creditBalanceLabel.lineBreakMode = .byClipping
        creditBalanceLabel.isHidden = true
        creditBalanceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        batteryBar.translatesAutoresizingMaskIntoConstraints = false
        creditsIndicatorLabel.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.addSubview(batteryBar)
        statusContainer.addSubview(creditsIndicatorLabel)

        let row = NSStackView(views: [
            titleLabel,
            statusContainer,
            remainingLabel,
            resetLabel,
            separatorLabel,
            usageLabel,
            creditSeparatorLabel,
            creditBalanceLabel
        ])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 6
        row.setCustomSpacing(4, after: titleLabel)
        row.setCustomSpacing(0, after: remainingLabel)
        row.setCustomSpacing(4, after: resetLabel)
        row.setCustomSpacing(4, after: separatorLabel)
        row.setCustomSpacing(4, after: usageLabel)
        row.setCustomSpacing(4, after: creditSeparatorLabel)

        addSubview(row)

        let preferredHeight = heightAnchor.constraint(equalToConstant: 13)
        preferredHeight.priority = .defaultHigh

        let preferredProgressWidth = statusContainer.widthAnchor.constraint(equalToConstant: 72)
        preferredProgressWidth.priority = .defaultHigh
        let preferredResetWidth = resetLabel.widthAnchor.constraint(equalToConstant: 125)
        preferredResetWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            preferredHeight,
            titleLabel.widthAnchor.constraint(equalToConstant: 38),
            preferredProgressWidth,
            statusContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            statusContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 72),
            statusContainer.heightAnchor.constraint(equalToConstant: 11),
            batteryBar.widthAnchor.constraint(equalTo: statusContainer.widthAnchor),
            batteryBar.heightAnchor.constraint(equalToConstant: 11),
            batteryBar.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor),
            batteryBar.topAnchor.constraint(equalTo: statusContainer.topAnchor),
            creditsIndicatorLabel.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 5),
            creditsIndicatorLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusContainer.trailingAnchor),
            creditsIndicatorLabel.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),
            remainingLabel.widthAnchor.constraint(equalToConstant: 58),
            preferredResetWidth,
            resetLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            separatorLabel.widthAnchor.constraint(equalToConstant: 12),
            usageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private static func creditIndicator(count: Int) -> String {
        if count <= 5 {
            return Array(repeating: "●", count: max(0, count)).joined(separator: "  ")
        }
        return "●  × \(count)"
    }

    private func updateCreditBalance(_ text: String?) {
        let shouldShow = text?.isEmpty == false
        creditSeparatorLabel.isHidden = !shouldShow
        creditBalanceLabel.isHidden = !shouldShow
        creditBalanceLabel.stringValue = text?.replacingOccurrences(of: "还剩点数：", with: "") ?? ""
        creditBalanceLabel.toolTip = text
    }
}
