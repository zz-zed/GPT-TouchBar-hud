import AppKit
import QuartzCore

final class TouchBarRateLimitsView: NSView {
    static let contentWidth: CGFloat = 460
    private let chatGPTIconView = NSImageView()
    private let taskBadge = NSTextField(labelWithString: "")
    private var hasRunningTasks = false
    private var itemVisibility: Bool?
    private var itemVisibilityObservation: NSKeyValueObservation?
    private var windowObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private static let breathingAnimationKey = "taskBadgeBreathing"
    private let fiveHourRow = TouchBarLimitRow(title: "5h")
    private let weeklyRow = TouchBarLimitRow(title: "Week")
    private let creditBalanceRow = TouchBarCreditBalanceRow()

    init() {
        super.init(frame: .zero)
        configure()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.updateTaskAnimation() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        if let window {
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.updateTaskAnimation() }
        }
        updateTaskAnimation()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateTaskAnimation()
    }

    func observeVisibility(of item: NSTouchBarItem) {
        itemVisibilityObservation = item.observe(\.isVisible, options: [.initial, .new]) { [weak self] item, _ in
            self?.setTouchBarItemVisible(item.isVisible)
        }
    }

    func setTouchBarItemVisible(_ visible: Bool) {
        itemVisibility = visible
        updateTaskAnimation()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateTaskAnimation()
    }

    private func updateTaskAnimation() {
        guard let layer = taskBadge.layer else { return }
        let shouldAnimate = hasRunningTasks && !isHiddenOrHasHiddenAncestor &&
            (itemVisibility ?? (window?.occlusionState.contains(.visible) == true)) &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate else {
            layer.removeAnimation(forKey: Self.breathingAnimationKey)
            return
        }
        // Repeated status updates must not restart the cycle. Core Animation
        // drives the effect without a timer or repeated redraws of the quota rows.
        guard layer.animation(forKey: Self.breathingAnimationKey) == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.45
        animation.duration = 1.2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: Self.breathingAnimationKey)
    }

    func update(with state: RateLimitDisplayState) {
        let taskStatus = state.displayedTaskStatus
        taskBadge.isHidden = taskStatus == nil
        taskBadge.stringValue = taskStatus?.badge ?? ""
        taskBadge.backgroundColor = taskStatus.map {
            $0.runningCount > 0 ? .systemBlue : ($0.recentlyCompletedCount > 0 ? .systemGreen : .darkGray)
        } ?? .clear
        hasRunningTasks = (taskStatus?.runningCount ?? 0) > 0
        updateTaskAnimation()
        chatGPTIconView.toolTip = taskStatus?.detail ?? "ChatGPT"
        chatGPTIconView.setAccessibilityLabel(taskStatus?.label ?? "ChatGPT")
        fiveHourRow.toolTip = state.tokenUsage?.toolTip
        weeklyRow.toolTip = state.tokenUsage?.toolTip
        var hasLeadingLimitRow = false

        if let fiveHour = state.fiveHour {
            fiveHourRow.isHidden = false
            hasLeadingLimitRow = true
            fiveHourRow.updateLimit(
                title: "5h",
                meter: fiveHour,
                usageText: state.tokenUsage?.yesterdayText ?? "Yday --"
            )
        } else if let resetCredits = state.resetCredits, resetCredits.availableCount > 0 {
            fiveHourRow.isHidden = false
            hasLeadingLimitRow = true
            fiveHourRow.updateResetCredits(
                resetCredits,
                usageText: state.tokenUsage?.yesterdayText ?? "Yday --"
            )
        } else if state.lastUpdated != nil {
            fiveHourRow.isHidden = true
        } else {
            fiveHourRow.isHidden = false
            fiveHourRow.updatePlaceholder(title: "5h", usageText: "Yday --")
        }

        creditBalanceRow.isHidden = true

        if let weekly = state.weekly {
            weeklyRow.isHidden = false
            weeklyRow.updateLimit(
                title: "Week",
                meter: weekly,
                usageText: state.tokenUsage?.cumulativeText ?? "Total --",
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
            weeklyRow.updatePlaceholder(title: "Week", usageText: "Total --")
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
        taskBadge.translatesAutoresizingMaskIntoConstraints = false
        taskBadge.font = .systemFont(ofSize: 8, weight: .bold)
        taskBadge.textColor = .white
        taskBadge.alignment = .center
        taskBadge.drawsBackground = true
        taskBadge.isHidden = true
        taskBadge.wantsLayer = true
        taskBadge.layer?.cornerRadius = 5
        taskBadge.layer?.masksToBounds = true
        chatGPTIconView.addSubview(taskBadge)
        NSLayoutConstraint.activate([
            taskBadge.trailingAnchor.constraint(equalTo: chatGPTIconView.trailingAnchor),
            taskBadge.bottomAnchor.constraint(equalTo: chatGPTIconView.bottomAnchor, constant: -1),
            taskBadge.widthAnchor.constraint(equalToConstant: 20),
            taskBadge.heightAnchor.constraint(equalToConstant: 11)
        ])

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
            fiveHourRow.widthAnchor.constraint(equalToConstant: 434),
            weeklyRow.widthAnchor.constraint(equalToConstant: 434),
            creditBalanceRow.widthAnchor.constraint(equalToConstant: 434),
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
    private let remainingLabel = NSTextField(labelWithString: "--")
    private let resetLabel = NSTextField(labelWithString: "Reset --")
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
        remainingLabel.stringValue = "\(meter.remainingText)"
        resetLabel.stringValue = meter.resetText
        usageLabel.stringValue = usageText
        updateCreditBalance(creditBalanceText)
    }

    func updateResetCredits(_ resetCredits: ResetCreditSummary, usageText: String) {
        titleLabel.stringValue = "Reset"
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
        remainingLabel.stringValue = "--"
        resetLabel.stringValue = "Reset --"
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
        let preferredResetWidth = resetLabel.widthAnchor.constraint(equalToConstant: 95)
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
            remainingLabel.widthAnchor.constraint(equalToConstant: 36),
            preferredResetWidth,
            resetLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            separatorLabel.widthAnchor.constraint(equalToConstant: 12),
            usageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
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
