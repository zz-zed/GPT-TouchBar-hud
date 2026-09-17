import AppKit
import QuartzCore

final class TouchBarRateLimitsView: NSView {
    static var contentWidth: CGFloat { DisplayLanguage.current == .english ? 460 : 600 }
    private let chatGPTIconView = NSImageView()
    private let taskBadge = NSTextField(labelWithString: "")
    private var hasRunningTasks = false
    private var itemVisibility: Bool?
    private var itemVisibilityObservation: NSKeyValueObservation?
    private var windowObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private static let breathingAnimationKey = "taskBadgeBreathing"
    private var widthConstraint: NSLayoutConstraint!
    private let rowViews = [BalancedRowView(), BalancedRowView()]
    private let usageLabels = [BalancedRowView.label(), BalancedRowView.label()]
    private let balanceTitle = BalancedRowView.label()
    private let balanceValue = BalancedRowView.label()
    private let usageDivider = NSBox()
    private let balanceDivider = NSBox()

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
        let status = state.displayedTaskStatus
        taskBadge.stringValue = status?.badge ?? ""
        taskBadge.isHidden = status == nil
        taskBadge.backgroundColor = TaskStatusAppearance(status).color ?? .clear
        hasRunningTasks = (status?.runningCount ?? 0) > 0
        chatGPTIconView.setAccessibilityLabel(status?.label ?? "ChatGPT")
        chatGPTIconView.toolTip = status?.detail ?? "ChatGPT"
        updateTaskAnimation()

        var rows: [(String, String, String, Double?)] = []
        func add(_ meter: LimitMeter, _ title: String) {
            let date = meter.resetText.replacingOccurrences(of: " 重置", with: "")
            rows.append((title, meter.remainingText + (state.errorMessage == nil ? "" : "*"), date, meter.remainingPercent))
        }
        if let five = state.fiveHour { add(five, DisplayLanguage.text("5 小时", "5h")) }
        else if let credits = state.resetCredits, credits.availableCount > 0 {
            rows.append((DisplayLanguage.text("重置卡", "Reset"), DisplayLanguage.text("\(credits.availableCount) 次", "\(credits.availableCount) left"), credits.expirationText.replacingOccurrences(of: " 到期", with: "").replacingOccurrences(of: "到期 ", with: ""), nil))
        }
        if let week = state.weekly { add(week, DisplayLanguage.text("周限额", "Week")) }
        if rows.isEmpty && state.lastUpdated == nil {
            rows = [("5h", "--", DisplayLanguage.text("重置 --", "Reset --"), 0), ("7d", "--", DisplayLanguage.text("重置 --", "Reset --"), 0)]
        }
        for index in rowViews.indices {
            let row = rowViews[index]
            row.isHidden = index >= rows.count
            if index < rows.count {
                let data = rows[index]
                row.update(title: data.0, value: data.1, date: data.2, percent: data.3)
                row.toolTip = state.statusText
                if index == 0, state.fiveHour == nil, let credits = state.resetCredits {
                    row.date.toolTip = credits.expirationText
                } else {
                    row.date.toolTip = data.2
                }
            }
        }
        usageLabels[0].stringValue = state.tokenUsage?.yesterdayText ?? DisplayLanguage.text("昨日 --", "Yday --")
        usageLabels[1].stringValue = state.tokenUsage?.cumulativeText ?? DisplayLanguage.text("累计 --", "Total --")
        usageLabels.forEach { $0.toolTip = state.tokenUsage?.toolTip }
        balanceTitle.stringValue = DisplayLanguage.text("点数", "Credits")
        balanceValue.stringValue = state.creditBalance?.displayText.replacingOccurrences(of: "还剩点数：", with: "") ?? ""
        let hasBalance = state.creditBalance != nil
        balanceTitle.isHidden = !hasBalance
        balanceValue.isHidden = !hasBalance
        balanceDivider.isHidden = !hasBalance
        balanceValue.toolTip = state.creditBalance?.displayText

