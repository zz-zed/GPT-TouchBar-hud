import AppKit
import ResetNewsCore

/// Interactive fixture only: no AppDelegate, account client, monitors, or settings writes.
@main
struct StatusMenuPreviewMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        DisplayLanguage.defaults = UserDefaults(suiteName: "StatusMenuPreview." + UUID().uuidString)!
        let delegate = StatusMenuPreviewDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class StatusMenuPreviewDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private let openButton = NSButton(title: "打开模拟菜单", target: nil, action: nil)
    private let scenario = NSSegmentedControl(labels: ["预告 0 条", "预告 1 条"], trackingMode: .selectOne, target: nil, action: nil)
    private let feedback = NSTextField(labelWithString: "所有数据均为模拟，操作仅更新此测试窗口。")
    private let menu = NSMenu()
    private let popover = ResetNewsPopoverController()
    private var quota = RateLimitDisplayState.initial
    private var news = ResetNewsViewState(enabled: true, status: .success)
    private var summary: StatusSummaryView!
    private var forecastShortcut: NSMenuItem!
    private var refreshCount = 0
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let now = Date()
        quota.fiveHour = LimitMeter(title: "5小时", shortTitle: "5h", window: .init(usedPercent: 38, windowDurationMins: 300, resetsAt: now.addingTimeInterval(3600).timeIntervalSince1970))
        quota.weekly = LimitMeter(title: "周", shortTitle: "7d", window: .init(usedPercent: 3, windowDurationMins: 10080, resetsAt: now.addingTimeInterval(7 * 86400).timeIntervalSince1970))
        quota.resetCredits = ResetCreditSummary(response: .init(availableCount: 2, credits: [.init(status: "available", expiresAt: now.addingTimeInterval(8 * 86400).timeIntervalSince1970)]))
        quota.tokenUsage = TokenUsageSummary(yesterdayTokens: 1_488_000, cumulativeTokens: 3_470_000_000)
        quota.lastUpdated = now
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 740), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "菜单交互测试（模拟数据）"
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "菜单交互测试（模拟数据）")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.frame = NSRect(x: 24, y: 685, width: 560, height: 28)
        let note = NSTextField(labelWithString: "零条只读；一条可查看预告。⌘R 刷新，⌘⇧P 查看预告，Escape 返回。")
        note.frame = NSRect(x: 24, y: 650, width: 570, height: 24)
        note.font = .systemFont(ofSize: 12)
        scenario.frame = NSRect(x: 24, y: 605, width: 260, height: 30)
        scenario.selectedSegment = 0
        scenario.target = self; scenario.action = #selector(changeScenario)
        openButton.frame = NSRect(x: 310, y: 605, width: 190, height: 30)
        openButton.bezelStyle = .rounded
        openButton.target = self; openButton.action = #selector(openMenu)
        feedback.frame = NSRect(x: 24, y: 544, width: 560, height: 38)
        feedback.font = .systemFont(ofSize: 12); feedback.textColor = .secondaryLabelColor
        for view in [title, note, scenario, openButton, feedback] { window.contentView?.addSubview(view) }
        summary = StatusSummaryView(state: quota)
        summary.update(quota, news: news)
        summary.onRefresh = { [weak self] in self?.simulateRefresh() }
        summary.onForecast = { [weak self] in self?.openForecast() }
        let summaryItem = NSMenuItem(); summaryItem.view = summary
        menu.delegate = self
        menu.addItem(summaryItem); menu.addItem(.separator())
        let shortcut = item("刷新额度", action: #selector(refreshShortcut), key: "r")
        shortcut.isHidden = true; shortcut.allowsKeyEquivalentWhenHidden = true
        menu.addItem(shortcut)
        forecastShortcut = item("查看重置预告", action: #selector(forecastFromShortcut), key: "p")
        forecastShortcut.keyEquivalentModifierMask = [.command, .shift]
        forecastShortcut.isHidden = true
        forecastShortcut.allowsKeyEquivalentWhenHidden = true
        forecastShortcut.isEnabled = news.forecastCount > 0
        menu.addItem(forecastShortcut)
        menu.addItem(item("测试菜单操作", action: #selector(testAction)))
        let settings = NSMenuItem(title: "显示与偏好（模拟）", action: nil, keyEquivalent: "")
        settings.submenu = NSMenu()
        settings.submenu?.addItem(item("模拟设置…", action: #selector(testAction), key: ","))
        settings.submenu?.addItem(item("模拟显示形式", action: #selector(testAction)))
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(item("退出测试", action: #selector(quit), key: "q"))
        popover.model.onCheck = { [weak self] in self?.feedback.stringValue = "已点击检查预告（模拟，未发起请求）。" }
        popover.model.onSettings = { [weak self] in self?.feedback.stringValue = "已点击预告设置（模拟，未改变配置）。" }
        popover.model.onVisibleItem = { [weak self] id in
            guard let self else { return }
            self.news.readIDs.insert(id)
            self.popover.update(self.news)
        }
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
    @objc private func changeScenario() {
        popover.close()
        news.items = scenario.selectedSegment == 1 ? [fixture()] : []
        news.readIDs = []
        summary.update(quota, news: news)
        forecastShortcut.isEnabled = news.forecastCount > 0
        feedback.stringValue = scenario.selectedSegment == 1 ? "预告 1 条：整组可点击，详情中可返回菜单。" : "预告 0 条：只读状态，无箭头或点击响应，预告快捷键禁用。"
    }
    private func fixture() -> ResetNewsItem {
        let now = Date()
        return ResetNewsItem(id: "status-menu-preview-fixture", sources: [.feed], originalText: "菜单交互测试的模拟预告，不代表真实公告。",
            facts: [.init(kind: .upcomingReset, scope: "模拟数据", effectiveAt: now.addingTimeInterval(86400))], publishedAt: now, firstSeenAt: now)
    }
    @objc private func openMenu() {
        popover.close()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: openButton.bounds.minY), in: openButton)
    }
    func menuWillOpen(_ menu: NSMenu) {
        summary.update(quota, news: news)
        forecastShortcut.isEnabled = news.forecastCount > 0
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === forecastShortcut { return news.forecastCount > 0 }
        if menuItem.action == #selector(refreshShortcut) { return !quota.isRefreshing }
        return true
    }
    @objc private func forecastFromShortcut() { openForecast() }
    private func openForecast() {
        guard news.forecastCount > 0 else { return }
        menu.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.popover.update(self.news)
            self.popover.show(relativeTo: self.openButton, onBack: { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in self?.openMenu() }
            })
        }
    }
    @objc private func refreshShortcut() { simulateRefresh() }
    private func simulateRefresh() {
        guard !quota.isRefreshing else { return }
        refreshCount += 1
        quota.isRefreshing = true; summary.update(quota, news: news)
        feedback.stringValue = "模拟刷新第 \(refreshCount) 次（持续 2 秒），未读取账号。"
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.quota.isRefreshing = false; self.quota.lastUpdated = Date()
            self.summary.update(self.quota, news: self.news)
            self.feedback.stringValue = "第 \(self.refreshCount) 次模拟刷新完成。"
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
    @objc private func testAction(_ sender: NSMenuItem) { feedback.stringValue = "已触发：\(sender.title)（仅模拟）。" }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { refreshTimer?.invalidate(); popover.close() }
}
