import AppKit
import SwiftUI

final class ResetNewsPopoverModel: ObservableObject {
    @Published var state = ResetNewsViewState()
    var context = PresentationContext()
    @Published var forecast = ForecastPresentation(ResetNewsViewState())
    @Published var isVisible = false
    @Published var focusedItemID: String?
    @Published var contentSize = CGSize(width: 420, height: 360)
    var onBack: (() -> Void)?
    var onCheck: (() -> Void)?
    var onMarkAllRead: (() -> Void)?
    var onSettings: (() -> Void)?
    var onVisibleItem: ((String) -> Void)?
    private(set) var pageVisible = false

    func pageVisibilityChanged(_ visible: Bool) { pageVisible = visible }
    func cardVisible(_ id: String) {
        guard isVisible, pageVisible, state.items.contains(where: { $0.id == id }), !state.readIDs.contains(id) else { return }
        onVisibleItem?(id)
    }
}

private struct ResetNewsPopoverContent: View {
    @ObservedObject var model: ResetNewsPopoverModel
    let isCurrentPresentation: () -> Bool
    let onPreferredHeight: (CGFloat) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.onBack != nil {
                Button(action: { if isCurrentPresentation() { model.onBack?() } }) {
                    Label(model.context.text("返回额度", "Back to quota"), systemImage: "chevron.left")
                }.buttonStyle(PlainButtonStyle()).foregroundColor(.secondary)
                    .font(.system(size: 12)).accessibilityIdentifier("resetNews.backToMenu")
            }
            ResetNewsListView(state: model.state, isVisible: model.isVisible && isCurrentPresentation(), focusedItemID: model.focusedItemID,
                onCheck: { if isCurrentPresentation() { model.onCheck?() } },
                onMarkAllRead: { if isCurrentPresentation() { model.onMarkAllRead?() } },
                onSettings: { if isCurrentPresentation() { model.onSettings?() } },
                onPageVisibility: { if isCurrentPresentation() { model.pageVisibilityChanged($0) } },
                onVisibleItem: { if isCurrentPresentation() { model.cardVisible($0) } },
                onPreferredHeightChange: { if isCurrentPresentation() { onPreferredHeight($0) } },
                presentation: model.forecast, context: model.context)
        }.padding(16).frame(width: model.contentSize.width, height: model.contentSize.height, alignment: .topLeading)
    }
}

struct ResetNewsPopoverPlacement {
    let usableFrame: CGRect
    let contentSize: CGSize
    let preferredEdge: NSRectEdge

    init(anchor: CGRect, visibleFrame: CGRect) {
        usableFrame = visibleFrame.insetBy(dx: 8, dy: 8)
        let below = max(0, min(usableFrame.maxY, anchor.minY) - usableFrame.minY)
        let above = max(0, usableFrame.maxY - max(usableFrame.minY, anchor.maxY))
        preferredEdge = below >= above ? .minY : .maxY
        // NSPopover adds a 13-point native frame on each side. Reserve it before
        // sizing the fixed content host; only the card list may then scroll.
        contentSize = CGSize(width: max(1, min(420, usableFrame.width - 26)),
            height: max(1, min(480, usableFrame.height - 26, max(180, max(below, above) - 26))))
    }

    func containedFrame(_ frame: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, usableFrame.width), height: min(frame.height, usableFrame.height))
        return CGRect(x: min(max(frame.minX, usableFrame.minX), usableFrame.maxX - size.width),
            y: min(max(frame.minY, usableFrame.minY), usableFrame.maxY - size.height), width: size.width, height: size.height)
    }
}

