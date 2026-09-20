import AppKit

/// Synthetic only: these dimensions are NOT calibrated hardware measurements.
/// The fake camera uses its own rounded-bottom path, never the HUD's surfacePath.
final class SyntheticCameraView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height, r = min(8, h / 2)
        let path = NSBezierPath()
        path.move(to: .zero)
        path.line(to: NSPoint(x: w, y: 0))
        path.line(to: NSPoint(x: w, y: h - r))
        path.curve(to: NSPoint(x: w - r, y: h), controlPoint1: NSPoint(x: w, y: h - r * 0.448), controlPoint2: NSPoint(x: w - r * 0.448, y: h))
        path.line(to: NSPoint(x: r, y: h))
        path.curve(to: NSPoint(x: 0, y: h - r), controlPoint1: NSPoint(x: r * 0.448, y: h), controlPoint2: NSPoint(x: 0, y: h - r * 0.448))
        path.close()
        NSColor.black.setFill()
        path.fill()
    }
}

enum NotchSimulation {
    static func geometry(screen: NSRect = NSRect(x: 0, y: 0, width: 760, height: 600), inset: CGFloat = 32,
                         neck: CGFloat = 180, scale: CGFloat = 2) -> NotchHUDGeometry {
        let side = (screen.width - neck) / 2
        return NotchHUDGeometry(screen: screen, topInset: inset,
            leftArea: NSRect(x: screen.minX, y: screen.maxY - inset, width: side, height: inset),
            rightArea: NSRect(x: screen.midX + neck / 2, y: screen.maxY - inset, width: side, height: inset), backingScale: scale)!
    }
    static func state(single: Bool = false, long: Bool = false) -> RateLimitDisplayState {
        var result = RateLimitDisplayState.initial
        result.fiveHour = LimitMeter(title: "5h", shortTitle: "5h", window: RateLimitWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: 1800000000))
        if !single { result.weekly = LimitMeter(title: "周", shortTitle: "W", window: RateLimitWindow(usedPercent: 22, windowDurationMins: 10080, resetsAt: 1800000000)) }
        result.taskStatus = TaskStatusSummary(runningCount: long ? 123456789 : 0)
        result.lastUpdated = Date(timeIntervalSince1970: 1800000000)
        return result
    }
    static let blue = NSColor(srgbRed: 0.13, green: 0.48, blue: 0.86, alpha: 1)
}

/// Test-only composition: independent fake hardware + unmodified production view.
final class NotchSimulationScene: NSView {
    let hud = NotchHUDView(frame: .zero)
    let camera = SyntheticCameraView(frame: .zero)
    var background = NotchSimulation.blue { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        addSubview(hud)
        addSubview(camera)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { background.setFill(); bounds.fill() }

    func configure(geometry: NotchHUDGeometry, state: RateLimitDisplayState, width: CGFloat? = nil,
                   progress: Double = 0, legacyBelowCamera: Bool = false) {
        hud.update(state, expanded: false)
        let compactWidth = geometry.frame(width: width ?? hud.compactWidth, height: 24).width
        let compact = geometry.frame(width: compactWidth, height: hud.preferredHeight(width: compactWidth))
        let expandedWidth = max(340, width ?? hud.compactWidth)
        hud.update(state, expanded: true)
        let target = geometry.frame(width: expandedWidth, height: hud.preferredHeight(width: expandedWidth))
        let current = geometry.transitionFrame(from: compact, to: target, progress: progress)
        hud.update(state, expanded: progress > 0)
        hud.notchWidth = geometry.notchWidth
        hud.cameraEnclosure = legacyBelowCamera ? nil : geometry.enclosure(in: current)
        hud.frame = NSRect(x: current.minX - geometry.screen.minX, y: legacyBelowCamera ? geometry.topInset : 0,
                           width: current.width, height: current.height - (legacyBelowCamera ? geometry.topInset : 0))
        hud.detailsReady = progress == 1
        hud.needsLayout = true
        camera.frame = NSRect(x: geometry.cameraEnclosure.minX - geometry.screen.minX, y: 0,
                              width: geometry.notchWidth, height: geometry.topInset)
        layoutSubtreeIfNeeded()
        needsDisplay = true
    }
    func bitmap(scale: CGFloat = 2) -> NSBitmapImageRep {
        // Explicit backing scale makes raster checks independent of the runner's display.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale),
            pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = bounds.size
        cacheDisplay(in: bounds, to: rep)
        return rep
    }
    func save(_ name: String, scale: CGFloat = 2) throws {
        try bitmap(scale: scale).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/\(name).png"))
    }
}
