import Foundation

protocol RateLimitClient: QuotaSnapshotClient, AccountUsageClient {
    var onRateLimitsUpdated: (() -> Void)? { get set }
    var onAccountUpdated: (() -> Void)? { get set }
    func start(completion: @escaping (Result<Void, Error>) -> Void)
    func stop()
}

extension CodexAppServerClient: RateLimitClient {}

protocol RateLimitStoreDelegate: AnyObject {
    func rateLimitStore(_ store: RateLimitStore, didUpdate state: RateLimitDisplayState)
}

final class RateLimitStore {
    weak var delegate: RateLimitStoreDelegate?

    private let client: RateLimitClient
    private lazy var quotaReader = VerifiedQuotaReader(client: client)
    private lazy var accountUsage = AccountTokenUsageStore(client: client)
    private(set) var verifiedAccountKey: String?
    private(set) var currentLimitID = "codex"
    private var timer: Timer?
    private var state = RateLimitDisplayState.initial
    private var refreshInFlight = false
    private var isStarted = false
    private var generation = 0
    private var requestGeneration = 0

    init(client: RateLimitClient = CodexAppServerClient()) { self.client = client }

    func start() {
        guard !isStarted else {
            refresh(forceTokenUsage: true)
            return
        }
        isStarted = true
        generation += 1
        let revision = generation

        accountUsage.onUpdate = { [weak self] usage in
            guard let self, self.isStarted else { return }
            self.state.tokenUsage = usage
            self.publish()
        }
        client.onAccountUpdated = { [weak self] in
            guard let self, self.isStarted else { return }
            self.requestGeneration += 1
            self.refreshInFlight = false
            self.verifiedAccountKey = nil
            self.state = .initial
            self.accountUsage.invalidate()
            self.publish()
            self.refresh()
        }

        client.onRateLimitsUpdated = { [weak self] in
            self?.refresh()
        }

        client.start { [weak self] result in
            guard let self, self.isStarted, self.generation == revision else {
                return
            }

            switch result {
            case .success:
                self.refresh()
                self.startTimer()
            case .failure(let error):
                self.publishError(error.localizedDescription)
            }
        }
    }

    func stop() {
        isStarted = false
        generation += 1
        requestGeneration += 1
        refreshInFlight = false
        verifiedAccountKey = nil
        accountUsage.invalidate()
        state.tokenUsage = nil
        timer?.invalidate()
        timer = nil
        client.stop()
    }

    func refresh(forceTokenUsage: Bool = false) {
        guard isStarted else { return }
        accountUsage.refresh(force: forceTokenUsage)
        guard !refreshInFlight else {
            return
        }

        refreshInFlight = true
        requestGeneration += 1
        state.isRefreshing = true
        state.errorMessage = nil
        publish()
        let revision = generation
        let requestRevision = requestGeneration

        quotaReader.read { [weak self] result in
            guard let self, self.isStarted, self.generation == revision,
                  self.requestGeneration == requestRevision else {
                return
            }

            self.refreshInFlight = false

            switch result {
            case .success(let snapshot):
                if let previous = self.verifiedAccountKey, let next = snapshot.accountKey, previous != next {
                    self.state = .initial
                    self.verifiedAccountKey = nil
                    self.accountUsage.invalidate()
                    self.publish()
                    self.accountUsage.refresh()
                }
                self.verifiedAccountKey = snapshot.accountKey
                self.apply(snapshot.response)
            case .failure(let error):
                if error is QuotaIdentityError {
                    self.verifiedAccountKey = nil
                    self.state = .initial
                    self.accountUsage.invalidate()
                }
                self.state.isRefreshing = false
                self.state.errorMessage = error.localizedDescription
                self.publish()
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func apply(_ response: GetAccountRateLimitsResponse) {
        let snapshot = response.rateLimitsByLimitId?["codex"] ?? response.rateLimits
        currentLimitID = snapshot.limitId ?? "codex"
        let windows = classifyWindows(primary: snapshot.primary, secondary: snapshot.secondary)

        state.fiveHour = windows.fiveHour
        state.weekly = windows.weekly
        state.resetCredits = response.rateLimitResetCredits.map(ResetCreditSummary.init)
        state.creditBalance = snapshot.credits.flatMap(CreditBalanceSummary.init)
        state.isRefreshing = false
        state.lastUpdated = Date()
        state.errorMessage = nil
        publish()
    }

    private func classifyWindows(primary: RateLimitWindow?, secondary: RateLimitWindow?) -> (fiveHour: LimitMeter?, weekly: LimitMeter?) {
        let candidates = [primary, secondary].compactMap { $0 }

        var fiveHourWindow = candidates.first { window in
            guard let duration = window.windowDurationMins else {
                return false
            }
            return abs(duration - 300) < 30
        }

        var weeklyWindow = candidates.first { window in
            guard let duration = window.windowDurationMins else {
                return false
            }
            return duration >= 7 * 24 * 60 - 60
        }

        // Older app-server versions relied on primary/secondary ordering and did
        // not always include durations. Only use that fallback when two distinct
        // windows are present, so a weekly-only window is never duplicated as 5h.
        if primary != nil, secondary != nil {
            fiveHourWindow = fiveHourWindow ?? primary
            weeklyWindow = weeklyWindow ?? secondary
        } else if fiveHourWindow == nil, weeklyWindow == nil {
            weeklyWindow = primary ?? secondary
        }

        let fiveHour = fiveHourWindow.map {
            LimitMeter(title: "5 小时", shortTitle: "5h", window: $0)
        }

        let weekly = weeklyWindow.map {
            LimitMeter(title: "周限额", shortTitle: "W", window: $0)
        }

        return (fiveHour, weekly)
    }

    private func publishError(_ message: String) {
        state.isRefreshing = false
        state.errorMessage = message
        publish()
    }

    private func publish() {
        delegate?.rateLimitStore(self, didUpdate: state)
    }

}