/// Notification clicks use only locally cached IDs. Opening this controller has no fetch or URL action.
final class ResetNewsPopoverController: NSObject, NSPopoverDelegate {
    struct FocusSnapshot {
        let applicationIsActive: Bool
        let frontmostProcessIdentifier: pid_t?
        static var current: Self {
            Self(applicationIsActive: NSApp.isActive,
                 frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        }
    }
    private let focusSnapshot: () -> FocusSnapshot
    private let workspaceNotifications: NotificationCenter
    private var applicationWasActive = false
    private var presentationFrontmostPID: pid_t?
    init(focusSnapshot: @escaping () -> FocusSnapshot = { .current },
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.focusSnapshot = focusSnapshot
        self.workspaceNotifications = workspaceNotifications
        super.init()
    }
    let model = ResetNewsPopoverModel()
    struct PresentationTrace: Encodable {
        let event: String
        let source: String?
        let sequence: Int
        let uptime: TimeInterval
        let presentation: String?
        let currentPresentation: String?
        let nativeWindow: String?
        let windowNumber: Int?
        let isShown: Bool?
        let windowVisible: Bool?
        let modelVisible: Bool
        let keyWindow: Bool?
        let mainWindow: Bool?
        let appActive: Bool
        let observedAppActive: Bool
        let presentationHadActiveApp: Bool
        let presentationFrontmostPID: pid_t?
        let frontmostProcessIdentifier: pid_t?
        let onActiveSpace: Bool?
        let windowFrame: String?
        let anchorVisible: Bool?
        let anchorOnActiveSpace: Bool?
        let anchorWindowFrame: String?
        let anchorScreen: String?
        let screens: [String]?
    }
    /// Optional fixture diagnostics; the application does not install a sink.
    var onPresentationTrace: ((PresentationTrace) -> Void)?
    private var presentationSequence = 0
    private var popover: NSPopover?
    private var placement: ResetNewsPopoverPlacement?
    private var visibilityObserver: NSObjectProtocol?
    private var dismissalObservers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    var presentedWindow: NSWindow? { popover?.contentViewController?.view.window }
    private func trace(_ event: String, presentation: NSPopover?, source: String? = nil,
                       window: NSWindow? = nil, anchor: NSView? = nil) {
        guard let onPresentationTrace else { return }
        let content = presentation?.contentViewController
        let window = window ?? (content?.isViewLoaded == true ? content?.view.window : nil)
        let anchorWindow = anchor?.window
        let focus = focusSnapshot()
        func screenDescription(_ screen: NSScreen) -> String {
            "\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "unknown"): \(NSStringFromRect(screen.frame))"
        }
        onPresentationTrace(PresentationTrace(event: event, source: source, sequence: presentationSequence,
            uptime: ProcessInfo.processInfo.systemUptime,
            presentation: presentation.map { String(describing: ObjectIdentifier($0)) },
            currentPresentation: popover.map { String(describing: ObjectIdentifier($0)) },
            nativeWindow: window.map { String(describing: ObjectIdentifier($0)) }, windowNumber: window?.windowNumber,
            isShown: presentation?.isShown, windowVisible: window?.isVisible, modelVisible: model.isVisible,
            keyWindow: window?.isKeyWindow, mainWindow: window?.isMainWindow, appActive: NSApp.isActive,
            observedAppActive: focus.applicationIsActive, presentationHadActiveApp: applicationWasActive,
            presentationFrontmostPID: presentationFrontmostPID, frontmostProcessIdentifier: focus.frontmostProcessIdentifier,
            onActiveSpace: window?.isOnActiveSpace, windowFrame: window.map { NSStringFromRect($0.frame) },
            anchorVisible: anchorWindow?.isVisible, anchorOnActiveSpace: anchorWindow?.isOnActiveSpace,
            anchorWindowFrame: anchorWindow.map { NSStringFromRect($0.frame) },
            anchorScreen: anchorWindow?.screen.map(screenDescription),
            screens: anchor == nil ? nil : NSScreen.screens.map(screenDescription)))
    }
    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        let container = NSView(frame: CGRect(origin: .zero, size: model.contentSize))
        let host = NSHostingView(rootView: ResetNewsPopoverContent(model: model,
            isCurrentPresentation: { [weak self, weak popover] in
                guard let popover else { return false }
                return self?.popover === popover
            }, onPreferredHeight: { [weak self, weak popover] height in
                // Layout preferences are delivered during SwiftUI layout. Resize on the next turn.
                self?.trace("resize.scheduled", presentation: popover)
                DispatchQueue.main.async { [weak self, weak popover] in
                    self?.resize(popover, preferredListHeight: height)
                }
            }))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        let contentController = NSViewController()
        contentController.view = container
        contentController.preferredContentSize = model.contentSize
        popover.contentViewController = contentController
        popover.contentSize = model.contentSize
        return popover
    }
    private func resize(_ presentation: NSPopover?, preferredListHeight: CGFloat) {
        trace("resize.delivered", presentation: presentation)
        guard let presentation, presentation === popover, let placement else { return }
        let chrome: CGFloat = model.onBack == nil ? 32 : 60
        let height = min(placement.contentSize.height, max(180, ceil(preferredListHeight + chrome)))
        let size = CGSize(width: placement.contentSize.width, height: height)
        guard model.contentSize != size else { return }
        // The native window must resize before its autoresizing content subtree.
        // Resizing the container first would apply the height delta a second time.
        if let window = presentedWindow {
            let old = window.frame
            let frame = CGRect(x: old.minX, y: old.maxY - height - 26,
                width: size.width + 26, height: height + 26)
            window.setFrame(placement.containedFrame(frame), display: false)
        }
        presentation.contentViewController?.preferredContentSize = size
        presentation.contentSize = size
        model.contentSize = size
        containWindow(for: presentation)
        DispatchQueue.main.async { [weak self, weak presentation] in
            self?.containWindow(for: presentation)
        }
    }
    func update(_ state: ResetNewsViewState, forecast: ForecastPresentation? = nil,
                context: PresentationContext = PresentationContext()) {
        model.context = context
        let next = forecast ?? ForecastPresentation(state, context: context)
        if model.forecast != next { model.forecast = next }
        if model.state != state { model.state = state }
    }
    func show(relativeTo anchor: NSView, itemIDs: [String] = [], onBack: (() -> Void)? = nil) {
        guard let anchorWindow = anchor.window else { return }
        let anchorRect = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: anchorRect.midX, y: anchorRect.midY)) })
            ?? anchorWindow.screen else { return }
        let placement = ResetNewsPopoverPlacement(anchor: anchorRect, visibleFrame: screen.visibleFrame)
        // Do not reparent a closing popover's content between HUD and menu-bar
        // anchors. Each presentation owns its native window and delegate cycle.
        close(source: "replacement")
        presentationSequence += 1
        trace("show.requested", presentation: nil, source: "anchor:\(anchorWindow.windowNumber)", anchor: anchor)
        model.onBack = onBack.map { callback in
            { [weak self] in self?.close(source: "back"); callback() }
        }
        self.placement = placement
        let localIDs = Set(model.state.items.map(\.id))
        model.focusedItemID = itemIDs.first { localIDs.contains($0) }
        model.contentSize = CGSize(width: placement.contentSize.width, height: min(360, placement.contentSize.height))
        let presentation = makePopover()
        popover = presentation
        let focus = focusSnapshot()
        applicationWasActive = focus.applicationIsActive
        presentationFrontmostPID = focus.frontmostProcessIdentifier
        presentation.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: placement.preferredEdge)
        recordApplicationActivation(for: presentation)
        trace("show.returned", presentation: presentation, anchor: anchor)
        containWindow(for: presentation)
        // AppKit can finish positioning after show returns, especially when the
        // anchor is in a menu-bar window on a different display.
        DispatchQueue.main.async { [weak self, weak presentation] in self?.containWindow(for: presentation) }
    }
    func close() { close(source: "explicit") }
    private func close(source: String) {
        let closingPopover = popover
        let closingWindow = presentedWindow
        trace("close.begin", presentation: closingPopover, source: source, window: closingWindow)
        // Invalidate first: closing AppKit windows can deliver callbacks inline.
        popover = nil
        applicationWasActive = false
        presentationFrontmostPID = nil
        placement = nil
        removePresentationObservers()
        model.isVisible = false
        model.onBack = nil
        model.pageVisibilityChanged(false)
        closingPopover?.delegate = nil
        closingPopover?.close()
        // isShown and native visibility can diverge during an anchor transition.
        closingWindow?.orderOut(nil)
        trace("close.end", presentation: closingPopover, source: source, window: closingWindow)
    }
    func popoverDidShow(_ notification: Notification) {
        trace("native.didShow", presentation: notification.object as? NSPopover)
        guard let presentation = notification.object as? NSPopover, presentation === popover else { return }
        containWindow(for: presentation)
        recordApplicationActivation(for: presentation)
        removePresentationObservers()
        if let window = presentation.contentViewController?.view.window {
            visibilityObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self, weak presentation] _ in self?.refreshVisibility(for: presentation) }
            dismissalObservers = [
                NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                    object: window, queue: .main) { [weak self, weak presentation] _ in self?.closeIfCurrent(presentation, source: "key") },
                NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                    object: NSApp, queue: .main) { [weak self, weak presentation] _ in self?.applicationResigned(for: presentation) },
                NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                    object: NSApp, queue: .main) { [weak self, weak presentation] _ in self?.recordApplicationActivation(for: presentation) }
            ]
            // A nonactivating HUD/status-item popover may never become key or
            // activate this app, so focus notifications alone are insufficient.
            workspaceObserver = workspaceNotifications.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self, weak presentation] notification in
                    guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                    self?.workspaceActivated(application, for: presentation)
                }
            let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) { [weak self, weak presentation] event in
                if event.type == .keyDown {
                    if event.keyCode == 53, let self, let presentation, self.popover === presentation,
                       let back = self.model.onBack { back(); return nil }
                    return event
                }
                if let self, let presentation, self.popover === presentation, event.window !== self.presentedWindow { self.close(source: "local") }
                return event
            }
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self, weak presentation] _ in self?.closeIfCurrent(presentation, source: "global") }
        }
        refreshVisibility(for: presentation)
    }
    private func recordApplicationActivation(for presentation: NSPopover?) {
        guard let presentation, presentation === popover else { return }
        let focus = focusSnapshot()
        guard focus.applicationIsActive else { return }
        applicationWasActive = true
        presentationFrontmostPID = focus.frontmostProcessIdentifier
        trace("focus.active", presentation: presentation)
    }
    private func applicationResigned(for presentation: NSPopover?) {
        guard let presentation, presentation === popover else { return }
        let focus = focusSnapshot()
        // Process notifications have no presentation identity. A previous
        // deactivation may arrive after a new, still-active popup has opened.
        if focus.applicationIsActive {
            recordApplicationActivation(for: presentation)
            trace("dismiss.ignored", presentation: presentation, source: "app.active")
            return
        }
        guard applicationWasActive else {
            trace("dismiss.ignored", presentation: presentation, source: "app.alreadyInactive")
            return
        }
        closeIfCurrent(presentation, source: "app")
    }
    private func workspaceActivated(_ application: NSRunningApplication, for presentation: NSPopover?) {
        guard let presentation, presentation === popover else { return }
        let focus = focusSnapshot()
        if let currentPID = focus.frontmostProcessIdentifier {
            guard currentPID == application.processIdentifier, currentPID != presentationFrontmostPID else {
                trace("dismiss.ignored", presentation: presentation, source: "workspace.unchangedOrStale")
                return
            }
        }
        // If the actual foreground process cannot be read, retain the existing
        // conservative close behavior rather than suppress a valid switch.
        closeIfCurrent(presentation, source: "workspace")
    }
    private func closeIfCurrent(_ presentation: NSPopover?, source: String) {
        trace("dismiss.delivered", presentation: presentation, source: source)
        guard let presentation, presentation === popover else { return }
        close(source: source)
    }
    private func removePresentationObservers() {
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = nil
        for observer in dismissalObservers { NotificationCenter.default.removeObserver(observer) }
        dismissalObservers.removeAll()
        if let workspaceObserver { workspaceNotifications.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        localClickMonitor = nil
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        globalClickMonitor = nil
    }
    private func containWindow(for presentation: NSPopover?) {
        trace("contain.delivered", presentation: presentation)
        guard let presentation, presentation === popover, presentation.isShown,
              let window = presentedWindow, let placement else { return }
        let frame = placement.containedFrame(window.frame)
        if window.frame != frame { window.setFrame(frame, display: true) }
    }
    private func refreshVisibility(for presentation: NSPopover?) {
        guard let presentation, presentation === popover else { return }
        let window = presentedWindow
        model.isVisible = presentation.isShown && window?.isVisible == true && window?.isOnActiveSpace == true
            && window?.occlusionState.contains(.visible) == true
        if !model.isVisible { model.pageVisibilityChanged(false) }
        trace("visibility.refreshed", presentation: presentation)
    }
    func popoverWillClose(_ notification: Notification) {
        trace("native.willClose", presentation: notification.object as? NSPopover)
        guard let presentation = notification.object as? NSPopover, presentation === popover else { return }
        model.isVisible = false
        model.pageVisibilityChanged(false)
        removePresentationObservers()
    }
    func popoverDidClose(_ notification: Notification) {
        trace("native.didClose", presentation: notification.object as? NSPopover)
        guard let presentation = notification.object as? NSPopover, presentation === popover else { return }
        presentation.delegate = nil
        presentedWindow?.orderOut(nil)
        popover = nil
        applicationWasActive = false
        presentationFrontmostPID = nil
        placement = nil
        removePresentationObservers()
        model.isVisible = false
        model.pageVisibilityChanged(false)
    }
    deinit { close() }
}
