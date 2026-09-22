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
    private var checking = false
    private var failures = 0
    private var earliestRequest: Date?
    private var recoveryPendingSources: Set<ResetNewsSource> = []

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
        state.items = repository.state.items
        state.readIDs = repository.state.readIDs
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

    deinit { for observer in clockObservers { notificationCenter.removeObserver(observer) } }

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
        recoveryPendingSources = Set(repository.state.baselineSources)
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
        let stale = successful.contains { $0.metadata.isStale(at: date) }
        let rejected = successful.reduce(0) { $0 + $1.metadata.rejectedIdentityCount }
        if !successful.isEmpty {
            let previous = repository.state
            let incoming = successful.flatMap(\.items)
            let successfulSources = Set(successful.map(\.source))
            let recoveringSources = recoveryPendingSources.intersection(successfulSources)
            let recoveringIDs = Set(incoming.filter { recoveringSources.contains($0.source) }.map(\.stableID))
            let reduction = ResetNewsReducer(forecastPolicy: ResetForecastPolicy(calendar: calendar())).reduce(
                previous: ResetNewsState(items: previous.items, notificationRecords: previous.notified, hasBaseline: previous.hasBaseline,
                                         retiredForecasts: previous.retiredForecasts),
                incoming: incoming, now: date)
            var next = previous
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
            let saved = repository.replace(next, now: date)
            syncRepository()
            state.lastSuccess = date
            // A stale endpoint suppresses this whole refresh's strong reminders. Persisting consumption prevents replay.
            if saved && !stale {
                var candidates = reduction.notificationCandidates
                candidates += reduction.recoveryCandidates.filter { recoveringIDs.contains($0.id) }
                candidates = candidates.filter { previouslyBaselinedIDs.contains($0.id) }
                // One local notification summarizes a batch, including recovery after sleep/lock or process absence.
                notifications.deliver(candidates, recovery: !recoveringSources.isEmpty, now: date, calendar: calendar())
            }
            // A successful endpoint cannot consume recovery eligibility belonging to a failed endpoint.
            recoveryPendingSources.subtract(successfulSources)
        }
        if successful.isEmpty {
            state.status = .failure
        } else if !result.failures.isEmpty || rejected > 0 {
            state.status = .partial
        } else if stale {
            state.status = .stale
        } else {
            state.status = .success
        }
        let errors = result.failures.compactMap { endpoint in endpoint.error.map { "\(endpoint.source.rawValue)：\($0.description)" } }
        var details = errors
        if rejected > 0 { details.append("已跳过 \(rejected) 条来源身份不匹配的消息") }
        if stale { details.append("发布副本已过期，已暂停强提醒") }
        if let error = repository.lastPersistenceError { details.append(error) }
        state.detail = details.isEmpty ? nil : details.joined(separator: "；")
        let delay: TimeInterval
        if result.failures.isEmpty && !stale {
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
        state.items = repository.state.items
        state.readIDs = repository.state.readIDs
        if let error = repository.lastPersistenceError { state.detail = error }
    }

    private func publish() {
        precondition(Thread.isMainThread)
        repository.refreshLocalForecasts(now: now())
        syncRepository()
        state.notificationPermission = notifications.permission
        onStateChange?(state)
    }

    private static func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() }
        else { DispatchQueue.main.async(execute: action) }
    }
}
