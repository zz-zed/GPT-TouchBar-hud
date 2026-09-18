import AppKit

final class CompactHUDPanel: NSPanel {
    private let defaultSize = NSSize(width: 250, height: DesignTokens.hudHeight)
    private var hasPositionedInitialFrame = false

    init(contentViewController: NSViewController) {
        super.init(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.contentViewController = contentViewController
        self.backgroundColor = .clear
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.hasShadow = true
        self.hidesOnDeactivate = false
        // Quota display has no text input. A background HUD click should not
        // automatically take keyboard focus; the legacy path requests it explicitly.
        self.becomesKeyOnlyIfNeeded = true
        self.isMovableByWindowBackground = true
        self.isOpaque = false
        self.isReleasedWhenClosed = false
        self.level = .statusBar
        self.titleVisibility = .hidden
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    func orderFrontPinned() {
        positionInitialFrameIfNeeded()
        recoverPositionIfOffscreen()
        orderFrontRegardless()
    }

    func recoverPositionIfOffscreen() {
        guard hasPositionedInitialFrame, !NSScreen.screens.isEmpty else { return }
        let areas = NSScreen.screens.map { screen -> NSRect in
            var area = screen.visibleFrame
            if #available(macOS 12.0, *) {
                let insets = screen.safeAreaInsets
                let safe = NSRect(x: screen.frame.minX + insets.left, y: screen.frame.minY + insets.bottom,
                                  width: screen.frame.width - insets.left - insets.right,
                                  height: screen.frame.height - insets.top - insets.bottom)
                area = area.intersection(safe)
            }
            return area.insetBy(dx: 8, dy: 8)
        }
        let target = areas.max { a, b in
            let left = a.intersection(frame), right = b.intersection(frame)
            return (left.isNull ? 0 : left.width * left.height) < (right.isNull ? 0 : right.width * right.height)
        } ?? areas[0]
        setFrameOrigin(Self.clampedOrigin(frame: frame, usable: target))
    }

    static func clampedOrigin(frame: NSRect, usable: NSRect) -> NSPoint {
        NSPoint(x: min(max(frame.minX, usable.minX), max(usable.minX, usable.maxX - frame.width)),
                y: min(max(frame.minY, usable.minY), max(usable.minY, usable.maxY - frame.height)))
    }

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .leftMouseUp { recoverPositionIfOffscreen() }
    }

    private func positionInitialFrameIfNeeded() {
        guard !hasPositionedInitialFrame else {
            return
        }

        let screenFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let contentSize = contentView?.fittingSize ?? defaultSize
        let size = NSSize(width: max(80, contentSize.width), height: defaultSize.height)
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height - 68
        )
        setFrame(NSRect(origin: origin, size: size), display: false)
        hasPositionedInitialFrame = true
    }
}
