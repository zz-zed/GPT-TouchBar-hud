import Foundation

private final class FakeQuotaClient: RateLimitClient {
    var onRateLimitsUpdated: (() -> Void)?
    var onAccountUpdated: (() -> Void)?
    var account: String? = "account-a"
    var identities: [Result<String?, Error>] = []
    var deferred = false
    var quota: Result<GetAccountRateLimitsResponse, Error> = .success(response(remaining: 70))
    var pending: [(Result<GetAccountRateLimitsResponse, Error>) -> Void] = []
    func start(completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func stop() {}
    func readAccountIdentity(completion: @escaping (Result<String?, Error>) -> Void) {
        completion(identities.isEmpty ? .success(account) : identities.removeFirst())
    }
    func readRateLimits(completion: @escaping (Result<GetAccountRateLimitsResponse, Error>) -> Void) {
        if deferred { pending.append(completion) } else { completion(quota) }
    }
    func readTokenUsage(completion: @escaping (Result<AccountTokenUsageResponse, Error>) -> Void) {
        completion(.failure(CodexAppServerError.missingResult))
    }
}

private func response(remaining: Double) -> GetAccountRateLimitsResponse {
    GetAccountRateLimitsResponse(rateLimits: RateLimitSnapshot(limitId: "codex", limitName: nil,
        primary: RateLimitWindow(usedPercent: 100 - remaining, windowDurationMins: 300,
                                 resetsAt: Date().addingTimeInterval(3600).timeIntervalSince1970),
        secondary: nil, credits: nil), rateLimitsByLimitId: nil, rateLimitResetCredits: nil)
}

private final class QuotaObserver: RateLimitStoreDelegate {
    var states: [RateLimitDisplayState] = []
    func rateLimitStore(_ store: RateLimitStore, didUpdate state: RateLimitDisplayState) { states.append(state) }
}

@main enum VerifiedQuotaTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); checks += 1
    }
    static func main() {
        let client = FakeQuotaClient()
        let reader = VerifiedQuotaReader(client: client)
        var result: Result<VerifiedQuotaSnapshot, Error>?
        reader.read { result = $0 }
        let first = try! result!.get()
        check(first.accountKey?.count == 64, "Verified ownership has a SHA256 key")
        check(first.accountKey != "account-a", "Raw identity cannot enter preferences")
        client.account = "account-b"
        reader.read { result = $0 }
        check(try! result!.get().accountKey != first.accountKey, "Accounts have separate keys")
        client.identities = [.success("a"), .success("b")]
        reader.read { result = $0 }
        if case .failure(let error) = result { check(error is QuotaIdentityError, "Reject account changing during read") }
        else { preconditionFailure("Mixed-account response accepted") }
        client.identities = [.success("a"), .success(nil)]
        reader.read { result = $0 }
        if case .failure(let error) = result { check(error is QuotaIdentityError, "Reject losing account after read") }
        else { preconditionFailure("Unverified response accepted") }
        client.account = nil
        reader.read { result = $0 }
        check(try! result!.get().accountKey == nil, "Older hosts retain quota display without alert ownership")
        client.account = "account-a"
        client.quota = .failure(CodexAppServerError.requestTimedOut)
        reader.read { result = $0 }
        if case .failure = result { checks += 1 } else { preconditionFailure("Quota failure accepted") }

        let asynchronous = FakeQuotaClient()
        asynchronous.deferred = true
        let observer = QuotaObserver()
        let store = RateLimitStore(client: asynchronous)
        store.delegate = observer
        store.start()
        check(asynchronous.pending.count == 1, "One request initially")
        let old = asynchronous.pending.removeFirst()
        asynchronous.account = "account-b"
        asynchronous.onAccountUpdated?()
        check(store.verifiedAccountKey == nil && observer.states.last?.lastUpdated == nil, "Account event clears ownership and snapshot")
        check(asynchronous.pending.count == 1, "Account event starts replacement request")
        old(.success(response(remaining: 5)))
        check(observer.states.last?.fiveHour == nil, "Old callback cannot restore old quota")
        asynchronous.pending.removeFirst()(.success(response(remaining: 65)))
        check(observer.states.last?.fiveHour?.remainingPercent == 65, "New account quota is displayed")
        check(store.verifiedAccountKey != nil, "Only replacement response grants alert ownership")
        store.refresh()
        let stopped = asynchronous.pending.removeFirst()
        store.stop()
        let count = observer.states.count
        stopped(.success(response(remaining: 1)))
        check(observer.states.count == count && store.verifiedAccountKey == nil, "Stopped request cannot publish or alert")
        print("Verified quota checks passed: \(checks)")
    }
}
