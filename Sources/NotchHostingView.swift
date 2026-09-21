import AppKit
import SwiftUI

final class NotchIslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary, .fullScreenDisallowsTiling, .stationary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        title = "GPT HUD · Island"
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class NotchHostingView: NSHostingView<NotchRootView> {
    let bridge: NotchGeometryBridge
    var contextMenuProvider: (() -> NSMenu)?
    var onPage: ((Int) -> Void)?
    private var horizontalScroll: CGFloat = 0
    private var pagedThisGesture = false
    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    init(model: NotchPresentationModel, bridge: NotchGeometryBridge) {
        self.bridge = bridge
        super.init(rootView: NotchRootView(model: model, bridge: bridge))
        autoresizingMask = [.width, .height]
    }
    required init(rootView: NotchRootView) { fatalError("Use init(model:bridge:)") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bridge.snapshot?.acceptsClick(convert(point, from: superview)) == true else { return nil }
        return super.hitTest(point)
    }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?() }
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { super.scrollWheel(with: event); return }
        if event.phase.contains(.began) { horizontalScroll = 0; pagedThisGesture = false }
        horizontalScroll += event.scrollingDeltaX
        if abs(horizontalScroll) > 32 && !pagedThisGesture {
            onPage?(horizontalScroll < 0 ? 1 : -1)
            pagedThisGesture = true
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) || event.phase.isEmpty {
            horizontalScroll = 0
            pagedThisGesture = false
        }
    }
}
