import AppKit

/// Presentation only; all authority, coverage, completion, quota and token rules
/// come from the existing application snapshot. No extra fetchers or task inference.
struct NotchContentAdapter {
    let context: PresentationContext
    private var language: DisplayLanguage { context.language }
    let state: RateLimitDisplayState
    let tasksEnabled: Bool
    let metrics: [HUDMetric]
    let task: NotchTaskPresentation
    let updated: String
    private let weeklyPeekDate: (short: String, full: String)
    var isRefreshing: Bool { state.isRefreshing }
    var hasError: Bool { state.errorMessage != nil }
    var taskTitle: String { tasksEnabled ? task.title : context.text("任务监测已关闭", "Task monitoring off") }
    var taskDetail: String {
        guard tasksEnabled else { return context.text("开启任务展示后可查看本机监测状态。", "Enable task display to view local monitoring status.") }
        return state.taskStatus?.detail(language: context.language) ?? task.note ?? context.text("任务数量未知。", "Task count is unknown.")
    }
    var errorSummary: String? {
        guard hasError else { return nil }
        return metrics.isEmpty ? context.text("连接异常 · 暂无额度数据", "Offline · no quota data")
            : context.text("连接异常 · 以下为上次数据", "Offline · last known values")
    }
    init(_ state: RateLimitDisplayState, tasksEnabled: Bool, metrics: [HUDMetric]? = nil,
         context: PresentationContext = PresentationContext()) {
        self.context = context
        self.state = state
        self.tasksEnabled = tasksEnabled
        self.metrics = metrics ?? HUDMetric.rows(for: state, context: context)
        task = NotchTaskPresentation(state.taskStatus, enabled: tasksEnabled, language: context.language)
        weeklyPeekDate = Self.weeklyPeekDate(state.weekly, context: context)
        updated = state.isRefreshing ? context.text("刷新中…", "Refreshing…") : state.lastUpdated.map {
            context.text("更新于 ", "Updated ") + Self.updateTime($0, context: context)
        } ?? context.text("尚未更新", "Not updated")
    }
    /// Compare what the renderer consumes, excluding diagnostic timestamps and IDs.
    func hasSamePresentation(as other: Self) -> Bool {
        language == other.language && tasksEnabled == other.tasksEnabled &&
        metrics == other.metrics && task == other.task && taskDetail == other.taskDetail &&
        updated == other.updated && isRefreshing == other.isRefreshing &&
        state.errorMessage == other.state.errorMessage &&
        weeklyPeekDate == other.weeklyPeekDate &&
        state.fiveHour == other.state.fiveHour &&
        state.resetCredits == other.state.resetCredits &&
        state.creditBalance == other.state.creditBalance &&
        state.tokenUsage == other.state.tokenUsage
    }
    func peek(left: Bool) -> (value: String, detail: String, help: String) {
        let row: HUDMetric?
        if left { row = state.fiveHour != nil || (state.resetCredits?.availableCount ?? 0) > 0 ? metrics.first : nil }
        else { row = state.weekly != nil ? metrics.last : nil }
        guard let row else {
            let value = left ? "5h —" : "7d —"
            let detail = context.text("暂无数据", "No data")
            return (value, detail, value + " · " + detail)
        }
        if left { return (row.compact, row.date, row.compact + " · " + row.date) }
        return (row.compact, weeklyPeekDate.short, row.title + " " + row.value + " · " + weeklyPeekDate.full)
    }

    private static func updateTime(_ date: Date, context: PresentationContext) -> String {
        let formatter = DateFormatter(); formatter.timeStyle = .short
        formatter.calendar = context.calendar; formatter.timeZone = context.calendar.timeZone
        return formatter.string(from: date)
    }
    private static func weeklyPeekDate(_ meter: LimitMeter?, context: PresentationContext) -> (short: String, full: String) {
        let missing = (context.text("重置 --", "Resets —"), context.text("重置时间未知", "Reset time unknown"))
        guard let date = meter?.resetDate, date.timeIntervalSince1970.isFinite else { return missing }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = context.calendar
        formatter.timeZone = context.calendar.timeZone
        formatter.dateFormat = "MM/dd HH:mm"
        let short = formatter.string(from: date)
        guard !short.isEmpty else { return missing }
        formatter.dateFormat = context.text("yyyy年MM月dd日 HH:mm", "yyyy-MM-dd HH:mm")
        let full = formatter.string(from: date)
        guard !full.isEmpty else { return missing }
        return (short, context.text(full + " 重置", "Resets " + full))
    }
}
