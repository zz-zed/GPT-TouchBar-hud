import Foundation
import ResetNewsCore

protocol ResetNewsScheduling: AnyObject {
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> ResetNewsCancellable
}

final class ResetNewsMainQueueScheduler: ResetNewsScheduling {
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> ResetNewsCancellable {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
        return ResetNewsCancellation { work.cancel() }
    }
}

enum ResetNewsCheckDisposition: Equatable { case started, joined, throttled, inactive }

/// Owns all mutable runtime state on the main thread. Callback boundaries always re-check generation and gates.
final class ResetNewsMonitor {
    static let enabledPreferenceKey = "resetNewsEnabled"
    static let soundPreferenceKey = "resetNewsSoundEnabled"

    var onStateChange: ((ResetNewsViewState) -> Void)?
    var onOpenDetails: (([String]) -> Void)?
    private(set) var state = ResetNewsViewState()
    private let repository: ResetNewsRepository
    private let client: ResetNewsFetching
    private let notifications: ResetNewsNotificationController
    private let scheduler: ResetNewsScheduling
    private let defaults: UserDefaults
    private let now: () -> Date
    private let jitter: () -> Double
    private let calendar: () -> Calendar
    private let notificationCenter: NotificationCenter
    private var clockObservers: [NSObjectProtocol] = []
    private var codexRunning = false
    private var hudRunning = false
    private var suspended = false
    private var runtimeActive = false
    private var generation = 0
    private var request: ResetNewsCancellable?
    private var timer: ResetNewsCancellable?
    private var projectionTimer: ResetNewsCancellable?
    private var projectionDate: Date?
    private var checking = false
    private var failures = 0
    private var earliestRequest: Date?
    private var forecastRefreshFailed = true
    private var recoveringForecast = false

    var enabled: Bool { state.enabled }
    var soundEnabled: Bool { notifications.soundEnabled }
    var isPollingAllowed: Bool { enabled && codexRunning && hudRunning && !suspended }

