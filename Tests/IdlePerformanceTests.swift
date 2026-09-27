import AppKit

@main
enum IdlePerformanceTests {
    private static var checks = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func main() throws {
        if CommandLine.arguments.contains("app-server") { try fixtureServer(); return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "GPTTouchBarHUD.idle-tests." + UUID().uuidString
        DisplayLanguage.defaults = UserDefaults(suiteName: suite)!
        defer { DisplayLanguage.defaults.removePersistentDomain(forName: suite) }
        DisplayLanguage.current = .chinese
        presentationChecks()
        try framingChecks()
        connectionChecks()
        print("PASS: \(checks) idle performance and connection checks")
    }

    private static func presentationChecks() {
        var state = RateLimitDisplayState.initial
        state.lastUpdated = Date(timeIntervalSince1970: 1_800_000_000)
        state.fiveHour = LimitMeter(title: "5 小时", shortTitle: "5h",
            window: RateLimitWindow(usedPercent: 30, windowDurationMins: 300, resetsAt: 1_800_010_000))
        state.taskStatus = TaskStatusSummary(runningCount: 1)
        let summary = StatusSummaryView(state: state)
        let originalLabels = summary.subviews.map(ObjectIdentifier.init)
        let bar = TouchBarRateLimitsView()
        bar.update(with: state)
        let barLayouts = bar.layoutUpdateCount
        let appearance = HUDAppearance(colorChoice: .graphite, backgroundOpacity: 0.94, contentOpacity: 1)
        let hud = CompactQuotaHUDView(initialAppearance: appearance, onRefresh: {}, onClose: {}, contextMenuProvider: { NSMenu() })
        hud.update(with: state)
        let hudLayouts = hud.layoutUpdateCount
        for index in 0..<60 {
            state.taskStatus?.legacyDiagnostics = LegacyTaskDiagnostics(lastSuccessfulCheck: Date(timeIntervalSince1970: Double(index * 60)))
            summary.update(state); bar.update(with: state); hud.update(with: state)
        }
        check(summary.layoutUpdateCount == 1, "60 diagnostic snapshots do not rebuild menu summary")
        check(summary.subviews.map(ObjectIdentifier.init) == originalLabels, "Menu summary retains its label instances")
        check(bar.layoutUpdateCount == barLayouts, "60 diagnostic snapshots do not measure Touch Bar layout")
        check(hud.layoutUpdateCount == hudLayouts, "60 diagnostic snapshots do not measure floating HUD layout")
        state.lastUpdated = state.lastUpdated?.addingTimeInterval(60)
        bar.update(with: state); hud.update(with: state); summary.update(state)
        check(bar.layoutUpdateCount == barLayouts && hud.layoutUpdateCount == hudLayouts,
              "Update time alone does not change quota geometry")
        check(bar.toolTip == state.statusText && hud.toolTip == state.statusText,
              "Metadata still refreshes when layout is unchanged")
        check(summary.layoutUpdateCount == 2 && summary.subviews.map(ObjectIdentifier.init) == originalLabels,
              "Visible summary timestamp updates using existing labels")
        state.taskStatus = nil
        summary.update(state)
        check(summary.subviews.count == originalLabels.count - 1, "Summary removes an obsolete task row")
        state.taskStatus = TaskStatusSummary(runningCount: 1)
        state.isRefreshing = true
        hud.update(with: state)
        check(buttons(hud).first { $0.accessibilityIdentifier() == "hud.refresh" }?.isEnabled == false,
              "Refresh affordance updates independently of quota values")
        DisplayLanguage.current = .english
        bar.update(with: state); hud.update(with: state)
        check(bar.layoutUpdateCount > barLayouts && hud.layoutUpdateCount > hudLayouts,
              "Language changes invalidate presentation with equal business data")
        DisplayLanguage.current = .chinese

        let controller = CompactHUDViewController(initialAppearance: appearance, onRefresh: {}, onClose: {},
            onPresentTouchBar: { false }, contextMenuProvider: { NSMenu() })
        let panel = NSWindow(contentViewController: controller)
        panel.orderOut(nil)
        let floating = controller.view as! CompactQuotaHUDView
        let hiddenLayouts = floating.layoutUpdateCount
        let touchBar = controller.makeQuotaTouchBar()
        let item = controller.touchBar(touchBar, makeItemForIdentifier: touchBar.defaultItemIdentifiers[0]) as! NSCustomTouchBarItem
        let ownedBar = item.view as! TouchBarRateLimitsView
        controller.update(with: state)
        controller.updateMessages(forecastCount: 3, available: true)
        check(floating.layoutUpdateCount == hiddenLayouts, "A hidden floating window defers state rendering")
        check(ownedBar.accessibilityLabel()?.contains("70%") == true,
              "The controller's Touch Bar receives quota updates while its floating window is hidden")
        check(buttons(ownedBar).first?.accessibilityLabel() == ResetForecastIndicator.accessibilityLabel(3),
              "Hidden floating window does not suppress Touch Bar forecast updates")
        controller.prepareToShow()
        check(floating.layoutUpdateCount == hiddenLayouts + 1, "Reopening renders the latest deferred quota once")
        check(floating.messageAnchorView.accessibilityLabel() == ResetForecastIndicator.accessibilityLabel(3),
              "Reopening includes deferred forecast count")
        controller.prepareToShow()
        check(floating.layoutUpdateCount == hiddenLayouts + 1, "Preparing an unchanged window does not repeat quota layout")
    }

    private static func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }

