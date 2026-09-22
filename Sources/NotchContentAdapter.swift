import AppKit

/// Presentation only; all authority, coverage, completion, quota and token rules
/// come from the existing application snapshot. No extra fetchers or task inference.
struct NotchContentAdapter {
    let state: RateLimitDisplayState
    let tasksEnabled: Bool
    let metrics: [HUDMetric]
    let task: NotchTaskPresentation
    let updated: String
    private let weeklyPeekDate: (short: String, full: String)
    var isRefreshing: Bool { state.isRefreshing }
    var hasError: Bool { state.errorMessage != nil }
    var taskTitle: String { tasksEnabled ? task.title : DisplayLanguage.text("任务监测已关闭", "Task monitoring off") }
    var taskDetail: String {
        guard tasksEnabled else { return DisplayLanguage.text("开启任务展示后可查看本机监测状态。", "Enable task display to view local monitoring status.") }
        return state.taskStatus?.detail ?? task.note ?? DisplayLanguage.text("任务数量未知。", "Task count is unknown.")
    }
    var errorSummary: String? {
        guard hasError else { return nil }
        return metrics.isEmpty ? DisplayLanguage.text("连接异常 · 暂无额度数据", "Offline · no quota data")
            : DisplayLanguage.text("连接异常 · 以下为上次数据", "Offline · last known values")
    }
    init(_ state: RateLimitDisplayState, tasksEnabled: Bool) {
        self.state = state
        self.tasksEnabled = tasksEnabled
        metrics = HUDMetric.rows(for: state)
        task = NotchTaskPresentation(state.taskStatus, enabled: tasksEnabled)
        weeklyPeekDate = Self.weeklyPeekDate(state.weekly)
        updated = state.isRefreshing ? DisplayLanguage.text("刷新中…", "Refreshing…") : state.lastUpdated.map {
            DisplayLanguage.text("更新于 ", "Updated ") + DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short)
        } ?? DisplayLanguage.text("尚未更新", "Not updated")
    }
    func peek(left: Bool) -> (value: String, detail: String, help: String) {
        let row: HUDMetric?
        if left { row = state.fiveHour != nil || (state.resetCredits?.availableCount ?? 0) > 0 ? metrics.first : nil }
        else { row = state.weekly != nil ? metrics.last : nil }
        guard let row else {
            let value = left ? "5h —" : "7d —"
            let detail = DisplayLanguage.text("暂无数据", "No data")
            return (value, detail, value + " · " + detail)
        }
        if left { return (row.compact, row.date, row.compact + " · " + row.date) }
        return (row.compact, weeklyPeekDate.short, row.title + " " + row.value + " · " + weeklyPeekDate.full)
    }

    private static func weeklyPeekDate(_ meter: LimitMeter?) -> (short: String, full: String) {
        let missing = (DisplayLanguage.text("重置 --", "Resets —"), DisplayLanguage.text("重置时间未知", "Reset time unknown"))
        guard let date = meter?.resetDate, date.timeIntervalSince1970.isFinite else { return missing }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "MM/dd HH:mm"
        let short = formatter.string(from: date)
        guard !short.isEmpty else { return missing }
        formatter.dateFormat = DisplayLanguage.text("yyyy年MM月dd日 HH:mm", "yyyy-MM-dd HH:mm")
        let full = formatter.string(from: date)
        guard !full.isEmpty else { return missing }
        return (short, DisplayLanguage.text(full + " 重置", "Resets " + full))
    }
}
