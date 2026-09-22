import Foundation
import ResetNewsCore

enum ResetNewsCheckStatus: String, Equatable {
    case idle, checking, success, partial, stale, failure, codexNotRunning, disabled

    var label: String {
        switch self {
        case .idle: return "已暂停检查预告"
        case .checking: return "正在检查重置预告"
        case .success: return "预告检查成功"
        case .partial: return "部分预告来源获取失败"
        case .stale: return "预告来源副本已过期"
        case .failure: return "预告检查失败"
        case .codexNotRunning: return "等待 Codex 启动"
        case .disabled: return "重置预告已关闭"
        }
    }
}

struct ResetNewsViewState: Equatable {
    var enabled = false
    var status: ResetNewsCheckStatus = .disabled
    var items: [ResetNewsItem] = []
    var readIDs: Set<String> = []
    var lastAttempt: Date?
    var lastSuccess: Date?
    var nextCheck: Date?
    var detail: String?
    var notificationPermission: ResetNewsNotificationPermission = .notRequested

    var forecastCount: Int { items.count }
    var unreadCount: Int { items.filter { !readIDs.contains($0.id) }.count }
    var latestUnread: ResetNewsItem? { items.first { !readIDs.contains($0.id) } }
    var statusText: String { detail.map { status.label + " · " + $0 } ?? status.label }
}

enum ResetNewsSchedule {
    static let minimumInterval: TimeInterval = 60

    static func failureDelay(_ failures: Int) -> TimeInterval {
        let delays: [TimeInterval] = [60, 120, 240, 480, 900]
        return delays[min(max(failures - 1, 0), delays.count - 1)]
    }

    static func successDelay(jitter: Double) -> TimeInterval {
        120 + min(max(jitter, 0), 1) * 12
    }
}
