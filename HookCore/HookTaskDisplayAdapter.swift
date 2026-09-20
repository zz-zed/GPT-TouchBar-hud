import Foundation

public enum HookTaskDisplayState: Sendable { case running, submitted, unknown, completed, idle }

/// Every surface uses this same interpretation. Pending may overlap running; never sum the counts.
public struct HookTaskDisplayAdapter {
    public let snapshot: TaskActivitySnapshot
    public let english: Bool
    public init(_ snapshot: TaskActivitySnapshot, english: Bool = false) { self.snapshot = snapshot; self.english = english }
    public var hasRunningTasks: Bool { snapshot.confirmedRunningCount > 0 }
    public var state: HookTaskDisplayState {
        if hasRunningTasks { return .running }
        if snapshot.submittedCount > 0 && snapshot.submittedCount == snapshot.pendingVerificationCount { return .submitted }
        if snapshot.hasUncertainty { return .unknown }
        return snapshot.showsCompletion ? .completed : .idle
    }
    public var badge: String { snapshot.compactText }
    public var label: String {
        switch state {
        case .running: return (english ? "Run " : "执行中 ") + badge
        case .submitted: return english ? "Confirming start…" : "正在确认开始…"
        case .unknown: return english ? "Task count unconfirmed" : "任务数量待核对"
        case .completed: return english ? "Recently completed" : "最近完成"
        case .idle: return english ? "No active tasks in scope" : "接入范围内暂无执行中任务"
        }
    }
    public var detail: String {
        let counts = english
            ? "Local connected tasks: \(snapshot.confirmedRunningCount) confirmed running; \(snapshot.pendingVerificationCount) pending verification (may overlap running); \(snapshot.recentlyCompletedCount) recently completed."
            : "本机已接入任务：已确认运行 \(snapshot.confirmedRunningCount) 个；待核对 \(snapshot.pendingVerificationCount) 个（可与运行数重叠）；最近完成 \(snapshot.recentlyCompletedCount) 个。"
        let gaps = snapshot.coverage.gaps.sorted { $0.rawValue < $1.rawValue }.map { gapDescription($0) }.joined(separator: "、")
        let coverage = snapshot.coverage.isComplete ? (english ? "Scope complete." : "接入范围内无已知缺口。")
            : (english ? "Coverage gaps: " : "覆盖缺口：") + gaps + "。"
        let health = snapshot.sourceHealth.map { ($0.source == "codexLocal" ? "Codex" : (english ? "Task source" : "任务来源")) + ": " + healthDescription($0.state) }.joined(separator: "; ")
        return counts + "\n" + coverage + "\n" + health + "\n" + (english ? "Transport health does not establish coverage. Completion refers to a turn, not the whole goal." : "连接正常不代表覆盖完整。完成指当前轮次，不代表整个目标完成。")
    }
    private func gapDescription(_ gap: CoverageGap) -> String {
        if english {
            switch gap {
            case .initialCoverageUnknown: return "Tasks already running at startup have not been fully identified"
            case .capacity: return "Record or connection limit reached"
            case .recoveryBudget: return "Recovery read limit reached"
            case .truncatedLog: return "Part of the log was outside the read limit"
            case .missingLog: return "Matching log unavailable"
            case .invalidPath: return "Log path or permissions could not be verified"
            case .malformedLog: return "Log format could not be verified"
            case .rotatedLog: return "Log rotated or truncated"
            case .orderingConflict: return "Turn order or identity needs verification"
            case .disconnected: return "Connection or host unavailable"
            case .restart: return "State after restart needs verification"
            case .sleep: return "State after sleep needs verification"
            case .staleEvidence: return "Execution evidence is no longer fresh"
            case .protocolError: return "Unsupported or oversized event received"
            }
        }
        switch gap {
        case .initialCoverageUnknown: return "启动前任务范围未确认"
        case .capacity: return "达到记录或连接容量"
        case .recoveryBudget: return "恢复读取达到上限"
        case .truncatedLog: return "日志超出读取范围"
        case .missingLog: return "缺少对应日志"
        case .invalidPath: return "日志路径或权限校验未通过"
        case .malformedLog: return "日志格式无法核对"
        case .rotatedLog: return "日志已轮转或截断"
        case .orderingConflict: return "轮次顺序或归属待核对"
        case .disconnected: return "连接或宿主失联"
        case .restart: return "重启后的状态待核对"
        case .sleep: return "休眠后的状态待核对"
        case .staleEvidence: return "执行证据已过可信观察范围"
        case .protocolError: return "收到不兼容或超限事件"
        }
    }
    private func healthDescription(_ state: HookHealthState) -> String {
        if english {
            switch state {
            case .disabled: return "Disabled"
            case .awaitingEvents: return "Waiting for events; review hook trust in the host"
            case .connected: return "Events received"
            case .degraded: return "Connection needs attention"
            case .unavailable: return "Not connected"
            case .suspended: return "Paused during sleep"
            }
        }
        switch state {
        case .disabled: return "已关闭"
        case .awaitingEvents: return "等待事件；请在宿主审阅信任"
        case .connected: return "已收到事件"
        case .degraded: return "接入异常"
        case .unavailable: return "未连接"
        case .suspended: return "休眠暂停"
        }
    }
}

/// Keep this with the display controller, not a freshly constructed view. First delivery is baseline.
public struct HookCompletionFeedbackTracker {
    private var highWater = Date.distantPast
    private var idsAtHighWater: Set<String> = []
    private var saturated = false
    private var initialized = false
    public init() {}
    public mutating func consume(_ snapshot: TaskActivitySnapshot, now: Date) -> [TaskCompletion] {
        // An occurrence-time watermark rejects late history and replays even after IDs age out.
        let candidates = snapshot.recentCompletions.filter {
            ($0.occurredAt > highWater || ($0.occurredAt == highWater && !saturated && !idsAtHighWater.contains($0.id)))
            && (0..<30).contains(now.timeIntervalSince($0.occurredAt))
        }
        if let newest = snapshot.recentCompletions.map(\.occurredAt).max(), newest > highWater {
            highWater = newest; idsAtHighWater.removeAll(); saturated = false
        }
        for event in snapshot.recentCompletions where event.occurredAt == highWater {
            if idsAtHighWater.count < HookBudget.turns { idsAtHighWater.insert(event.id) }
            else if !idsAtHighWater.contains(event.id) { saturated = true }
        }
        if !initialized {
            initialized = true
            if snapshot.updatedAt > highWater { highWater = snapshot.updatedAt; idsAtHighWater.removeAll(); saturated = false }
            return []
        }
        // A confirmed completion may be secondary to ongoing work under partial coverage.
        // Only a complete, certain, non-running scope can show the primary completion state.
        guard snapshot.confirmedRunningCount > 0 || !snapshot.hasUncertainty else { return [] }
        return saturated ? [] : candidates
    }
}
