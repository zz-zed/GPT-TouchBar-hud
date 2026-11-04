#if HUD_SHARED_CORE_TESTS
@testable import HUDCoreTestSupport
#endif
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: " + message) }
}
private final class FakeCancel: APICostCancellation { var cancelled = false; func cancel() { cancelled = true } }
private final class FakeCosts: APICostFetching {
    struct Call {
        let period: APICostPeriod
        let end: Date
        let cancellation: FakeCancel
        let completion: (Result<APICostSnapshot, APICostError>) -> Void
    }
    var calls: [Call] = []
    func fetch(key: String, period: APICostPeriod, end: Date, completion: @escaping (Result<APICostSnapshot, APICostError>) -> Void) -> APICostCancellation {
        let cancellation = FakeCancel()
        calls.append(Call(period: period, end: end, cancellation: cancellation, completion: completion))
        return cancellation
    }
    func succeed(_ index: Int, _ value: Decimal = 12, at: Date? = nil) {
        let call = calls[index]
        call.completion(.success(APICostSnapshot(period: call.period, queryEnd: call.end, fetchedAt: at ?? call.end, amount: value)))
    }
}
private final class FakeVault: APICostCredentialVault {
    var reads = 0, writes = 0, removals = 0
    var saveFails = false, removeFails = false
    func read() throws -> String { reads += 1; return "synthetic-cost-fixture" }
    func save(_ key: String) throws { if saveFails { throw APICostError.credentialStorage }; writes += 1 }
    func remove() throws { if removeFails { throw APICostError.credentialStorage }; removals += 1 }
}
private final class TestCostClock { var date = ISO8601DateFormatter().date(from: "2026-11-03T06:20:00Z")! }
private final class Harness {
    let clock = TestCostClock()
    var date: Date { get { clock.date } set { clock.date = newValue } }
    let client = FakeCosts(), vault = FakeVault()
    let suite = "api-cost-tests." + UUID().uuidString
    lazy var defaults = UserDefaults(suiteName: suite)!
    lazy var store = APICostStore(client: client, vault: vault, defaults: defaults, now: { [clock] in clock.date }, schedulesTimers: false)
    deinit { store.stop(); defaults.removePersistentDomain(forName: suite) }
    func connect() {
        store.start(); store.validateAndConnect("synthetic-cost-fixture") { expect($0, "validation succeeds") }; client.succeed(client.calls.count - 1)
    }
    func advance(_ seconds: Double) { date = date.addingTimeInterval(seconds) }
}

