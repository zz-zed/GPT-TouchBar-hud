import Foundation

struct AccountTokenUsageResponse: Decodable {
    struct Summary: Decodable { let lifetimeTokens: Int? }
    struct DailyBucket: Decodable { let startDate: String; let tokens: Int }
    let summary: Summary
    let dailyUsageBuckets: [DailyBucket]?

    func display(now: Date, calendar: Calendar, updatedAt: Date, stale: Bool = false,
                 status: String? = nil) -> TokenUsageSummary {
        let day = Self.yesterday(now: now, calendar: calendar)
        let matches = dailyUsageBuckets?.filter { $0.startDate == day } ?? []
        // Missing or duplicate buckets are unknown, not zero; dates are service date labels.
        let yesterday = matches.count == 1 && matches[0].tokens >= 0 ? matches[0].tokens : nil
        let total = summary.lifetimeTokens.flatMap { $0 >= 0 ? $0 : nil }
        return TokenUsageSummary(yesterdayTokens: yesterday, cumulativeTokens: total,
                                 isStale: stale, status: status, updatedAt: updatedAt)
    }

    static func yesterday(now: Date, calendar: Calendar) -> String {
        let date = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

// Main-thread coordinator. Cache is memory-only and discarded on auth/lifecycle changes.
final class AccountTokenUsageStore {
    private let client: AccountUsageClient
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let calendar: () -> Calendar
    private var generation = 0
    private var inFlight = false
    private var identity: String?
    private var cached: AccountTokenUsageResponse?
    private var updatedAt: Date?
    private var nextCheck: TimeInterval = 0
    private var nextFetch: TimeInterval = 0
    private var lastAttempt: TimeInterval?
    private var failures = 0
    private var lastDay: String?
    private var errorStatus: String?
    var onUpdate: ((TokenUsageSummary?) -> Void)?

    init(client: AccountUsageClient, now: @escaping () -> Date = Date.init,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         calendar: @escaping () -> Calendar = { Calendar(identifier: .gregorian) }) {
        self.client = client; self.now = now; self.uptime = uptime; self.calendar = calendar
    }

    func invalidate() {
        generation += 1
        inFlight = false
        identity = nil
        cached = nil
        updatedAt = nil
        nextCheck = 0; nextFetch = 0; lastAttempt = nil; failures = 0; lastDay = nil
        errorStatus = nil
        onUpdate?(nil)
    }

    func refresh(force: Bool = false) {
        publish() // Re-evaluate yesterday even when the last request failed across midnight.
        let tick = uptime()
        let day = AccountTokenUsageResponse.yesterday(now: now(), calendar: calendar())
        let dayChanged = lastDay != day
        guard !inFlight, force || dayChanged || tick >= nextCheck || tick >= nextFetch else { return }
        guard lastAttempt.map({ tick - $0 >= 10 }) ?? true else { return }
        if force { lastAttempt = tick }
        nextCheck = tick + 60
        lastDay = day
        inFlight = true
        let revision = generation
        client.readAccountIdentity { [weak self] result in
            guard let self, self.generation == revision else { return }
            switch result {
            case .failure:
                // Cannot verify whose data we are displaying: never retain unverified cache.
                self.cached = nil; self.identity = nil
                self.fail("无法确认登录账号，Token 统计暂不可用", identityFailure: true)
            case .success(nil):
                self.cached = nil; self.identity = nil
                self.fail("请先在 ChatGPT/Codex 中登录账号", identityFailure: true)
            case .success(let account?):
                let changed = self.identity != account
                if changed {
                    self.identity = account; self.cached = nil; self.updatedAt = nil
                    self.failures = 0; self.errorStatus = nil
                    self.publish()
                }
                guard force || dayChanged || changed || tick >= self.nextFetch else {
                    self.inFlight = false
                    return
                }
                self.fetch(account: account, revision: revision)
            }
        }
    }

    private func fetch(account: String, revision: Int) {
        lastAttempt = uptime()
        client.readTokenUsage { [weak self] result in
            guard let self, self.generation == revision else { return }
            // Check again: discard a response that raced with a login/account change.
            self.client.readAccountIdentity { [weak self] identityResult in
                guard let self, self.generation == revision else { return }
                guard case .success(let current?) = identityResult, current == account else {
                    self.invalidate()
                    return
                }
                switch result {
                case .success(let response):
                    self.cached = response; self.updatedAt = self.now()
                    self.failures = 0; self.errorStatus = nil
                    self.nextFetch = self.uptime() + 300
                    self.inFlight = false
                    self.publish()
                case .failure(let error):
                    let description = error.localizedDescription.lowercased()
                    let unsupported = description.contains("unknown method") || description.contains("method not found")
                        || description.contains("unknown variant")
                    self.fail(unsupported ? "当前 app-server 不支持账号 Token 统计，请更新宿主应用"
                              : "账号 Token 统计更新失败；* 表示上次成功结果")
                }
            }
        }
    }

    private func fail(_ message: String, identityFailure: Bool = false) {
        inFlight = false
        failures = min(failures + 1, 4)
        nextFetch = uptime() + min(1800, 300 * pow(2, Double(failures - 1)))
        // Usage backoff must not prevent detection of a different logged-in account.
        nextCheck = identityFailure ? nextFetch : uptime() + 60
        errorStatus = message
        publish()
    }

    private func publish() {
        let date = now()
        let stale = errorStatus != nil || updatedAt.map { date.timeIntervalSince($0) >= 360 } == true
        if let cached, let updatedAt {
            onUpdate?(cached.display(now: date, calendar: calendar(), updatedAt: updatedAt,
                                    stale: stale, status: errorStatus))
        } else {
            onUpdate?(TokenUsageSummary(yesterdayTokens: nil, cumulativeTokens: nil, status: errorStatus))
        }
    }
}
