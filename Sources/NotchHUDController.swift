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
        // Apple documents fullScreenPrimary as the opt-out from other apps' full-screen Spaces.
        // This borderless, nonresizable panel never offers its own full-screen action.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary, .fullScreenDisallowsTiling, .stationary, .ignoresCycle]
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

final class NotchDetailContent: NSView {
    override var isFlipped: Bool { true }
    var separatorY: CGFloat? { didSet { needsDisplay = true } }
    var separatorAlpha: CGFloat = 1
    override func draw(_ dirtyRect: NSRect) {
        guard let y = separatorY else { return }
        NSColor(calibratedWhite: 0.16, alpha: separatorAlpha).setFill()
        NSRect(x: 8, y: y, width: bounds.width - 16, height: 0.5).fill()
    }
}

/// One below-camera surface. The scroll viewport stays inside its rounded edges.
/// Transparent corners are excluded from both view hit-testing and window mouse routing.
final class NotchHUDView: NSView {
    var onToggle: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onHide: (() -> Void)?
    var onCollapse: (() -> Void)?
    private(set) var state = RateLimitDisplayState.initial
    private(set) var expanded = false
    let detailContent = NotchDetailContent(frame: .zero)
    let detailScroll = NSScrollView(frame: .zero)
    private let strip = NSButton(title: "", target: nil, action: nil)
    private let taskTitle = NSTextField(labelWithString: "")
    private let updateLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let secondary = NSTextField(labelWithString: "")
    private let points = NSTextField(labelWithString: "")
    private let taskNote = NSTextField(labelWithString: "")
    var notchWidth: CGFloat = 0
    var detailsAlpha: CGFloat = 1 { didSet { needsLayout = true; needsDisplay = true } }
    var detailsReady = true { didSet { needsLayout = true } }
    private(set) var summaryText = ""
    private let refresh = NSButton(title: "", target: nil, action: nil)
    private let hideButton = NSButton(title: "", target: nil, action: nil)
    private let settings = NSButton(title: "", target: nil, action: nil)
    private let collapseButton = NSButton(title: "", target: nil, action: nil)
    private var metricViews: [(NSTextField, NSTextField, NSTextField, NotchProgressView)] = []
    private var rows: [HUDMetric] = []
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        detailScroll.drawsBackground = false
        detailScroll.borderType = .noBorder
        detailScroll.scrollerStyle = .overlay
        detailScroll.autohidesScrollers = true
        detailScroll.documentView = detailContent
        addSubview(detailScroll)
        for _ in 0..<2 {
            metricViews.append((NSTextField(labelWithString: ""), NSTextField(labelWithString: ""), NSTextField(labelWithString: ""), NotchProgressView()))
        }
        let labels = [taskTitle, updateLabel, errorLabel, emptyLabel, secondary, points, taskNote] + metricViews.flatMap { [$0.0, $0.1, $0.2] }
        for label in labels {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = NSColor(calibratedWhite: 0.82, alpha: 1)
            label.lineBreakMode = .byWordWrapping
            label.cell?.wraps = true
            label.cell?.usesSingleLineMode = false
            label.cell?.isScrollable = false
            label.maximumNumberOfLines = 0
            detailContent.addSubview(label)
        }
        taskTitle.font = .systemFont(ofSize: 11, weight: .medium)
        for label in [updateLabel, secondary, points] { label.font = .systemFont(ofSize: 10) }
        taskNote.textColor = .systemOrange
        taskTitle.textColor = .white
        errorLabel.textColor = .systemOrange
        for (title, value, date, progress) in metricViews {
            title.font = .systemFont(ofSize: 11, weight: .medium)
            title.textColor = .white
            value.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
            value.textColor = DesignTokens.accent
            value.alignment = .right
            date.font = .systemFont(ofSize: 10)
            date.alignment = .left
            detailContent.addSubview(progress)
        }
        for (button, action) in [(strip, #selector(toggle)), (refresh, #selector(refreshClicked)), (hideButton, #selector(hideClicked)), (settings, #selector(settingsClicked)), (collapseButton, #selector(collapseClicked))] {
            button.target = self
            button.action = action
            button.isBordered = false
            button.font = .systemFont(ofSize: 11, weight: .semibold)
            button.contentTintColor = .lightGray
            if button === strip { addSubview(button) } else { detailContent.addSubview(button) }
        }
        strip.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        strip.cell?.wraps = true
        strip.cell?.usesSingleLineMode = false
        strip.cell?.lineBreakMode = .byWordWrapping
        strip.imagePosition = .imageLeft
        strip.imageScaling = .scaleProportionallyDown
        strip.setAccessibilityIdentifier("notch.summary")
        refresh.setAccessibilityIdentifier("notch.refresh")
        hideButton.setAccessibilityIdentifier("notch.hide")
        settings.setAccessibilityIdentifier("notch.settings")
        collapseButton.setAccessibilityIdentifier("notch.collapse")
        setAccessibilityLabel("GPT HUD")
        update(.initial, expanded: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var compactWidth: CGFloat { ceil(strip.attributedTitle.size().width) + 26 }
    var preferredHeight: CGFloat { preferredHeight(width: max(340, compactWidth)) }
    func preferredHeight(width: CGFloat) -> CGFloat {
        expanded ? layoutDetails(width: width, apply: false) : summaryHeight(width: width)
    }
    private func summaryHeight(width: CGFloat) -> CGFloat {
        guard compactWidth > width else { return 24 }
        let rect = strip.attributedTitle.boundingRect(with: NSSize(width: max(1, width - 26), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(24, ceil(rect.height) + 6)
    }
    func update(_ state: RateLimitDisplayState, expanded: Bool, taskDisplayEnabled: Bool = true, abbreviateLabels: Bool = false) {
        self.state = state
        self.expanded = expanded
        rows = HUDMetric.rows(for: state)
        let task = NotchTaskPresentation(state.taskStatus, enabled: taskDisplayEnabled)
        let values = rows.isEmpty ? DisplayLanguage.text("额度 —", "Quota —") : rows.map(\.compact).joined(separator: "  ")
        summaryText = (taskDisplayEnabled ? task.badge + "  " : "") + values + (state.errorMessage == nil ? "" : " !")
        // One attributed group is both rendered and measured: no phantom digits or separators.
        let title = NSMutableAttributedString()
        if taskDisplayEnabled, let source = task.appearance.menuIcon() {
            let color = task.appearance.color ?? .white
            let icon = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
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
        func append(_ text: String, font: NSFont, color: NSColor) {
            title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        if taskDisplayEnabled { append(" " + task.badge, font: strip.font!, color: task.appearance.color ?? .white) }
        if rows.isEmpty {
            append((title.length > 0 ? "  " : "") + values, font: strip.font!, color: .white)
        } else {
            for row in rows {
                append((title.length > 0 ? "   " : "") + (abbreviateLabels && row.percent == nil ? DisplayLanguage.text("卡", "R") : row.compactTitle) + " ", font: .systemFont(ofSize: 10), color: .lightGray)
                append(row.value, font: strip.font!, color: DesignTokens.accent)
            }
        }
        if state.errorMessage != nil { append("  !", font: strip.font!, color: .systemOrange) }
        strip.attributedTitle = title
        strip.setAccessibilityLabel(task.title + "，" + values + DisplayLanguage.text(expanded ? "，收起详情" : "，展开详情", expanded ? ", Collapse details" : ", Expand details"))
        strip.toolTip = task.note ?? state.taskStatus?.detail ?? task.title
        taskTitle.stringValue = task.title
        taskTitle.toolTip = state.taskStatus?.detail
        taskNote.stringValue = task.note ?? ""
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
        refresh.attributedTitle = NSAttributedString(string: refresh.title, attributes: [.font: refresh.font!, .foregroundColor: DesignTokens.accent])
        refresh.isEnabled = !state.isRefreshing
        hideButton.title = DisplayLanguage.text("隐藏", "Hide")
        settings.title = DisplayLanguage.text("设置", "Settings")
        collapseButton.title = DisplayLanguage.text("收起", "Collapse")
        needsLayout = true
        needsDisplay = true
    }
    /// Same measurement pass supplies natural height and frames; wrapping is never tail truncation.
    private func textHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        let rect = (label.stringValue as NSString).boundingRect(
            with: NSSize(width: max(1, width - 4), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: label.font!])
        return ceil(rect.height) + 2
    }
    @discardableResult
    private func layoutDetails(width panelWidth: CGFloat, apply: Bool) -> CGFloat {
        let width = max(1, panelWidth - 32)
        let summary = summaryHeight(width: panelWidth)
        func place(_ view: NSView, _ y: CGFloat, _ h: CGFloat, x: CGFloat = 16, w: CGFloat? = nil) {
            guard apply else { return }
            view.isHidden = false
            view.alphaValue = detailsAlpha
            view.frame = NSRect(x: x - 8, y: y - summary, width: w ?? width, height: h)
        }
        func text(_ label: NSTextField, _ y: CGFloat, x: CGFloat = 16, w: CGFloat? = nil) -> CGFloat {
            let h = textHeight(label, width: w ?? width)
            place(label, y, h, x: x, w: w)
            return h
        }
        let updateWidth = min(width * 0.4, ceil(updateLabel.attributedStringValue.size().width) + 4)
        var y: CGFloat = summaryHeight(width: panelWidth) + 10
        let titleHeight = text(taskTitle, y, w: width - updateWidth - 10)
        let updateHeight = text(updateLabel, y, x: 16 + width - updateWidth, w: updateWidth)
        y += max(titleHeight, updateHeight) + 9
        if !taskNote.stringValue.isEmpty { y += text(taskNote, y) + 8 }
        if state.errorMessage != nil { y += text(errorLabel, y) + 8 }
        if rows.isEmpty { y += text(emptyLabel, y) + 10 }
        for (index, row) in rows.enumerated() {
            let views = metricViews[index]
            let valueWidth = min(width * 0.6, ceil(views.1.attributedStringValue.size().width) + 4)
            let h = max(text(views.0, y + 3, w: width - valueWidth - 8) + 3,
                        text(views.1, y, x: 16 + width - valueWidth, w: valueWidth))
            y += h + 3
            if row.percent != nil { place(views.3, y, 3); y += 6 }
            y += text(views.2, y) + 10
        }
        if apply { detailContent.separatorY = nil }
        if state.tokenUsage != nil || state.creditBalance != nil {
            y += 4
            if apply {
                detailContent.separatorY = y - summary - 5
                detailContent.separatorAlpha = detailsAlpha
            }
            let pointsWidth = min(width * 0.4, ceil(points.attributedStringValue.size().width) + 4)
            let both = state.tokenUsage != nil && state.creditBalance != nil
            let secondaryHeight = state.tokenUsage == nil ? 0 : text(secondary, y, w: both ? width - pointsWidth - 10 : width)
            let pointsHeight = state.creditBalance == nil ? 0 : text(points, y, x: both ? 16 + width - pointsWidth : 16, w: both ? pointsWidth : width)
            y += max(secondaryHeight, pointsHeight)
        }
        let buttons = [refresh, settings, hideButton, collapseButton]
        let buttonWidth = (width - 18) / 4
        for (index, button) in buttons.enumerated() { place(button, y + 9, 24, x: 16 + CGFloat(index) * (buttonWidth + 6), w: buttonWidth) }
        return y + 9 + 24 + 12
    }
    override func layout() {
        super.layout()
        subviews.forEach { $0.isHidden = true }
        detailContent.subviews.forEach { $0.isHidden = true }
        strip.isHidden = false
        let summary = summaryHeight(width: bounds.width)
        strip.frame = NSRect(x: 13, y: 0, width: max(0, bounds.width - 26), height: summary)
        guard expanded && detailsReady else { return }
        let naturalHeight = layoutDetails(width: bounds.width, apply: true)
        detailScroll.isHidden = false
        detailScroll.frame = NSRect(x: 8, y: summary, width: max(0, bounds.width - 16), height: max(0, bounds.height - summary - 8))
        detailScroll.hasVerticalScroller = naturalHeight > bounds.height
        detailContent.frame.size = NSSize(width: detailScroll.bounds.width, height: max(detailScroll.bounds.height, naturalHeight - summary - 8))
        if !detailScroll.hasVerticalScroller { detailScroll.contentView.scroll(to: .zero) }
        detailScroll.reflectScrolledClipView(detailScroll.contentView)
    }
    func surfacePath() -> NSBezierPath {
        let w = bounds.width, h = bounds.height
        let neck = min(w, notchWidth)
        let l = (w - neck) / 2, right = l + neck
        let shoulder = min(7, l)
        let r = min(11, h / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: l, y: 0))
        path.line(to: NSPoint(x: right, y: 0))
        path.curve(to: NSPoint(x: w, y: shoulder), controlPoint1: NSPoint(x: right, y: 0), controlPoint2: NSPoint(x: w, y: 0))
        path.line(to: NSPoint(x: w, y: h - r))
        path.curve(to: NSPoint(x: w - r, y: h), controlPoint1: NSPoint(x: w, y: h - 3), controlPoint2: NSPoint(x: w - 3, y: h))
        path.line(to: NSPoint(x: r, y: h))
        path.curve(to: NSPoint(x: 0, y: h - r), controlPoint1: NSPoint(x: 3, y: h), controlPoint2: NSPoint(x: 0, y: h - 3))
        path.line(to: NSPoint(x: 0, y: shoulder))
        path.curve(to: NSPoint(x: l, y: 0), controlPoint1: NSPoint(x: 0, y: 0), controlPoint2: NSPoint(x: l, y: 0))
        path.close()
        return path
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        surfacePath().fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard surfacePath().contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
    @objc private func toggle() { onToggle?() }
    @objc private func refreshClicked() { onRefresh?() }
    @objc private func hideClicked() { onHide?() }
    @objc private func settingsClicked() { onSettings?() }
    @objc private func collapseClicked() { onCollapse?() }
}

final class NotchHUDController: NSObject {
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onHide: (() -> Void)?
    var onVisibilityChanged: (() -> Void)?
    let panel: NSPanel = NotchPanel()
    let view = NotchHUDView(frame: .zero)
    private var geometry: NotchHUDGeometry?
    private var state = RateLimitDisplayState.initial
    private var taskDisplayEnabled = true
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var transition: Timer?
    private(set) var visibility = NotchVisibility()
    private var lastReportedVisible = false
    var isVisible: Bool { visibility.isVisible }
    var isPresented: Bool { visibility.requested }
    private(set) var isExpanded = false
    // Injectable for deterministic geometry tests. System Reduced Motion always wins.
    var animationsEnabled = true
    var isAnimating: Bool { transition != nil }

    override init() {
        super.init()
        panel.contentView = view
        view.onToggle = { [weak self] in self?.toggleExpanded() }
        view.onCollapse = { [weak self] in self?.collapse() }
        view.onRefresh = { [weak self] in self?.onRefresh?() }
        view.onSettings = { [weak self] in self?.collapse(animated: false); self?.onSettings?() }
        view.onHide = { [weak self] in self?.onHide?() }
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: NSWindow.didChangeOcclusionStateNotification, object: panel)
    }
    @discardableResult
    func show(in geometry: NotchHUDGeometry? = NotchHUDGeometry.current()) -> Bool {
        guard let geometry else { hide(); return false }
        let wasPresented = isPresented
        self.geometry = geometry
        visibility.requested = true
        relayout()
        // Do not re-order on Space/occlusion notifications: AppKit owns full-screen exclusion.
        if !wasPresented { panel.orderFrontRegardless() }
        installEventMonitors()
        refreshVisibility()
        return true
    }
    func hide() {
        stopTransition()
        isExpanded = false
        geometry = nil
        visibility.requested = false
        panel.orderOut(nil)
        refreshVisibility()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
    func update(_ state: RateLimitDisplayState, taskDisplayEnabled: Bool = true) {
        self.state = state
        self.taskDisplayEnabled = taskDisplayEnabled
        // Data changes are immediate and never initiate or replay a completion animation.
        relayout()
    }
    func toggleExpanded() {
        guard isPresented else { return }
        isExpanded.toggle()
        relayout(animated: true)
    }
    func collapse(animated: Bool = true) {
        guard isExpanded || isAnimating else { return }
        isExpanded = false
        relayout(animated: animated)
    }
    func environmentChanged() {
        collapse(animated: false)
        refreshVisibility()
    }
    @objc private func visibilityChanged() { refreshVisibility() }
    func refreshVisibility() {
        let wasVisible = lastReportedVisible
        visibility.onActiveSpace = panel.isOnActiveSpace
        visibility.unoccluded = panel.isVisible && panel.occlusionState.contains(.visible)
        if !isVisible { collapse(animated: false) }
        updateMouseRouting()
        lastReportedVisible = isVisible
        if wasVisible != isVisible { onVisibilityChanged?() }
    }
    private func stopTransition() {
        transition?.invalidate()
        transition = nil
        view.detailsReady = true
        view.detailsAlpha = 1
    }
    private func applyFrame(_ frame: NSRect) {
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        view.needsLayout = true
        view.needsDisplay = true
        view.layoutSubtreeIfNeeded()
        // Routing uses the current bounds/path at every intermediate animation frame.
        updateMouseRouting()
    }
    private func relayout(animated: Bool = false) {
        stopTransition()
        view.update(state, expanded: isExpanded, taskDisplayEnabled: taskDisplayEnabled)
        guard let geometry else { return }
        view.notchWidth = geometry.notchWidth
        let availableWidth = geometry.frame(width: geometry.screen.width, height: 24).width
        if view.compactWidth > availableWidth {
            view.update(state, expanded: isExpanded, taskDisplayEnabled: taskDisplayEnabled, abbreviateLabels: true)
        }
        let width = geometry.frame(width: isExpanded ? max(340, view.compactWidth) : view.compactWidth, height: 24).width
        let target = geometry.frame(width: width, height: view.preferredHeight(width: width))
        guard animated, animationsEnabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              panel.frame.width > 0, panel.frame != target else { applyFrame(target); return }
        let start = panel.frame.size
        let started = ProcessInfo.processInfo.systemUptime
        let expanding = isExpanded
        view.detailsReady = false
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let progress = min(1, elapsed / 0.18)
            let eased = CGFloat(1 - pow(1 - progress, 3))
            let size = NSSize(width: start.width + (target.width - start.width) * eased,
                              height: start.height + (target.height - start.height) * eased)
            self.view.detailsReady = progress == 1
            self.view.detailsAlpha = expanding ? CGFloat(min(1, max(0, (elapsed - 0.18) / 0.10))) : 1
            self.applyFrame(geometry.frame(width: size.width, height: size.height))
            if elapsed >= (expanding ? 0.28 : 0.18) {
                self.stopTransition()
                self.applyFrame(target)
            }
        }
        transition = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func contains(_ point: NSPoint) -> Bool {
        let local = view.convert(panel.convertPoint(fromScreen: point), from: nil)
        return view.surfacePath().contains(local)
    }
    private func updateMouseRouting() {
        panel.ignoresMouseEvents = !isVisible || !contains(NSEvent.mouseLocation)
    }
    private func installEventMonitors() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]
        // Mouse-only monitoring; no global keyboard hook or new privacy permission.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.handleMouse(event) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouse(event)
            return event
        }
    }
    private func handleMouse(_ event: NSEvent) {
        updateMouseRouting()
        if (event.type == .leftMouseDown || event.type == .rightMouseDown) && !contains(NSEvent.mouseLocation) { collapse() }
    }
    deinit {
        transition?.invalidate()
        NotificationCenter.default.removeObserver(self)
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
