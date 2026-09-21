import AppKit

/// AppKit owns event routing; SwiftUI owns the sole animation geometry.
final class NotchInteractionController {
    private let panel: NSPanel
    private let bridge: NotchGeometryBridge
    private let model: NotchPresentationModel
    private let deferredInput = NotchDelayScheduler()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private(set) var enabled = false

    init(panel: NSPanel, bridge: NotchGeometryBridge, model: NotchPresentationModel) {
        self.panel = panel
        self.bridge = bridge
        self.model = model
        bridge.onChange = { [weak self] _ in
            guard let self else { return }
            // Runs for every presented frame even if the physical cursor does not move.
            self.updateRouting()
            // Observable state writes must happen outside NSViewRepresentable updates.
            self.deferredInput.cancelAll()
            self.deferredInput.after(0) { [weak self] in self?.updateHover() }
        }
    }
    func local(_ screenPoint: NSPoint) -> NSPoint {
        NSPoint(x: screenPoint.x - panel.frame.minX, y: panel.frame.maxY - screenPoint.y)
    }
    func contains(_ screenPoint: NSPoint) -> Bool { bridge.snapshot?.acceptsClick(local(screenPoint)) == true }
    func updateRouting(at point: NSPoint? = nil) {
        let accepts = contains(point ?? mouseLocation())
        panel.ignoresMouseEvents = !enabled || (!accepts && !model.pointerCaptured)
    }
    private func updateHover() {
        guard enabled else { return }
        model.hover(bridge.snapshot?.maintainsHover(local(mouseLocation())) == true)
    }
    func start() {
        enabled = true
        updateRouting()
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                         .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.handle(event) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event // Outside clicks always continue to their original destination.
        }
    }
    func handle(_ event: NSEvent) {
        guard enabled else { return }
        let inside = contains(mouseLocation())
        updateRouting()
        updateHover()
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            if inside && event.window === panel {
                model.setCaptured(true)
                if event.type == .leftMouseDown { model.click() }
            } else if !inside { model.outsideClick() }
        case .leftMouseUp, .rightMouseUp:
            model.setCaptured(false)
            updateRouting()
        default: break
        }
    }
    func stop() {
        enabled = false
        deferredInput.cancelAll()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        panel.ignoresMouseEvents = true
    }
    deinit { stop() }
}
