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
    var onOpenMessages: (() -> Void)? {
        didSet { hudView.onOpenMessages = onOpenMessages; touchBarView.onOpenMessages = onOpenTouchBarMessages ?? onOpenMessages }
    }
    var onOpenTouchBarMessages: (() -> Void)? {
        didSet { touchBarView.onOpenMessages = onOpenTouchBarMessages ?? onOpenMessages }
    }
    private var messageForecastCount: Int?
    private var messagesAvailable = false
    var messageAnchorView: NSView { hudView.messageAnchorView }

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
        updateMessages(forecastCount: messageForecastCount, available: messagesAvailable)
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
            TaskPresentationTrace.record(state, surface: .floatingHUD, action: .notLoaded)
            return
        }

        // The controller also owns the responder-chain Touch Bar. Its updates
        // must continue independently of the floating window's visibility.
        if hudView.window?.isVisible != false { hudView.update(with: state) }
        else { TaskPresentationTrace.record(state, surface: .floatingHUD, action: .hidden) }
        touchBarView.update(with: state)
    }

    func prepareToShow() {
        _ = view
        hudView.update(with: currentState)
        hudView.updateMessages(forecastCount: messageForecastCount, available: messagesAvailable)
    }

    func updateAppearance(_ appearance: HUDAppearance) {
        hudView.updateAppearance(appearance)
    }
    func updateMessages(forecastCount: Int?, available: Bool) {
        messageForecastCount = forecastCount
        messagesAvailable = available
        if hudView.window?.isVisible != false {
            hudView.updateMessages(forecastCount: forecastCount, available: available)
        }
        touchBarView.updateMessages(forecastCount: forecastCount, available: available)
    }

    @objc private func closeClicked() {
        onClose()
    }
}

final class CompactQuotaHUDView: NSView {
    private struct Content: Equatable {
        let fivePercent: Int?
        let weeklyPercent: Int?
        let credits: String?
        let refreshing: Bool
        let hasError: Bool
        let task: String?
        let appearance: TaskStatusAppearance
        let language: DisplayLanguage
    }
    private var renderedContent: Content?
    private var forecastLanguage: DisplayLanguage?
    private(set) var layoutUpdateCount = 0
    weak var touchBarProvider: CompactHUDViewController?

    private let firstItem = CompactQuotaItemView()
    private let taskLabel = NSTextField(labelWithString: "")
    private let messagesButton = CompactHUDActionButton(title: "", target: nil, action: nil)
    var messageAnchorView: NSView { messagesButton }
    var onOpenMessages: (() -> Void)?
    private var forecastCount: Int?
    private var metricCount = 2
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
    private var contentContainer = NSView()
    private var contentConstraints: [NSLayoutConstraint] = []
    private var glassView: NSView?
    private var surfaceConstraints: [NSLayoutConstraint] = []
    private(set) var surface: HUDAppearance.Surface = .classic
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
        TaskPresentationTrace.record(state, surface: .floatingHUD, action: .renderRequested)
        let taskStatus = state.displayedTaskStatus
        toolTip = state.statusText
        taskLabel.toolTip = taskStatus?.detail
        let next = Content(fivePercent: state.fiveHour.map { Int($0.remainingPercent.rounded()) },
                           weeklyPercent: state.weekly.map { Int($0.remainingPercent.rounded()) },
                           credits: state.resetCredits.flatMap { $0.availableCount > 0 ? $0.compactText : nil },
                           refreshing: state.isRefreshing, hasError: state.errorMessage != nil,
                           task: taskStatus?.label, appearance: TaskStatusAppearance(taskStatus),
                           language: DisplayLanguage.current)
        guard next != renderedContent else { return }
        renderedContent = next
        layoutUpdateCount += 1
        refreshButton.isEnabled = !state.isRefreshing
        refreshButton.image = NSImage(systemSymbolName: state.isRefreshing ? "ellipsis" : (state.errorMessage == nil ? "arrow.clockwise" : "exclamationmark.arrow.circlepath"), accessibilityDescription: state.statusText)
        let refreshLabel = DisplayLanguage.text("刷新额度", "Refresh quotas")
        refreshButton.toolTip = refreshLabel
        refreshButton.setAccessibilityLabel(refreshLabel)
        updateForecastPresentation()
        taskLabel.isHidden = taskStatus == nil
        taskLabel.stringValue = taskStatus?.label ?? ""
        taskLabel.toolTip = taskStatus?.detail
        updateTaskColor()
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
        let next = HUDAppearance.surface(for: appearance.material,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        if next != surface {
            surface = next
            installSurface()
        }
        updateBackground(solid: solid)
        contentStack?.alphaValue = next == .classic && !solid ? appearance.contentOpacity : 1
        firstItem.usesSemanticColors = next != .classic
        secondItem.usesSemanticColors = next != .classic
        refreshButton.usesSemanticColors = next != .classic
        messagesButton.usesSemanticColors = next != .classic
        refreshButton.contentTintColor = next == .classic ? NSColor.white.withAlphaComponent(0.88) : .labelColor
        updateTaskColor()
        updateForecastPresentation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground(solid: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }

    private func updateBackground(solid: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background: NSColor
            switch surface {
            case .glass: background = .clear
            case .solidSystem: background = .windowBackgroundColor
            case .classic: background = solid ? hudAppearance.backgroundColor.withAlphaComponent(1) : hudAppearance.backgroundColor
            }
            layer?.backgroundColor = background.cgColor
            layer?.borderWidth = surface == .glass ? 0 : 0.5
            layer?.borderColor = (surface == .solidSystem ? NSColor.labelColor.withAlphaComponent(0.7)
                : NSColor.white.withAlphaComponent(solid ? 0.7 : 0.18)).cgColor
        }
    }