        // Columns fit their visible content; both quota rows share the same widths.
        let visible = rowViews.filter { !$0.isHidden }
        let titleWidth = ceil(visible.map { $0.title.fittingSize.width }.max() ?? 0)
        let valueWidth = ceil(visible.map { $0.value.fittingSize.width }.max() ?? 0)
        let dateWidth = ceil(visible.map { $0.date.fittingSize.width }.max() ?? 0)
        let rowWidth = titleWidth + DesignTokens.progressWidth + valueWidth + dateWidth + DesignTokens.spacing * 3
        let rowX: CGFloat = 30
        for (index, row) in rowViews.enumerated() where !row.isHidden {
            row.frame = NSRect(x: rowX, y: visible.count == 1 ? 8 : (index == 0 ? 16 : 2), width: rowWidth, height: 13)
            row.arrange(titleWidth: titleWidth, valueWidth: valueWidth, dateWidth: dateWidth)
        }
        let usageX = rowX + (visible.isEmpty ? 0 : rowWidth + 8)
        usageDivider.frame = NSRect(x: usageX - 4, y: 3, width: 1, height: 24)
        let usageWidth = ceil(usageLabels.map { $0.fittingSize.width }.max() ?? 0)
        for index in usageLabels.indices {
            usageLabels[index].frame = NSRect(x: usageX + 3, y: index == 0 ? 16 : 2, width: usageWidth, height: 13)
        }
        var total = usageX + 3 + usageWidth
        if hasBalance {
            balanceDivider.frame = NSRect(x: total + 6, y: 3, width: 1, height: 24)
            let balanceWidth = ceil(max(balanceTitle.fittingSize.width, balanceValue.fittingSize.width))
            balanceTitle.frame = NSRect(x: total + 12, y: 16, width: balanceWidth, height: 13)
            balanceValue.frame = NSRect(x: total + 12, y: 2, width: balanceWidth, height: 13)
            total += 12 + balanceWidth
        }
        widthConstraint.constant = ceil(total + 2)
        toolTip = state.statusText
        setAccessibilityLabel(([status?.label].compactMap { $0 } + rows.map { "\($0.0) \($0.1) \($0.2)" } + usageLabels.map(\.stringValue) + (hasBalance ? [balanceValue.stringValue] : [])).joined(separator: ", "))
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: Self.contentWidth)
        NSLayoutConstraint.activate([widthConstraint, heightAnchor.constraint(equalToConstant: DesignTokens.touchBarHeight)])
        chatGPTIconView.image = Self.chatGPTIcon()
        chatGPTIconView.imageScaling = .scaleProportionallyUpOrDown
        chatGPTIconView.frame = NSRect(x: 0, y: 0, width: 24, height: 30)
        addSubview(chatGPTIconView)
        taskBadge.font = .systemFont(ofSize: 8, weight: .bold)
        taskBadge.textColor = .white
        taskBadge.alignment = .center
        taskBadge.drawsBackground = true
        taskBadge.wantsLayer = true
        taskBadge.layer?.cornerRadius = 4
        taskBadge.layer?.masksToBounds = true
        taskBadge.frame = NSRect(x: 4, y: 0, width: 20, height: 11)
        chatGPTIconView.addSubview(taskBadge)
        rowViews.forEach { addSubview($0) }
        usageLabels.forEach { addSubview($0) }
        addSubview(balanceTitle)
        addSubview(balanceValue)
        for divider in [usageDivider, balanceDivider] { divider.boxType = .separator; addSubview(divider) }
        update(with: .initial)
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

private final class BalancedRowView: NSView {
    let title = label()
    let value = label()
    let date = label()
    private let progress = BalancedProgressView()
    private let credit = label()

    static func label() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        label.textColor = .white
        label.lineBreakMode = .byClipping
        return label
    }

    init() {
        super.init(frame: .zero)
        [title, value, date, progress, credit].forEach { addSubview($0) }
        title.textColor = .white
        date.textColor = .white
        credit.textColor = .white
        credit.font = .systemFont(ofSize: 10, weight: .bold)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(title: String, value: String, date: String, percent: Double?) {
        self.title.stringValue = title
        self.value.stringValue = value
        self.date.stringValue = date
        self.value.textColor = percent.map { $0 <= 20 ? .systemRed : .white } ?? .white
        progress.isHidden = percent == nil
        credit.isHidden = percent != nil
        credit.stringValue = DisplayLanguage.text("可用", "Ready")
        progress.percent = percent ?? 0
    }

    func arrange(titleWidth: CGFloat, valueWidth: CGFloat, dateWidth: CGFloat) {
        title.frame = NSRect(x: 0, y: 0, width: titleWidth, height: 13)
        let progressX = titleWidth + DesignTokens.spacing
        progress.frame = NSRect(x: progressX, y: 4, width: DesignTokens.progressWidth, height: 5)
        credit.frame = NSRect(x: progressX, y: 0, width: DesignTokens.progressWidth, height: 13)
        let valueX = progressX + DesignTokens.progressWidth + DesignTokens.spacing
        value.frame = NSRect(x: valueX, y: 0, width: valueWidth, height: 13)
        date.frame = NSRect(x: valueX + valueWidth + DesignTokens.spacing, y: 0, width: dateWidth, height: 13)
    }
}

private final class BalancedProgressView: NSView {
    var percent: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.darkGray.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        (percent <= 20 ? NSColor.systemRed : DesignTokens.accent).setFill()
        let width = bounds.width * max(0, min(100, percent)) / 100
        if width > 0 { NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: 2, yRadius: 2).fill() }
    }
}
