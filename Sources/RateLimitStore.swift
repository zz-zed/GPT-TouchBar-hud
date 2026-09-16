import Foundation

protocol RateLimitStoreDelegate: AnyObject {
    func rateLimitStore(_ store: RateLimitStore, didUpdate state: RateLimitDisplayState)
}

final class RateLimitStore {
    weak var delegate: RateLimitStoreDelegate?

    private let client = CodexAppServerClient()
    private lazy var accountUsage = AccountTokenUsageStore(client: client)
    private var timer: Timer?
    private var state = RateLimitDisplayState.initial
    private var refreshInFlight = false
    private var isStarted = false
    private var generation = 0

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
            self.accountUsage.invalidate()
            self.accountUsage.refresh()
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
        refreshInFlight = false
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
        state.isRefreshing = true
        state.errorMessage = nil
        publish()
        let revision = generation

        client.readRateLimits { [weak self] result in
            guard let self, self.isStarted, self.generation == revision else {
                return
            }

            self.refreshInFlight = false

            switch result {
            case .success(let response):
                self.apply(response)
            case .failure(let error):
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