    private static func framingChecks() throws {
        var buffer = AppServerLineBuffer(limit: 4)
        var lines: [Data] = []
        try buffer.append(Data("ab".utf8)) { lines.append($0) }
        try buffer.append(Data("cd\nx\n\n1234\n".utf8)) { lines.append($0) }
        check(lines.map { String(decoding: $0, as: UTF8.self) } == ["abcd", "x", "1234"],
              "Framing handles partial lines, empty lines and batches larger than the per-frame limit")
        check(buffer.pending.isEmpty, "Complete lines release their buffer")
        try buffer.append(Data("1234".utf8)) { _ in }
        do {
            try buffer.append(Data("5".utf8)) { _ in }
            preconditionFailure("Oversized unterminated frame was accepted")
        } catch CodexAppServerError.responseTooLarge {
            check(buffer.pending.isEmpty, "Oversized partial frame releases accumulated bytes")
        }
        do {
            try buffer.append(Data("12345\n".utf8)) { _ in }
            preconditionFailure("Oversized terminated frame was accepted")
        } catch CodexAppServerError.responseTooLarge { checks += 1 }
        try buffer.append(Data("old".utf8)) { _ in }
        buffer.reset()
        lines.removeAll()
        let unicode = Data("新\n".utf8)
        try buffer.append(unicode.prefix(1)) { lines.append($0) }
        try buffer.append(unicode.dropFirst()) { lines.append($0) }
        check(lines == [Data("新".utf8)], "Reset removes old fragments and split UTF-8 remains intact")
    }

    private static func connectionChecks() {
        let client = CodexAppServerClient(executableURL: URL(fileURLWithPath: CommandLine.arguments[0]))
        for index in 0..<6 {
            var result: Result<Void, Error>?
            client.start { result = $0 }
            wait("connection restart \(index)") { result != nil }
            if case .success? = result { checks += 1 }
            else { preconditionFailure("Reconnect failed: \(String(describing: result))") }
            client.stop()
        }
        var started = false
        client.start { result in
            if case .success = result { started = true }
        }
        wait("overflow fixture startup") { started }
        var response: Result<String?, Error>?
        client.readAccountIdentity { response = $0 }
        wait("overflow response") { response != nil }
        if case .failure(let error)? = response, case CodexAppServerError.responseTooLarge = error { checks += 1 }
        else { preconditionFailure("Oversized server output must fail the request explicitly: \(String(describing: response))") }
        client.stop()
    }

    private static func wait(_ phase: String, _ completed: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !completed() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        check(completed(), "Local fixture completed before timeout: \(phase)")
    }

    /// Launched only by this test binary; never contacts the installed app-server.
    private static func fixtureServer() throws {
        while let line = readLine() {
            let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            if request["method"] as? String == "initialize" {
                let response = try JSONSerialization.data(withJSONObject: ["id": request["id"]!, "result": [:]])
                try FileHandle.standardOutput.write(contentsOf: response + Data("\nold-fragment".utf8))
            } else {
                try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
                let chunk = Data(repeating: 0x78, count: 64 * 1024)
                for _ in 0...256 { try FileHandle.standardOutput.write(contentsOf: chunk) }
            }
        }
    }
}
