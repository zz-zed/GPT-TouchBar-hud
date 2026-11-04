import Foundation

/// Credentials are sent only to the fixed API endpoint; redirects are never followed.
private final class APICostNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class APICostClient: APICostFetching {
    private let session: URLSession
    private let now: () -> Date
    init(configuration: URLSessionConfiguration = .ephemeral, now: @escaping () -> Date = Date.init) {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: APICostNoRedirect(), delegateQueue: nil)
        self.now = now
    }
    deinit { session.invalidateAndCancel() }
    func fetch(key: String, period: APICostPeriod, end: Date,
               completion: @escaping (Result<APICostSnapshot, APICostError>) -> Void) -> APICostCancellation {
        let operation = APICostRequest(session: session, key: key, period: period, end: end, now: now, completion: completion)
        operation.start()
        return operation
    }
}

private struct APICostPage: Decodable {
    struct Bucket: Decodable {
        struct Entry: Decodable {
            struct Amount: Decodable { let value: Decimal; let currency: String }
            let object: String
            let amount: Amount
        }
        let start_time: Int64
        let end_time: Int64
        let results: [Entry]
    }
    let data: [Bucket]
    let has_more: Bool
    let next_page: String?
}

private final class APICostRequest: APICostCancellation {
    private let session: URLSession
    private var key: String
    private let period: APICostPeriod
    private let end: Date
    private let now: () -> Date
    private var completion: ((Result<APICostSnapshot, APICostError>) -> Void)?
    private var task: URLSessionDataTask?
    private var deadline: DispatchWorkItem?
    private var seenCursors = Set<String>()
    private var intervals: [(Int64, Int64)] = []
    private var amount: Decimal = 0
    private var records = 0
    private var pages = 0

    init(session: URLSession, key: String, period: APICostPeriod, end: Date, now: @escaping () -> Date,
         completion: @escaping (Result<APICostSnapshot, APICostError>) -> Void) {
        self.session = session; self.key = key; self.period = period; self.end = end; self.now = now; self.completion = completion
    }
    func start() {
        guard end > period.start, end <= period.end, !key.isEmpty,
              !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 33 || $0.value > 126 }) else {
            DispatchQueue.main.async { [self] in finish(.failure(.invalidData)) }; return
        }
        let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(.timeout)) }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: timeout)
        request(cursor: nil)
    }
    func cancel() {
        completion = nil; key = ""; task?.cancel(); task = nil; deadline?.cancel(); deadline = nil
    }
    private func finish(_ result: Result<APICostSnapshot, APICostError>) {
        let callback = completion
        cancel()
        callback?(result)
    }
    private func request(cursor: String?) {
        guard completion != nil else { return }
        pages += 1
        guard pages <= 64 else { finish(.failure(.invalidData)); return }
        var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
        components.queryItems = [URLQueryItem(name: "start_time", value: String(Int64(period.start.timeIntervalSince1970))),
                                URLQueryItem(name: "end_time", value: String(Int64(end.timeIntervalSince1970))),
                                URLQueryItem(name: "bucket_width", value: "1d"), URLQueryItem(name: "limit", value: "31")]
        if let cursor { components.queryItems?.append(URLQueryItem(name: "page", value: cursor)) }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { [weak self] in self?.receive(data, response: response, error: error) }
        }
        task?.resume()
    }
    private func receive(_ data: Data?, response: URLResponse?, error: Error?) {
        guard completion != nil else { return }
        if let error { finish(.failure((error as? URLError)?.code == .timedOut ? .timeout : .network)); return }
        guard let response = response as? HTTPURLResponse else { finish(.failure(.network)); return }
        switch response.statusCode {
        case 200: break
        case 401: finish(.failure(.authentication)); return
        case 403: finish(.failure(.permission)); return
        case 429: finish(.failure(.rateLimited(Self.retryDate(response.value(forHTTPHeaderField: "Retry-After"), now: now())))); return
        default: finish(.failure(.service)); return
        }
        guard let data, data.count <= 2_000_000, let page = try? JSONDecoder().decode(APICostPage.self, from: data) else {
            finish(.failure(.invalidData)); return
        }
        for bucket in page.data {
            guard bucket.end_time > bucket.start_time,
                  !intervals.contains(where: { bucket.start_time < $0.1 && bucket.end_time > $0.0 }) else {
                finish(.failure(.invalidData)); return
            }
            intervals.append((bucket.start_time, bucket.end_time))
            for entry in bucket.results {
                guard entry.object == "organization.costs.result", entry.amount.currency == "usd", !entry.amount.value.isNaN else {
                    finish(.failure(.invalidData)); return
                }
                var lhs = amount, rhs = entry.amount.value, sum = Decimal()
                guard NSDecimalAdd(&sum, &lhs, &rhs, .plain) == .noError else { finish(.failure(.invalidData)); return }
                amount = sum; records += 1
            }
        }
        if page.has_more {
            guard let cursor = page.next_page, !cursor.isEmpty, cursor.count <= 4096, seenCursors.insert(cursor).inserted else {
                finish(.failure(.invalidData)); return
            }
            request(cursor: cursor)
        } else {
            finish(.success(APICostSnapshot(period: period, queryEnd: end, fetchedAt: now(), amount: records == 0 ? nil : amount,
                responseCounts: APICostResponseCounts(pages: pages, buckets: intervals.count, records: records))))
        }
    }
    static func retryDate(_ raw: String?, now: Date) -> Date? {
        guard let raw else { return nil }
        if let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: raw)
    }
}
