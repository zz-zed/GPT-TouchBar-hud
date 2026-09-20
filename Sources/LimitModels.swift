import Foundation
import HookCore

enum DisplayLanguage: String, CaseIterable {
    case chinese = "zh", english = "en"
    static var defaults = UserDefaults.standard
    static var current: DisplayLanguage {
        get { DisplayLanguage(rawValue: defaults.string(forKey: "displayLanguage") ?? "zh") ?? .chinese }
        set { defaults.set(newValue.rawValue, forKey: "displayLanguage") }
    }
    static func text(_ chinese: String, _ english: String) -> String {
        current == .chinese ? chinese : english
    }
}

struct GetAccountRateLimitsResponse: Codable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    let rateLimitResetCredits: RateLimitResetCreditsResponse?
}

struct RateLimitSnapshot: Codable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
}

struct CreditsSnapshot: Codable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

struct RateLimitWindow: Codable {
    let usedPercent: Double
    let windowDurationMins: Double?
    let resetsAt: Double?
}

struct RateLimitResetCreditsResponse: Codable {
    let availableCount: Int
    let credits: [RateLimitResetCreditResponse]?
}

struct RateLimitResetCreditResponse: Codable {
    let status: String?
    let expiresAt: Double?
}

struct LimitMeter: Equatable {
    let title: String
    let shortTitle: String
    let usedPercent: Double
    let remainingPercent: Double
    let resetDate: Date?
    let durationMinutes: Double?

    var remainingText: String {
        "\(Int(remainingPercent.rounded()))%"
    }

    var resetText: String {
        guard let resetDate else {
            return DisplayLanguage.text("重置 --", "Reset --")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current

        formatter.dateFormat = DisplayLanguage.text("MM月dd日 HH:mm", "MM/dd HH:mm")

        return formatter.string(from: resetDate) + DisplayLanguage.text(" 重置", "")
    }

    init(title: String, shortTitle: String, window: RateLimitWindow) {
        self.title = title
        self.shortTitle = shortTitle
        self.usedPercent = window.usedPercent
        self.remainingPercent = max(0, min(100, 100 - window.usedPercent))
        self.resetDate = Self.date(fromEpoch: window.resetsAt)
        self.durationMinutes = window.windowDurationMins
    }

    private static func date(fromEpoch value: Double?) -> Date? {
        guard let value else {
            return nil
        }

        let seconds = value > 10_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }
}

struct RateLimitDisplayState: Equatable {
    var taskStatus: TaskStatusSummary? = nil
    var displayedTaskStatus: TaskStatusSummary? {
        taskStatus.flatMap { $0.activity == nil && $0.isIdle ? nil : $0 }
    }
    var fiveHour: LimitMeter?
    var weekly: LimitMeter?
    var resetCredits: ResetCreditSummary?
    var creditBalance: CreditBalanceSummary?
    var tokenUsage: TokenUsageSummary?
    var isRefreshing: Bool
    var lastUpdated: Date?
    var errorMessage: String?

    static let initial = RateLimitDisplayState(
        fiveHour: nil,
        weekly: nil,
        resetCredits: nil,
        creditBalance: nil,
        tokenUsage: nil,
        isRefreshing: false,
        lastUpdated: nil,
        errorMessage: nil
    )

    var statusText: String {
        if let errorMessage {
            return errorMessage
        }

        if isRefreshing {
            return lastUpdated == nil ? "正在读取本机 Codex app-server..." : "正在刷新，保留上一组数据"
        }

        guard let lastUpdated else {
            return "尚未读取额度"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "上次更新 \(formatter.string(from: lastUpdated))"
    }
}

/// Local lifecycle evidence, not a server-authoritative task/goal status.
struct TaskStatusSummary: Equatable {
    // When present, activity is the sole source for display; legacy counts are ignored.
    var activity: TaskActivitySnapshot? = nil
    // Nil preserves legacy/source-only callers; the app always supplies a bounded feedback decision.
    var completionFeedbackVisible: Bool? = nil
    var activityPresentation: HookTaskDisplayAdapter? {
        activity.map { HookTaskDisplayAdapter($0, english: DisplayLanguage.current == .english, showsCompletionFeedback: completionFeedbackVisible ?? true) }
    }
    var hasRunningTasks: Bool { activityPresentation?.hasRunningTasks ?? (runningCount > 0) }
    var runningCount: Int = 0
    var recentlyCompletedCount: Int = 0
    var unknownCount: Int = 0

    var isIdle: Bool {
        if let activityPresentation { return activityPresentation.state == .idle }
        return runningCount == 0 && recentlyCompletedCount == 0 && unknownCount == 0
    }