    private func installSurface() {
        // All foreground content belongs to contentView so AppKit can adapt its
        // appearance to the glass. Keep the same controls and responder identities.
        NSLayoutConstraint.deactivate(surfaceConstraints + contentConstraints)
        surfaceConstraints = []
        contentConstraints = []
        contentStack?.removeFromSuperview()
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            glass.contentView = nil
        }
        #endif
        contentContainer.removeFromSuperview()
        glassView?.removeFromSuperview()
        glassView = nil
        // AppKit owns the glass content wrapper's layout. Recreate that wrapper
        // on a material change while retaining the stack and all of its controls.
        contentContainer = NSView(frame: bounds)
        if let stack = contentStack {
            contentContainer.addSubview(stack)
            contentConstraints = [stack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: DesignTokens.hudInset),
                stack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -DesignTokens.hudInset),
                stack.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor)]
            NSLayoutConstraint.activate(contentConstraints)
        }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), surface == .glass {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = DesignTokens.hudHeight / 2
            contentContainer.translatesAutoresizingMaskIntoConstraints = true
            contentContainer.autoresizingMask = [.width, .height]
            contentContainer.frame = glass.bounds
            glass.contentView = contentContainer
            addSubview(glass)
            pinSurface(glass)
            glassView = glass
            return
        }
        #endif
        addSubview(contentContainer)
        pinSurface(contentContainer)
    }

    private func pinSurface(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        surfaceConstraints = [view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)]
        NSLayoutConstraint.activate(surfaceConstraints)
    }

    private func updateTaskColor() {
        taskLabel.textColor = surface == .classic ? (renderedContent?.appearance.color ?? .lightGray) : .labelColor
    }

    func updateMessages(forecastCount: Int?, available: Bool) {
        let count = forecastCount.map { max(0, $0) }
        guard self.forecastCount != count || messagesButton.isHidden != !available ||
                forecastLanguage != DisplayLanguage.current else { return }
        self.forecastCount = count
        forecastLanguage = DisplayLanguage.current
        messagesButton.isHidden = !available
        updateForecastPresentation()
        setMetricCount(metricCount)
    }

    private func updateForecastPresentation() {
        let count = ResetForecastIndicator.countText(forecastCount)
        messagesButton.title = DisplayLanguage.text("重置预告 \(count)", "Reset forecasts \(count)")
        messagesButton.contentTintColor = surface == .classic
            ? ((forecastCount ?? 0) > 0 ? DesignTokens.accent : NSColor.white.withAlphaComponent(0.84))
            : .labelColor
        let accessibilityLabel = ResetForecastIndicator.accessibilityLabel(forecastCount)
        messagesButton.toolTip = accessibilityLabel
        messagesButton.setAccessibilityLabel(accessibilityLabel)
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
        refreshButton.setAccessibilityIdentifier("hud.refresh")
        messagesButton.image = ResetForecastIndicator.image()
        messagesButton.imagePosition = .imageLeft
        messagesButton.imageScaling = .scaleProportionallyDown
        messagesButton.isBordered = false
        messagesButton.contentTintColor = NSColor.white.withAlphaComponent(0.84)
        messagesButton.font = .systemFont(ofSize: 10, weight: .medium)
        messagesButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        messagesButton.target = self
        messagesButton.action = #selector(messagesClicked)
        messagesButton.isHidden = true
        messagesButton.setAccessibilityIdentifier("hud.messages")

        taskLabel.isHidden = true
        taskLabel.font = .systemFont(ofSize: 11, weight: .medium)
        taskLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [taskLabel, firstItem, secondItem, refreshButton, messagesButton])
        contentStack = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = DesignTokens.hudSpacing
        stack.alphaValue = hudAppearance.contentOpacity

        let widthConstraint = widthAnchor.constraint(equalToConstant: 250)
        self.widthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: DesignTokens.hudHeight),
            refreshButton.widthAnchor.constraint(equalToConstant: DesignTokens.buttonSize),
            refreshButton.heightAnchor.constraint(equalToConstant: DesignTokens.buttonSize)
        ])
        installSurface()
    }

    private func setMetricCount(_ count: Int) {
        metricCount = count
        let showsSecondItem = count > 1
        secondItem.isHidden = !showsSecondItem

        let visibleItems = [taskLabel, firstItem, secondItem, refreshButton, messagesButton].filter { !$0.isHidden }
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
        (window as? CompactHUDPanel)?.recoverPositionIfOffscreen()
    }

    @objc private func refreshClicked() {
        onRefresh()
    }
    @objc private func messagesClicked() { onOpenMessages?() }

    @objc private func closeClicked() {
        onClose()
    }
}

