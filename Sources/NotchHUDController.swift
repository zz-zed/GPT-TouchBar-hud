import AppKit

private final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        title = "GPT HUD · 刘海融合"
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class NotchProgressView: NSView {
    var percent: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        DesignTokens.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * max(0, min(100, percent)) / 100, height: bounds.height), xRadius: 2, yRadius: 2).fill()
    }
}

/// A rectangular window only below the camera, with two rounded bottom corners.
/// Transparent corners are excluded from both view hit-testing and window mouse routing.
final class NotchHUDView: NSView {
    var onToggle: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onDesktop: (() -> Void)?
    var onCollapse: (() -> Void)?
    private(set) var state = RateLimitDisplayState.initial
    private(set) var expanded = false
    private let strip = NSButton(title: "", target: nil, action: nil)
    private let taskTitle = NSTextField(labelWithString: "")
    private let updateLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let secondary = NSTextField(labelWithString: "")
    private let points = NSTextField(labelWithString: "")
    private let refresh = NSButton(title: "", target: nil, action: nil)
    private let desktop = NSButton(title: "", target: nil, action: nil)
    private let settings = NSButton(title: "", target: nil, action: nil)
    private let collapseButton = NSButton(title: "", target: nil, action: nil)
    private var metricViews: [(NSTextField, NSTextField, NSTextField, NotchProgressView)] = []
    private var rows: [HUDMetric] = []
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for _ in 0..<2 {
            metricViews.append((NSTextField(labelWithString: ""), NSTextField(labelWithString: ""), NSTextField(labelWithString: ""), NotchProgressView()))
        }
        let labels = [taskTitle, updateLabel, errorLabel, emptyLabel, secondary, points] + metricViews.flatMap { [$0.0, $0.1, $0.2] }
        for label in labels {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = NSColor(calibratedWhite: 0.82, alpha: 1)
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        taskTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        taskTitle.textColor = .white
        errorLabel.textColor = .systemOrange
        for (title, value, date, progress) in metricViews {
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            title.textColor = .white
            value.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
            value.textColor = DesignTokens.accent
            value.alignment = .right
            date.alignment = .right
            addSubview(progress)
        }
        for (button, action) in [(strip, #selector(toggle)), (refresh, #selector(refreshClicked)), (desktop, #selector(desktopClicked)), (settings, #selector(settingsClicked)), (collapseButton, #selector(collapseClicked))] {
            button.target = self
            button.action = action
            button.isBordered = false
            button.font = .systemFont(ofSize: 11, weight: .semibold)
            button.contentTintColor = .white
            addSubview(button)
        }
        strip.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        strip.imagePosition = .imageLeft
        strip.imageScaling = .scaleProportionallyDown
        strip.setAccessibilityIdentifier("notch.summary")
        refresh.setAccessibilityIdentifier("notch.refresh")
        collapseButton.setAccessibilityIdentifier("notch.collapse")
        setAccessibilityLabel("GPT HUD")
        update(.initial, expanded: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var compactWidth: CGFloat {
        let text = " 9+  |  " + (rows.isEmpty ? "--" : rows.map(\.reservedCompact).joined(separator: "  |  ")) + " !"
        return ceil((text as NSString).size(withAttributes: [.font: strip.font!]).width) + 48
    }
    var preferredHeight: CGFloat {
        guard expanded else { return 30 }
        let headerHeight: CGFloat = 30 + 34
        let errorHeight: CGFloat = state.errorMessage == nil ? 0 : 25
        let metricsHeight: CGFloat = rows.isEmpty
            ? 38
            : rows.reduce(CGFloat(0)) { result, row in result + (row.percent == nil ? 57 : 67) }
        let tokenHeight: CGFloat = state.tokenUsage == nil ? 0 : 27
        let balanceHeight: CGFloat = state.creditBalance == nil ? 0 : 23
        let actionsHeight: CGFloat = 46
        return headerHeight + errorHeight + metricsHeight + tokenHeight + balanceHeight + actionsHeight
    }
    func update(_ state: RateLimitDisplayState, expanded: Bool) {
        self.state = state
        self.expanded = expanded
        rows = HUDMetric.rows(for: state)
        let task = state.displayedTaskStatus
        let values = rows.isEmpty ? "--" : rows.map(\.compact).joined(separator: "  |  ")
        strip.title = (task.map { " " + $0.badge + "  |  " } ?? " ") + values + (state.errorMessage == nil ? "" : " !")
        let appearance = TaskStatusAppearance(task)
        // One centered inline group: NSButton.imageLeft otherwise leaves the icon
        // at the far edge while centering the text independently in expanded mode.
        let title = NSMutableAttributedString()
        if let source = appearance.menuIcon() {
            let color = appearance.color ?? .white
            let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                source.draw(in: rect)
                color.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            let attachment = NSTextAttachment()
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: icon)
            let symbol = NSMutableAttributedString(attachment: attachment)
            symbol.addAttribute(.baselineOffset, value: -3, range: NSRange(location: 0, length: symbol.length))
            title.append(symbol)
        }
        title.append(NSAttributedString(string: strip.title, attributes: [.font: strip.font!, .foregroundColor: NSColor.white]))
        strip.attributedTitle = title
        strip.setAccessibilityLabel((task?.label ?? DisplayLanguage.text("额度概览", "Quota overview")) + "，" + values + (expanded ? "，收起详情" : "，展开详情"))
        strip.toolTip = state.statusText
        taskTitle.stringValue = task?.label ?? DisplayLanguage.text("额度概览", "Quota overview")
        taskTitle.toolTip = task?.detail
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        updateLabel.stringValue = state.isRefreshing ? DisplayLanguage.text("刷新中…", "Refreshing…")
            : state.lastUpdated.map { DisplayLanguage.text("上次 ", "Updated ") + formatter.string(from: $0) } ?? DisplayLanguage.text("尚未更新", "Not updated")
        updateLabel.alignment = .right
        errorLabel.stringValue = rows.isEmpty ? DisplayLanguage.text("连接异常 · 暂无额度数据", "Offline · no quota data") : DisplayLanguage.text("连接异常 · 以下为上次数据", "Offline · last known values")
        errorLabel.toolTip = state.errorMessage
        emptyLabel.stringValue = DisplayLanguage.text("暂无额度数据", "No quota data")
        if state.resetCredits?.availableCount == 0 {
            emptyLabel.stringValue += DisplayLanguage.text(" · 重置卡 0 张", " · 0 reset credits")
        }
        for (index, views) in metricViews.enumerated() {
            guard index < rows.count else { continue }
            let row = rows[index]
            views.0.stringValue = row.title
            views.1.stringValue = row.value
            views.2.stringValue = row.date
            views.2.toolTip = row.date
            views.3.percent = row.percent ?? 0
        }
        secondary.stringValue = state.tokenUsage.map { $0.yesterdayText + "  ·  " + $0.cumulativeText } ?? ""
        secondary.toolTip = state.tokenUsage?.toolTip
        points.stringValue = state.creditBalance.map { DisplayLanguage.current == .chinese ? $0.displayText : $0.displayText.replacingOccurrences(of: "还剩点数：", with: "Credits: ") } ?? ""
        points.toolTip = points.stringValue
        refresh.title = state.isRefreshing ? "…" : DisplayLanguage.text("刷新", "Refresh")
        refresh.attributedTitle = NSAttributedString(string: refresh.title, attributes: [.font: refresh.font!, .foregroundColor: NSColor.black])
        refresh.isEnabled = !state.isRefreshing
        desktop.title = DisplayLanguage.text("桌面", "Desktop")
        settings.title = DisplayLanguage.text("设置", "Settings")
        collapseButton.title = DisplayLanguage.text("收起", "Collapse")
        needsLayout = true
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        subviews.forEach { $0.isHidden = true }
        strip.isHidden = false
        strip.frame = NSRect(x: 8, y: 0, width: max(0, bounds.width - 16), height: 30)
        guard expanded else { return }
        let width = bounds.width - 32
        func place(_ view: NSView, _ y: CGFloat, _ height: CGFloat, x: CGFloat = 16, w: CGFloat? = nil) {
            view.isHidden = false
            view.frame = NSRect(x: x, y: y, width: w ?? width, height: height)
        }
        place(taskTitle, 38, 18, w: width * 0.55)
        place(updateLabel, 39, 17, x: 16 + width * 0.55, w: width * 0.45)
        var y: CGFloat = 64
        if state.errorMessage != nil { place(errorLabel, y, 19); y += 25 }
        if rows.isEmpty { place(emptyLabel, y, 20); y += 38 }
        for (index, row) in rows.enumerated() {
            let views = metricViews[index]
            place(views.0, y + 3, 19, w: width * 0.58)
            place(views.1, y, 25, x: 16 + width * 0.58, w: width * 0.42)
            if row.percent != nil { place(views.3, y + 29, 3) }
            place(views.2, y + (row.percent == nil ? 29 : 39), 18)
            y += row.percent == nil ? 57 : 67
        }
        if state.tokenUsage != nil { place(secondary, y + 3, 19); y += 27 }
        if state.creditBalance != nil { place(points, y + 2, 18); y += 23 }
        let buttons = [refresh, desktop, settings, collapseButton]
        let buttonWidth = (width - 18) / 4
        for (index, button) in buttons.enumerated() { place(button, y + 6, 28, x: 16 + CGFloat(index) * (buttonWidth + 6), w: buttonWidth) }
    }
    func surfacePath() -> NSBezierPath {
        let r: CGFloat = min(expanded ? 22 : 15, bounds.height / 2)
        let path = NSBezierPath()
        path.move(to: .zero)
        path.line(to: NSPoint(x: bounds.width, y: 0))
        path.line(to: NSPoint(x: bounds.width, y: bounds.height - r))
        path.curve(to: NSPoint(x: bounds.width - r, y: bounds.height), controlPoint1: NSPoint(x: bounds.width, y: bounds.height), controlPoint2: NSPoint(x: bounds.width, y: bounds.height))
        path.line(to: NSPoint(x: r, y: bounds.height))
        path.curve(to: NSPoint(x: 0, y: bounds.height - r), controlPoint1: NSPoint(x: 0, y: bounds.height), controlPoint2: NSPoint(x: 0, y: bounds.height))
        path.close()
        return path
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        surfacePath().fill()
        guard expanded else { return }
        for button in [refresh, desktop, settings, collapseButton] where !button.isHidden {
            (button === refresh ? DesignTokens.accent : NSColor(calibratedRed: 0.09, green: 0.15, blue: 0.12, alpha: 1)).setFill()
            NSBezierPath(roundedRect: button.frame, xRadius: 6, yRadius: 6).fill()
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard surfacePath().contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
    @objc private func toggle() { onToggle?() }
    @objc private func refreshClicked() { onRefresh?() }
    @objc private func desktopClicked() { onDesktop?() }
    @objc private func settingsClicked() { onSettings?() }
    @objc private func collapseClicked() { onCollapse?() }
}

final class NotchHUDController: NSObject {
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onDesktop: (() -> Void)?
    let panel: NSPanel = NotchPanel()
    let view = NotchHUDView(frame: .zero)
    private var geometry: NotchHUDGeometry?
    private var state = RateLimitDisplayState.initial
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private(set) var isVisible = false
    private(set) var isExpanded = false

    override init() {
        super.init()
        panel.contentView = view
        view.onToggle = { [weak self] in self?.toggleExpanded() }
        view.onCollapse = { [weak self] in self?.collapse() }
        view.onRefresh = { [weak self] in self?.onRefresh?() }
        view.onSettings = { [weak self] in self?.collapse(); self?.onSettings?() }
        view.onDesktop = { [weak self] in self?.collapse(); self?.onDesktop?() }
    }
    @discardableResult
    func show(in geometry: NotchHUDGeometry? = NotchHUDGeometry.current()) -> Bool {
        guard let geometry else { hide(); return false }
        self.geometry = geometry
        isVisible = true
        relayout()
        panel.orderFrontRegardless()
        installEventMonitors()
        updateMouseRouting()
        return true
    }
    func hide() {
        isVisible = false
        isExpanded = false
        geometry = nil
        panel.orderOut(nil)
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
    func update(_ state: RateLimitDisplayState) {
        self.state = state
        relayout()
    }
    func toggleExpanded() {
        guard isVisible else { return }
        isExpanded.toggle()
        relayout()
    }
    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        relayout()
    }
    private func relayout() {
        view.update(state, expanded: isExpanded)
        guard let geometry else { return }
        // Fixed top and center. Never animate the whole window (which would move the attachment).
        let frame = geometry.frame(width: isExpanded ? max(380, view.compactWidth) : view.compactWidth, height: view.preferredHeight)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        view.layoutSubtreeIfNeeded()
        updateMouseRouting()
    }
    private func contains(_ point: NSPoint) -> Bool {
        let local = view.convert(panel.convertPoint(fromScreen: point), from: nil)
        return view.surfacePath().contains(local)
    }
    private func updateMouseRouting() {
        guard isVisible else { return }
        panel.ignoresMouseEvents = !contains(NSEvent.mouseLocation)
    }
    private func installEventMonitors() {
        guard globalMonitor == nil else { return }
        // Mouse-only monitoring needs no keyboard monitoring/accessibility permission.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }
            self.updateMouseRouting()
            if (event.type == .leftMouseDown || event.type == .rightMouseDown) && !self.contains(NSEvent.mouseLocation) { self.collapse() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            self.updateMouseRouting()
            if event.type == .keyDown {
                if event.keyCode == 53 && self.isExpanded { self.collapse(); return nil }
            } else if (event.type == .leftMouseDown || event.type == .rightMouseDown) && !self.contains(NSEvent.mouseLocation) { self.collapse() }
            return event
        }
    }
    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
