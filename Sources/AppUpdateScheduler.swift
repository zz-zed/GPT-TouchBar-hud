import Foundation

protocol AppReleaseFetching: AnyObject {
    func fetchLatest(completion: @escaping (Result<AppRelease, AppUpdateFetchFailure>) -> Void)
}

enum AppUpdateRequestDisposition: Equatable {
    case started
    case joined
}

enum AppUpdatePresentationPolicy {
    static func shouldPresentResult(for origins: Set<AppUpdateCheckOrigin>) -> Bool {
        origins.contains(.manual)
    }
}

enum AppUpdateAvailabilityPolicy {
    static func storedVersion(for release: AppRelease, skippedVersion: String?) -> String? {
        skippedVersion == release.tag_name ? nil : release.tag_name
    }

    static func skipping(_ version: String, in state: AppUpdatePersistentState) -> AppUpdatePersistentState {
        var result = state
        result.skippedVersion = version
        result.availableVersion = nil
        return result
    }
}

/// Owns one release request at a time. A manual request arriving during an automatic
/// request joins it so both presentation policies can consume the same result.
final class AppUpdateCheckEngine {
    private let fetcher: AppReleaseFetching
    private let currentVersion: String
    private var origins: Set<AppUpdateCheckOrigin> = []
    private(set) var isChecking = false
    var onCompletion: ((AppUpdateCheckOutcome, Set<AppUpdateCheckOrigin>) -> Void)?

    init(fetcher: AppReleaseFetching, currentVersion: String) {
        self.fetcher = fetcher
        self.currentVersion = currentVersion
    }

    @discardableResult
    func request(_ origin: AppUpdateCheckOrigin) -> AppUpdateRequestDisposition {
        origins.insert(origin)
        guard !isChecking else { return .joined }
        isChecking = true
        fetcher.fetchLatest { [weak self] result in
            guard let self else { return }
            let requestOrigins = self.origins
            self.origins.removeAll()
            self.isChecking = false

            let outcome: AppUpdateCheckOutcome
            switch result {
            case let .failure(error):
                outcome = .failure(error)
            case let .success(release):
                guard let latest = AppVersion(release.tag_name), let current = AppVersion(self.currentVersion) else {
                    outcome = .failure(AppUpdateFetchFailure("发布版本格式无效，不会安装任何文件。"))
                    break
                }
                outcome = latest > current ? .update(release) : .upToDate(release)
            }
            self.onCompletion?(outcome, requestOrigins)
        }
        return .started
    }
}

struct AppUpdateSchedulePolicy {
    let startupDelay: TimeInterval
    let successInterval: TimeInterval
    let retryDelays: [TimeInterval]
    let exhaustedRetryDelay: TimeInterval

    static let standard = AppUpdateSchedulePolicy(
        startupDelay: 30,
        successInterval: 24 * 60 * 60,
        retryDelays: [5 * 60, 30 * 60, 2 * 60 * 60],
        exhaustedRetryDelay: 24 * 60 * 60
    )

    func firstScheduledDate(launchedAt: Date, state: AppUpdatePersistentState, now: Date) -> Date {
        max(launchedAt.addingTimeInterval(startupDelay), nextEligibleDate(state: state, now: now))
    }

    func nextEligibleDate(state: AppUpdatePersistentState, now: Date) -> Date {
        var result = now
        if let lastSuccess = state.lastSuccess {
            result = max(result, lastSuccess.addingTimeInterval(successInterval))
        }
        if let retryNotBefore = state.retryNotBefore {
            result = max(result, retryNotBefore)
        }
        return result
    }

    func isDue(state: AppUpdatePersistentState, now: Date) -> Bool {
        nextEligibleDate(state: state, now: now) <= now
    }

    func recordingSuccess(in state: AppUpdatePersistentState, at date: Date) -> AppUpdatePersistentState {
        var result = state
        result.lastSuccess = date
        result.consecutiveAutomaticFailures = 0
        result.retryNotBefore = nil
        return result
    }

    func recordingAutomaticFailure(
        in state: AppUpdatePersistentState,
        at date: Date,
        serverRetryAfter: Date?
    ) -> AppUpdatePersistentState {
        var result = state
        let failureCount = state.consecutiveAutomaticFailures + 1
        result.consecutiveAutomaticFailures = failureCount
        let delay = failureCount <= retryDelays.count
            ? retryDelays[failureCount - 1]
            : exhaustedRetryDelay
        var retryDate = date.addingTimeInterval(delay)
        if let serverRetryAfter { retryDate = max(retryDate, serverRetryAfter) }
        result.retryNotBefore = retryDate
        return result
    }
}

struct AppUpdateSchedulePlanner {
    let launchedAt: Date
    let policy: AppUpdateSchedulePolicy

    func nextDate(state: AppUpdatePersistentState, now: Date) -> Date {
        policy.firstScheduledDate(launchedAt: launchedAt, state: state, now: now)
    }

    func shouldCheckAfterWake(state: AppUpdatePersistentState, now: Date) -> Bool {
        nextDate(state: state, now: now) <= now
    }
}

enum AppUpdateRuntime {
    static func allowsAutomaticChecks(
        bundleURL: URL,
        bundleIdentifier: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard bundleIdentifier == "io.github.zz-zed.GPTTouchBarHUD" else { return false }
        let target = bundleURL.standardizedFileURL
        let allowed = [
            URL(fileURLWithPath: "/Applications/GPT TouchBar HUD.app").standardizedFileURL,
            homeDirectory.appendingPathComponent("Applications/GPT TouchBar HUD.app").standardizedFileURL
        ]
        return allowed.contains(target) && target.pathExtension == "app"
    }
}
