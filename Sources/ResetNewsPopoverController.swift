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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ResetForecastIndicator.accessibilityLabel(model.state.forecastCount)).font(.system(size: 16, weight: .semibold))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("resetNews.heading")
            ResetNewsListView(state: model.state, isVisible: model.isVisible, focusedItemID: model.focusedItemID,
                onCheck: { model.onCheck?() }, onMarkAllRead: { model.onMarkAllRead?() },
                onSettings: { model.onSettings?() }, onPageVisibility: model.pageVisibilityChanged,
                onVisibleItem: model.cardVisible)
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
    private let popover = NSPopover()
    private let contentController = NSViewController()
    private var placement: ResetNewsPopoverPlacement?
    private var visibilityObserver: NSObjectProtocol?
    var presentedWindow: NSWindow? { popover.contentViewController?.view.window }
    override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        let container = NSView(frame: CGRect(origin: .zero, size: model.contentSize))
        let host = NSHostingView(rootView: ResetNewsPopoverContent(model: model))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        contentController.view = container
        popover.contentViewController = contentController
    }
    func update(_ state: ResetNewsViewState) { model.state = state }
    func show(relativeTo anchor: NSView, itemIDs: [String] = []) {
        guard let anchorWindow = anchor.window else { return }
        let anchorRect = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: anchorRect.midX, y: anchorRect.midY)) })
            ?? anchorWindow.screen else { return }
        let placement = ResetNewsPopoverPlacement(anchor: anchorRect, visibleFrame: screen.visibleFrame)
        self.placement = placement
        let localIDs = Set(model.state.items.map(\.id))
        model.focusedItemID = itemIDs.first { localIDs.contains($0) }
        if popover.isShown { popover.performClose(nil) }
        model.contentSize = placement.contentSize
        contentController.view.setFrameSize(placement.contentSize)
        contentController.preferredContentSize = placement.contentSize
        popover.contentSize = placement.contentSize
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: placement.preferredEdge)
        containWindow()
        // AppKit can finish positioning after show returns, especially when the
        // anchor is in a menu-bar window on a different display.
        DispatchQueue.main.async { [weak self] in self?.containWindow() }
    }
    func close() { popover.performClose(nil); model.isVisible = false; model.pageVisibilityChanged(false) }
    func popoverDidShow(_ notification: Notification) {
        containWindow()
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        if let window = popover.contentViewController?.view.window {
            visibilityObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in self?.refreshVisibility() }
        }
        refreshVisibility()
    }
    private func containWindow() {
        guard popover.isShown, let window = presentedWindow, let placement else { return }
        let frame = placement.containedFrame(window.frame)
        if window.frame != frame { window.setFrame(frame, display: true) }
    }
    private func refreshVisibility() {
        let window = popover.contentViewController?.view.window
        model.isVisible = popover.isShown && window?.isVisible == true && window?.isOnActiveSpace == true
            && window?.occlusionState.contains(.visible) == true
        if !model.isVisible { model.pageVisibilityChanged(false) }
    }
    func popoverWillClose(_ notification: Notification) {
        model.isVisible = false
        model.pageVisibilityChanged(false)
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = nil
    }
    deinit { if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) } }
}
