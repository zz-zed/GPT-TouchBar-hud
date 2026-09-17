import AppKit

final class CompactHUDViewController: NSViewController, NSTouchBarDelegate {
    private enum TouchBarIdentifiers {
        static let touchBar = NSTouchBar.CustomizationIdentifier("io.github.zz-zed.GPTTouchBarHUD.compactHUD.touchBar")
        static let limits = NSTouchBarItem.Identifier("io.github.zz-zed.GPTTouchBarHUD.compactHUD.limits")
    }

    private let hudView: CompactQuotaHUDView
    private lazy var touchBarView = TouchBarRateLimitsView()
    private var currentState = RateLimitDisplayState.initial
    private let onRefresh: () -> Void
    private let onClose: () -> Void
    private let onPresentTouchBar: () -> Bool

    init(
        initialAppearance: HUDAppearance,
        onRefresh: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onPresentTouchBar: @escaping () -> Bool,
        contextMenuProvider: @escaping () -> NSMenu
    ) {
        self.onRefresh = onRefresh
        self.onClose = onClose
        self.onPresentTouchBar = onPresentTouchBar
        self.hudView = CompactQuotaHUDView(
            initialAppearance: initialAppearance,
            onRefresh: onRefresh,
            onClose: onClose,
            contextMenuProvider: contextMenuProvider
        )
        super.init(nibName: nil, bundle: nil)
        self.hudView.touchBarProvider = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = hudView
        view.frame = NSRect(x: 0, y: 0, width: 250, height: DesignTokens.hudHeight)
        update(with: currentState)
    }

    override func makeTouchBar() -> NSTouchBar? {
        makeQuotaTouchBar()
    }

    func makeQuotaTouchBar() -> NSTouchBar {
        let touchBar = NSTouchBar()
        touchBar.customizationIdentifier = TouchBarIdentifiers.touchBar
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [TouchBarIdentifiers.limits, .flexibleSpace]
        return touchBar
    }

    func activateTouchBar(bringAppForward: Bool = false) {
        if onPresentTouchBar() { return }
        hudView.activateTouchBar(bringAppForward: bringAppForward)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case TouchBarIdentifiers.limits:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = touchBarView
            touchBarView.observeVisibility(of: item)
            return item
        default:
            return nil
        }
    }

    func update(with state: RateLimitDisplayState) {
        currentState = state

        guard isViewLoaded else {
            return
        }

        hudView.update(with: state)
        touchBarView.update(with: state)
    }

    func updateAppearance(_ appearance: HUDAppearance) {
        hudView.updateAppearance(appearance)
    }

    @objc private func closeClicked() {
        onClose()
    }
}

final class CompactQuotaHUDView: NSView {
    weak var touchBarProvider: CompactHUDViewController?

    private let firstItem = CompactQuotaItemView()
    private let taskLabel = NSTextField(labelWithString: "")
    private let secondItem = CompactQuotaItemView()
    private let refreshButton = CompactIconButton(
        symbolName: "arrow.clockwise",
        accessibilityLabel: "刷新额度"
    )
    private let onRefresh: () -> Void
    private let onClose: () -> Void
    private let contextMenuProvider: () -> NSMenu
    private var hudAppearance: HUDAppearance
    private var widthConstraint: NSLayoutConstraint?
    private var contentStack: NSStackView?
    private var accessibilityObserver: NSObjectProtocol?

