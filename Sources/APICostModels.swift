import Foundation

struct APICostPeriod: Equatable {
    let start: Date
    let end: Date

    static func month(containing date: Date) -> APICostPeriod {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        return APICostPeriod(start: start, end: calendar.date(byAdding: .month, value: 1, to: start)!)
    }

    var title: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: start) + " · UTC"
    }
}

struct APICostSnapshot: Equatable {
    let period: APICostPeriod
    let queryEnd: Date
    let fetchedAt: Date
    /// nil means a complete response contained no cost records, not a confirmed zero.
    let amount: Decimal?
    /// Aggregate response shape only; never contains credentials or billing entries.
    var responseCounts: APICostResponseCounts? = nil

    var emptyResponseDiagnostic: String? {
        guard amount == nil, let responseCounts else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "接口返回空记录（HTTP 200）：\(responseCounts.pages) 页，\(responseCounts.buckets) 个时间桶，\(responseCounts.records) 条费用记录。\n查询范围（UTC）：\(formatter.string(from: period.start)) 至 \(formatter.string(from: queryEnd))（不含结束时刻）。"
    }

    func amountText(language: DisplayLanguage) -> String {
        guard let amount else { return language.text("暂无消费记录", "No cost records") }
        if amount > 0 && amount < Decimal(string: "0.01")! { return "< US$0.01" }
        if amount < 0 && amount > Decimal(string: "-0.01")! { return "− < US$0.01" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        guard let value = formatter.string(from: NSDecimalNumber(decimal: amount < 0 ? -amount : amount)) else { return "—" }
        return (amount < 0 ? "−US$" : "US$") + value
    }
}

struct APICostResponseCounts: Equatable {
    let pages: Int
    let buckets: Int
    let records: Int
}

enum APICostError: Error, Equatable {
    case authentication, permission, rateLimited(Date?), network, timeout, invalidData, service, credentialStorage

    var requiresRepair: Bool { self == .authentication || self == .permission || self == .credentialStorage }
    func message(language: DisplayLanguage) -> String {
        switch self {
        case .authentication: return language.text("接入密钥失效，请在设置中更换。", "Key invalid. Replace it in settings.")
        case .permission: return language.text("无费用查询权限，请使用 Admin API key。", "Costs access denied. Use an Admin API key.")
        case .rateLimited: return language.text("请求受限，请稍后重试。", "Rate limited. Try again later.")
        case .network: return language.text("无法连接服务，请检查网络。", "Connection failed. Check your network.")
        case .timeout: return language.text("获取超时，请稍后重试。", "Request timed out. Try again later.")
        case .invalidData: return language.text("费用数据不完整，未更新统计。", "Incomplete cost data. Totals were not updated.")
        case .service: return language.text("费用服务暂不可用。", "Costs service temporarily unavailable.")
        case .credentialStorage: return language.text("无法访问本机钥匙串，请在设置中重试。", "Keychain unavailable. Retry in settings.")
        }
    }
}

struct APICostViewState: Equatable {
    var enabled = false
    var configured = false
    var refreshing = false
    var validating = false
    var period = APICostPeriod.month(containing: Date())
    var snapshot: APICostSnapshot?
    var error: APICostError?
    var validationError: APICostError?
    var canRefresh = false
    var isStale = false
    var visible: Bool { enabled && configured }
    func amountText(language: DisplayLanguage) -> String {
        guard let snapshot, snapshot.period == period else { return "—" }
        return snapshot.amountText(language: language)
    }
    func detail(language: DisplayLanguage) -> String {
        guard let snapshot, snapshot.period == period else {
            return period.title + " · " + language.text(refreshing ? "正在获取…" : "尚未获取", refreshing ? "Loading…" : "Not fetched")
        }
        let formatter = DateFormatter()
        formatter.locale = language == .chinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        formatter.dateFormat = "MM/dd HH:mm"
        return period.title + " · " + language.text("最近获取 ", "Fetched ") + formatter.string(from: snapshot.fetchedAt)
    }
    func status(language: DisplayLanguage) -> String {
        if let error { return error.message(language: language) + (snapshot == nil ? "" : language.text(" 显示上次统计。", " Showing previous totals.")) }
        if refreshing { return language.text("正在刷新消费…", "Refreshing costs…") }
        if isStale { return language.text("数据可能未更新，请刷新。", "Data may be out of date. Refresh to update.") }
        return language.text("费用统计可能存在延迟。", "Reported costs may be delayed.")
    }

    /// Shared action copy for the compact menu and notch. Retry availability
    /// remains governed by canRefresh, including the server's rate-limit delay.
    func recoveryTitle(language: DisplayLanguage) -> String? {
        guard let error else { return nil }
        switch error {
        case .authentication:
            return language.text("密钥已失效 · 更换密钥…", "Key invalid · Replace key…")
        case .permission:
            return language.text("无查询权限 · 检查权限…", "Access denied · Check permissions…")
        case .credentialStorage:
            return language.text("钥匙串不可用 · 前往设置…", "Keychain unavailable · Open settings…")
        case .network:
            return language.text("连接失败 · 重试", "Connection failed · Retry")
        case .timeout:
            return language.text("获取超时 · 重试", "Request timed out · Retry")
        case .service:
            return language.text("服务不可用 · 重试", "Service unavailable · Retry")
        case .invalidData:
            return language.text("数据异常 · 重试", "Invalid data · Retry")
        case .rateLimited:
            return language.text("请求受限 · 稍后重试", "Rate limited · Retry later")
        }
    }
}

protocol APICostCancellation: AnyObject { func cancel() }
protocol APICostFetching: AnyObject {
    /// Caller and completion are on the main queue. Only sanitized errors escape.
    func fetch(key: String, period: APICostPeriod, end: Date,
               completion: @escaping (Result<APICostSnapshot, APICostError>) -> Void) -> APICostCancellation
}
