import AppKit

/// Stable AppDelegate boundary. The internal launch switch creates exactly one renderer.
final class NotchHUDController {
    let island: NotchIslandController?
    private let legacy: LegacyNotchHUDController?
    var onRefresh: (() -> Void)? { didSet { island?.model.onRefresh = onRefresh; legacy?.onRefresh = onRefresh } }
    var onSettings: (() -> Void)? { didSet { island?.onSettings = onSettings; legacy?.onSettings = onSettings } }
    var onHide: (() -> Void)? { didSet { island?.model.onHide = onHide; legacy?.onHide = onHide } }
    var onVisibilityChanged: (() -> Void)? { didSet { island?.onVisibilityChanged = onVisibilityChanged; legacy?.onVisibilityChanged = onVisibilityChanged } }
    var isExpanded: Bool { island.map { $0.model.state == .expanded } ?? legacy?.isExpanded ?? false }
    var isVisible: Bool { island?.isVisible ?? legacy?.isVisible ?? false }
    init(useLegacy: Bool = ProcessInfo.processInfo.environment["GPT_HUD_NOTCH_RENDERER"] == "legacy") {
        island = useLegacy ? nil : NotchIslandController()
        legacy = useLegacy ? LegacyNotchHUDController() : nil
    }
    @discardableResult func show(in geometry: NotchHUDGeometry? = NotchHUDGeometry.current()) -> Bool {
        island?.show(in: geometry) ?? legacy?.show(in: geometry) ?? false
    }
    func hide() { island?.hide(); legacy?.hide() }
    func update(_ state: RateLimitDisplayState, taskDisplayEnabled: Bool = true) {
        island?.model.update(state, tasksEnabled: taskDisplayEnabled)
        legacy?.update(state, taskDisplayEnabled: taskDisplayEnabled)
    }
    func collapse(animated: Bool = true) { island?.model.collapse(animated: animated); legacy?.collapse(animated: animated) }
    func environmentChanged() { island?.environmentChanged(); legacy?.environmentChanged() }
    func setAlwaysShowQuota(_ enabled: Bool) { island?.model.setAlwaysShowQuota(enabled) }
}

final class NotchIslandController: NSObject, NSMenuDelegate {
    let panel = NotchIslandPanel()
    let model: NotchPresentationModel
    let bridge = NotchGeometryBridge()
    let host: NotchHostingView
    let interaction: NotchInteractionController
    var onSettings: (() -> Void)?
    var onVisibilityChanged: (() -> Void)?
    private(set) var visibility = NotchVisibility()
    var isVisible: Bool { visibility.isVisible }
    private var reportedVisible = false
    private var powerObserver: NSObjectProtocol?
    private let automaticallyTracksMouse: Bool
    private(set) var frameChanges = 0

    init(defaults: UserDefaults = .standard, clock: NotchClock = NotchSystemClock(), automaticallyTracksMouse: Bool = true) {
        self.automaticallyTracksMouse = automaticallyTracksMouse
        model = NotchPresentationModel(clock: clock, alwaysShowQuota: defaults.bool(forKey: NotchPresentationModel.alwaysShowKey))
        host = NotchHostingView(model: model, bridge: bridge)
        interaction = NotchInteractionController(panel: panel, bridge: bridge, model: model)
        super.init()
        panel.contentView = host
        model.onSettings = { [weak self] in self?.model.collapse(animated: false); self?.onSettings?() }
        host.contextMenuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        host.onPage = { [weak self] delta in
            guard let self, let page = NotchDetailPage(rawValue: self.model.page.rawValue + delta) else { return }
            self.model.selectPage(page)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshVisibility), name: NSWindow.didChangeOcclusionStateNotification, object: panel)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateAccessibility), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        if #available(macOS 12.0, *) {
            // Foundation posts this notification on a global queue. Keep all
            // ObservableObject and AppKit writes on the main queue.
            powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.updateAccessibility()
            }
        }
        updateAccessibility()
    }
    @discardableResult func show(in geometry: NotchHUDGeometry?, visibleTopDelta: CGFloat? = nil) -> Bool {
        guard let geometry else { hide(); return false }
        let measured = visibleTopDelta ?? NSScreen.screens.first { $0.frame == geometry.screen }.map { $0.frame.maxY - $0.visibleFrame.maxY }
        let layout = NotchLayout(geometry: geometry, visibleTopDelta: measured)
        guard layout.isUsable else { hide(); return false }
        if model.layout != layout {
            interaction.stop()
            bridge.invalidate()
            model.configure(layout)
            panel.setFrame(layout.windowFrame, display: true)
            frameChanges += 1
            // Initial non-animated geometry is authoritative before the first hosting pass.
            bridge.publish(NotchPresentationGeometry(size: model.size, carrierWidth: layout.windowFrame.width,
                                                     exclusion: layout.localExclusion), epoch: bridge.epoch)
        }
        let wasRequested = visibility.requested
        visibility.requested = true
        if !wasRequested { panel.orderFrontRegardless() }
        refreshVisibility()
        return true
    }
    func hide() {
        visibility.requested = false
        interaction.stop()
        bridge.invalidate()
        model.reset(visible: false)
        panel.orderOut(nil)
        refreshVisibility()
    }
    func environmentChanged() {
        interaction.stop()
        bridge.invalidate()
        model.reset(visible: false)
        refreshVisibility()
    }
    @objc func refreshVisibility() {
        visibility.onActiveSpace = panel.isOnActiveSpace
        visibility.unoccluded = panel.isVisible && panel.occlusionState.contains(.visible)
        model.setVisible(isVisible)
        if isVisible {
            if automaticallyTracksMouse { interaction.start() }
        } else { interaction.stop() }
        if reportedVisible != isVisible { reportedVisible = isVisible; onVisibilityChanged?() }
    }
    @objc private func updateAccessibility() {
        var lowPower = false
        if #available(macOS 12.0, *) { lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        model.setEnvironment(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                             reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency, lowPower: lowPower)
    }
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for page in NotchDetailPage.allCases {
            let item = NSMenuItem(title: page.title, action: #selector(menuPage(_:)), keyEquivalent: "")
            item.tag = page.rawValue; item.target = self
            menu.addItem(item)
        }
        return menu
    }
    @objc private func menuPage(_ item: NSMenuItem) {
        model.click()
        if let page = NotchDetailPage(rawValue: item.tag) { model.selectPage(page) }
    }
    func menuWillOpen(_ menu: NSMenu) { model.beginMenu() }
    func menuDidClose(_ menu: NSMenu) { model.endMenu() }
    deinit {
        interaction.stop()
        model.scheduler.cancelAll()
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        panel.orderOut(nil)
    }
}
