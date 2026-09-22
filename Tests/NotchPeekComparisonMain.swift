import AppKit
import SwiftUI
import ResetNewsCore

/// Local fixture renderer only. It never instantiates AppDelegate, a monitor,
/// a feed client, or any system notification channel.
private final class PeekComparisonDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private final class PeekComparisonCanvas: NSView {
    let color: NSColor
    override var isFlipped: Bool { true }
    init(size: NSSize, color: NSColor) {
        self.color = color
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}

private enum PeekComparisonVariant: String, CaseIterable {
    case current, a, b
    var title: String {
        switch self {
        case .current: return "当前 · 真实 Peek"
        case .a: return "A · 短日期双行（预览）"
        case .b: return "B · 原宽度双列（预览）"
        }
    }
}

/// A/B replace only the right quota content in the native view hierarchy,
/// before rendering. All other pixels originate from the real NotchRootView.
private struct PeekComparisonView: View {
    let variant: PeekComparisonVariant
    let model: NotchPresentationModel
    let layout: NotchLayout
    let bridge: NotchGeometryBridge

    var body: some View {
        if variant == .current {
            NotchRootView(model: model, bridge: bridge)
        } else {
            NotchRootView(model: model, bridge: bridge)
                .overlay(replacement)
        }
    }

    private var replacement: some View {
        let geometry = NotchPresentationGeometry(size: layout.size(for: .peek),
            carrierWidth: layout.windowFrame.width, exclusion: layout.localExclusion)
        return ZStack(alignment: .topLeading) {
            quota
                .frame(width: layout.pillSlotWidth - 8, height: layout.visualBarHeight)
                .background(Color.black)
                .position(x: layout.windowFrame.width / 2 + layout.notchWidth / 2 + 38 + layout.pillSlotWidth / 2,
                    y: layout.visualBarHeight / 2)
        }
        .frame(width: layout.windowFrame.width, height: layout.windowFrame.height, alignment: .topLeading)
        .mask(Path(geometry.path))
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var quota: some View {
        if variant == .a {
            VStack(spacing: 0) {
                Text("周 43%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(NotchStyle.accent)
                Text("09/25 10:00")
                    .font(.system(size: 9))
                    .foregroundColor(NotchStyle.secondary)
            }
            .fixedSize()
        } else {
            HStack(spacing: 8) {
                VStack(spacing: 0) {
                    Text("周余").font(.system(size: 10)).foregroundColor(NotchStyle.secondary)
                    Text("43%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(NotchStyle.accent)
                }.frame(width: 36)
                VStack(spacing: 0) {
                    Text("09/25").font(.system(size: 10))
                    Text("10:00").font(.system(size: 11, design: .monospaced))
                }.foregroundColor(NotchStyle.secondary).frame(width: 44)
            }
            .fixedSize()
        }
    }
}

@main
private enum NotchPeekComparisonMain {
    static let output = URL(fileURLWithPath: "Design/reset-news-preview/peek-comparison", isDirectory: true)
    static let canvasSize = NSSize(width: 560, height: 96)
    static let rightRect = CGRect(x: 358, y: 20, width: 162, height: 60)
    static let backdrop = NSColor(calibratedRed: 0.77, green: 0.85, blue: 0.93, alpha: 1)
    static let exampleDate = ISO8601DateFormatter().date(from: "2026-09-22T10:00:00+08:00")!

    static var layout: NotchLayout {
        let geometry = NotchHUDGeometry(screen: CGRect(x: 0, y: 0, width: 760, height: 600), topInset: 32,
            leftArea: CGRect(x: 0, y: 568, width: 290, height: 32),
            rightArea: CGRect(x: 470, y: 568, width: 290, height: 32))!
        return NotchLayout(geometry: geometry)
    }

    static func model(count: Int) -> NotchPresentationModel {
        let value = NotchPresentationModel(alwaysShowQuota: false)
        value.animationsEnabled = false
        value.configure(layout)
        value.setVisible(true)
        value.setEnvironment(reduceMotion: true, reduceTransparency: true, lowPower: true)
        var quota = RateLimitDisplayState.initial
        quota.fiveHour = LimitMeter(title: "5 小时", shortTitle: "5h", window: RateLimitWindow(
            usedPercent: 28, windowDurationMins: 300, resetsAt: exampleDate.addingTimeInterval(7_200).timeIntervalSince1970))
        quota.weekly = LimitMeter(title: "周限额", shortTitle: "7d", window: RateLimitWindow(
            usedPercent: 57, windowDurationMins: 10_080, resetsAt: exampleDate.addingTimeInterval(3 * 86_400).timeIntervalSince1970))
        value.update(quota, tasksEnabled: true)
        let items = (0..<count).map { index in
            ResetNewsItem(id: "peek-fixture-\(index)", sources: [.feed], originalText: "Preview fixture only",
                facts: [.init(kind: .upcomingReset)], firstSeenAt: exampleDate)
        }
        value.updateResetNews(ResetNewsViewState(enabled: true, status: .success, items: items))
        value.hover(true)
        return value
    }

    static func canvas(variant: PeekComparisonVariant, count: Int) -> NSView {
        let canvas = PeekComparisonCanvas(size: canvasSize, color: backdrop)
        let host = NSHostingView(rootView: PeekComparisonView(variant: variant, model: model(count: count),
            layout: layout, bridge: NotchGeometryBridge()))
        host.frame = CGRect(x: (canvasSize.width - layout.windowFrame.width) / 2, y: 32,
            width: layout.windowFrame.width, height: layout.windowFrame.height)
        canvas.addSubview(host)
        return canvas
    }

    static func pump(_ duration: TimeInterval = 0.2) {
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.003), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.003))
        } while Date() < deadline
    }

