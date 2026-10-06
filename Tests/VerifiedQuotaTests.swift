import Foundation

private final class FakeQuotaClient: RateLimitClient {
    var onRateLimitsUpdated: (() -> Void)?
    var onAccountUpdated: (() -> Void)?
    var onConnectionClosed: ((Error) -> Void)?
    var startResult: Result<Void, Error> = .success(())
    var starts = 0
    var deferStart = false
    var pendingStarts: [(Result<Void, Error>) -> Void] = []
    var quotaReads = 0
    var account: String? = "account-a"
    var identities: [Result<String?, Error>] = []
    var deferred = false
    var quota: Result<GetAccountRateLimitsResponse, Error> = .success(response(remaining: 70))
    var pending: [(Result<GetAccountRateLimitsResponse, Error>) -> Void] = []
    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        starts += 1
        if deferStart { pendingStarts.append(completion) } else { completion(startResult) }
    }
    func stop() {}
    func readAccountIdentity(completion: @escaping (Result<String?, Error>) -> Void) {
        completion(identities.isEmpty ? .success(account) : identities.removeFirst())
    }
    func readRateLimits(completion: @escaping (Result<GetAccountRateLimitsResponse, Error>) -> Void) {
        quotaReads += 1
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
        testConnectionRecovery()
        testWindowClassification()
        print("Verified quota checks passed: \(checks)")
    }

    static func spin(_ duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    static func testConnectionRecovery() {
        let failed = FakeQuotaClient()
        failed.startResult = .failure(CodexAppServerError.processUnavailable)
        let manual = RateLimitStore(client: failed, retryDelays: [1])
        let observer = QuotaObserver(); manual.delegate = observer
        manual.start()
        check(failed.quotaReads == 0, "Failed startup does not read an unavailable connection")
        failed.startResult = .success(())
        manual.start()
        check(failed.starts == 2 && observer.states.last?.fiveHour != nil,
              "Manual refresh reconnects after initial startup failure")
        manual.stop()

        let recovering = FakeQuotaClient()
        recovering.startResult = .failure(CodexAppServerError.runtimeNotFound)
        let automatic = RateLimitStore(client: recovering, retryDelays: [0.03])
        automatic.start()
        recovering.startResult = .success(())
        spin(0.12)
        check(recovering.starts == 2 && automatic.verifiedAccountKey != nil,
              "Initial failure automatically recovers when runtime becomes available")
        recovering.onConnectionClosed?(CodexAppServerError.processUnavailable)
        check(automatic.verifiedAccountKey == nil, "Disconnect immediately invalidates alert ownership")
        spin(0.12)
        check(recovering.starts == 3 && automatic.verifiedAccountKey != nil,
              "An idle connection exit reconnects without waiting for a quota request")
        recovering.quota = .failure(CodexAppServerError.processUnavailable)
        automatic.refresh()
        recovering.quota = .success(response(remaining: 70))
        spin(0.12)
        check(recovering.starts == 4, "Unavailable read also transitions into connection recovery")
        let obsoleteDisconnect = recovering.onConnectionClosed
        automatic.stop(); automatic.start()
        obsoleteDisconnect?(CodexAppServerError.processUnavailable)
        spin(0.12)
        check(recovering.starts == 5 && automatic.verifiedAccountKey != nil,
              "A disconnect callback from an older lifecycle cannot disturb the new connection")
        automatic.stop()

        let delayed = FakeQuotaClient(); delayed.deferStart = true
        let merging = RateLimitStore(client: delayed, retryDelays: [0.03])
        merging.start(); merging.start(); merging.refresh()
        check(delayed.starts == 1 && delayed.quotaReads == 0,
              "Repeated refreshes merge while initialization is pending")
        let stale = delayed.pendingStarts.removeFirst()
        merging.stop(); merging.start()
        stale(.success(()))
        check(delayed.quotaReads == 0, "Stopped initialization cannot launch an old refresh")
        delayed.pendingStarts.removeFirst()(.success(()))
        check(delayed.starts == 2 && delayed.quotaReads == 1, "Only the current initialization publishes quota")
        merging.stop()

        let stopped = FakeQuotaClient(); stopped.startResult = .failure(CodexAppServerError.processUnavailable)
        let noRetry = RateLimitStore(client: stopped, retryDelays: [0.03])
        noRetry.start(); noRetry.stop(); spin(0.12)
        check(stopped.starts == 1, "Stopping monitoring cancels scheduled reconnection")

        let crashing = FakeQuotaClient(); crashing.startResult = .failure(CodexAppServerError.processUnavailable)
        let backoff = RateLimitStore(client: crashing, retryDelays: [0.03, 0.25])
        backoff.start(); spin(0.12)
        check(crashing.starts == 2, "Repeated startup failures back off instead of retrying at the initial frequency")
        crashing.startResult = .success(())
        spin(0.3)
        check(crashing.starts == 3, "Retry delay remains bounded and still permits recovery")
        crashing.onConnectionClosed?(CodexAppServerError.processUnavailable)
        spin(0.12)
        check(crashing.starts == 3, "A brief successful handshake does not reset crash-loop backoff")
        spin(0.25)
        check(crashing.starts == 4, "Crash-loop backoff eventually reconnects")
        backoff.stop()
    }

    static func testWindowClassification() {
        func window(_ duration: Double?, _ remaining: Double) -> RateLimitWindow {
            RateLimitWindow(usedPercent: 100 - remaining, windowDurationMins: duration, resetsAt: nil)
        }
        let cases: [(Double?, Double?, Double?, Double?)] = [
            (300, 10080, 90, 80), (10080, 300, 80, 90),
            (10080, 1440, nil, 90), (300, 1440, 90, nil),
            (1440, 43200, nil, nil), (nil, nil, 90, 80),
            (nil, 10080, 90, 80), (10080, nil, 80, 90),
            (300, nil, 90, 80), (nil, 300, 80, 90),
            (300, 300, 90, nil), (10080, 10080, nil, 90),
            (300, 10141, 90, nil), (270, 10020, nil, 80)
        ]
        for (primary, secondary, fiveHour, weekly) in cases {
            let result = RateLimitWindowClassifier.classify(primary: window(primary, 90), secondary: window(secondary, 80))
            check(result.fiveHour?.remainingPercent == fiveHour && result.weekly?.remainingPercent == weekly,
                  "Classification respects explicit duration and slot identity: \(String(describing: primary))/\(String(describing: secondary))")
        }
        for duration in [1440.0, 43200, 0, -1, .infinity, .nan] {
            let result = RateLimitWindowClassifier.classify(primary: window(duration, 90), secondary: nil)
            check(result.fiveHour == nil && result.weekly == nil, "Unsupported single window never becomes a weekly meter")
        }
        let weekly = RateLimitWindowClassifier.classify(primary: window(10080, 90), secondary: nil)
        check(weekly.fiveHour == nil && weekly.weekly?.remainingPercent == 90, "Explicit weekly-only response stays weekly-only")
        let legacy = RateLimitWindowClassifier.classify(primary: nil, secondary: window(nil, 80))
        check(legacy.fiveHour == nil && legacy.weekly?.remainingPercent == 80, "Legacy single window keeps its existing weekly presentation")
        let empty = RateLimitWindowClassifier.classify(primary: nil, secondary: nil)
        check(empty.fiveHour == nil && empty.weekly == nil, "An empty response has no inferred quota")
    }
}
