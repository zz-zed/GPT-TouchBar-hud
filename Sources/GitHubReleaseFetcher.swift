import Foundation

final class GitHubReleaseFetcher: AppReleaseFetching {
    private let session: URLSession
    private let userAgent: String
    private let lock = NSLock()
    private var apiRetryNotBefore: Date?

    init(session: URLSession, version: String) {
        self.session = session
        userAgent = "GPTTouchBarHUD/\(version)"
    }

    func fetchLatest(completion: @escaping (Result<AppRelease, AppUpdateFetchFailure>) -> Void) {
        lock.lock()
        let apiRetryNotBefore = self.apiRetryNotBefore
        lock.unlock()
        if let apiRetryNotBefore, apiRetryNotBefore > Date() {
            fetchReleasePage(apiRetryAfter: apiRetryNotBefore, completion: completion)
            return
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppRelease.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            if error == nil, http?.statusCode == 200,
               let data, data.count < 2_000_000,
               let release = try? JSONDecoder().decode(AppRelease.self, from: data),
               !release.draft, !release.prerelease {
                self.complete(.success(release), completion)
                return
            }
            let limited = http?.statusCode == 429 ||
                (http?.statusCode == 403 && http?.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0")
            let retryAfter = limited ? self.retryDate(from: http) : nil
            if limited, let retryAfter, retryAfter > Date() {
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
            if pageLimited || apiRetryAfter != nil {
                let retryAfter = [apiRetryAfter, self.retryDate(from: http)].compactMap { $0 }.max()
                self.complete(.failure(AppUpdateFetchFailure("GitHub 暂时限制了更新检查，请稍后重试。", retryAfter: retryAfter)), completion)
            } else {
                self.complete(.failure(AppUpdateFetchFailure("GitHub API 和 Release 页面均无法读取。请检查网络或稍后重试；不会安装任何文件。")), completion)
            }
        }.resume()
    }

    private func retryDate(from response: HTTPURLResponse?) -> Date? {
        guard let response else { return nil }
        if let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init), seconds >= 0 {
            return Date().addingTimeInterval(seconds)
        }
        if let epoch = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init), epoch > 0 {
            return Date(timeIntervalSince1970: epoch)
        }
        return nil
    }

    private func complete(
        _ result: Result<AppRelease, AppUpdateFetchFailure>,
        _ completion: @escaping (Result<AppRelease, AppUpdateFetchFailure>) -> Void
    ) {
        DispatchQueue.main.async { completion(result) }
    }
}