    static func window(_ content: NSView) -> NSWindow {
        // Match the 2× output with real 2× backing when the Mac has a Retina screen.
        // This moves only the temporary fixture window, never a user window or setting.
        let display = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        let screen = display?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let stage = NSWindow(contentRect: CGRect(x: screen.minX + 20, y: screen.minY + 50,
            width: content.frame.width, height: content.frame.height), styleMask: .borderless, backing: .buffered, defer: false)
        stage.isReleasedWhenClosed = false
        stage.appearance = NSAppearance(named: .aqua)
        stage.contentView = content
        stage.orderFrontRegardless()
        pump()
        return stage
    }

    static func bitmap(_ view: NSView, rect: CGRect? = nil) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = rect ?? view.bounds
        precondition(view.bounds.contains(bounds), "Capture region must be inside its native canvas")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2),
            pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }

    static func save(_ bitmap: NSBitmapImageRep, name: String, directory: URL? = nil) throws {
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode \(name)") }
        try png.write(to: (directory ?? output).appendingPathComponent(name), options: .atomic)
        print("Saved \(name): \(Int(bitmap.size.width))×\(Int(bitmap.size.height)) pt / \(bitmap.pixelsWide)×\(bitmap.pixelsHigh) px")
    }

    static func implementedA() throws {
        let directory = URL(fileURLWithPath: "Design/reset-news-preview/a-implemented", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for count in [0, 3, 120] {
            let canvas = PeekComparisonCanvas(size: canvasSize, color: backdrop)
            // Product-only evidence: no PeekComparisonView or A/B replacement layer.
            let host = NSHostingView(rootView: NotchRootView(model: model(count: count), bridge: NotchGeometryBridge()))
            host.frame = CGRect(x: (canvasSize.width - layout.windowFrame.width) / 2, y: 32,
                width: layout.windowFrame.width, height: layout.windowFrame.height)
            canvas.addSubview(host)
            let stage = window(canvas)
            defer { stage.orderOut(nil) }
            let suffix = count > 99 ? "99" : String(count)
            try save(bitmap(canvas), name: "a-\(suffix).png", directory: directory)
            try save(bitmap(canvas, rect: rightRect), name: "a-right-\(suffix).png", directory: directory)
        }
        print("PASS: 6 implemented-A PNGs from the real NotchRootView; no comparison baseline files touched.")
    }

    static func label(_ text: String, frame: CGRect, size: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSTextField {
        let value = NSTextField(labelWithString: text)
        value.frame = frame
        value.font = .systemFont(ofSize: size, weight: weight)
        value.textColor = .labelColor
        return value
    }

    static func comparison(rightImages: [PeekComparisonVariant: NSBitmapImageRep]) throws {
        let canvas = PeekComparisonCanvas(size: NSSize(width: 952, height: 564), color: .white)
        canvas.addSubview(label("Peek 等宽比较 · 原尺寸全条", frame: CGRect(x: 20, y: 14, width: 540, height: 25), size: 17, weight: .semibold))
        canvas.addSubview(label("右侧放大 2×", frame: CGRect(x: 598, y: 17, width: 320, height: 24), size: 14))
        canvas.addSubview(label("示例数据 · 三版均为 448×32 pt；预告入口 38 pt＋周额度槽 96 pt", frame: CGRect(x: 20, y: 45, width: 900, height: 20), size: 11))
        for (index, variant) in PeekComparisonVariant.allCases.enumerated() {
            let y = 78 + CGFloat(index) * 154
            canvas.addSubview(label(variant.title, frame: CGRect(x: 20, y: y, width: 560, height: 22), size: 14, weight: .semibold))
            let whole = self.canvas(variant: variant, count: 3)
            whole.frame.origin = CGPoint(x: 20, y: y + 29)
            canvas.addSubview(whole)
            let image = NSImage(size: rightRect.size)
            image.addRepresentation(rightImages[variant]!)
            let zoom = NSImageView(frame: CGRect(x: 598, y: y + 17, width: rightRect.width * 2, height: rightRect.height * 2))
            zoom.image = image
            zoom.imageScaling = .scaleAxesIndependently
            canvas.addSubview(zoom)
        }
        let stage = window(canvas)
        defer { stage.orderOut(nil) }
        try save(bitmap(canvas), name: "comparison.png")
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let originalDefaults = DisplayLanguage.defaults
        let originalTimeZone = NSTimeZone.default
        DisplayLanguage.defaults = PeekComparisonDefaults()
        DisplayLanguage.current = .chinese
        NSTimeZone.default = TimeZone(secondsFromGMT: 8 * 3_600)!
        defer { DisplayLanguage.defaults = originalDefaults; NSTimeZone.default = originalTimeZone }
        precondition(layout.size(for: .peek) == NSSize(width: 448, height: 32), "Keep all three previews at the real 448×32 pt Peek size")
        precondition(layout.notchWidth == 180 && layout.pillSlotWidth == 96, "Keep camera and quota slots unchanged")
        precondition(layout.markX(left: false) == 489, "Keep the forecast shoulder anchored")
        if CommandLine.arguments.contains("--implemented-a") {
            try implementedA()
            return
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var rightImages: [PeekComparisonVariant: NSBitmapImageRep] = [:]
        for count in [3, 0, 120] {
            let suffix = count > 99 ? "99" : String(count)
            for variant in PeekComparisonVariant.allCases {
                let canvas = self.canvas(variant: variant, count: count)
                let stage = window(canvas)
                defer { stage.orderOut(nil) }
                let right = bitmap(canvas, rect: rightRect)
                try save(right, name: "\(variant.rawValue)-right-\(suffix).png")
                try save(bitmap(canvas), name: "\(variant.rawValue)-\(suffix).png")
                if count == 3 {
                    rightImages[variant] = right
                }
            }
        }
        try comparison(rightImages: rightImages)
        print("PASS: 19 native preview PNGs; current uses the real Peek, A/B are preview-only quota replacements. No product sources or user preferences changed.")
    }
}
