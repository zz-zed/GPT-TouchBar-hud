import Foundation

private final class FakeUsageClient: AccountUsageClient {
    var account: Result<String?, Error> = .success("account-a")
    var response: Result<AccountTokenUsageResponse, Error>!
    var reads = 0
    var accountReads = 0
    var deferred = false
    var pending: ((Result<AccountTokenUsageResponse, Error>) -> Void)?
    func readAccountIdentity(completion: @escaping (Result<String?, Error>) -> Void) {
        accountReads += 1
        completion(account)
    }
    func readTokenUsage(completion: @escaping (Result<AccountTokenUsageResponse, Error>) -> Void) {
        reads += 1
        if deferred { pending = completion } else { completion(response) }
    }
}

@main
enum AccountTokenUsageTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
        checks += 1
    }

    static func main() throws {
        func decode(_ json: String) throws -> AccountTokenUsageResponse {
            try JSONDecoder().decode(AccountTokenUsageResponse.self, from: Data(json.utf8))
        }
        let fixture = try decode("""
        {"summary":{"lifetimeTokens":2659004914},"dailyUsageBuckets":[
          {"startDate":"2026-09-15","tokens":27442835},
          {"startDate":"2026-09-14","tokens":1000}]}
        """)
        var date = ISO8601DateFormatter().date(from: "2026-09-16T04:00:00Z")!
        var tick: TimeInterval = 1000
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func display(_ response: AccountTokenUsageResponse) -> TokenUsageSummary {
            response.display(now: date, calendar: calendar, updatedAt: date)
        }
        check(display(fixture).yesterdayTokens == 27442835, "Match service daily bucket, not daily sum")
        check(display(fixture).cumulativeTokens == 2659004914, "Int64 lifetime independent of bucket range")
        check(display(fixture).yesterdayText == "昨日 2744.3 万", "Keep tenths above 100 wan")
        check(display(fixture).cumulativeText == "累计 26.6 亿", "Match screenshot rounding")
        for (tokens, expected) in [
            (0, "0 个"), (9999, "9999 个"), (10000, "1.00 万"),
            (99999499, "9999.9 万"), (99999500, "1.00 亿"),
            (100000000, "1.00 亿"), (120000000, "1.20 亿"),
            (1200000000, "12.0 亿")
        ] {
            let summary = TokenUsageSummary(yesterdayTokens: tokens, cumulativeTokens: nil)
            check(summary.yesterdayText == "昨日 \(expected)", "Daily unit promotion at \(tokens)")
        }
        var staleDaily = TokenUsageSummary(yesterdayTokens: 120000000, cumulativeTokens: nil)
        staleDaily.isStale = true
        check(staleDaily.yesterdayText == "昨日 1.20 亿*", "Promoted units preserve stale marker")
        let empty = try decode("{\"summary\":{},\"dailyUsageBuckets\":null}")
        check(display(empty).yesterdayText == "昨日 --", "Null buckets are unknown")
        check(display(empty).cumulativeText == "累计 --", "Missing lifetime is unknown")
        let missing = try decode("{\"summary\":{\"lifetimeTokens\":0},\"dailyUsageBuckets\":[]}")
        check(display(missing).yesterdayTokens == nil, "Empty buckets do not imply zero")
        check(display(missing).cumulativeTokens == 0, "Explicit zero lifetime is valid")
        let zero = try decode("{\"summary\":{},\"dailyUsageBuckets\":[{\"startDate\":\"2026-09-15\",\"tokens\":0}]}")
        check(display(zero).yesterdayTokens == 0, "Explicit zero daily usage is valid")
        let duplicate = try decode("{\"summary\":{\"lifetimeTokens\":-1},\"dailyUsageBuckets\":[{\"startDate\":\"2026-09-15\",\"tokens\":1},{\"startDate\":\"2026-09-15\",\"tokens\":2}]}")
        check(display(duplicate).yesterdayTokens == nil && display(duplicate).cumulativeTokens == nil,
              "Reject ambiguous buckets and negative total")
        let negative = try decode("{\"summary\":{},\"dailyUsageBuckets\":[{\"startDate\":\"2026-09-15\",\"tokens\":-1}]}")
        check(display(negative).yesterdayTokens == nil, "Reject negative daily usage")
        check((try? decode("{}")) == nil, "Reject malformed top-level response")
        let nearMidnight = ISO8601DateFormatter().date(from: "2026-09-15T16:01:00Z")!
        check(AccountTokenUsageResponse.yesterday(now: nearMidnight, calendar: calendar) == "2026-09-15",
              "Local date boundary, not UTC date")
        var dst = Calendar(identifier: .gregorian)
        dst.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        check(AccountTokenUsageResponse.yesterday(now: ISO8601DateFormatter().date(from: "2026-03-09T07:30:00Z")!, calendar: dst) == "2026-03-08",
              "Yesterday respects daylight-saving transition")

        let client = FakeUsageClient()
        client.response = .success(fixture)
        let store = AccountTokenUsageStore(client: client, now: { date }, uptime: { tick }, calendar: { calendar })
        var shown: TokenUsageSummary?
        store.onUpdate = { shown = $0 }
        store.refresh()
        check(client.reads == 1 && shown?.cumulativeTokens == 2659004914, "Initial authenticated fetch")
        check(client.accountReads == 2, "Validate identity before and after usage request")
        store.refresh(force: true)
        check(client.reads == 1, "Debounce repeated manual refresh")
        tick += 60; store.refresh()
        check(client.reads == 1 && client.accountReads == 3, "Check account without refetching usage within five minutes")
        tick += 240; store.refresh()
        check(client.reads == 2, "Refresh usage after five minutes")
        tick += 10; store.refresh(force: true)
        check(client.reads == 3, "Manual refresh bypasses five-minute cache")

        client.response = .failure(CodexAppServerError.requestTimedOut)
        tick += 300; store.refresh()
        check(shown?.cumulativeTokens == 2659004914 && shown?.isStale == true, "Keep same-account cache on timeout")
        check(shown?.yesterdayText.hasSuffix("*") == true && shown?.status != nil, "Visible stale marker and explanation")
        tick += 299; store.refresh()
        check(client.reads == 4, "First failure backs off for five minutes")
        tick += 1; store.refresh()
        check(client.reads == 5, "Retry at first backoff deadline")
        tick += 300; store.refresh()
        check(client.reads == 5, "Second failure increases backoff to ten minutes")
        check(client.accountReads == 13, "Usage backoff does not pause account identity checks")
        date = date.addingTimeInterval(86400); tick += 60; store.refresh()
        check(shown?.yesterdayTokens == nil, "Never label the previous day's cached number as new yesterday")
        check(shown?.cumulativeTokens == 2659004914, "Lifetime can remain as marked stale across midnight")

        client.account = .success("account-b")
        tick += 10; store.refresh(force: true)
        check(shown?.cumulativeTokens == nil, "Changing accounts clears previous account on fetch failure")
        client.response = .success(fixture)
        tick += 10; store.refresh(force: true)
        check(shown?.isStale == false, "Successful response clears failure state")
        client.account = .success(nil)
        tick += 10; store.refresh(force: true)
        check(shown?.cumulativeTokens == nil && shown?.status?.contains("登录") == true, "Logout clears cache")

        client.account = .success("account-a")
        client.response = .failure(CodexAppServerError.serverError("Method not found"))
        tick += 10; store.refresh(force: true)
        check(shown?.status?.contains("不支持") == true, "Unsupported older server is explicit")
        client.account = .failure(CodexAppServerError.requestTimedOut)
        tick += 10; store.refresh(force: true)
        check(shown?.cumulativeTokens == nil, "Cannot verify identity: no cached account numbers")
        let authReads = client.accountReads
        store.refresh(force: true)
        check(client.accountReads == authReads, "Manual refresh debounce also applies to auth failure")

        client.account = .success("account-a"); client.deferred = true
        tick += 10; store.refresh(force: true)
        let delayed = client.pending
        let before = client.reads
        tick += 60; store.refresh(force: true)
        check(client.reads == before, "Never overlap requests")
        store.invalidate()
        delayed?(.success(fixture))
        check(shown == nil, "Ignore old callback after invalidation/stop")
        tick += 10; store.refresh(force: true)
        client.account = .success("account-b")
        client.pending?(.success(fixture))
        check(shown == nil, "Discard response racing with account change")
        print("PASS: \(checks) account token usage checks")
    }
}