private final class CompactQuotaItemView: NSView {
    private let dotView = CompactStatusDotView()
    private let label = NSTextField(labelWithString: "-- --")
    private var isPlaceholder = true
    private var placeholderHasError = false
    var usesSemanticColors = false { didSet { updateColors() } }

    private func updateColors() {
        label.textColor = usesSemanticColors ? (isPlaceholder ? .secondaryLabelColor : .labelColor)
            : NSColor.white.withAlphaComponent(isPlaceholder ? 0.62 : 1)
        if isPlaceholder {
            dotView.color = placeholderHasError ? .systemRed
                : (usesSemanticColors ? .tertiaryLabelColor : NSColor.white.withAlphaComponent(0.28))
        }
    }

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
        isPlaceholder = false
        updateColors()
        dotView.color = color(for: remaining)
    }

    func update(with resetCredits: ResetCreditSummary) {
        label.stringValue = resetCredits.compactText
        isPlaceholder = false
        updateColors()
        dotView.color = .systemTeal
    }

    func updatePlaceholder(title: String, hasError: Bool) {
        label.stringValue = "\(title) --"
        isPlaceholder = true
        placeholderHasError = hasError
        updateColors()
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

private class CompactHUDActionButton: NSButton {
    var usesSemanticColors = false { didSet { updateHighlight() } }
    private var tracking: NSTrackingArea?
    private var hovering = false
    private var pressing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; updateHighlight() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateHighlight() }
    override func highlight(_ flag: Bool) { super.highlight(flag); pressing = flag; updateHighlight() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateHighlight() }
    private func updateHighlight() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (usesSemanticColors ? NSColor.labelColor : .white)
                .withAlphaComponent(isEnabled ? (pressing ? 0.16 : (hovering ? 0.08 : 0)) : 0).cgColor
        }
    }
}

private final class CompactIconButton: CompactHUDActionButton {
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
