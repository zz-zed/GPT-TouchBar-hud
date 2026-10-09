import Foundation

protocol RateLimitClient: QuotaSnapshotClient, AccountUsageClient {
    var onRateLimitsUpdated: (() -> Void)? { get set }
    var onAccountUpdated: (() -> Void)? { get set }
    var onConnectionClosed: ((Error) -> Void)? { get set }
    func start(completion: @escaping (Result<Void, Error>) -> Void)
    func stop()
}

extension CodexAppServerClient: RateLimitClient {}

protocol RateLimitStoreDelegate: AnyObject {
    func rateLimitStore(_ store: RateLimitStore, didUpdate state: RateLimitDisplayState)
}

final class RateLimitStore {
    private enum ConnectionState { case disconnected, connecting, connected, waitingToRetry }
    weak var delegate: RateLimitStoreDelegate?

    private let client: RateLimitClient
    private let diagnostics: DiagnosticRecording
    private var hasConnected = false
    private var hadConnectionFailure = false
    private lazy var quotaReader = VerifiedQuotaReader(client: client)
    private lazy var accountUsage = AccountTokenUsageStore(client: client)
    private(set) var verifiedAccountKey: String?
    private(set) var currentLimitID = "codex"
    private var timer: Timer?
    private var retryTimer: Timer?
    private let retryDelays: [TimeInterval]
    private var retryCount = 0
    private var connectionState = ConnectionState.disconnected
    private var connectionRevision = 0
    private var connectionEstablishedAt: TimeInterval?
    private var forceTokenUsageAfterConnection = false
    private var state = RateLimitDisplayState.initial
    private var refreshInFlight = false
    private var isStarted = false
    private var generation = 0
    private var requestGeneration = 0

    init(client: RateLimitClient? = nil, retryDelays: [TimeInterval] = [1, 2, 5, 15, 30, 60],
         diagnostics: DiagnosticRecording = NoopDiagnosticRecorder()) {
        precondition(!retryDelays.isEmpty && retryDelays.allSatisfy { $0 > 0 && $0.isFinite })
        self.client = client ?? CodexAppServerClient(diagnostics: diagnostics)
        self.diagnostics = diagnostics
        self.retryDelays = retryDelays
    }

    func start() {
        guard !isStarted else {
            refresh(forceTokenUsage: true)
            return
        }
        isStarted = true
        generation += 1
        let revision = generation

        accountUsage.onUpdate = { [weak self] usage in
            guard let self, self.isStarted, self.generation == revision else { return }
            self.state.tokenUsage = usage
            self.publish()
        }
        client.onAccountUpdated = { [weak self] in
            guard let self, self.isStarted, self.generation == revision else { return }
            self.requestGeneration += 1
            self.refreshInFlight = false
            self.verifiedAccountKey = nil
            self.state = .initial
            self.accountUsage.invalidate()
            self.publish()
            self.refresh()
        }

        client.onRateLimitsUpdated = { [weak self] in
            guard let self, self.isStarted, self.generation == revision else { return }
            self.refresh()
        }

        refresh(forceTokenUsage: true)
    }

    private func connect() {
        guard isStarted, connectionState != .connecting else { return }
        retryTimer?.invalidate()
        retryTimer = nil
        connectionState = .connecting
        connectionRevision += 1
        let attempt = connectionRevision
        let revision = generation
        diagnostics.record(.connection(phase: .start, generation: UInt64(attempt), retryCount: retryCount, layer: .store))
        state.isRefreshing = true
        state.errorMessage = nil
        publish()
        guard isStarted, generation == revision, connectionRevision == attempt,
              connectionState == .connecting else { return }

        client.onConnectionClosed = { [weak self] error in
            guard let self, self.isStarted, self.generation == revision,
                  self.connectionRevision == attempt, self.connectionState == .connected else { return }
            self.connectionFailed(error)
        }

        client.start { [weak self] result in
            guard let self, self.isStarted, self.generation == revision,
                  self.connectionRevision == attempt, self.connectionState == .connecting else {
                return
            }

            switch result {
            case .success:
                self.connectionState = .connected
                self.diagnostics.record(.connection(phase: self.hadConnectionFailure || self.hasConnected ? .recovered : .initialize,
                                                    generation: UInt64(attempt), layer: .store))
                self.hasConnected = true
                self.hadConnectionFailure = false
                self.connectionEstablishedAt = ProcessInfo.processInfo.systemUptime
                let force = self.forceTokenUsageAfterConnection
                self.forceTokenUsageAfterConnection = false
                self.startTimer()
                self.refresh(forceTokenUsage: force)
            case .failure(let error):
                self.connectionFailed(error)
            }
        }
    }