    init(repository: ResetNewsRepository = ResetNewsRepository(), client: ResetNewsFetching = ResetNewsFeedClient(),
         notifications: ResetNewsNotificationController = ResetNewsNotificationController(),
         scheduler: ResetNewsScheduling = ResetNewsMainQueueScheduler(), defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init, jitter: @escaping () -> Double = { Double.random(in: 0...1) },
         calendar: @escaping () -> Calendar = { .current }, notificationCenter: NotificationCenter = .default) {
        precondition(Thread.isMainThread)
        self.repository = repository
        self.client = client
        self.notifications = notifications
        self.scheduler = scheduler
        self.defaults = defaults
        self.now = now
        self.jitter = jitter
        self.calendar = calendar
        self.notificationCenter = notificationCenter
        repository.refreshLocalForecasts(now: now())
        // Default on only when no choice was saved; never overwrite an explicit opt-out.
        state.enabled = defaults.object(forKey: Self.enabledPreferenceKey) == nil
            ? true : defaults.bool(forKey: Self.enabledPreferenceKey)
        notifications.soundEnabled = defaults.bool(forKey: Self.soundPreferenceKey)
        syncRepository()
        state.detail = repository.lastPersistenceError
        state.status = state.enabled ? .codexNotRunning : .disabled
        notifications.onOpenDetails = { [weak self] ids in
            guard let self else { return }
            self.publish() // A notification can be opened after the local calendar day changed.
            self.onOpenDetails?(ids.filter { id in self.state.items.contains { $0.id == id } })
        }
        notifications.onPermissionChange = { [weak self] permission in
            Self.onMain {
                guard let self else { return }
                self.state.notificationPermission = permission
                self.publish()
            }
        }
        if state.enabled { notifications.enable() }
        for name in [Notification.Name.NSCalendarDayChanged, Notification.Name.NSSystemTimeZoneDidChange] {
            clockObservers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.publish() // Local-only pruning: no permission prompt or network request.
            })
        }
    }

    deinit {
        projectionTimer?.cancel()
        for observer in clockObservers { notificationCenter.removeObserver(observer) }
    }

    func setEnabled(_ enabled: Bool) {
        precondition(Thread.isMainThread)
        state.enabled = enabled
        defaults.set(enabled, forKey: Self.enabledPreferenceKey)
        if enabled { notifications.enable() }
        reconcileGate()
    }

    func setSoundEnabled(_ enabled: Bool) {
        precondition(Thread.isMainThread)
        notifications.soundEnabled = enabled
        defaults.set(enabled, forKey: Self.soundPreferenceKey)
    }

    func updateGate(codexRunning: Bool, hudRunning: Bool, suspended: Bool) {
        precondition(Thread.isMainThread)
        self.codexRunning = codexRunning
        self.hudRunning = hudRunning
        self.suspended = suspended
        reconcileGate()
    }

    func stop() {
        precondition(Thread.isMainThread)
        hudRunning = false
        stopWork()
        state.status = enabled ? .idle : .disabled
        publish()
    }

    @discardableResult
    func checkNow() -> ResetNewsCheckDisposition {
        precondition(Thread.isMainThread)
        return beginCheck()
    }

    /// Call only for cards actually viewed, never for opening the surrounding menu or history window.
    func markRead(_ ids: Set<String>) {
        precondition(Thread.isMainThread)
        repository.markRead(ids, now: now())
        syncRepository()
        publish()
    }

    func markAllRead() {
        precondition(Thread.isMainThread)
        repository.markAllRead(now: now())
        syncRepository()
        publish()
    }

    private func reconcileGate() {
        guard isPollingAllowed else {
            stopWork()
            state.status = !enabled ? .disabled : (!codexRunning ? .codexNotRunning : .idle)
            publish()
            return
        }
        guard !runtimeActive else { publish(); return }
        runtimeActive = true
        recoveringForecast = repository.state.forecastBaselineEstablished == true
        notifications.resume()
        beginCheck()
    }

    private func stopWork() {
        generation += 1
        runtimeActive = false
        checking = false
        request?.cancel()
        request = nil
        timer?.cancel()
        timer = nil
        state.nextCheck = nil
        notifications.stop()
    }

    @discardableResult
    private func beginCheck() -> ResetNewsCheckDisposition {
        guard isPollingAllowed, runtimeActive else { return .inactive }
        guard !checking else { return .joined }
        let date = now()
        if let earliestRequest, earliestRequest > date {
            schedule(at: earliestRequest)
            publish()
            return .throttled
        }
        timer?.cancel()
        timer = nil
        checking = true
        state.status = .checking
        state.detail = nil
        state.lastAttempt = date
        state.nextCheck = nil
        earliestRequest = date.addingTimeInterval(ResetNewsSchedule.minimumInterval)
        let requestGeneration = generation
        publish()
        let token = client.fetch { [weak self] result in
            Self.onMain {
                guard let self, self.generation == requestGeneration, self.isPollingAllowed, self.runtimeActive else { return }
                self.complete(result)
            }
        }
        // A test transport may finish synchronously.
        if checking { request = token }
        return .started
    }

    private func complete(_ result: ResetNewsFetchResult) {
        checking = false
        request = nil
        let date = now()
        if let retry = result.retryAfter { earliestRequest = max(earliestRequest ?? date, retry) }
        let successful = result.successful
        var stale = successful.contains { $0.metadata.isStale(at: date) }
        let rejected = successful.reduce(0) { $0 + $1.metadata.rejectedIdentityCount }
        var forecastIssue: String?
        forecastRefreshFailed = true
        if !successful.isEmpty {
            let previous = repository.state
            var incoming = successful.filter { $0.source != .forecast }.flatMap(\.items)
            var next = previous
            var reminder: ResetForecastSnapshot?
            if let endpoint = successful.first(where: { $0.source == .forecast }), let snapshot = endpoint.forecast {
                // A cached or delayed response cannot undo a more recent current-signal decision.
                let expires = endpoint.metadata.publishedExpiresAt ?? snapshot.updatedAt.addingTimeInterval(180)
                let outOfOrder = previous.forecast.map { snapshot.updatedAt < $0.updatedAt } ?? false
                let conflictingVersion = previous.forecast.map {
                    snapshot.updatedAt == $0.updatedAt
                        && (snapshot.notificationKey != $0.notificationKey || snapshot.lastResetAt != $0.lastResetAt)
                } ?? false
                let futureDated = snapshot.updatedAt > date.addingTimeInterval(60)
                let expired = endpoint.metadata.isStale(at: date) || expires <= date
                stale = stale || expired
                if outOfOrder || conflictingVersion || futureDated {
                    forecastIssue = "当前预告副本时间异常，保留上次结果"
                } else {
                    // Consume even stale signals so a later fresh copy cannot replay an old alert.
                    let unseen = snapshot.notificationKey.map { !previous.notifiedKeys.contains($0) } ?? false
                    if let key = snapshot.notificationKey, unseen {
                        next.notified.append(.init(key: key, recordedAt: date))
                    }
                    if !expired {
                        next.forecast = snapshot
                        next.forecastFetchedAt = date
                        next.forecastExpiresAt = expires
                        next.forecastBaselineEstablished = true
                        forecastRefreshFailed = false
                        if let signal = snapshot.officialSignal {
                            let evidence = signal.evidenceItem(calendar: calendar())
                            incoming.append(ResetNewsSourceItem(source: .forecast, sourceID: signal.sourceID,
                                url: signal.sourceURL, body: signal.originalText, publishedAt: signal.publishedAt,
                                structuredFacts: evidence.facts))
                        }
                        if previous.forecastBaselineEstablished == true, unseen { reminder = snapshot }
                    }
                }
            } else if !result.failures.contains(where: { $0.source == .forecast }) {
                forecastIssue = "当前预告状态未获取"
            }
            let reduction = ResetNewsReducer(forecastPolicy: ResetForecastPolicy(calendar: calendar())).reduce(
                previous: ResetNewsState(items: previous.items, notificationRecords: next.notified, hasBaseline: previous.hasBaseline,
                                         retiredForecasts: previous.retiredForecasts),
                incoming: incoming, now: date)
            next.items = reduction.state.items
            next.notified = reduction.state.notificationRecords
            next.retiredForecasts = reduction.state.retiredForecasts
            for endpoint in successful where !next.baselineSources.contains(endpoint.source) { next.baselineSources.append(endpoint.source) }
            let previouslyBaselinedIDs = Set(incoming.filter { previous.baselineSources.contains($0.source) }.map(\.stableID))
            let previousByID = Dictionary(uniqueKeysWithValues: previous.items.map { ($0.id, $0) })
            for item in next.items {
                if previousByID[item.id] == nil && !previouslyBaselinedIDs.contains(item.id) {
                    next.readIDs.insert(item.id) // Each endpoint's initial history is a silent, read baseline.
                } else if previousByID[item.id]?.materialRevision != item.materialRevision {
                    next.readIDs.remove(item.id)
                }
            }
            if !forecastRefreshFailed, let snapshot = next.forecast,
               let item = snapshot.item(now: date, calendar: calendar()) {
                if previous.forecastBaselineEstablished != true {
                    next.readIDs.insert(item.id)
                } else if let key = snapshot.notificationKey, !previous.notifiedKeys.contains(key) {
                    next.readIDs.remove(item.id)
                } else if previous.readIDs.contains(item.id) {
                    next.readIDs.insert(item.id)
                }
            }
            let saved = repository.replace(next, now: date)
            syncRepository()
            state.lastSuccess = date
            // Only the accepted current signal may notify. Feed/timeline remain evidence,
            // including when their history contains explicit future wording.
            if saved {
                if let reminder { notifications.deliver(reminder, recovery: recoveringForecast, now: date, calendar: calendar()) }
            }
            if !forecastRefreshFailed { recoveringForecast = false }
        }
        if successful.isEmpty {
            state.status = .failure
        } else if !result.failures.isEmpty || rejected > 0 || forecastIssue != nil {
            state.status = .partial
        } else if stale {
            state.status = .stale
        } else {
            state.status = .success
        }
        let errors = result.failures.compactMap { endpoint in endpoint.error.map { "\(endpoint.source.rawValue)：\($0.description)" } }
        var details = errors
        if let forecastIssue { details.append(forecastIssue) }
        if rejected > 0 { details.append("已跳过 \(rejected) 条来源身份不匹配的消息") }
        if stale { details.append("部分来源副本已过期") }
        if forecastRefreshFailed { details.append("当前预告未更新，已暂停强提醒") }
        if let error = repository.lastPersistenceError { details.append(error) }
        state.detail = details.isEmpty ? nil : details.joined(separator: "；")
        let delay: TimeInterval
        if result.failures.isEmpty && !stale && forecastIssue == nil {
            failures = 0
            delay = ResetNewsSchedule.successDelay(jitter: jitter())
        } else {
            failures += 1
            delay = ResetNewsSchedule.failureDelay(failures)
        }
        schedule(at: max(date.addingTimeInterval(delay), earliestRequest ?? date))
        publish()
    }

    private func schedule(at date: Date) {
        guard isPollingAllowed, runtimeActive else { return }
        timer?.cancel()
        state.nextCheck = date
        let scheduledGeneration = generation
        timer = scheduler.schedule(after: max(0, date.timeIntervalSince(now()))) { [weak self] in
            guard let self, self.generation == scheduledGeneration, self.isPollingAllowed, self.runtimeActive else { return }
            self.timer = nil
            self.beginCheck()
        }
    }

    private func syncRepository() {
        let stored = repository.state
        let date = now()
        state.items = stored.forecast?.item(now: date, calendar: calendar()).map { [$0] } ?? []
        state.forecastAvailability = stored.forecast == nil ? .unknown
            : (!forecastRefreshFailed && runtimeActive && stored.forecastExpiresAt.map { $0 > date } == true ? .current : .cached)
        state.forecastCheckedAt = stored.forecastFetchedAt
        state.readIDs = repository.state.readIDs
        if let error = repository.lastPersistenceError { state.detail = error }
    }

    private func publish() {
        precondition(Thread.isMainThread)
        repository.refreshLocalForecasts(now: now())
        syncRepository()
        scheduleProjection()
        state.notificationPermission = notifications.permission
        onStateChange?(state)
    }

    /// Expiry changes the local presentation even when the next network check is
    /// later or Codex has stopped. This timer never fetches or posts a notification.
    private func scheduleProjection() {
        let date = now()
        let next = [repository.state.forecastExpiresAt,
                    repository.state.forecast?.officialSignal?.expiresAt(calendar: calendar())]
            .compactMap { $0 }.filter { $0 > date }.min()
        guard next != projectionDate else { return }
        projectionTimer?.cancel()
        projectionTimer = nil
        projectionDate = next
        guard let next else { return }
        projectionTimer = scheduler.schedule(after: next.timeIntervalSince(date)) { [weak self] in
            guard let self else { return }
            self.projectionTimer = nil
            self.projectionDate = nil
            self.publish()
        }
    }

    private static func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() }
        else { DispatchQueue.main.async(execute: action) }
    }
}
