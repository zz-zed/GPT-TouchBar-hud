import AppKit
import Combine

extension NotchHarness {
    static func interactionAndRenderingChecks(_ controller: NotchIslandController) throws {
        let model = controller.model, layout = model.layout!
        let frame = controller.panel.frame
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Fixed cursor at the current expanded edge. No mouse movement is generated.
        let edge = CGPoint(x: frame.midX + layout.expandedSize.width / 2 - 12, y: frame.maxY - 80)
        controller.interaction.mouseLocation = { edge }
        model.hover(true)
        controller.interaction.start()
        controller.interaction.updateRouting()
        check(!controller.panel.ignoresMouseEvents, "expanded edge currently receives input")
        model.collapse()
        pump(0.08)
        try snapshot(controller, "closing-080ms")
        pump(0.40)
        check(controller.panel.ignoresMouseEvents, "stationary pointer becomes click-through as shell shrinks")
        check(model.state == .compact, "stationary cursor outside shrunken shell remains collapsed")
        controller.interaction.stop()
        model.click(); pump(0.09)
        let beforeReverse = controller.bridge.snapshot!.size
        model.collapse()
        check(controller.bridge.snapshot!.size == beforeReverse, "reverse starts from current presented size")
        pump(0.05)
        let reversing = controller.bridge.snapshot!.size
        model.click()
        check(controller.bridge.snapshot!.size == reversing, "second reversal never snaps to Compact endpoint")
        let generation = model.scheduler.generation
        var refreshed = sample; refreshed.isRefreshing = true
        model.update(refreshed, tasksEnabled: true)
        check(model.scheduler.generation == generation && model.state == .expanded, "refresh during native animation preserves generation")
        pump(0.70)
        check(model.detailsVisible && model.state == .expanded, "interrupted animation settles with details")
        check(abs(controller.bridge.snapshot!.size.height - layout.expandedSize.height) < 0.05, "reversed geometry converges to expanded height")
        let camera = CGPoint(x: frame.midX, y: frame.maxY - 10)
        controller.interaction.mouseLocation = { camera }
        controller.interaction.start(); controller.interaction.updateRouting()
        check(controller.panel.ignoresMouseEvents, "AppKit camera exclusion passes through")
        model.hover(true)
        check(model.state == .expanded, "camera crossing preserves Expanded")
        model.beginMenu(); model.hover(false); pump(0.1)
        check(model.state == .expanded, "native menu lease prevents hover collapse")
        model.endMenu()
        pump(0.45)
        controller.interaction.stop()
        model.click(); pump(0.7)
        for page in NotchDetailPage.allCases {
            let oldSize = controller.bridge.snapshot!.size
            model.selectPage(page); pump(0.40)
            check(abs(controller.bridge.snapshot!.size.width - oldSize.width) < 0.05 && abs(controller.bridge.snapshot!.size.height - oldSize.height) < 0.05 && controller.panel.frame == frame, "\(page) page change does not move shell")
            try snapshot(controller, "page-\(page.rawValue)")
        }
        model.click(); controller.hide(); pump(0.35)
        check(!controller.panel.isVisible && !model.visible && !model.detailsMounted, "hide blocks delayed content and window resurrection")
        check(controller.panel.ignoresMouseEvents, "hidden carrier ignores all mouse events")
        check(controller.show(in: fixture()), "hidden controller reopens")
        controller.interaction.stop(); pump(0.1)
        check(model.state == model.restingState && !model.detailsMounted, "reopen respects resting state")
        check(controller.bridge.snapshot != nil, "reopen republishes geometry after epoch invalidation")
        model.click(); pump(0.05); controller.environmentChanged(); pump(0.4)
        controller.interaction.stop()
        check(model.state == model.restingState && !model.detailsMounted, "environment change cancels old content callbacks")
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID && !controller.panel.isKeyWindow, "refresh/pages/lifecycle preserve foreground focus")
        check(NSApp.activationPolicy() == .accessory, "native harness preserves accessory activation policy")
        if #available(macOS 12.0, *) {
            var publications = 0
            let observer = model.objectWillChange.sink {
                check(Thread.isMainThread, "power notification publishes UI state on main thread")
                publications += 1
            }
            DispatchQueue.global().async {
                NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: ProcessInfo.processInfo)
            }
            pump(0.06)
            check(publications > 0, "background power notification reaches main-queue observer")
            observer.cancel()
        }
        let facade = NotchHUDController(useLegacy: false)
        check(facade.island != nil, "default facade creates island renderer")
        let fallback = NotchHUDController(useLegacy: true)
        check(fallback.island == nil, "legacy launch switch creates no island window")
        facade.hide(); fallback.hide()
    }
}

extension NotchHarness {
    static func renderedContentChecks(_ controller: NotchIslandController) throws {
        controller.interaction.stop()
        controller.model.animationsEnabled = false
        controller.model.setEnvironment(reduceMotion: true, reduceTransparency: true, lowPower: true)
        let small = fixture(CGRect(x: 120, y: 80, width: 400, height: 600))
        check(controller.show(in: small, visibleTopDelta: 25), "narrow display presents bounded native content")
        controller.model.setVisible(true)
        var long = sample
        long.fiveHour = nil
        long.resetCredits = ResetCreditSummary(response: RateLimitResetCreditsResponse(availableCount: 999999, credits: nil))
        long.taskStatus = TaskStatusSummary(runningCount: 999999, unknownCount: 123456)
        long.tokenUsage = TokenUsageSummary(yesterdayTokens: 999999999999, cumulativeTokens: 999999999999999, isStale: true,
            status: String(repeating: "Long source diagnostic / 覆盖范围待确认。", count: 12))
        long.errorMessage = String(repeating: "Connection error / 服务不可用。", count: 12)
        for language in DisplayLanguage.allCases {
            DisplayLanguage.current = language
            for (name, state, enabled) in [("missing", RateLimitDisplayState.initial, true), ("disabled", sample, false), ("long-stale", long, true)] {
                controller.model.update(state, tasksEnabled: enabled)
                controller.model.click()
                pump(0.04)
                for page in NotchDetailPage.allCases {
                    controller.model.selectPage(page); pump(0.04)
                    check(controller.bridge.snapshot?.size == controller.model.layout?.expandedSize, "narrow \(language.rawValue)/\(name)/\(page) retains bounded shell")
                    try syntheticSnapshot(controller, "narrow-\(language.rawValue)-\(name)-\(page.rawValue)")
                }
            }
        }
        DisplayLanguage.current = .chinese
        controller.hide()
        check(!controller.show(in: nil), "missing notch geometry safely declines presentation")
    }
}

extension NotchHarness {
    static func nativeMenuChecks(_ controller: NotchIslandController) {
        let model = controller.model
        controller.interaction.stop()
        model.animationsEnabled = false
        model.update(sample, tasksEnabled: true)
        model.click(); pump(0.1)
        model.click(); model.hover(true); pump(0.04)
        let menu = controller.host.contextMenuProvider!()
        let timer = Timer(timeInterval: 0.12, repeats: false) { _ in
            check(model.menuDepth == 1, "real NSMenu delegate acquires hover hold")
            model.hover(false)
            check(model.state == .expanded, "real open NSMenu keeps island expanded outside surface")
            menu.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .common)
        _ = menu.popUp(positioning: nil, at: CGPoint(x: 180, y: 70), in: controller.host)
        timer.invalidate()
        check(model.menuDepth == 0, "real NSMenu close releases hover hold")
        check(model.state == model.restingState, "menu close outside returns to rest")
    }
}
