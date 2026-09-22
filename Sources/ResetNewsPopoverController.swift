import AppKit
import SwiftUI

final class ResetNewsPopoverModel: ObservableObject {
    @Published var state = ResetNewsViewState()
    @Published var isVisible = false
    @Published var focusedItemID: String?
    @Published var contentSize = CGSize(width: 420, height: 480)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ResetForecastIndicator.accessibilityLabel(model.state.forecastCount)).font(.system(size: 16, weight: .semibold))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("resetNews.heading")
            ResetNewsListView(state: model.state, isVisible: model.isVisible && isCurrentPresentation(), focusedItemID: model.focusedItemID,
                onCheck: { if isCurrentPresentation() { model.onCheck?() } },
                onMarkAllRead: { if isCurrentPresentation() { model.onMarkAllRead?() } },
                onSettings: { if isCurrentPresentation() { model.onSettings?() } },
                onPageVisibility: { if isCurrentPresentation() { model.pageVisibilityChanged($0) } },
                onVisibleItem: { if isCurrentPresentation() { model.cardVisible($0) } })
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
    let model = ResetNewsPopoverModel()
    private var popover: NSPopover?
    private var placement: ResetNewsPopoverPlacement?
    private var visibilityObserver: NSObjectProtocol?
    private var dismissalObservers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    var presentedWindow: NSWindow? { popover?.contentViewController?.view.window }
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
    func update(_ state: ResetNewsViewState) { model.state = state }
    func show(relativeTo anchor: NSView, itemIDs: [String] = []) {
        guard let anchorWindow = anchor.window else { return }
        let anchorRect = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: anchorRect.midX, y: anchorRect.midY)) })
            ?? anchorWindow.screen else { return }
        let placement = ResetNewsPopoverPlacement(anchor: anchorRect, visibleFrame: screen.visibleFrame)
        // Do not reparent a closing popover's content between HUD and menu-bar
        // anchors. Each presentation owns its native window and delegate cycle.
        close()
        self.placement = placement
        let localIDs = Set(model.state.items.map(\.id))
        model.focusedItemID = itemIDs.first { localIDs.contains($0) }
        model.contentSize = placement.contentSize
        let presentation = makePopover()
        popover = presentation
        presentation.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: placement.preferredEdge)
        containWindow(for: presentation)
        // AppKit can finish positioning after show returns, especially when the
        // anchor is in a menu-bar window on a different display.
        DispatchQueue.main.async { [weak self, weak presentation] in self?.containWindow(for: presentation) }
    }
    func close() {
        let closingPopover = popover
        let closingWindow = presentedWindow
        // Invalidate first: closing AppKit windows can deliver callbacks inline.
        popover = nil
        placement = nil
        removePresentationObservers()
        model.isVisible = false
        model.pageVisibilityChanged(false)
        closingPopover?.delegate = nil
        closingPopover?.close()
        // isShown and native visibility can diverge during an anchor transition.
        closingWindow?.orderOut(nil)
    }
    func popoverDidShow(_ notification: Notification) {
        guard let presentation = notification.object as? NSPopover, presentation === popover else { return }
        containWindow(for: presentation)
        removePresentationObservers()
        if let window = presentation.contentViewController?.view.window {
            visibilityObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self, weak presentation] _ in self?.refreshVisibility(for: presentation) }
            dismissalObservers = [
                NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                    object: window, queue: .main) { [weak self, weak presentation] _ in self?.closeIfCurrent(presentation) },
                NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                    object: NSApp, queue: .main) { [weak self, weak presentation] _ in self?.closeIfCurrent(presentation) }
            ]
            // A nonactivating HUD/status-item popover may never become key or
            // activate this app, so focus notifications alone are insufficient.
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self, weak presentation] notification in
                    guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                    self?.closeIfCurrent(presentation)
                }
            let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self, weak presentation] event in
                if let self, let presentation, self.popover === presentation, event.window !== self.presentedWindow { self.close() }
                return event
            }
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self, weak presentation] _ in self?.closeIfCurrent(presentation) }
        }
        refreshVisibility(for: presentation)
    }
    private func closeIfCurrent(_ presentation: NSPopover?) {
        guard let presentation, presentation === popover else { return }
        close()
    }
    private func removePresentationObservers() {
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = nil
        for observer in dismissalObservers { NotificationCenter.default.removeObserver(observer) }
        dismissalObservers.removeAll()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        localClickMonitor = nil
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        globalClickMonitor = nil
    }
    private func containWindow(for presentation: NSPopover?) {
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
    }
    func popoverWillClose(_ notification: Notification) {
        guard let presentation = notification.object as? NSPopover, presentation === popover else { return }
        model.isVisible = false
        model.pageVisibilityChanged(false)
        removePresentationObservers()
    }
    func popoverDidClose(_ notification: Notification) {
        guard let presentation = notification.object as? NSPopover, presentation === popover else { return }
        presentation.delegate = nil
        presentedWindow?.orderOut(nil)
        popover = nil
        placement = nil
        removePresentationObservers()
        model.isVisible = false
        model.pageVisibilityChanged(false)
    }
    deinit { close() }
}
