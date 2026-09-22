import AppKit
import SwiftUI
import ResetNewsCore

/// Screenshot-only harness: no AppDelegate, monitors, network clients or real notification channels.
private final class PreviewDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private final class PreviewCanvas: NSView {
    var color: NSColor
    override var isFlipped: Bool { true }
    init(size: NSSize, color: NSColor = .windowBackgroundColor) {
        self.color = color
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}

private final class PreviewCamera: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(NotchSurfaceShape.path(bounds, bottomRadius: 9))
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
    }
}

private final class CapturingNotificationChannel: ResetNewsNotificationChannel {
    var onOpen: (([String]) -> Void)?
    var payloads: [ResetNewsNotificationPayload] = []
    func readPermission(completion: @escaping (ResetNewsNotificationPermission) -> Void) { completion(.allowed) }
    func requestAuthorization(completion: @escaping (ResetNewsNotificationPermission) -> Void) { completion(.allowed) }
    func add(_ payload: ResetNewsNotificationPayload, completion: @escaping (Error?) -> Void) {
        payloads.append(payload)
        completion(nil)
    }
    func removePending(prefix: String) {}
}

@main
enum ResetNewsPreviewMain {
    static let output = URL(fileURLWithPath: "Design/reset-news-preview", isDirectory: true)
    static let date = ISO8601DateFormatter().date(from: "2026-09-22T10:00:00+08:00")!
    static let appearance = HUDAppearance(colorChoice: .graphite, backgroundOpacity: 0.94, contentOpacity: 1)

    static var quota: RateLimitDisplayState {
        var value = RateLimitDisplayState.initial
        value.fiveHour = LimitMeter(title: "5 小时", shortTitle: "5h", window: RateLimitWindow(
            usedPercent: 28, windowDurationMins: 300, resetsAt: date.addingTimeInterval(7_200).timeIntervalSince1970))
        value.weekly = LimitMeter(title: "周限额", shortTitle: "7d", window: RateLimitWindow(
            usedPercent: 57, windowDurationMins: 10_080, resetsAt: date.addingTimeInterval(3 * 86_400).timeIntervalSince1970))
        value.taskStatus = TaskStatusSummary(runningCount: 2)
        value.tokenUsage = TokenUsageSummary(yesterdayTokens: 128_400, cumulativeTokens: 8_620_000)
        value.lastUpdated = date
        return value
    }

    static var news: ResetNewsViewState {
        let items = [
            ResetNewsItem(id: "preview-upcoming", sources: [.feed], originalText: "Fictional upcoming reset example",
                facts: [.init(kind: .upcomingReset, scope: "all", effectiveAt: date.addingTimeInterval(3_600))],
                publishedAt: date.addingTimeInterval(-600), firstSeenAt: date),
            ResetNewsItem(id: "preview-announced", sources: [.timeline], originalText: "Fictional completed reset announcement",
                facts: [.init(kind: .resetAnnouncement, scope: "Plus,Pro")],
                publishedAt: date.addingTimeInterval(-3_600), firstSeenAt: date),
            ResetNewsItem(id: "preview-credits", sources: [.feed], originalText: "Fictional extra credit example",
                facts: [.init(kind: .extraResetCredits, scope: "Pro", count: 2, expiresAt: date.addingTimeInterval(7 * 86_400))],
                publishedAt: date.addingTimeInterval(-7_200), firstSeenAt: date),
            ResetNewsItem(id: "preview-tentative", sources: [.timeline], originalText: "Fictional tentative announcement",
                facts: [.init(kind: .upcomingReset, scope: "Plus", timingText: "本周", confidence: .tentative)],
                publishedAt: date.addingTimeInterval(-10_800), firstSeenAt: date),
            ResetNewsItem(id: "preview-cancelled", sources: [.feed], originalText: "Fictional cancelled reset example",
                facts: [.init(kind: .upcomingReset, scope: "all", timingText: "原定今晚")], status: .cancelled,
                publishedAt: date.addingTimeInterval(-86_400), firstSeenAt: date)
        ]
        return ResetNewsViewState(enabled: true, status: .success, items: items,
            readIDs: ["preview-tentative", "preview-cancelled"], lastAttempt: date, lastSuccess: date,
            nextCheck: date.addingTimeInterval(120), notificationPermission: .allowed)
    }