    var label: String {
        if let activityPresentation { return activityPresentation.label }
        if runningCount > 0 { return DisplayLanguage.text("执行中 \(runningCount)", "Run \(runningCount)") }
        if recentlyCompletedCount > 0 { return DisplayLanguage.text("本轮完成", "Done") }
        return isIdle ? DisplayLanguage.text("空闲", "Idle") : DisplayLanguage.text("状态未知", "Unknown")
    }

    var badge: String {
        if let activityPresentation { return activityPresentation.badge }
        if runningCount > 0 { return runningCount > 9 ? "9+" : "\(runningCount)" }
        return recentlyCompletedCount > 0 ? "✓" : (isIdle ? "" : "?")
    }

    var detail: String {
        if let activityPresentation { return activityPresentation.detail }
        return "本机近期任务：Running \(runningCount)，Done \(recentlyCompletedCount)，未知 \(unknownCount)。仅根据本地日志推断；不代表整个目标完成，也不区分等待授权与工具执行。"
    }
}

struct CreditBalanceSummary: Equatable {
    let balance: Decimal

    var displayText: String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2

        let value = formatter.string(from: NSDecimalNumber(decimal: balance)) ?? "0.00"
        return "还剩点数：US$\(value)"
    }

    init?(response: CreditsSnapshot) {
        guard
            response.hasCredits,
            !response.unlimited,
            let rawBalance = response.balance,
            let balance = Decimal(string: rawBalance, locale: Locale(identifier: "en_US_POSIX")),
            balance > 0
        else {
            return nil
        }

        self.balance = balance
    }
}

struct ResetCreditSummary: Equatable {
    let availableCount: Int
    let earliestExpirationDate: Date?

    var compactText: String {
        DisplayLanguage.text("重置 \(availableCount)次", "Reset \(availableCount)")
    }

    var availableText: String {
        DisplayLanguage.text("可用 \(availableCount) 次", "\(availableCount) left")
    }

    var expirationText: String {
        guard let earliestExpirationDate else {
            return DisplayLanguage.text("到期 --", "Exp --")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = DisplayLanguage.text("MM月dd日 HH:mm", "MM/dd HH:mm")
        return formatter.string(from: earliestExpirationDate) + DisplayLanguage.text(" 到期", "")
    }

    init(response: RateLimitResetCreditsResponse) {
        availableCount = max(0, response.availableCount)
        earliestExpirationDate = response.credits?
            .filter { $0.status == nil || $0.status == "available" }
            .compactMap { credit in
                guard let value = credit.expiresAt else {
                    return nil
                }
                let seconds = value > 10_000_000_000 ? value / 1000 : value
                return Date(timeIntervalSince1970: seconds)
            }
            .min()
    }
}

struct TokenUsageSummary: Equatable {
    let yesterdayTokens: Int?
    let cumulativeTokens: Int?
    var isStale = false
    var status: String? = nil
    var updatedAt: Date? = nil

    var yesterdayText: String {
        DisplayLanguage.text("昨日 ", "Yday ") + (yesterdayTokens.map(Self.formatDaily) ?? "--") + (isStale && yesterdayTokens != nil ? "*" : "")
    }

    var cumulativeText: String {
        DisplayLanguage.text("累计 ", "Total ") + (cumulativeTokens.map { DisplayLanguage.current == .english ? Self.formatCompactTokens($0) : "\(Self.formatted(Double($0) / 100_000_000)) 亿" } ?? "--") + (isStale && cumulativeTokens != nil ? "*" : "")
    }

    var toolTip: String {
        var text = "GPT 账号 Token 统计；缺失项显示 --，* 表示旧数据。"
        if let updatedAt {
            text += "\n上次更新：" + DateFormatter.localizedString(from: updatedAt, dateStyle: .short, timeStyle: .medium)
        }
        if let status { text += "\n" + status }
        return text
    }

    private static func formatDaily(_ tokens: Int) -> String {
        if DisplayLanguage.current == .english { return formatCompactTokens(tokens) }
        if tokens < 10_000 { return "\(tokens) 个" }
        if tokens >= 99_999_500 { return "\(formatted(Double(tokens) / 100_000_000)) 亿" }
        return "\(formatted(Double(tokens) / 10_000)) 万"
    }

    private static func formatCompactTokens(_ tokens: Int) -> String {
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (divisor, suffix) in units {
            if Double(tokens) >= divisor * 0.99995 {
                let value = Double(tokens) / divisor
                return String(format: "%.1f", value) + suffix
            }
        }
        return "\(tokens)"
    }

    private static func formatted(_ value: Double) -> String {
        if value >= 10 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.2f", value)
    }
}
