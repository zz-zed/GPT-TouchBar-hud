import AppKit
#if HUD_SHARED_CORE_TESTS
@testable import HUDCoreTestSupport
#endif

// Shared fixture data; the core model checks always supply synthetic screen bounds.
extension NotchHarness {
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
}