    init(
        initialAppearance: HUDAppearance,
        onRefresh: @escaping () -> Void,
        onClose: @escaping () -> Void,
        contextMenuProvider: @escaping () -> NSMenu
    ) {
        self.onRefresh = onRefresh
        self.onClose = onClose
        self.contextMenuProvider = contextMenuProvider
        self.hudAppearance = initialAppearance
        super.init(frame: .zero)
        configure()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.updateAppearance(self.hudAppearance)
        }
        updateAppearance(initialAppearance)
    }

    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        touchBarProvider?.activateTouchBar(bringAppForward: true)
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider()
    }

    override func makeTouchBar() -> NSTouchBar? {
        touchBarProvider?.makeQuotaTouchBar()
    }

    func activateTouchBar(bringAppForward: Bool = false) {
        if bringAppForward {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }

        touchBar = nil
        touchBar = makeTouchBar()
        window?.makeFirstResponder(nil)
        window?.makeFirstResponder(self)
    }

    func update(with state: RateLimitDisplayState) {
        refreshButton.isEnabled = !state.isRefreshing
        refreshButton.image = NSImage(systemSymbolName: state.isRefreshing ? "ellipsis" : (state.errorMessage == nil ? "arrow.clockwise" : "exclamationmark.arrow.circlepath"), accessibilityDescription: state.statusText)
        refreshButton.toolTip = state.statusText
        let taskStatus = state.displayedTaskStatus
        taskLabel.isHidden = taskStatus == nil
        taskLabel.stringValue = taskStatus?.label ?? ""
        taskLabel.toolTip = taskStatus?.detail
        taskLabel.textColor = taskStatus.map {
            TaskStatusAppearance($0).color ?? .lightGray
        } ?? .white
        let hasError = state.errorMessage != nil && state.fiveHour == nil && state.weekly == nil

        if let fiveHour = state.fiveHour {
            firstItem.update(with: fiveHour, title: "5h")
            if let weekly = state.weekly {
                secondItem.update(with: weekly, title: "7d")
                setMetricCount(2)
            } else {
                setMetricCount(1)
            }
        } else if let resetCredits = state.resetCredits, resetCredits.availableCount > 0 {
            firstItem.update(with: resetCredits)
            if let weekly = state.weekly {
                secondItem.update(with: weekly, title: "7d")
                setMetricCount(2)
            } else {
                setMetricCount(1)
            }
        } else if let weekly = state.weekly {
            firstItem.update(with: weekly, title: "7d")
            setMetricCount(1)
        } else {
            firstItem.updatePlaceholder(title: "5h", hasError: hasError)
            secondItem.updatePlaceholder(title: "7d", hasError: hasError)
            setMetricCount(2)
        }

        toolTip = state.statusText
    }

    func updateAppearance(_ appearance: HUDAppearance) {
        self.hudAppearance = appearance
        let solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer?.backgroundColor = (solid ? appearance.backgroundColor.withAlphaComponent(1) : appearance.backgroundColor).cgColor
        contentStack?.alphaValue = solid ? 1 : appearance.contentOpacity
        layer?.borderColor = NSColor.white.withAlphaComponent(solid ? 0.7 : 0.18).cgColor
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = hudAppearance.backgroundColor.cgColor
        layer?.cornerRadius = DesignTokens.hudHeight / 2
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false

        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)

        taskLabel.isHidden = true
        taskLabel.font = .systemFont(ofSize: 11, weight: .medium)
        taskLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [taskLabel, firstItem, secondItem, refreshButton])
        contentStack = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = DesignTokens.hudSpacing
        stack.alphaValue = hudAppearance.contentOpacity

        addSubview(stack)

        let widthConstraint = widthAnchor.constraint(equalToConstant: 250)
        self.widthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: DesignTokens.hudHeight),
            refreshButton.widthAnchor.constraint(equalToConstant: DesignTokens.buttonSize),
            refreshButton.heightAnchor.constraint(equalToConstant: DesignTokens.buttonSize),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.hudInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.hudInset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func setMetricCount(_ count: Int) {
        let showsSecondItem = count > 1
        secondItem.isHidden = !showsSecondItem

        let visibleItems = [taskLabel, firstItem, secondItem, refreshButton].filter { !$0.isHidden }
        let targetWidth = ceil(visibleItems.reduce(CGFloat(0)) { $0 + $1.fittingSize.width }
            + CGFloat(max(0, visibleItems.count - 1)) * DesignTokens.hudSpacing + DesignTokens.hudInset * 2)
        guard widthConstraint?.constant != targetWidth else {
            return
        }

        widthConstraint?.constant = targetWidth

        guard let window, window is CompactHUDPanel else {
            frame.size.width = targetWidth
            return
        }

        let previousMidX = window.frame.midX
        window.setContentSize(NSSize(width: targetWidth, height: DesignTokens.hudHeight))
        var origin = window.frame.origin
        origin.x = previousMidX - window.frame.width / 2
        window.setFrameOrigin(origin)
    }

    @objc private func refreshClicked() {
        onRefresh()
    }

    @objc private func closeClicked() {
        onClose()
    }
}

private final class CompactQuotaItemView: NSView {
    private let dotView = CompactStatusDotView()
    private let label = NSTextField(labelWithString: "-- --")

    init() {
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with meter: LimitMeter, title: String) {
        let remaining = Int(meter.remainingPercent.rounded())
        label.stringValue = "\(title) \(remaining)%"
        label.textColor = .white
        dotView.color = color(for: remaining)
    }

    func update(with resetCredits: ResetCreditSummary) {
        label.stringValue = resetCredits.compactText
        label.textColor = .white
        dotView.color = .systemTeal
    }

    func updatePlaceholder(title: String, hasError: Bool) {
        label.stringValue = "\(title) --"
        label.textColor = NSColor.white.withAlphaComponent(0.62)
        dotView.color = hasError ? NSColor.systemRed : NSColor.white.withAlphaComponent(0.28)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [dotView, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6

        addSubview(stack)

        NSLayoutConstraint.activate([
            dotView.widthAnchor.constraint(equalToConstant: 8),
            dotView.heightAnchor.constraint(equalToConstant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func color(for remaining: Int) -> NSColor {
        if remaining <= 20 {
            return NSColor.systemRed
        }
        if remaining <= 45 {
            return NSColor.systemYellow
        }
        return DesignTokens.accent
    }
}

private final class CompactIconButton: NSButton {
    init(symbolName: String, accessibilityLabel: String) {
        super.init(frame: .zero)

        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        contentTintColor = NSColor.white.withAlphaComponent(0.88)
        toolTip = accessibilityLabel
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class CompactStatusDotView: NSView {
    var color = NSColor.systemGreen {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }
}