/// URL loading is replaced entirely; no real endpoint or credential is used.
private final class CostURLProtocol: URLProtocol {
    struct Reply { let status: Int; let body: Data; var retry: String? = nil }
    static let lock = NSLock()
    static var replies: [Reply] = []
    static var urls: [URL] = []
    static var authorizationOK = true
    static func configure(_ values: [Reply]) { lock.lock(); defer { lock.unlock() }; replies = values; urls = []; authorizationOK = true }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.urls.append(request.url!)
        Self.authorizationOK = Self.authorizationOK && request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-cost-fixture"
        let reply = Self.replies.isEmpty ? Reply(status: 500, body: Data()) : Self.replies.removeFirst()
        Self.lock.unlock()
        var headers = ["Content-Type": "application/json"]
        if let retry = reply.retry { headers["Retry-After"] = retry }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct APICostTests {
    static func main() {
        testStore(); testClient(); print("PASS: API costs — state, pagination, precision, errors, isolation and UTC rollover")
    }
    static func testStore() {
        do {
            let h = Harness(); h.store.start()
            expect(h.vault.reads == 0 && h.client.calls.isEmpty, "opt-out never reads Keychain or requests costs")
            h.connect()
            expect(h.store.state.visible && h.vault.writes == 1, "verified access enables display")
            expect(h.store.state.snapshot?.amount == 12, "validated snapshot adopted")
            expect(!h.defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "synthetic-cost-fixture" }, "no credential in defaults")
            h.store.refresh(); expect(h.client.calls.count == 1, "manual cooldown")
            h.advance(31); h.store.refresh(); h.client.calls[1].completion(.failure(.network))
            expect(h.store.state.snapshot?.amount == 12 && h.store.state.error == .network, "failure retains complete total")
            h.advance(59); h.store.tick(); expect(h.client.calls.count == 2, "backoff waits")
            h.advance(1); h.store.tick(); expect(h.client.calls.count == 3, "automatic retry after 60 seconds")
            h.client.succeed(2, 14)
            expect(h.store.state.snapshot?.amount == 14 && h.store.state.error == nil, "success replaces rather than accumulates")
            h.advance(31); h.store.refresh(); h.store.setEnabled(false); h.client.succeed(3, 999)
            expect(!h.store.state.visible && h.store.state.snapshot?.amount == 14, "disable ignores late callback")
            h.advance(31); h.store.setEnabled(true); h.client.calls[4].completion(.failure(.authentication))
            h.advance(2000); h.store.tick(); h.store.refresh()
            expect(h.client.calls.count == 5 && !h.store.state.canRefresh, "auth failure stops auto and manual requests")
        }
        do {
            let h = Harness(); h.connect(); h.advance(31); h.store.refresh()
            h.store.validateAndConnect("synthetic-replacement") { expect($0, "replacement succeeds") }
            h.client.succeed(2, 23); h.client.succeed(1, 888)
            expect(h.store.state.snapshot?.amount == 23 && h.client.calls[1].cancellation.cancelled, "replacement rejects old account callback")
            h.advance(31); h.store.refresh()
            h.store.validateAndConnect("synthetic-invalid") { expect(!$0, "candidate failure") }
            h.client.calls[4].completion(.failure(.permission)); h.client.succeed(3, 24)
            expect(h.store.state.error == nil && h.store.state.snapshot?.amount == 24, "candidate failure does not invalidate original")
            h.store.validateAndConnect("synthetic-superseded") { _ in fatalError("superseded validation callback") }
            h.store.validateAndConnect("synthetic-current") { expect($0, "latest candidate") }
            h.client.succeed(5, 999); h.client.succeed(6, 25)
            expect(h.store.state.snapshot?.amount == 25 && h.vault.writes == 3, "only latest candidate may save")
            h.store.validateAndConnect("synthetic-cancelled") { _ in fatalError("disconnect revived validation") }
            h.store.disconnect(); h.client.succeed(7, 999)
            expect(!h.store.state.configured && h.store.state.snapshot == nil, "disconnect clears state and pending validation")
        }
        do {
            let h = Harness(); h.connect(); h.advance(31); h.store.refresh()
            let until = h.date.addingTimeInterval(300)
            h.client.calls[1].completion(.failure(.rateLimited(until)))
            h.advance(120); h.store.refresh(); h.store.tick()
            h.store.validateAndConnect("synthetic-cost-fixture") { expect(!$0, "validation obeys backoff") }
            expect(h.client.calls.count == 2, "429 cannot be bypassed by manual or validation")
            h.advance(180); h.store.tick(); expect(h.client.calls.count == 3, "retry after server deadline")
            h.client.succeed(2)
            h.date = ISO8601DateFormatter().date(from: "2026-12-01T00:00:01Z")!
            h.store.tick()
            expect(h.store.state.snapshot == nil && h.store.state.period.title == "2026-12 · UTC", "rollover never labels November amount December")
            h.client.calls[3].completion(.failure(.network))
            expect(h.store.state.amountText(language: .chinese) == "—", "new-month failure remains unknown")
        }
        do {
            let h = Harness(); h.connect(); h.advance(31); h.store.refresh(); h.store.setSuspended(true)
            h.client.succeed(1, 999); h.advance(1000); h.store.tick()
            expect(h.client.calls.count == 2 && h.store.state.snapshot?.amount == 12, "sleep stops and ignores network work")
            h.store.setSuspended(false); expect(h.client.calls.count == 3, "wake refreshes due state")
            h.client.succeed(2); h.store.stop(); h.advance(2000); h.store.tick()
            expect(h.client.calls.count == 3 && h.store.state.snapshot == nil, "stop removes in-memory snapshot")
        }
        do {
            let h = Harness(); h.connect(); h.vault.saveFails = true
            h.store.validateAndConnect("synthetic-new") { expect(!$0, "Keychain failure") }; h.client.succeed(1, 999)
            expect(h.store.state.snapshot?.amount == 12 && h.store.state.validationError == .credentialStorage, "save failure retains original")
        }
    }
    static func testClient() {
        let date = ISO8601DateFormatter().date(from: "2026-11-03T06:20:00Z")!
        let period = APICostPeriod.month(containing: date)
        let start = Int64(period.start.timeIntervalSince1970)
        func page(_ day: Int, _ entries: String, more: Bool = false, cursor: String? = nil) -> Data {
            let next = cursor.map { "\"\($0)\"" } ?? "null"
            return Data("{\"data\":[{\"start_time\":\(start + Int64(day * 86400)),\"end_time\":\(start + Int64((day + 1) * 86400)),\"results\":[\(entries)]}],\"has_more\":\(more),\"next_page\":\(next)}".utf8)
        }
        func entry(_ amount: String, currency: String = "usd") -> String {
            "{\"object\":\"organization.costs.result\",\"amount\":{\"value\":\(amount),\"currency\":\"\(currency)\"}}"
        }
        func run(_ replies: [CostURLProtocol.Reply]) -> Result<APICostSnapshot, APICostError> {
            CostURLProtocol.configure(replies)
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CostURLProtocol.self]
            let client = APICostClient(configuration: config, now: { date })
            var result: Result<APICostSnapshot, APICostError>?
            let task = client.fetch(key: "synthetic-cost-fixture", period: period, end: date) { result = $0 }
            let deadline = Date().addingTimeInterval(5)
            while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            withExtendedLifetime((client, task)) {}
            guard let result else { fatalError("client test timed out") }
            return result
        }
        let result = run([.init(status: 200, body: page(0, entry("0.1"), more: true, cursor: "cursor-a")),
                          .init(status: 200, body: page(1, entry("0.2") + "," + entry("-0.05")))])
        expect((try! result.get()).amount == Decimal(string: "0.25"), "exact signed decimal aggregation")
        expect((try! result.get()).responseCounts == APICostResponseCounts(pages: 2, buckets: 2, records: 3), "counts cover complete pagination")
        expect((try! result.get()).emptyResponseDiagnostic == nil, "diagnostic is limited to empty results")
        expect(CostURLProtocol.urls.count == 2 && CostURLProtocol.authorizationOK, "pagination requests authenticated")
        let query = URLComponents(url: CostURLProtocol.urls[1], resolvingAgainstBaseURL: false)!.queryItems!
        expect(query.first(where: { $0.name == "page" })?.value == "cursor-a", "uses server cursor")
        expect(query.first(where: { $0.name == "start_time" })?.value == String(start), "UTC month start")
        expect(!query.contains { ["api_key_ids", "project_ids", "line_items"].contains($0.name) }, "entire billing scope, no hidden filter")
        for url in CostURLProtocol.urls { expect(url.host == "api.openai.com" && url.path == "/v1/organization/costs", "fixed official endpoint") }
        expect((try! run([.init(status: 200, body: page(0, ""))]).get()).amount == nil, "empty records distinct from zero")
        let empty = try! run([.init(status: 200, body: page(0, ""))]).get()
        expect(empty.responseCounts == APICostResponseCounts(pages: 1, buckets: 1, records: 0), "empty buckets retained in diagnostic")
        expect(empty.emptyResponseDiagnostic?.contains("2026-11-01 00:00:00") == true && empty.emptyResponseDiagnostic?.contains("2026-11-03 06:20:00") == true, "diagnostic shows actual UTC query interval")
        let zero = try! run([.init(status: 200, body: page(0, entry("0")))]).get()
        expect(zero.amount == 0 && zero.amountText(language: .chinese) == "US$0.00", "confirmed zero formatting")
        let tiny = try! run([.init(status: 200, body: page(0, entry("0.001")))]).get()
        expect(tiny.amountText(language: .chinese) == "< US$0.01", "tiny expense not rounded to zero")
        let invalid: [[CostURLProtocol.Reply]] = [
            [.init(status: 200, body: page(0, entry("1"), more: true))],
            [.init(status: 200, body: page(0, entry("1"), more: true, cursor: "a")), .init(status: 200, body: page(1, entry("2"), more: true, cursor: "a"))],
            [.init(status: 200, body: page(0, entry("1"), more: true, cursor: "a")), .init(status: 200, body: page(0, entry("2")))],
            [.init(status: 200, body: page(0, entry("1", currency: "eur")))],
            [.init(status: 200, body: page(0, "{\"object\":\"organization.costs.result\"}"))],
            [.init(status: 200, body: Data("invalid".utf8))]
        ]
        for replies in invalid { if case .failure(.invalidData) = run(replies) {} else { fatalError("invalid page published") } }
        for (status, expected) in [(401, APICostError.authentication), (403, .permission), (500, .service), (302, .service)] {
            if case .failure(let error) = run([.init(status: status, body: Data())]) { expect(error == expected, "HTTP error classification") }
            else { fatalError("HTTP error accepted") }
        }
        if case .failure(.rateLimited(let until)) = run([.init(status: 429, body: Data(), retry: "120")]) {
            expect(until == date.addingTimeInterval(120), "Retry-After seconds")
        } else { fatalError("429 not preserved") }
        if case .failure(.service) = run([.init(status: 200, body: page(0, entry("999"), more: true, cursor: "a")), .init(status: 500, body: Data())]) {} else { fatalError("partial total published") }
    }
}