    static func newsForCount(_ count: Int) -> ResetNewsViewState {
        var state = news
        if count == 0 { state.readIDs = Set(state.items.map(\.id)); return state }
        if count == 3 { return state }
        state.items = (0..<count).map { index in
            var item = news.items[index % news.items.count]
            item.id = "preview-count-\(index)"
            return item
        }
        state.readIDs = []
        return state
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
        let window = NSWindow(contentRect: NSRect(x: 60, y: 40, width: content.frame.width, height: content.frame.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = content
        window.orderFrontRegardless()
        pump()
        return window
    }

    static func save(_ view: NSView, _ name: String, rect: CGRect? = nil) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = rect ?? view.bounds
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2),
            pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode \(name)") }
        try png.write(to: output.appendingPathComponent(name), options: .atomic)
        print("Saved \(name) (\(bitmap.pixelsWide)×\(bitmap.pixelsHigh))")
    }

    static func list(_ state: ResetNewsViewState, visible: Bool = true) -> ResetNewsListView {
        ResetNewsListView(state: state, isVisible: visible, onCheck: {}, onMarkAllRead: {}, onSettings: {},
            onPageVisibility: { _ in }, onVisibleItem: { _ in })
    }

    static func quiet() throws {
        let canvas = PreviewCanvas(size: NSSize(width: 500, height: 110), color: NSColor(calibratedWhite: 0.9, alpha: 1))
        let view = CompactQuotaHUDView(initialAppearance: appearance, onRefresh: {}, onClose: {}, contextMenuProvider: { NSMenu() })
        canvas.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: canvas.centerXAnchor), view.centerYAnchor.constraint(equalTo: canvas.centerYAnchor)])
        view.update(with: quota)
        view.updateMessages(forecastCount: 3, available: true)
        let host = window(canvas)
        defer { host.orderOut(nil) }
        try save(canvas, "01-quiet-unread-3.png")
    }

    static func touchBar() throws {
        let canvas = PreviewCanvas(size: NSSize(width: 680, height: 86), color: NSColor(calibratedWhite: 0.06, alpha: 1))
        canvas.appearance = NSAppearance(named: .darkAqua)
        let view = TouchBarRateLimitsView()
        view.appearance = NSAppearance(named: .darkAqua)
        canvas.addSubview(view)
        NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: canvas.centerXAnchor), view.centerYAnchor.constraint(equalTo: canvas.centerYAnchor)])
        view.update(with: quota)
        view.updateMessages(forecastCount: 3, available: true)
        let host = window(canvas)
        defer { host.orderOut(nil) }
        try save(canvas, "02-touchbar-unread-3.png")
    }

    static func notch() throws {
        let screen = CGRect(x: 0, y: 0, width: 760, height: 600)
        let geometry = NotchHUDGeometry(screen: screen, topInset: 32,
            leftArea: CGRect(x: 0, y: 568, width: 290, height: 32),
            rightArea: CGRect(x: 470, y: 568, width: 290, height: 32))!
        let layout = NotchLayout(geometry: geometry)
        let model = NotchPresentationModel(alwaysShowQuota: false)
        model.animationsEnabled = false
        model.configure(layout)
        model.setVisible(true)
        model.setEnvironment(reduceMotion: true, reduceTransparency: true, lowPower: true)
        model.update(quota, tasksEnabled: true)
        model.updateResetNews(news)
        let canvas = PreviewCanvas(size: layout.windowFrame.size, color: NSColor(calibratedRed: 0.77, green: 0.85, blue: 0.93, alpha: 1))
        let host = NotchHostingView(model: model, bridge: NotchGeometryBridge())
        host.frame = canvas.bounds
        canvas.addSubview(host)
        canvas.addSubview(PreviewCamera(frame: layout.localExclusion))
        let stage = window(canvas)
        defer { stage.orderOut(nil) }
        try save(canvas, "03-notch-compact.png", rect: CGRect(x: 0, y: 0, width: 760, height: 118))
        model.openResetForecasts()
        pump()
        try save(canvas, "04-notch-messages.png", rect: CGRect(x: 0, y: 0, width: 760, height: 320))
    }

    static func messageList() throws {
        let canvas = PreviewCanvas(size: NSSize(width: 460, height: 930))
        let host = NSHostingView(rootView: list(news).padding(16))
        host.frame = canvas.bounds
        canvas.addSubview(host)
        let stage = window(canvas)
        defer { stage.orderOut(nil) }
        try save(canvas, "05-messages-list.png")
    }

    static func popover() throws {
        let canvas = PreviewCanvas(size: NSSize(width: 500, height: 60))
        let anchor = NSButton(title: "重置预告（3）", target: nil, action: nil)
        anchor.frame = CGRect(x: 185, y: 12, width: 130, height: 30)
        canvas.addSubview(anchor)
        let stage = window(canvas)
        stage.setFrameOrigin(NSPoint(x: 180, y: 700))
        let existing = Set(NSApp.windows.map(\.windowNumber))
        let controller = ResetNewsPopoverController()
        controller.update(news)
        controller.show(relativeTo: anchor)
        pump(0.4)
        defer { controller.close(); stage.orderOut(nil) }
        guard let popover = NSApp.windows.first(where: { !existing.contains($0.windowNumber) && $0.isVisible }),
              let content = popover.contentView else { throw NSError(domain: "ResetNewsPreview", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Native popover did not expose a visible preview window"]) }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        pump()
        try save(content, "06-messages-popover.png")
    }

    static func settings() throws {
        let controller = PreferencesWindowController(appearance: appearance)
        controller.update(appearance: appearance, state: quota, taskEnabled: true, persistentEnabled: true, persistentAvailable: true)
        controller.updateResetNews(news, soundEnabled: false)
        controller.showResetNewsTab()
        controller.window?.appearance = NSAppearance(named: .aqua)
        controller.showWindow(nil)
        pump()
        defer { controller.window?.orderOut(nil) }
        let tabs = controller.window!.contentView!.subviews.compactMap { $0 as? NSTabView }.first!
        let content = tabs.selectedTabViewItem!.view!
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        pump()
        try save(content, "07-settings.png")
        print("Settings image is the real selected tab body; system tab-strip bitmap is intentionally excluded.")
    }

    static func states() throws {
        let canvas = PreviewCanvas(size: NSSize(width: 880, height: 620), color: .white)
        var waiting = ResetNewsViewState(enabled: true, status: .codexNotRunning)
        waiting.notificationPermission = .allowed
        var partial = news
        partial.status = .partial
        partial.detail = "一个来源暂不可用，保留已获取消息"
        partial.items = [news.items[2]]
        var stale = partial
        stale.status = .stale
        stale.detail = "发布副本已过期，已暂停强提醒"
        for (index, state) in [ResetNewsViewState(), waiting, partial, stale].enumerated() {
            let panel = PreviewCanvas(size: NSSize(width: 420, height: 290))
            panel.frame.origin = CGPoint(x: 10 + CGFloat(index % 2) * 440, y: 10 + CGFloat(index / 2) * 310)
            panel.layer?.cornerRadius = 10
            let host = NSHostingView(rootView: list(state).padding(14))
            host.frame = panel.bounds
            panel.addSubview(host)
            canvas.addSubview(panel)
        }
        let stage = window(canvas)
        defer { stage.orderOut(nil) }
        try save(canvas, "08-message-states.png")
    }

    static func notifications() throws {
        struct Example: Encodable { let title: String; let body: String; let sound: Bool; let itemIDs: [String] }
        let channel = CapturingNotificationChannel()
        let controller = ResetNewsNotificationController(channel: channel)
        controller.enable()
        controller.deliver([news.items[2]])
        controller.deliver(Array(news.items.prefix(3)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let payloads = channel.payloads.map { Example(title: $0.title, body: $0.body, sound: $0.sound, itemIDs: $0.itemIDs) }
        try encoder.encode(payloads).write(to: output.appendingPathComponent("notification-examples.json"), options: .atomic)
        print("Captured \(payloads.count) notification payload examples with an in-memory fake channel.")
    }

    static func annotation(_ text: String, frame: CGRect, fontSize: CGFloat = 12) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        label.font = .systemFont(ofSize: fontSize, weight: .medium)
        label.textColor = .labelColor
        return label
    }

    static func forecastCountMatrix() throws {
        let canvas = PreviewCanvas(size: NSSize(width: 900, height: 900), color: .white)
        let geometry = NotchHUDGeometry(screen: CGRect(x: 0, y: 0, width: 760, height: 600), topInset: 32,
            leftArea: CGRect(x: 0, y: 568, width: 290, height: 32),
            rightArea: CGRect(x: 470, y: 568, width: 290, height: 32))!
        let layout = NotchLayout(geometry: geometry)
        var retainedModels: [NotchPresentationModel] = []
        for (index, count) in [0, 3, 120].enumerated() {
            let y = CGFloat(index) * 300
            canvas.addSubview(annotation("\(ResetForecastIndicator.countText(count)) 条 · 实际原生入口", frame: CGRect(x: 24, y: y + 12, width: 560, height: 22), fontSize: 15))
            canvas.addSubview(annotation("桌面浮窗", frame: CGRect(x: 24, y: y + 51, width: 100, height: 20)))
            let quiet = CompactQuotaHUDView(initialAppearance: appearance, onRefresh: {}, onClose: {}, contextMenuProvider: { NSMenu() })
            quiet.translatesAutoresizingMaskIntoConstraints = false
            canvas.addSubview(quiet)
            quiet.update(with: quota)
            quiet.updateMessages(forecastCount: count, available: true)
            NSLayoutConstraint.activate([quiet.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 150),
                quiet.topAnchor.constraint(equalTo: canvas.topAnchor, constant: y + 40)])

            let touchCanvas = PreviewCanvas(size: NSSize(width: 850, height: 50), color: NSColor(calibratedWhite: 0.06, alpha: 1))
            touchCanvas.frame.origin = CGPoint(x: 24, y: y + 94)
            touchCanvas.layer?.cornerRadius = 8
            let touchBar = TouchBarRateLimitsView()
            touchBar.appearance = NSAppearance(named: .darkAqua)
            touchCanvas.addSubview(touchBar)
            touchBar.update(with: quota)
            touchBar.updateMessages(forecastCount: count, available: true)
            NSLayoutConstraint.activate([touchBar.centerXAnchor.constraint(equalTo: touchCanvas.centerXAnchor),
                touchBar.centerYAnchor.constraint(equalTo: touchCanvas.centerYAnchor)])
            canvas.addSubview(touchCanvas)

            for (column, state) in NotchPresentationState.allCases.enumerated() {
                let x = CGFloat(column) * 292 + 24
                canvas.addSubview(annotation("刘海 \(state.rawValue) · 右肩原尺寸", frame: CGRect(x: x, y: y + 164, width: 270, height: 20)))
                let clipping = PreviewCanvas(size: NSSize(width: 260, height: 64), color: NSColor(calibratedRed: 0.77, green: 0.85, blue: 0.93, alpha: 1))
                clipping.frame.origin = CGPoint(x: x, y: y + 190)
                clipping.layer?.masksToBounds = true
                let model = NotchPresentationModel(alwaysShowQuota: false)
                model.animationsEnabled = false
                model.configure(layout)
                model.setVisible(true)
                model.setEnvironment(reduceMotion: true, reduceTransparency: true, lowPower: true)
                model.update(quota, tasksEnabled: true)
                model.updateResetNews(newsForCount(count))
                if state == .peek { model.hover(true) }
                if state == .expanded { model.openResetForecasts() }
                retainedModels.append(model)
                let host = NotchHostingView(model: model, bridge: NotchGeometryBridge())
                host.frame = CGRect(x: clipping.bounds.midX - layout.markX(left: false), y: 0,
                    width: layout.windowFrame.width, height: layout.windowFrame.height)
                clipping.addSubview(host)
                canvas.addSubview(clipping)
            }
        }
        let stage = window(canvas)
        defer { stage.orderOut(nil) }
        pump()
        try save(canvas, "09-reset-forecast-counts.png")
        withExtendedLifetime(retainedModels) {}
    }

    static func forecastIcon() throws {
        let canvas = PreviewCanvas(size: NSSize(width: 500, height: 170), color: .white)
        for (size, x): (CGFloat, CGFloat) in [(96, 46), (18, 287)] {
            let image = NSImageView(frame: CGRect(x: x, y: (130 - size) / 2, width: size, height: size))
            image.image = ResetForecastIndicator.image(size: size)
            image.contentTintColor = .labelColor
            image.imageScaling = .scaleProportionallyUpOrDown
            canvas.addSubview(image)
        }
        canvas.addSubview(annotation("放大查看 · 96 pt", frame: CGRect(x: 46, y: 138, width: 180, height: 20)))
        canvas.addSubview(annotation("实际图标 · 18 pt", frame: CGRect(x: 252, y: 138, width: 180, height: 20)))
        let stage = window(canvas)
        defer { stage.orderOut(nil) }
        try save(canvas, "10-reset-forecast-icon.png")
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let originalDefaults = DisplayLanguage.defaults
        DisplayLanguage.defaults = PreviewDefaults()
        DisplayLanguage.current = .chinese
        defer { DisplayLanguage.defaults = originalDefaults }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try quiet()
        try touchBar()
        try notch()
        try messageList()
        try popover()
        try settings()
        try states()
        try notifications()
        try forecastCountMatrix()
        try forecastIcon()
        print("PASS: 10 native UI previews; fixture data only, no network or system notification requests.")
    }
}
