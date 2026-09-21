import AppKit
import SwiftUI
import HookCore

@main
enum NotchHarness {
    static var checks: [String] = []
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
        checks.append(message)
    }
    static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.003), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.003))
        } while Date() < deadline
    }
    static func fixture(_ screen: CGRect? = nil, inset: CGFloat = 32, notch: CGFloat = 180) -> NotchHUDGeometry {
        let rect = screen ?? CGRect(x: NSScreen.main!.frame.minX, y: NSScreen.main!.frame.minY,
                                    width: NSScreen.main!.frame.width, height: NSScreen.main!.frame.height - 100)
        return NotchHUDGeometry(screen: rect, topInset: inset,
            leftArea: CGRect(x: rect.minX, y: rect.maxY - inset, width: (rect.width - notch) / 2, height: inset),
            rightArea: CGRect(x: rect.midX + notch / 2, y: rect.maxY - inset, width: (rect.width - notch) / 2, height: inset))!
    }
    static var sample: RateLimitDisplayState {
        var state = RateLimitDisplayState.initial
        state.fiveHour = LimitMeter(title: "5h", shortTitle: "5h", window: RateLimitWindow(usedPercent: 28, windowDurationMins: 300, resetsAt: 1_800_000_000))
        state.weekly = LimitMeter(title: "7d", shortTitle: "7d", window: RateLimitWindow(usedPercent: 57, windowDurationMins: 10080, resetsAt: 1_800_000_000))
        state.taskStatus = TaskStatusSummary(runningCount: 2)
        state.tokenUsage = TokenUsageSummary(yesterdayTokens: 128400, cumulativeTokens: 8620000)
        state.lastUpdated = Date(timeIntervalSince1970: 1_800_000_000)
        return state
    }
    static func snapshot(_ controller: NotchIslandController, _ name: String) throws {
        controller.host.layoutSubtreeIfNeeded()
        controller.host.displayIfNeeded()
        let view = controller.host
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/notch-island/\(name).png"))
    }
    static func animationDiagnostics(_ controller: NotchIslandController, samples: [CGSize]) -> String {
        let model = controller.model
        let heights = samples.map(\.height)
        return "os=\(ProcessInfo.processInfo.operatingSystemVersionString), hostReduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), "
            + "animationsEnabled=\(model.animationsEnabled), reduceMotion=\(model.reduceMotion), state=\(model.state.rawValue), "
            + "visible=\(model.visible)/\(controller.isVisible), panelVisible=\(controller.panel.isVisible), occlusion=\(controller.panel.occlusionState.rawValue), "
            + "target=\(model.size), presented=\(String(describing: controller.bridge.snapshot?.size)), "
            + "samples=\(samples.count), heightRange=\(String(describing: heights.min()))...\(String(describing: heights.max())), "
            + "firstHeights=\(Array(heights.prefix(6))), lastHeights=\(Array(heights.suffix(3)))"
    }
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--click-receiver") { runClickReceiver(arguments: CommandLine.arguments); return }
        let suite = "NotchHarness." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        DisplayLanguage.defaults = defaults
        defer { DisplayLanguage.defaults = .standard; defaults.removePersistentDomain(forName: suite) }
        if !CommandLine.arguments.contains("--preview") {
            // Native interaction checks exercise Compact deliberately; product defaults are checked separately.
            defaults.set(false, forKey: NotchPresentationModel.alwaysShowKey)
            modelChecks()
            geometryChecks()
            contentChecks()
        }
        let controller = NotchIslandController(defaults: defaults, automaticallyTracksMouse: CommandLine.arguments.contains("--preview"))
        defer { controller.hide() }
        controller.model.update(sample, tasksEnabled: true)
        if CommandLine.arguments.contains("--preview") {
            let args = CommandLine.arguments
            func number(_ option: String, _ fallback: CGFloat) -> CGFloat {
                guard let index = args.firstIndex(of: option), index + 1 < args.count, let value = Double(args[index + 1]), value.isFinite else { return fallback }
                return CGFloat(value)
            }
            let screen = NSScreen.main!.frame
            let width = max(400, min(screen.width, number("--width", screen.width)))
            let height = max(480, min(screen.height - 100, number("--height", screen.height - 100)))
            let origin = CGPoint(x: screen.midX - width / 2, y: screen.maxY - 100 - height)
            let inset = max(20, min(80, number("--physical-inset", 32)))
            let notch = max(80, min(width / 2 - 1, number("--notch-width", 180)))
            let g = fixture(CGRect(origin: origin, size: CGSize(width: width, height: height)), inset: inset, notch: notch)
            _ = controller.show(in: g, visibleTopDelta: number("--visual-height", inset) + 1)
            if args.contains("--compact") {
                controller.model.setAlwaysShowQuota(false)
            } else if args.contains("--always-peek") {
                controller.model.setAlwaysShowQuota(true)
            }
            controller.model.setEnvironment(reduceMotion: args.contains("--reduced-motion"), reduceTransparency: args.contains("--reduced-transparency"), lowPower: args.contains("--low-power"))
            if args.contains("--english") { DisplayLanguage.current = .english; controller.model.update(sample, tasksEnabled: true) }
            let layout = controller.model.layout!
            let context = NotchIslandPanel()
            context.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            context.setFrame(layout.windowFrame, display: true)
            context.contentView = NotchSyntheticBackdrop(layout: layout)
            context.orderFrontRegardless()
            let camera = NotchSyntheticCamera(frame: layout.localExclusion)
            controller.host.addSubview(camera)
            if args.contains("--debug-regions") {
                let overlay = NotchRegionOverlay(frame: controller.host.bounds, bridge: controller.bridge)
                controller.host.addSubview(overlay)
                let route = controller.bridge.onChange
                controller.bridge.onChange = { geometry in route?(geometry); overlay.needsDisplay = true }
            }
            controller.model.onHide = { NSApp.terminate(nil) }
            print("Native synthetic-screen preview (no Hook/network/update services). Hover the wings, click to expand, use tabs/right-click menu, move out to collapse. Ctrl-C exits.")
            NSApp.run()
            withExtendedLifetime(context) {}
            return
        }
        // Hosted CI runners enable Reduce Motion/Transparency. Keep this fixture
        // deterministic without changing the user's system accessibility settings.
        controller.model.setEnvironment(reduceMotion: false, reduceTransparency: false, lowPower: false)
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        check(controller.show(in: fixture()), "synthetic geometry presents")
        controller.interaction.stop()
        controller.model.animationsEnabled = false
        controller.model.reset(visible: true)
        pump(0.12)
        let initialFrame = controller.panel.frame
        let layout = controller.model.layout!
        check(!controller.panel.canBecomeKey && !controller.panel.canBecomeMain, "panel cannot take key/main status")
        check(controller.panel.styleMask.contains(.nonactivatingPanel), "nonactivating style retained")
        check(controller.panel.level == .statusBar, "existing window level retained")
        for state in NotchPresentationState.allCases {
            switch state {
            case .compact: controller.model.reset(visible: true)
            case .peek: controller.model.hover(true)
            case .expanded: controller.model.click()
            }
            pump(0.12)
            check(controller.model.state == state, "stable \(state.rawValue) (actual=\(controller.model.state), visible=\(controller.isVisible))")
            check(controller.panel.frame == initialFrame, "\(state.rawValue) preserves carrier frame")
            check(controller.bridge.snapshot?.size == layout.size(for: state), "\(state.rawValue) actual hosting geometry matches")
            try snapshot(controller, "stage1-\(state.rawValue)")
            try syntheticSnapshot(controller, state.rawValue)
        }
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID, "show/hover/expand did not change foreground app")
        check(!controller.panel.isKeyWindow, "expanded panel remains non-key")
        let expanded = controller.bridge.snapshot!
        check(!expanded.acceptsClick(CGPoint(x: expanded.rect.minX + 0.1, y: expanded.rect.maxY - 0.1)), "rounded corner passes through")
        check(!expanded.acceptsClick(CGPoint(x: expanded.rect.minX - 3, y: 40)), "decoration passes through")
        check(!expanded.acceptsClick(CGPoint(x: layout.windowFrame.width / 2, y: 10)), "camera passes through")
        check(expanded.maintainsHover(CGPoint(x: layout.windowFrame.width / 2, y: 10)), "camera retains hover")
        controller.model.animationsEnabled = true
        controller.model.setEnvironment(reduceMotion: true, reduceTransparency: true, lowPower: true)
        controller.model.collapse(animated: false)
        pump(0.05)
        var reducedMotionSamples: [CGSize] = []
        let previous = controller.bridge.onChange
        controller.bridge.onChange = { geometry in previous?(geometry); reducedMotionSamples.append(geometry.size) }
        controller.model.click()
        check(!controller.model.motionEnabled && controller.model.detailsVisible && controller.model.scheduler.pendingCount == 0,
              "native Reduce Motion expansion reveals details without staged callbacks")
        pump(0.12)
        check(controller.bridge.snapshot?.size == layout.expandedSize, "native Reduce Motion expansion publishes final geometry")
        check(!reducedMotionSamples.contains { $0.height > layout.visualBarHeight + 2 && $0.height < layout.expandedSize.height - 2 },
              "native Reduce Motion expansion has no intermediate geometry")
        controller.bridge.onChange = previous
        controller.model.setEnvironment(reduceMotion: false, reduceTransparency: false, lowPower: false)
        controller.model.collapse(animated: false)
        pump(0.05)
        check(controller.model.motionEnabled && controller.model.visible && controller.isVisible,
              "native animation fixture enables motion on a visible panel")
        var samples: [CGSize] = []
        controller.bridge.onChange = { geometry in previous?(geometry); samples.append(geometry.size) }
        controller.model.click()
        pump(0.10)
        try snapshot(controller, "stage1-opening-100ms")
        pump(0.65)
        let hasIntermediateGeometry = samples.contains { $0.height > layout.visualBarHeight + 2 && $0.height < layout.expandedSize.height - 2 }
        if !hasIntermediateGeometry {
            FileHandle.standardError.write(Data(("Native animation failure: " + animationDiagnostics(controller, samples: samples) + "\n").utf8))
        }
        check(hasIntermediateGeometry, "actual SwiftUI animation publishes intermediate geometry")
        check(controller.panel.frame == initialFrame && controller.frameChanges == 1, "animation never resizes NSPanel")
        try interactionAndRenderingChecks(controller)
        nativeMenuChecks(controller)
        let clickResult = try nativeClickChecks(controller)
        try renderedContentChecks(controller)
        let report: [String: Any] = ["checks": checks, "passed": checks.count,
            "animationSamples": samples.map { ["width": $0.width, "height": $0.height] },
            "reducedMotionSamples": reducedMotionSamples.map { ["width": $0.width, "height": $0.height] },
            "hostReduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "hostReduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            "nativeClickDelivery": clickResult,
            "hardware": "synthetic screen geometry; not physical notch acceptance",
            "os": ProcessInfo.processInfo.operatingSystemVersionString]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "build/notch-island/results.json"))
        print("PASS: \(checks.count) native island checks; \(samples.count) presented frames")
        print(clickResult)
    }
}
