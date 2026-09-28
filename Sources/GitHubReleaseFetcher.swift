import Foundation

final class GitHubReleaseFetcher: AppReleaseFetching {
    private let session: URLSession
    private let userAgent: String
    private let now: () -> Date
    private let lock = NSLock()
    private var apiRetryNotBefore: Date?

    init(session: URLSession, version: String, now: @escaping () -> Date = Date.init) {
        self.session = session
        self.now = now
        userAgent = "GPTTouchBarHUD/\(version)"
    }

    func fetchLatest(completion: @escaping (Result<AppRelease, AppUpdateFetchFailure>) -> Void) {
        lock.lock()
        let apiRetryNotBefore = self.apiRetryNotBefore
        lock.unlock()
        if let apiRetryNotBefore, apiRetryNotBefore > now() {
            fetchReleasePage(apiRetryAfter: apiRetryNotBefore, completion: completion)
            return
        }
        var request = URLRequest(url: AppRelease.api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            if error == nil, http?.statusCode == 200,
               let finalURL = response?.url,
               AppRelease.isTrustedURL(finalURL, host: "api.github.com"), finalURL.path == AppRelease.api.path,
               let data, data.count < 2_000_000,
               let release = try? JSONDecoder().decode(AppRelease.self, from: data),
               release.isStableVersion {
                self.complete(.success(release), completion)
                return
            }
            let limited = http?.statusCode == 429 ||
                (http?.statusCode == 403 && http?.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0")
            let retryAfter = self.retryDate(from: http, includeRateLimitReset: limited)
            if let retryAfter, retryAfter > self.now() {
                self.lock.lock()
                self.apiRetryNotBefore = retryAfter
                self.lock.unlock()
            }
            self.fetchReleasePage(apiRetryAfter: retryAfter, completion: completion)
        }.resume()
    }

    private func fetchReleasePage(
        apiRetryAfter: Date?,
        completion: @escaping (Result<AppRelease, AppUpdateFetchFailure>) -> Void
    ) {
        var request = URLRequest(url: AppRelease.page)
        request.httpMethod = "HEAD"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            if error == nil, http?.statusCode == 200,
               let finalURL = response?.url,
               let release = AppRelease.fromLatestPageURL(finalURL) {
                self.complete(.success(release), completion)
                return
            }
            let pageLimited = http?.statusCode == 429 ||
                (http?.statusCode == 403 && http?.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0")
            let retryAfter = [apiRetryAfter, self.retryDate(from: http, includeRateLimitReset: pageLimited)].compactMap { $0 }.max()
            if retryAfter != nil || pageLimited {
                self.complete(.failure(AppUpdateFetchFailure("GitHub 暂时无法提供更新信息，请稍后重试。", retryAfter: retryAfter)), completion)
            } else {
                self.complete(.failure(AppUpdateFetchFailure("GitHub API 和 Release 页面均无法读取。请检查网络或稍后重试；不会安装任何文件。")), completion)
            }
        }.resume()
    }

    private func retryDate(from response: HTTPURLResponse?, includeRateLimitReset: Bool) -> Date? {
        guard let response else { return nil }
        var dates: [Date] = []
        if let value = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
                let date = now().addingTimeInterval(seconds)
                if date.timeIntervalSince1970.isFinite { dates.append(date) }
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                if let date = formatter.date(from: value) { dates.append(date) }
            }
        }
        if includeRateLimitReset,
           let epoch = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init), epoch.isFinite, epoch > 0 {
            dates.append(Date(timeIntervalSince1970: epoch))
        }
        return dates.filter { $0 > now() }.max()
    }

    private func complete(
        _ result: Result<AppRelease, AppUpdateFetchFailure>,
        _ completion: @escaping (Result<AppRelease, AppUpdateFetchFailure>) -> Void
    ) {
        DispatchQueue.main.async { completion(result) }
    }
}