    func stop() {
        isStarted = false
        connectionState = .disconnected
        connectionRevision += 1
        connectionEstablishedAt = nil
        retryTimer?.invalidate()
        retryTimer = nil
        retryCount = 0
        forceTokenUsageAfterConnection = false
        generation += 1
        requestGeneration += 1
        refreshInFlight = false
        verifiedAccountKey = nil
        accountUsage.invalidate()
        state.tokenUsage = nil
        timer?.invalidate()
        timer = nil
        client.onConnectionClosed = nil
        client.onAccountUpdated = nil
        client.onRateLimitsUpdated = nil
        client.stop()
    }

    func refresh(forceTokenUsage: Bool = false) {
        guard isStarted else { return }
        guard connectionState == .connected else {
            forceTokenUsageAfterConnection = forceTokenUsageAfterConnection || forceTokenUsage
            connect()
            return
        }
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
                if let connectionError = error as? CodexAppServerError,
                   case .processUnavailable = connectionError {
                    self.connectionFailed(error)
                    return
                }
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

    private func connectionFailed(_ error: Error) {
        hadConnectionFailure = true
        let revision = generation
        if let connectedAt = connectionEstablishedAt,
           ProcessInfo.processInfo.systemUptime - connectedAt >= 60 { retryCount = 0 }
        connectionEstablishedAt = nil
        connectionState = .waitingToRetry
        requestGeneration += 1
        refreshInFlight = false
        verifiedAccountKey = nil
        accountUsage.invalidate()
        timer?.invalidate()
        timer = nil
        publishError(error.localizedDescription)
        guard isStarted, generation == revision, connectionState == .waitingToRetry else { return }
        retryTimer?.invalidate()
        let delay = retryDelays[min(retryCount, retryDelays.count - 1)]
        retryCount = min(retryCount + 1, retryDelays.count - 1)
        diagnostics.record(.connection(phase: .retry, generation: UInt64(connectionRevision),
                                       result: CodexAppServerClient.diagnosticResult(for: error), retryCount: retryCount,
                                       delayMilliseconds: Int(min(86_400_000, delay * 1_000)), layer: .store))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.isStarted, self.generation == revision,
                  self.connectionState == .waitingToRetry else { return }
            self.retryTimer = nil
            self.connect()
        }
        retryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
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
        let windows = RateLimitWindowClassifier.classify(primary: snapshot.primary, secondary: snapshot.secondary)

        state.fiveHour = windows.fiveHour
        state.weekly = windows.weekly
        state.resetCredits = response.rateLimitResetCredits.map(ResetCreditSummary.init)
        state.creditBalance = snapshot.credits.flatMap(CreditBalanceSummary.init)
        state.isRefreshing = false
        state.lastUpdated = Date()
        state.errorMessage = nil
        publish()
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

/// Duration is authoritative. Ordering only supplies labels for legacy windows
/// with no duration, and an input slot can never supply both display meters.
enum RateLimitWindowClassifier {
    static func classify(primary: RateLimitWindow?, secondary: RateLimitWindow?) -> (fiveHour: LimitMeter?, weekly: LimitMeter?) {
        let windows = [primary, secondary]
        var fiveHour = windows.indices.first { index in
            guard let duration = windows[index]?.windowDurationMins else { return false }
            return abs(duration - 300) < 30
        }
        var weekly = windows.indices.first { index in
            guard let duration = windows[index]?.windowDurationMins else { return false }
            return abs(duration - 7 * 24 * 60) <= 60
        }
        if primary != nil, secondary != nil {
            for index in windows.indices where windows[index]?.windowDurationMins == nil {
                guard index != fiveHour, index != weekly else { continue }
                if fiveHour == nil, index == 0 || weekly != nil { fiveHour = index }
                else if weekly == nil, index == 1 || fiveHour != nil { weekly = index }
            }
        } else if let index = windows.indices.first(where: { windows[$0] != nil }),
                  windows[index]?.windowDurationMins == nil {
            // Retain the legacy single-window presentation without relabeling an
            // explicitly supplied daily, monthly or otherwise unsupported period.
            weekly = index
        }
        return (
            fiveHour.flatMap { windows[$0] }.map { LimitMeter(title: "5 小时", shortTitle: "5h", window: $0) },
            weekly.flatMap { windows[$0] }.map { LimitMeter(title: "周限额", shortTitle: "W", window: $0) }
        )
    }
}
