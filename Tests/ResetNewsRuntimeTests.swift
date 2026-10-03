import Foundation
import ResetNewsCore

// Standalone assertions keep these injected tests runnable with the project's Swift 5.8 / macOS 11 baseline.
private final class RuntimeClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar = Calendar.current
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

private final class FakeNewsClient: ResetNewsFetching {
    var callbacks: [(ResetNewsFetchResult) -> Void] = []
    var cancellations = 0
    func fetch(completion: @escaping (ResetNewsFetchResult) -> Void) -> ResetNewsCancellable {
        callbacks.append(completion)
        return ResetNewsCancellation { [weak self] in self?.cancellations += 1 }
    }
    func complete(_ result: ResetNewsFetchResult, index: Int? = nil) { callbacks[index ?? callbacks.count - 1](result) }
}

private final class FakeNewsScheduler: ResetNewsScheduling {
    struct Entry { let delay: TimeInterval; let action: () -> Void }
    var entries: [Entry] = []
    var cancellations = 0
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> ResetNewsCancellable {
        entries.append(.init(delay: delay, action: action))
        return ResetNewsCancellation { [weak self] in self?.cancellations += 1 }
    }
}

private final class FakeNewsNotifications: ResetNewsNotificationChannel {
    var onOpen: (([String]) -> Void)?
    var permission: ResetNewsNotificationPermission = .allowed
    var requests = 0
    var permissionReads = 0
    var payloads: [ResetNewsNotificationPayload] = []
    var removedPrefixes: [String] = []
    var delayedAdds: [(Error?) -> Void] = []
    var deferAdd = false
    var deferPermission = false
    var pendingPermission: ((ResetNewsNotificationPermission) -> Void)?
    var deferPermissionRead = false
    var pendingPermissionReads: [(ResetNewsNotificationPermission) -> Void] = []
    func requestAuthorization(completion: @escaping (ResetNewsNotificationPermission) -> Void) {
        requests += 1
        if deferPermission { pendingPermission = completion } else { completion(permission) }
    }
    func readPermission(completion: @escaping (ResetNewsNotificationPermission) -> Void) {
        permissionReads += 1
        if deferPermissionRead { pendingPermissionReads.append(completion) } else { completion(permission) }
    }
    func add(_ payload: ResetNewsNotificationPayload, completion: @escaping (Error?) -> Void) {
        payloads.append(payload)
        if deferAdd { delayedAdds.append(completion) } else { completion(nil) }
    }
    func removePending(prefix: String) { removedPrefixes.append(prefix) }
}

private final class FakeNewsHTTP: ResetNewsHTTPTransport {
    var requests: [URLRequest] = []
    var completions: [(Data?, URLResponse?, Error?) -> Void] = []
    var cancelled = 0
    func send(_ request: URLRequest, completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> ResetNewsCancellable {
        requests.append(request); completions.append(completion)
        return ResetNewsCancellation { [weak self] in self?.cancelled += 1 }
    }
    func respond(_ index: Int, body: String, status: Int = 200, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: requests[index].url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        completions[index](Data(body.utf8), response, nil)
    }
}

private final class RuntimeHarness {
    let clock = RuntimeClock()
    let client = FakeNewsClient()
    let scheduler = FakeNewsScheduler()
    let notificationCenter = NotificationCenter()
    let channel = FakeNewsNotifications()
    let directory: URL
    let repository: ResetNewsRepository
    let defaults: UserDefaults
    let suite = "reset-news-tests.\(UUID().uuidString)"
    let monitor: ResetNewsMonitor
    let notifications: ResetNewsNotificationController

    // Most lifecycle tests start explicitly disabled; nil exercises the product's unset default.
    init(corrupt: Bool = false, enabledPreference: Bool? = false, soundPreference: Bool? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("reset-news-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if corrupt { try Data("broken snapshot".utf8).write(to: directory.appendingPathComponent("state-v1.json")) }
        let clock = self.clock
        repository = ResetNewsRepository(directory: directory, now: clock.date, calendar: { clock.calendar })
        defaults = UserDefaults(suiteName: suite)!
        if let enabledPreference { defaults.set(enabledPreference, forKey: ResetNewsMonitor.enabledPreferenceKey) }
        if let soundPreference { defaults.set(soundPreference, forKey: ResetNewsMonitor.soundPreferenceKey) }
        notifications = ResetNewsNotificationController(channel: channel)
        monitor = ResetNewsMonitor(repository: repository, client: client, notifications: notifications,
                                   scheduler: scheduler, defaults: defaults, now: { clock.date }, jitter: { 0 },
                                   calendar: { clock.calendar }, notificationCenter: notificationCenter)
    }
    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    func activate() {
        monitor.updateGate(codexRunning: true, hudRunning: true, suspended: false)
        monitor.setEnabled(true)
    }
    func next(_ result: @autoclosure () throws -> ResetNewsFetchResult) rethrows {
        clock.advance(120)
        monitor.checkNow()
        client.complete(try result())
    }
    func source(_ id: String, source: ResetNewsSource = .feed, age: TimeInterval = 0) -> ResetNewsSourceItem {
        let canonicalID = id.allSatisfy(\.isNumber) ? id
            : String(id.utf8.reduce(UInt64(9000)) { ($0 &* 31) &+ UInt64($1) })
        return .init(source: source, sourceID: canonicalID, url: URL(string: "https://x.com/thsottiaux/status/\(canonicalID)"),
              body: "Codex limits will reset at the announced time.", publishedAt: clock.date.addingTimeInterval(-age),
              structuredFacts: [.init(kind: .upcomingReset, effectiveAt: Date(timeIntervalSince1970: 1_800_086_400))])
    }
    func result(_ items: [ResetNewsSourceItem], stale: Bool = false, expires: Date? = nil,
                timelineError: ResetNewsFetchError? = nil, rejected: Int = 0,
                forecast: ResetForecastSnapshot? = nil, forecastError: ResetNewsFetchError? = nil,
                missingForecast: Bool = false, forecastStale: Bool? = nil) -> ResetNewsFetchResult {
        // Lifecycle tests explicitly inject a matching authority snapshot. Production never
        // derives current availability from these feed/timeline context candidates.
        let authority = missingForecast || forecastError != nil ? nil : forecast ?? snapshot(items)
        return .init(endpoints: [
            .init(source: .feed, items: items.filter { $0.source == .feed },
                  metadata: .init(publishedExpiresAt: expires, stale: stale, rejectedIdentityCount: rejected), error: nil),
            .init(source: .timeline, items: items.filter { $0.source == .timeline }, metadata: .init(), error: timelineError),
            .init(source: .forecast, items: [], metadata: .init(publishedExpiresAt: expires ?? clock.date.addingTimeInterval(3600), stale: forecastStale ?? stale),
                  error: forecastError, forecast: authority)
        ])
    }

    func snapshot(_ items: [ResetNewsSourceItem], updatedAt: Date? = nil, lastResetAt: Date? = nil) -> ResetForecastSnapshot {
        let previous = repository.state
        let reduction = ResetNewsReducer(forecastPolicy: .init(calendar: clock.calendar)).reduce(
            previous: .init(items: previous.items, notificationRecords: previous.notified,
                            hasBaseline: previous.hasBaseline, retiredForecasts: previous.retiredForecasts),
            incoming: items, now: clock.date)
        // The test authority contains one official signal, independently of how many context cards exist.
        let candidate = items.isEmpty ? nil : reduction.state.items.last
        let signal = candidate.flatMap { item -> ResetForecastSignal? in
            guard let url = item.sourceURL, let fact = item.facts.first else { return nil }
            let sourceID = item.id.components(separatedBy: ":").last!
            return .init(sourceID: sourceID, sourceURL: url, originalText: item.originalText,
                         publishedAt: item.publishedAt ?? clock.date, officialWindow: fact.officialWindow,
                         effectiveAt: fact.effectiveAt)
        }
        return .init(updatedAt: updatedAt ?? clock.date, lastResetAt: lastResetAt, officialSignal: signal)
    }
}

@main enum ResetNewsRuntimeTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        checks += 1
    }

    static func main() throws {
        try defaultEnabledAndSavedPreferences()
        try gatesAndCancellation()
        try baselineReadAndDeduplication()
        try partialAndStale()
        try partialRefreshKeepsMergedFacts()
        try recoveryWaitsForEachBaselinedSource()
        try recoveryAndBackoff()
        try repositoryAndRetention()
        try localCalendarPruning()
        try legacyDiskMigration()
        try notificationChannel()
        try notificationPermissionRefresh()
        try httpClient()
        try capturedAPIRecordsAndEndpointRecovery()
        try observationsAreValidEmptyResponses()
        try officialIdentityFailuresRemainVisible()
        try passedClockDoesNotNotifyOnDiscoveryOrRecovery()
        try authorityNullCannotPromoteHistoricalCandidates()
        try authorityFailureAndMissingFieldsKeepCache()
        try authorityExpiryIsLocalAndDoesNotClaimCompletion()
        try latestResetDoesNotRetireAnIndependentFutureSignal()
        try authorityRestartAndReturnDoNotReplay()
        try reverseResponsesAndSnapshotRollback()
        try staleContextCannotSuppressFreshAuthority()
        try conflictingSameVersionCannotUndoAuthority()
        print("PASS: \(checks) reset news runtime checks; network and notification delivery were injected")
    }

    static func passedClockDoesNotNotifyOnDiscoveryOrRecovery() throws {
        let h = try RuntimeHarness()
        h.activate()
        h.client.complete(h.result([]))
        var past = h.source("801")
        past.structuredFacts = [.init(kind: .upcomingReset, effectiveAt: h.clock.date.addingTimeInterval(-60), effectiveAtPrecision: .exact)]
        h.next(h.result([past]))
        expect(h.monitor.state.forecastCount == 0 && h.repository.state.items.count == 1 && h.channel.payloads.isEmpty,
               "A passed exact clock remains context without becoming a current forecast or reminder")
        h.monitor.updateGate(codexRunning: false, hudRunning: true, suspended: false)
        h.clock.advance(120)
        h.monitor.updateGate(codexRunning: true, hudRunning: true, suspended: false)
        var recovered = h.source("802", age: 7 * 3600)
        recovered.structuredFacts = [.init(kind: .upcomingReset, effectiveAt: h.clock.date.addingTimeInterval(-60), effectiveAtPrecision: .deadline)]
        h.client.complete(h.result([past, recovered]))
        expect(h.monitor.state.forecastCount == 0 && h.repository.state.items.count == 2 && h.channel.payloads.isEmpty,
               "Recovery retains passed deadline context without a current forecast or notification")
    }

    static func defaultEnabledAndSavedPreferences() throws {
        for enabled: Bool? in [nil, false, true] {
            for sound: Bool? in [nil, false, true] {
                let h = try RuntimeHarness(enabledPreference: enabled, soundPreference: sound)
                let expectedEnabled = enabled ?? true
                expect(h.monitor.enabled == expectedEnabled, "Unset enables forecasts; explicit false and true remain authoritative")
                expect(h.monitor.soundEnabled == (sound ?? false), "Sound stays default-off and preserves either saved value")
                expect((h.defaults.object(forKey: ResetNewsMonitor.enabledPreferenceKey) as? Bool) == enabled,
                       "Constructing the monitor never persists its enabled fallback")
                expect((h.defaults.object(forKey: ResetNewsMonitor.soundPreferenceKey) as? Bool) == sound,
                       "Constructing the monitor never changes saved or unset sound")
                expect(h.channel.requests == (expectedEnabled ? 1 : 0), "Enabled initialization uses the existing authorization path")
                expect(h.client.callbacks.isEmpty, "Even default-enabled construction does not bypass process gates")
            }
        }

        let h = try RuntimeHarness(enabledPreference: nil)
        expect(h.monitor.state.status == .codexNotRunning, "Default-enabled state waits for Codex")
        h.monitor.updateGate(codexRunning: false, hudRunning: true, suspended: false)
        h.monitor.updateGate(codexRunning: true, hudRunning: false, suspended: false)
        h.monitor.updateGate(codexRunning: true, hudRunning: true, suspended: true)
        expect(h.client.callbacks.isEmpty, "Default-enabled state still requires Codex, HUD and an awake session")
        h.monitor.updateGate(codexRunning: true, hudRunning: true, suspended: false)
        expect(h.client.callbacks.count == 1 && h.channel.requests == 1, "Passing every gate starts polling without a second authorization request")
        h.monitor.setEnabled(false)
        expect(h.defaults.object(forKey: ResetNewsMonitor.enabledPreferenceKey) as? Bool == false,
               "Explicit disable persists an opt-out")
        let restoredChannel = FakeNewsNotifications()
        let clock = h.clock
        let restored = ResetNewsMonitor(repository: h.repository, client: FakeNewsClient(),
            notifications: ResetNewsNotificationController(channel: restoredChannel), scheduler: FakeNewsScheduler(),
            defaults: h.defaults, now: { clock.date }, calendar: { clock.calendar }, notificationCenter: NotificationCenter())
        expect(!restored.enabled && restored.state.status == .disabled && restoredChannel.requests == 0,
               "Rebuilding after explicit disable stays off and requests no notification permission")
    }

    static func gatesAndCancellation() throws {
        let h = try RuntimeHarness()
        var callbacksOnMain = true
        h.monitor.onStateChange = { _ in callbacksOnMain = callbacksOnMain && Thread.isMainThread }
        expect(!h.monitor.enabled && h.monitor.state.status == .disabled, "Saved explicit opt-out stays off")
        expect(h.channel.requests == 0 && h.client.callbacks.isEmpty, "No permission or network during construction")
        expect(h.monitor.checkNow() == .inactive, "Manual check respects disabled gate")
        h.monitor.setEnabled(true)
        expect(h.monitor.state.status == .codexNotRunning && h.client.callbacks.isEmpty, "Codex running gate")
        h.monitor.updateGate(codexRunning: true, hudRunning: false, suspended: false)
        expect(h.client.callbacks.isEmpty && h.monitor.state.status == .idle, "HUD running gate")
        h.monitor.updateGate(codexRunning: true, hudRunning: true, suspended: true)
        expect(h.client.callbacks.isEmpty, "Suspended gate")
        h.monitor.updateGate(codexRunning: true, hudRunning: true, suspended: false)
        expect(h.client.callbacks.count == 1 && h.monitor.state.status == .checking, "All gates permit check")
        expect(h.monitor.checkNow() == .joined && h.client.callbacks.count == 1, "Manual check joins in flight")
        h.monitor.stop()
        let stopped = h.monitor.state
        expect(h.client.cancellations == 1, "Stop cancels data task")
        h.client.complete(h.result([h.source("1")]))
        expect(h.monitor.state == stopped && h.repository.state.items.isEmpty, "Late result cannot mutate stopped state")
        expect(h.channel.payloads.isEmpty, "Late result cannot notify")
        h.monitor.updateGate(codexRunning: true, hudRunning: true, suspended: false)
        expect(h.client.callbacks.count == 1 && h.scheduler.entries.last?.delay == 60, "Resume respects endpoint minimum interval")
        h.clock.advance(60)
        h.scheduler.entries.last?.action()
        expect(h.client.callbacks.count == 2, "Resume executes due check")
        h.client.complete(h.result([]))
        let beforeDisable = h.scheduler.entries.last!
        h.monitor.setEnabled(false)
        beforeDisable.action()
        expect(h.client.callbacks.count == 2 && h.monitor.state.status == .disabled, "Cancelled timer cannot restart checks")
        expect(h.scheduler.cancellations > 0, "Stop cancels timer")
        expect(callbacksOnMain, "State callbacks use main thread")
        expect(h.channel.requests == 1, "Enable requests permission only once")

        let background = try RuntimeHarness()
        var mainThreadCallbacks = true
        background.monitor.onStateChange = { _ in mainThreadCallbacks = mainThreadCallbacks && Thread.isMainThread }
        background.activate()
        let result = background.result([])
        DispatchQueue.global().async { background.client.complete(result) }
        pump { background.monitor.state.status == .success }
        expect(mainThreadCallbacks, "A background transport completion publishes state only on the main thread")
    }

    static func baselineReadAndDeduplication() throws {
        let h = try RuntimeHarness()
        h.activate()
        let first = h.source("1")
        h.client.complete(h.result([first]))
        expect(h.repository.state.baselineSources.count == 3 && h.repository.state.forecastBaselineEstablished == true,
               "Initial context and authority successes establish independent baselines")
        expect(h.monitor.state.forecastAvailability == .current && h.monitor.state.forecastCount == 1,
               "A successful authority snapshot exposes exactly its current official signal")
        expect(h.channel.payloads.isEmpty && h.monitor.state.unreadCount == 0, "Initial official signal is a silent read baseline")
        expect(h.monitor.checkNow() == .throttled && h.client.callbacks.count == 1, "Repeated manual requests are throttled")
        h.next(h.result([first]))
        expect(h.channel.payloads.isEmpty && h.monitor.state.forecastCount == 1, "Identical authority poll does not replay")
        h.next(h.result([first, h.source("2")]))
        expect(h.channel.payloads.count == 1 && h.monitor.state.unreadCount == 1,
               "A replacement current signal notifies once and remains unread")
        expect(h.monitor.state.forecastCount == 1 && h.monitor.state.items.count == 1 && h.repository.state.items.count == 2,
               "Stored historical candidates never appear as additional current forecast cards")
        expect(h.channel.payloads[0].identifier.hasPrefix("reset-news:"), "Notification identifier is namespaced")
        expect(h.channel.payloads[0].title == "Codex 重置预告（1 条新预告）", "Notification count never means available account resets")
        expect(!h.channel.payloads[0].sound, "Default notification sound is off")
        h.monitor.markRead(["not-present"])
        expect(h.monitor.state.unreadCount == 1, "Opening unrelated content does not clear unread")
        h.monitor.markRead(["post:2"])
        expect(h.monitor.state.unreadCount == 0 && h.monitor.state.forecastCount == 1,
               "Reading the current signal does not reduce its forecast count")
        h.next(h.result([first, h.source("2"), h.source("3"), h.source("4")]))
        expect(h.monitor.state.unreadCount == 1 && h.monitor.state.forecastCount == 1,
               "The current signal alone determines unread and forecast quantities")
        expect(h.channel.payloads.count == 2 && h.channel.payloads[1].itemIDs == ["post:4"],
               "A context batch delivers only the explicitly supplied current authority signal")
        h.monitor.markAllRead()
        expect(h.monitor.state.unreadCount == 0, "Explicit mark all read")
        let reloaded = ResetNewsRepository(directory: h.directory, now: h.clock.date)
        expect(reloaded.state == h.repository.state, "Authority snapshot, read IDs, baseline and ledger persist")
        h.next(h.result([first, h.source("2"), h.source("3"), h.source("4")]))
        expect(h.channel.payloads.count == 2, "Persisted authority notification key prevents replay")
    }

    static func partialAndStale() throws {
        let h = try RuntimeHarness()
        h.activate()
        h.client.complete(h.result([h.source("1")], timelineError: .http(503)))
        expect(h.monitor.state.status == .partial && h.monitor.state.items.count == 1, "Partial failure preserves successful endpoint")
        expect(h.monitor.state.detail?.contains("503") == true, "Failure is not rendered as no messages")
        expect(Set(h.repository.state.baselineSources) == Set([.feed, .forecast]), "Failed endpoint does not establish baseline")
        h.next(h.result([h.source("1"), h.source("2"), h.source("3", source: .timeline)]))
        expect(h.channel.payloads.count == 1 && h.channel.payloads[0].itemIDs == ["post:3"], "Only a newly supplied authoritative signal may notify when context recovers")
        expect(!h.monitor.state.readIDs.contains("post:3") && h.monitor.state.unreadCount == 1,
               "A new authoritative signal remains unread independently of a context endpoint's initial baseline")
        h.next(h.result([h.source("4")], stale: true))
        expect(h.monitor.state.status == .stale && h.channel.payloads.count == 1, "Stale payload never strongly alerts")
        h.next(h.result([h.source("4")]))
        expect(h.channel.payloads.count == 1, "Fresh copy does not replay an already consumed stale item")
        h.next(h.result([h.source("5")], expires: h.clock.date.addingTimeInterval(-1)))
        expect(h.monitor.state.status == .stale && h.channel.payloads.count == 1, "Expired publication header suppresses alert")
        h.next(h.result([h.source("6")], rejected: 1))
        expect(h.monitor.state.status == .partial && h.monitor.state.detail?.contains("跳过 1") == true, "Rejected identity count is visible")
    }

    static func partialRefreshKeepsMergedFacts() throws {
        let h = try RuntimeHarness()
        h.activate()
        var feed = h.source("1")
        feed.structuredFacts = [.init(kind: .upcomingReset, effectiveAt: h.clock.date.addingTimeInterval(3600))]
        var timeline = h.source("1", source: .timeline)
        timeline.structuredFacts = feed.structuredFacts! + [.init(kind: .upcomingReset, effectiveAt: h.clock.date.addingTimeInterval(7200))]
        h.client.complete(h.result([feed, timeline]))
        expect(h.repository.state.items.first?.facts.count == 2, "Both endpoint facts remain in context initially")
        h.next(h.result([feed], timelineError: .http(503)))
        expect(h.monitor.state.status == .partial, "Failed timeline is reported as partial")
        expect(h.repository.state.items.first?.facts.count == 2, "Partial refresh retains unavailable context source facts")
        expect(h.repository.state.items.first?.materialRevision == 1, "Partial refresh cannot manufacture a context revision")
        expect(h.channel.payloads.isEmpty && h.monitor.state.unreadCount == 0, "Partial refresh does not replay or mark baseline unread")
        let reloaded = ResetNewsRepository(directory: h.directory, now: h.clock.date)
        expect(reloaded.state.items.first?.sourceSnapshots?.count == 3, "Per-source provenance survives repository round trip")
        let changedDate = h.clock.date.addingTimeInterval(10800)
        timeline.structuredFacts = [.init(kind: .upcomingReset, effectiveAt: changedDate)]
        timeline.updatedAt = h.clock.date.addingTimeInterval(60)
        h.next(h.result([feed, timeline]))
        expect(h.repository.state.items.first?.facts.first?.effectiveAt == changedDate,
               "Recovered source can explicitly update its own fact")
        expect(h.repository.state.items.first?.materialRevision == 2 && h.channel.payloads.count == 1,
               "Real source update notifies once")
        timeline.status = .cancelled
        timeline.updatedAt = h.clock.date.addingTimeInterval(60)
        h.next(h.result([feed, timeline]))
        expect(h.monitor.state.items.isEmpty && h.channel.payloads.count == 1,
               "Explicit cancellation is removed without strong notification")
        h.next(h.result([feed], timelineError: .http(503)))
        expect(h.repository.state.items.isEmpty && h.repository.state.retiredForecasts?.count == 1, "Older feed cannot restore cancelled timeline copy")
        expect(h.channel.payloads.count == 1, "Older copy cannot replay a notification")
    }

    static func recoveryWaitsForEachBaselinedSource() throws {
        let h = try RuntimeHarness()
        h.activate()
        h.client.complete(h.result([], forecastError: .http(503)))
        expect(h.monitor.state.forecastAvailability == .unknown && h.repository.state.forecastBaselineEstablished != true,
               "Context success does not establish an unavailable authority baseline")
        var historical = h.source("502", age: 7 * 3600)
        historical.structuredFacts = [.init(kind: .upcomingReset, effectiveAt: h.clock.date.addingTimeInterval(3600))]
        h.next(h.result([historical]))
        expect(h.monitor.state.forecastAvailability == .current && h.monitor.state.forecastCount == 1
            && h.channel.payloads.isEmpty && h.repository.state.forecastBaselineEstablished == true,
               "First successful authority recovery is silent regardless of existing context baselines")
        h.monitor.updateGate(codexRunning: false, hudRunning: true, suspended: false)
        h.clock.advance(180)
        h.monitor.updateGate(codexRunning: true, hudRunning: true, suspended: false)
        h.client.complete(h.result([historical]))
        expect(h.channel.payloads.isEmpty, "Runtime recovery cannot replay the same historical authority signal")
        h.next(h.result([historical], forecastError: .http(500)))
        expect(h.monitor.state.forecastAvailability == .cached && h.monitor.state.forecastCount == 1,
               "Failed authority refresh retains its valid cache independently of context success")
        h.next(h.result([historical]))
        expect(h.monitor.state.forecastAvailability == .current && h.channel.payloads.isEmpty,
               "Fresh authority recovery clears cached status without replaying consumed signal")
    }

    static func recoveryAndBackoff() throws {
        let h = try RuntimeHarness()
        h.activate()
        h.client.complete(h.result([]))
        expect(h.monitor.state.nextCheck == h.clock.date.addingTimeInterval(120), "Normal network schedule is 120 seconds with deterministic jitter")
        h.monitor.updateGate(codexRunning: false, hudRunning: true, suspended: false)
        h.clock.advance(180)
        h.monitor.updateGate(codexRunning: true, hudRunning: true, suspended: false)
        h.client.complete(h.result([h.source("1"), h.source("2"), h.source("3")]))
        expect(h.channel.payloads.count == 1 && h.channel.payloads[0].itemIDs == ["post:3"],
               "Recovery delivers only the new authoritative signal, never a historical context batch")
        expect(h.channel.payloads[0].identifier.hasPrefix("reset-news:summary:"), "Recovery uses summary identifier")
        let failure = ResetNewsFetchResult(endpoints: [
            .init(source: .feed, items: [], metadata: .init(), error: .http(503)),
            .init(source: .timeline, items: [], metadata: .init(), error: .network("offline")),
            .init(source: .forecast, items: [], metadata: .init(), error: .network("offline"))
        ])
        for expected: TimeInterval in [60, 120, 240, 480, 900, 900] {
            h.clock.advance(1_000)
            h.monitor.checkNow()
            h.client.complete(failure)
            expect(h.monitor.state.nextCheck == h.clock.date.addingTimeInterval(expected), "Failure network backoff \(expected)")
            expect(h.monitor.state.status == .failure, "All endpoint errors yield failure")
        }
        h.clock.advance(1_000)
        h.monitor.checkNow()
        let retryDate = h.clock.date.addingTimeInterval(1_800)
        h.client.complete(.init(endpoints: [.init(source: .feed, items: [], metadata: .init(retryAfter: retryDate), error: .http(429))]))
        expect(h.monitor.state.nextCheck == retryDate, "429 Retry-After wins over capped backoff")
        h.clock.advance(60)
        expect(h.monitor.checkNow() == .throttled, "Manual check cannot bypass Retry-After")
        expect(ResetNewsSchedule.successDelay(jitter: 1) == 132, "Small positive normal jitter")
    }

    static func repositoryAndRetention() throws {
        let h = try RuntimeHarness(corrupt: true)
        expect(h.repository.recoveredCorruptCache && !h.repository.state.hasBaseline, "Corrupt cache requires a fresh baseline")
        h.activate()
        h.client.complete(h.result([h.source("1")]))
        expect(h.channel.payloads.isEmpty && h.monitor.state.unreadCount == 0, "Corrupt-cache recovery never replays old history")
        var stored = h.repository.state
        stored.items = (0..<60).map { index in
            ResetNewsItem(id: "item:\(index)", sources: [.feed], originalText: "test",
                          facts: [.init(kind: .upcomingReset, effectiveAt: h.clock.date.addingTimeInterval(Double(index + 1) * 60))],
                          publishedAt: h.clock.date.addingTimeInterval(-Double(index)), firstSeenAt: h.clock.date)
        }
        stored.items.append(.init(id: "old", sources: [.feed], originalText: "old", facts: [],
                                  publishedAt: h.clock.date.addingTimeInterval(-31 * 86_400), firstSeenAt: h.clock.date))
        stored.readIDs = Set(stored.items.map(\.id))
        stored.notified = (0..<510).map { .init(key: "k:\($0)", recordedAt: h.clock.date.addingTimeInterval(-Double($0))) }
        stored.notified.append(.init(key: "old-notice", recordedAt: h.clock.date.addingTimeInterval(-91 * 86_400)))
        expect(h.repository.replace(stored, now: h.clock.date), "Atomic repository write succeeds")
        expect(h.repository.state.items.count == 60 && !h.repository.state.items.contains { $0.id == "old" }, "All valid forecasts retained without a fifty-item display truncation")
        expect(h.repository.state.readIDs.count == 60, "Read IDs pruned with history")
        expect(h.repository.state.notified.count == 500 && !h.repository.state.notifiedKeys.contains("old-notice"), "Ledger bounded at 90 days and 500 records")
        let reloaded = ResetNewsRepository(directory: h.directory, now: h.clock.date)
        expect(reloaded.state == h.repository.state && !reloaded.recoveredCorruptCache, "Versioned snapshot reloads exactly")
        var unsupported = stored
        unsupported.version = 999
        try JSONEncoder().encode(unsupported).write(to: h.repository.fileURL)
        let invalidVersion = ResetNewsRepository(directory: h.directory, now: h.clock.date)
        expect(invalidVersion.recoveredCorruptCache && !invalidVersion.state.hasBaseline, "Unknown cache version rebuilds a silent baseline")
    }

    static func localCalendarPruning() throws {
        let h = try RuntimeHarness()
        h.activate()
        var today = h.source("today")
        today.structuredFacts = [.init(kind: .upcomingReset, effectiveAt: h.clock.date.addingTimeInterval(-60))]
        h.client.complete(h.result([today]))
        expect(h.monitor.state.forecastCount == 0 && h.repository.state.items.count == 1 && h.monitor.state.unreadCount == 0,
               "Earlier today is context only after its exact scheduled instant passes")
        h.monitor.setEnabled(false)
        let requests = h.client.callbacks.count
        h.clock.date = h.clock.calendar.date(byAdding: .day, value: 1, to: h.clock.calendar.startOfDay(for: h.clock.date))!
        h.notificationCenter.post(name: .NSCalendarDayChanged, object: nil)
        expect(h.monitor.state.forecastCount == 0 && h.repository.state.readIDs.isEmpty, "Day change prunes disabled cached forecasts locally")
        expect(h.client.callbacks.count == requests && h.channel.payloads.isEmpty, "Local day cleanup neither fetches nor notifies")
        let disk = try JSONDecoder().decode(ResetNewsStoredState.self, from: Data(contentsOf: h.repository.fileURL))
        expect(disk.items.isEmpty && disk.readIDs.isEmpty && !disk.notified.isEmpty, "Day cleanup reaches disk and preserves notification ledger")

        let timezone = try RuntimeHarness()
        timezone.clock.date = ISO8601DateFormatter().date(from: "2026-11-01T06:30:00Z")!
        timezone.clock.calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        timezone.activate()
        var planned = timezone.source("zone")
        planned.structuredFacts = [.init(kind: .upcomingReset, effectiveAt: ISO8601DateFormatter().date(from: "2026-10-31T23:00:00Z")!)]
        timezone.client.complete(timezone.result([planned]))
        expect(timezone.monitor.state.forecastCount == 0 && timezone.repository.state.items.count == 1, "A passed instant may still have local-day context in Los Angeles")
        let zoneRequests = timezone.client.callbacks.count
        timezone.clock.calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        timezone.notificationCenter.post(name: .NSSystemTimeZoneDidChange, object: nil)
        expect(timezone.monitor.state.forecastCount == 0 && timezone.client.callbacks.count == zoneRequests,
               "Timezone change re-evaluates local day without networking")

        let sleeping = try RuntimeHarness()
        sleeping.activate()
        var plan = sleeping.source("wake")
        plan.structuredFacts = [.init(kind: .upcomingReset, effectiveAt: sleeping.clock.date.addingTimeInterval(60))]
        sleeping.client.complete(sleeping.result([plan]))
        sleeping.monitor.updateGate(codexRunning: true, hudRunning: true, suspended: true)
        sleeping.clock.advance(86400)
        sleeping.monitor.updateGate(codexRunning: true, hudRunning: true, suspended: false)
        expect(sleeping.monitor.state.forecastCount == 0, "Wake prunes stale day before its network request completes")
        sleeping.client.complete(.init(endpoints: [.init(source: .feed, items: [], metadata: .init(), error: .network("offline"))]))
        expect(sleeping.monitor.state.forecastCount == 0 && sleeping.monitor.state.status == .failure, "Network failure cannot preserve expired local dates")
    }

    static func legacyDiskMigration() throws {
        let h = try RuntimeHarness()
        let engine = ResetNewsRuleEngine()
        var future = h.source("future", age: 40 * 86400)
        future.structuredFacts?.append(.init(kind: .extraResetCredits, count: 99))
        let original = ResetNewsReducer().reduce(previous: .init(), incoming: [future], now: h.clock.date).state.items[0]
        var legacyFuture = original
        legacyFuture.facts.append(.init(kind: .extraResetCredits, count: 99))
        legacyFuture.sourceSnapshots?[0].facts.append(.init(kind: .resetAnnouncement))
        let history = engine.evaluate(.init(source: .feed, sourceID: "history", body: "We have reset Codex limits.", publishedAt: h.clock.date), now: h.clock.date)!
        var legacy = ResetNewsStoredState()
        legacy.items = [history, legacyFuture]
        legacy.readIDs = [history.id, legacyFuture.id, "missing"]
        legacy.notified = [.init(key: original.notificationKey, recordedAt: h.clock.date)]
        legacy.baselineSources = [.feed, .timeline]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        object.removeValue(forKey: "retiredForecasts")
        for key in ["forecast", "forecastFetchedAt", "forecastExpiresAt", "forecastBaselineEstablished"] { object.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: object).write(to: h.repository.fileURL)
        let migrated = ResetNewsRepository(directory: h.directory, now: h.clock.date)
        expect(migrated.state.items.map(\.id) == [legacyFuture.id], "Old disk history removed while a forty-day-old future plan survives")
        expect(migrated.state.items[0].facts.allSatisfy { $0.kind == .upcomingReset }
            && migrated.state.items[0].sourceSnapshots!.allSatisfy { $0.facts.allSatisfy { $0.kind == .upcomingReset } },
            "Migration removes historical facts from the card and every source snapshot")
        expect(migrated.state.readIDs == [legacyFuture.id] && migrated.state.notified == legacy.notified,
               "Migration clears removed read IDs but retains notification consumption")
        let disk = try JSONDecoder().decode(ResetNewsStoredState.self, from: Data(contentsOf: migrated.fileURL))
        expect(disk == migrated.state, "Migration actually rewrites isolated disk snapshot")
        let legacyClient = FakeNewsClient()
        let legacyChannel = FakeNewsNotifications()
        let clock = h.clock
        let legacyMonitor = ResetNewsMonitor(repository: migrated, client: legacyClient,
            notifications: ResetNewsNotificationController(channel: legacyChannel), scheduler: FakeNewsScheduler(),
            defaults: h.defaults, now: { clock.date }, calendar: { clock.calendar }, notificationCenter: NotificationCenter())
        expect(legacyMonitor.state.forecastAvailability == .unknown && legacyMonitor.state.items.isEmpty
            && migrated.state.forecastBaselineEstablished != true,
               "Legacy future candidates cannot manufacture a current authority snapshot or its baseline")
        legacyMonitor.updateGate(codexRunning: true, hudRunning: true, suspended: false)
        legacyMonitor.setEnabled(true)
        legacyClient.complete(h.result([future]))
        expect(legacyMonitor.state.forecastCount == 1 && legacyChannel.payloads.isEmpty
            && migrated.state.forecastBaselineEstablished == true,
               "First authority success after legacy migration establishes a silent baseline")
        let replay = ResetNewsReducer().reduce(previous: .init(items: disk.items, notificationRecords: disk.notified,
            hasBaseline: disk.hasBaseline, retiredForecasts: disk.retiredForecasts), incoming: [future], now: h.clock.date)
        expect(replay.notificationCandidates.isEmpty && replay.state.items[0].facts.count == 1,
               "Old source cannot reintroduce filtered credit facts or replay notification")
    }

    static func notificationChannel() throws {
        let h = try RuntimeHarness()
        let item = ResetNewsItem(id: "post:1", sources: [.feed], originalText: "test", facts: [.init(kind: .upcomingReset, effectiveAt: Date().addingTimeInterval(3600))], firstSeenAt: h.clock.date)
        h.notifications.deliver([item])
        expect(h.channel.payloads.isEmpty && h.channel.requests == 0, "Disabled controller does not request or send")
        h.notifications.enable()
        h.notifications.enable()
        expect(h.channel.requests == 1, "Repeated enable does not re-request authorization")
        h.notifications.soundEnabled = true
        h.channel.deferAdd = true
        h.notifications.deliver([item])
        expect(h.channel.payloads[0].sound, "Explicit sound preference is applied")
        var opened: [String] = []
        h.notifications.onOpenDetails = { opened = $0 }
        h.channel.onOpen?(["post:1"])
        expect(opened == ["post:1"], "Notification click opens only local item IDs")
        h.notifications.stop()
        expect(h.channel.removedPrefixes == ["reset-news:"], "Stop removes only module pending notifications")
        h.channel.delayedAdds[0](nil)
        expect(h.channel.removedPrefixes.count == 2, "Late notification add is cleaned after stop")
        h.notifications.deliver([item])
        expect(h.channel.payloads.count == 1, "Stopped controller cannot submit new notifications")
        let denied = FakeNewsNotifications()
        denied.permission = .denied
        let controller = ResetNewsNotificationController(channel: denied)
        controller.enable()
        controller.deliver([item])
        expect(controller.permission == .denied && denied.payloads.isEmpty, "Denied permission is explicit and quiet")
        let latePermission = FakeNewsNotifications()
        latePermission.deferPermission = true
        let stopped = ResetNewsNotificationController(channel: latePermission)
        var permissionUpdates = 0
        stopped.onPermissionChange = { _ in permissionUpdates += 1 }
        stopped.enable()
        stopped.stop()
        latePermission.pendingPermission?(.allowed)
        expect(permissionUpdates == 0, "Late authorization does not publish state after stop")
    }

    static func notificationPermissionRefresh() throws {
        let item = ResetNewsItem(id: "post:permission", sources: [.feed], originalText: "test",
            facts: [.init(kind: .upcomingReset, effectiveAt: Date().addingTimeInterval(3600))], firstSeenAt: Date())
        let channel = FakeNewsNotifications()
        channel.permission = .denied
        let controller = ResetNewsNotificationController(channel: channel)
        var changes: [ResetNewsNotificationPermission] = []
        controller.onPermissionChange = { changes.append($0) }
        controller.enable()
        expect(controller.permission == .denied && channel.requests == 1, "Initial denied authorization is recorded once")
        controller.stop()
        channel.permission = .allowed // The user changes permission in System Settings.
        controller.enable()
        controller.deliver([item])
        expect(controller.permission == .allowed && changes.last == .allowed, "Re-enabling refreshes externally granted permission")
        expect(channel.permissionReads == 1 && channel.requests == 1, "Re-enabling reads settings without another authorization request")
        expect(channel.payloads.count == 1, "An externally allowed controller can deliver after re-enabling")

        channel.permission = .denied
        controller.stop()
        controller.resume()
        controller.deliver([item])
        expect(controller.permission == .denied && channel.payloads.count == 1, "Resume also observes external revocation and suppresses delivery")
        expect(channel.requests == 1, "Runtime resume never requests authorization again")

        // The monitor uses resume when Codex/HUD gates reopen after suspension.
        let h = try RuntimeHarness()
        h.channel.permission = .denied
        h.activate()
        h.client.complete(h.result([]))
        expect(h.monitor.state.notificationPermission == .denied, "Monitor exposes initial denied permission")
        h.monitor.updateGate(codexRunning: true, hudRunning: true, suspended: true)
        h.channel.permission = .allowed
        h.clock.advance(120)
        h.monitor.updateGate(codexRunning: true, hudRunning: true, suspended: false)
        h.client.complete(h.result([h.source("permission-restored")]))
        expect(h.monitor.state.notificationPermission == .allowed, "Runtime recovery publishes refreshed allowed permission")
        expect(h.channel.payloads.count == 1 && h.channel.requests == 1, "Runtime recovery delivers new news without repeating authorization")

        channel.deferPermissionRead = true
        controller.resume()
        controller.resume()
        channel.pendingPermissionReads[1](.allowed)
        channel.pendingPermissionReads[0](.denied)
        expect(controller.permission == .allowed, "An older permission refresh cannot overwrite the latest result")
        controller.resume()
        let beforeStop = changes.count
        controller.stop()
        channel.pendingPermissionReads[2](.denied)
        expect(controller.permission == .allowed && changes.count == beforeStop, "A permission read completing after stop cannot mutate or publish")

        let pending = FakeNewsNotifications()
        pending.deferPermission = true
        let authorizing = ResetNewsNotificationController(channel: pending)
        authorizing.enable()
        authorizing.enable()
        authorizing.resume()
        expect(pending.requests == 1 && pending.permissionReads == 0, "Settings reads do not race the initial authorization sheet")
        pending.pendingPermission?(.allowed)
        expect(authorizing.permission == .allowed, "The first authorization result remains authoritative")
    }

    static func httpClient() throws {
        let transport = FakeNewsHTTP()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let client = ResetNewsFeedClient(transport: transport, bundleVersion: "0.1.test", now: { date })
        var result: ResetNewsFetchResult?
        _ = client.fetch { result = $0 }
        expect(transport.requests.count == 3, "Context feed, timeline and current forecast are requested together")
        expect(transport.requests.allSatisfy { $0.timeoutInterval == 15 && $0.httpMethod == "GET" }, "GET timeout is 15 seconds")
        expect(transport.requests[0].url?.absoluteString == "https://codex-reset.com/api/feed?locale=zh", "Fixed feed endpoint")
        expect(transport.requests[1].url?.absoluteString == "https://codex-reset.com/api/timeline?locale=zh", "Fixed timeline endpoint")
        expect(transport.requests[2].url?.absoluteString == "https://codex-reset.com/api/forecast?locale=zh", "Fixed authority forecast endpoint")
        expect(transport.requests[0].value(forHTTPHeaderField: "User-Agent") == "GPT-TouchBar-HUD/0.1.test (+https://github.com/zz-zed/GPT-TouchBar-hud)", "Identifying User-Agent")
        let valid = #"{"profile":{"handle":"thsottiaux"},"source_scope":"timeline","stale":true,"tweets":[{"id":"123","url":"https://x.com/thsottiaux/status/123","text":"We have reset Codex usage limits."}]}"#
        let none = String(decoding: try JSONSerialization.data(withJSONObject: noCurrentForecast(now: date)), as: UTF8.self)
        transport.respond(0, body: valid, headers: ["cache-control": "public, max-age=60", "x-published-checked-at": "2027-01-15T08:00:00Z", "x-published-expires-at": "2027-01-15T08:03:00.000Z"])
        transport.respond(1, body: "{}", status: 429, headers: ["Retry-After": "180"])
        expect(result == nil, "Two context responses cannot finish a three-endpoint refresh")
        transport.respond(2, body: none)
        pump { result != nil }
        expect(result?.successful.count == 2 && result?.failures.count == 1, "Endpoint failures remain separate from a successful null authority")
        expect(result?.successful.first?.metadata.stale == true && result?.successful.first?.metadata.maxAge == 60, "Payload stale and cache max-age parsed")
        expect(result?.successful.first?.metadata.publishedCheckedAt != nil && result?.successful.first?.metadata.publishedExpiresAt != nil, "Publication timestamps parsed")
        expect(result?.retryAfter == date.addingTimeInterval(180), "Numeric Retry-After parsed")
        expect(result?.successful.first { $0.source == .forecast }?.forecast?.officialSignal == nil,
               "A literal null current signal survives transport decoding as a successful snapshot")

        result = nil
        _ = client.fetch { result = $0 }
        transport.respond(3, body: valid.replacingOccurrences(of: "\"handle\":\"thsottiaux\"", with: "\"handle\":\"attacker\""))
        transport.respond(4, body: "invalid json")
        transport.respond(5, body: none)
        pump { result != nil }
        expect(result?.failures.count == 2, "Identity and JSON errors cannot become empty context success")
        if case .identity = result?.failures.first?.error { expect(true, "Root identity error is explicit") }
        else { expect(false, "Root identity error is explicit") }
        if case .json = result?.failures.last?.error { expect(true, "JSON error is explicit") }
        else { expect(false, "JSON error is explicit") }

        result = nil
        _ = client.fetch { result = $0 }
        let partlyValid = valid.replacingOccurrences(of: "]}", with: #",{"id":"456","url":"https://x.com/evil/status/456","text":"We reset Codex usage limits."}]}"#)
        transport.respond(6, body: partlyValid)
        transport.respond(7, body: "{\"events\":[]}")
        transport.respond(8, body: none)
        pump { result != nil }
        expect(result?.successful.count == 3 && result?.successful.first?.items.count == 1, "Individual invalid identity skips only that context record")
        expect(result?.successful.first?.metadata.rejectedIdentityCount == 1, "Invalid identity count preserved for UI")

        result = nil
        _ = client.fetch { result = $0 }
        transport.respond(9, body: "{\"events\":[]}")
        transport.respond(10, body: "{\"events\":[]}")
        transport.respond(11, body: "{\"updated_at\":\"2027-01-15T08:00:00Z\",\"last_reset_at\":null}")
        pump { result != nil }
        expect(result?.failures.contains { $0.source == .forecast } == true,
               "Missing official_signal is a forecast failure, never a successful no-preview snapshot")

        var calledAfterCancel = false
        let cancellation = client.fetch { _ in calledAfterCancel = true }
        cancellation.cancel()
        transport.respond(12, body: valid)
        transport.respond(13, body: "{\"events\":[]}")
        transport.respond(14, body: none)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        expect(!calledAfterCancel && transport.cancelled == 3, "Client cancellation cancels all three endpoints and suppresses completion")
        let response = HTTPURLResponse(url: URL(string: "https://codex-reset.com")!, statusCode: 429, httpVersion: nil,
                                       headerFields: ["Retry-After": "Tue, 22 Sep 2026 04:00:00 GMT"])!
        expect(ResetNewsHTTPMetadata.parse(response, now: date).retryAfter != nil, "HTTP-date Retry-After parsed")
    }

    // Trimmed from the 2026-10-03 public snapshots: one real post, its timeline summary,
    // and the site's nonofficial banked-reset observation. Ignored context retains its real envelope.
    static func fixture(_ name: String) throws -> [String: Any] {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ResetNews/\(name).json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
    }

    static var emptyFeed: [String: Any] {
        ["profile": ["handle": "thsottiaux"], "source_scope": "timeline", "tweets": [], "events": []]
    }

    static func noCurrentForecast(now: Date, lastResetAt: Date? = nil) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var object: [String: Any] = ["updated_at": formatter.string(from: now), "last_reset_at": NSNull(), "official_signal": NSNull()]
        if let lastResetAt { object["last_reset_at"] = formatter.string(from: lastResetAt) }
        return object
    }

    static func fixtureForecast(_ feed: [String: Any], _ timeline: [String: Any], now: Date) -> [String: Any] {
        var object = noCurrentForecast(now: now)
        let candidates = (feed["tweets"] as? [[String: Any]] ?? [])
            + (feed["events"] as? [[String: Any]] ?? []) + (timeline["events"] as? [[String: Any]] ?? [])
        if let record = candidates.first(where: { $0["source"] as? String != "observed" && $0["source"] as? String != "operator-observed" }),
           let id = record["id"], let url = record["url"], !(url is NSNull),
           let text = record["text"] ?? record["summary"], let published = record["at"] ?? record["announced_at"] {
            object["official_signal"] = ["tweet_id": id, "url": url, "summary": text, "at": published]
        }
        return object
    }

    static func fetched(_ feed: [String: Any], _ timeline: [String: Any], now: Date,
                        feedStatus: Int = 200, timelineStatus: Int = 200, forecastStatus: Int = 200,
                        forecast: [String: Any]? = nil, reverseResponses: Bool = false) throws -> ResetNewsFetchResult {
        let transport = FakeNewsHTTP()
        let client = ResetNewsFeedClient(transport: transport, now: { now })
        var result: ResetNewsFetchResult?
        _ = client.fetch { result = $0 }
        let bodies = [feed, timeline, forecast ?? fixtureForecast(feed, timeline, now: now)]
        let statuses = [feedStatus, timelineStatus, forecastStatus]
        let order = reverseResponses ? [2, 1, 0] : [0, 1, 2]
        for index in order {
            let body = String(decoding: try JSONSerialization.data(withJSONObject: bodies[index]), as: UTF8.self)
            let headers = index == 2 ? ["x-published-expires-at": ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))] : [:]
            transport.respond(index, body: body, status: statuses[index], headers: headers)
        }
        pump { result != nil }
        return result!
    }

    static func capturedAPIRecordsAndEndpointRecovery() throws {
        let feed = try fixture("feed-mixed")
        let timeline = try fixture("timeline-mixed")
        let h = try RuntimeHarness()
        // The post was published just after midnight UTC while its explicit PST date was still Oct 1.
        h.clock.date = ISO8601DateFormatter().date(from: "2026-10-02T03:00:00Z")!
        h.clock.calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        h.activate()
        h.client.complete(try fetched(emptyFeed, ["events": []], now: h.clock.date))
        let result = try fetched(feed, timeline, now: h.clock.date)
        expect(result.successful.count == 3 && result.failures.isEmpty,
               "Official records plus the site's observed banked event keep both API endpoints successful")
        expect(result.successful.allSatisfy { $0.metadata.rejectedIdentityCount == 0 },
               "A declared nonofficial observation is normal filtering, not an identity rejection")
        try h.next(try fetched(feed, timeline, now: h.clock.date))
        expect(h.monitor.state.status == .success && h.monitor.state.detail == nil,
               "Normally filtered observation records cannot produce the partial-source warning")
        expect(h.monitor.state.forecastCount == 1 && h.monitor.state.items.count == 1,
               "Tweet, feed event and timeline event with the same post ID count as one valid forecast")
        let fullText = (feed["tweets"] as! [[String: Any]])[0]["text"] as! String
        expect(h.monitor.state.items.first?.originalText == fullText,
               "A truncated timeline summary cannot replace the same-version complete original post")
        expect(Set(h.repository.state.items.first?.sources ?? []) == Set([.feed, .timeline, .forecast])
            && h.repository.state.items.first?.sourceSnapshots?.count == 3,
               "Deduplication still keeps both endpoint copies for partial refreshes")
        expect(h.channel.payloads.count == 1 && h.channel.payloads.first?.itemIDs == ["post:2105843926221660585"],
               "A new official post appearing three times across the API sends exactly one forecast alert")
        let revision = h.repository.state.items.first?.materialRevision
        try h.next(try fetched(feed, timeline, now: h.clock.date))
        expect(h.monitor.state.forecastCount == 1 && h.channel.payloads.count == 1
            && h.repository.state.items.first?.materialRevision == revision,
               "Repeated duplicate records neither inflate the forecast count nor replay its alert")
        try h.next(try fetched(feed, timeline, now: h.clock.date, timelineStatus: 503))
        expect(h.monitor.state.status == .partial && h.monitor.state.forecastCount == 1,
               "A real timeline HTTP failure stays visible while the successful feed keeps the valid forecast")
        expect(h.repository.state.items.first?.sourceSnapshots?.count == 3
            && h.repository.state.items.first?.originalText == fullText
            && h.repository.state.items.first?.materialRevision == revision && h.channel.payloads.count == 1,
               "Partial refresh preserves unavailable provenance, full original text and notification consumption")
        try h.next(try fetched(feed, timeline, now: h.clock.date, feedStatus: 503, timelineStatus: 503, forecastStatus: 503))
        expect(h.monitor.state.status == .failure && h.monitor.state.forecastCount == 1
            && h.monitor.state.detail?.contains("503") == true && h.channel.payloads.count == 1,
               "Total HTTP failure preserves the still-valid cached forecast without calling it an empty success")
    }

    static func observationsAreValidEmptyResponses() throws {
        let feed = try fixture("feed-mixed")
        let observation = (feed["events"] as! [[String: Any]]).first { $0["source"] as? String == "observed" }!
        var observationsOnly = emptyFeed
        observationsOnly["events"] = [observation]
        observationsOnly["banked_observations"] = feed["banked_observations"]
        observationsOnly["radar_context"] = feed["radar_context"]
        let h = try RuntimeHarness()
        h.activate()
        let result = try fetched(observationsOnly, ["events": [observation]], now: h.clock.date)
        expect(result.successful.count == 3 && result.successful.allSatisfy {
            $0.items.isEmpty && $0.metadata.rejectedIdentityCount == 0
        }, "A valid response containing only declared observations is an empty success")
        h.client.complete(result)
        expect(h.monitor.state.status == .success && h.monitor.state.forecastCount == 0
            && h.monitor.state.detail == nil && h.repository.state.baselineSources.count == 3,
               "Observation-only responses establish a silent baseline and show no forecasts or partial-source warning")
        expect(h.channel.payloads.isEmpty && h.monitor.state.unreadCount == 0,
               "An observed monitoring-account balance never creates a local forecast notification")
    }

    static func officialIdentityFailuresRemainVisible() throws {
        var feed = try fixture("feed-mixed")
        let timeline = try fixture("timeline-mixed")
        var malformed = (feed["events"] as! [[String: Any]])[0]
        malformed["id"] = "999"
        malformed["url"] = "https://x.com/someone_else/status/999"
        malformed["source"] = "live"
        feed["events"] = (feed["events"] as! [[String: Any]]) + [malformed]
        let h = try RuntimeHarness()
        h.clock.date = ISO8601DateFormatter().date(from: "2026-10-02T03:00:00Z")!
        h.clock.calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        h.activate()
        let mixed = try fetched(feed, timeline, now: h.clock.date)
        expect(mixed.successful.count == 3 && mixed.successful.first?.metadata.rejectedIdentityCount == 1,
               "Filtering a site observation does not hide a malformed record claiming official source identity")
        h.client.complete(mixed)
        expect(h.monitor.state.status == .partial && h.monitor.state.forecastCount == 1
            && h.monitor.state.detail?.contains("跳过 1") == true,
               "A genuinely rejected official record reports partial status and preserves the valid forecast")

        var invalidOnly = emptyFeed
        invalidOnly["events"] = [malformed]
        let rejected = try fetched(invalidOnly, ["events": [malformed]], now: h.clock.date)
        expect(rejected.successful.isEmpty && rejected.failures.count == 3,
               "Responses containing only malformed official records cannot become valid empty endpoints")
        expect(rejected.failures.filter { $0.source != .forecast }.allSatisfy { endpoint in
            if case .identity = endpoint.error { return true }; return false
        }, "All-invalid official responses fail explicit identity validation")
        h.next(rejected)
        expect(h.monitor.state.status == .failure && h.monitor.state.forecastCount == 1,
               "Identity failure preserves an earlier valid cache while reporting the failure")

        let observation = (feed["events"] as! [[String: Any]]).first { $0["source"] as? String == "observed" }!
        var wrongRoot = emptyFeed
        wrongRoot["profile"] = ["handle": "someone_else"]
        wrongRoot["events"] = [observation]
        let wrong = try fetched(wrongRoot, ["events": []], now: h.clock.date)
        expect(wrong.failures.count == 1 && wrong.failures.first?.source == .feed,
               "An observation-only payload cannot bypass the feed root profile validation")
        if case .identity = wrong.failures.first?.error { expect(true, "Wrong root profile remains an identity failure") }
        else { expect(false, "Wrong root profile remains an identity failure") }
    }

    static func authorityNullCannotPromoteHistoricalCandidates() throws {
        let h = try RuntimeHarness()
        h.activate()
        let candidate = h.source("9011")
        let lastReset = h.clock.date.addingTimeInterval(-3600)
        let none = ResetForecastSnapshot(updatedAt: h.clock.date, lastResetAt: lastReset, officialSignal: nil)
        h.client.complete(h.result([candidate], forecast: none))
        expect(h.monitor.state.forecastAvailability == .current && h.monitor.state.forecastCount == 0
            && h.monitor.state.items.isEmpty && h.repository.state.items.count == 1,
               "Explicit current null keeps historical future candidates out of every visible forecast card")
        expect(h.repository.state.forecast?.lastResetAt == lastReset && h.channel.payloads.isEmpty,
               "A confirmed past reset is metadata, never a current forecast or initial alert")
        h.next(h.result([candidate, h.source("9012")], forecast: .init(
            updatedAt: h.clock.date, lastResetAt: lastReset, officialSignal: nil)))
        expect(h.monitor.state.forecastCount == 0 && h.monitor.state.items.isEmpty && h.channel.payloads.isEmpty,
               "Newly encountered historical wording cannot notify when the authority explicitly reports no signal")
    }

    static func authorityFailureAndMissingFieldsKeepCache() throws {
        let h = try RuntimeHarness()
        h.activate()
        let signal = h.source("9021")
        h.client.complete(h.result([signal]))
        let checked = h.monitor.state.forecastCheckedAt
        let accepted = h.repository.state.forecast
        h.next(h.result([h.source("9022")], forecastError: .http(503)))
        expect(h.monitor.state.forecastAvailability == .cached && h.monitor.state.forecastCount == 1
            && h.monitor.state.items.first?.id == signal.stableID && h.monitor.state.status == .partial,
               "Authority failure retains the last valid signal with cached status instead of declaring no forecast")
        h.next(h.result([h.source("9023")], missingForecast: true))
        expect(h.monitor.state.forecastAvailability == .cached && h.repository.state.forecast == accepted
            && h.monitor.state.forecastCheckedAt == checked && h.channel.payloads.isEmpty,
               "A successful endpoint without a decoded authority field cannot clear cache or replay a signal")
        let unavailable = try RuntimeHarness()
        unavailable.activate()
        unavailable.client.complete(unavailable.result([unavailable.source("9024")], forecastError: .json("missing official_signal")))
        expect(unavailable.monitor.state.forecastAvailability == .unknown && unavailable.monitor.state.items.isEmpty
            && unavailable.repository.state.forecastBaselineEstablished != true,
               "Missing authority without any cache is unknown despite successfully loaded historical candidates")
    }

    static func authorityExpiryIsLocalAndDoesNotClaimCompletion() throws {
        let h = try RuntimeHarness()
        h.activate()
        var signal = h.source("9031")
        signal.structuredFacts = [.init(kind: .upcomingReset, effectiveAt: h.clock.date.addingTimeInterval(90), effectiveAtPrecision: .exact)]
        h.client.complete(h.result([signal]))
        expect(h.monitor.state.forecastCount == 1, "A current signal is visible before its announced instant")
        let requests = h.client.callbacks.count
        let expiry = h.scheduler.entries.last { abs($0.delay - 90) < 0.01 }
        expect(expiry != nil, "The current-signal boundary schedules a local presentation update")
        h.clock.advance(91)
        expiry?.action()
        expect(h.monitor.state.forecastCount == 0 && h.monitor.state.items.isEmpty
            && h.repository.state.forecast?.lastResetAt == nil,
               "An elapsed preview disappears without a completion post or fabricated completed-reset timestamp")
        expect(h.client.callbacks.count == requests && h.channel.payloads.isEmpty,
               "Preview expiry updates local presentation without network requests or reminders")

        let ttl = try RuntimeHarness()
        ttl.activate()
        ttl.client.complete(ttl.result([ttl.source("9032")], expires: ttl.clock.date.addingTimeInterval(90)))
        let ttlAction = ttl.scheduler.entries.last { abs($0.delay - 90) < 0.01 }
        let ttlRequests = ttl.client.callbacks.count
        ttl.clock.advance(91)
        ttlAction?.action()
        expect(ttl.monitor.state.forecastAvailability == .cached && ttl.monitor.state.forecastCount == 1,
               "HTTP validity expiry marks a still-future signal cached instead of inventing no forecast")
        expect(ttl.client.callbacks.count == ttlRequests && ttl.channel.payloads.isEmpty,
               "HTTP validity projection also stays local and silent")
    }

    static func latestResetDoesNotRetireAnIndependentFutureSignal() throws {
        let h = try RuntimeHarness()
        h.activate()
        let signal = h.source("9041")
        var snapshot = h.snapshot([signal], lastResetAt: h.clock.date.addingTimeInterval(-3600))
        h.client.complete(h.result([signal], forecast: snapshot))
        snapshot.updatedAt = h.clock.date.addingTimeInterval(120)
        snapshot.lastResetAt = h.clock.date.addingTimeInterval(60)
        h.next(h.result([signal], forecast: snapshot))
        expect(h.monitor.state.forecastCount == 1 && h.monitor.state.items.first?.id == signal.stableID
            && h.repository.state.forecast?.lastResetAt == snapshot.lastResetAt,
               "A newer completed reset timestamp cannot retire a separate future official signal")
        expect(h.channel.payloads.isEmpty, "Completion metadata changes do not replay an unchanged current signal")
    }

    static func authorityRestartAndReturnDoNotReplay() throws {
        let h = try RuntimeHarness()
        h.activate()
        h.client.complete(h.result([]))
        let signal = h.source("9051")
        let authority = h.snapshot([signal], updatedAt: h.clock.date.addingTimeInterval(120))
        h.next(h.result([signal], forecast: authority))
        expect(h.channel.payloads.count == 1, "A first new authority signal after baseline can remind once")
        h.next(h.result([signal], forecast: .init(updatedAt: h.clock.date, lastResetAt: nil, officialSignal: nil)))
        expect(h.monitor.state.forecastCount == 0, "An accepted null clears the visible signal")
        var returned = authority
        returned.updatedAt = h.clock.date.addingTimeInterval(120)
        h.next(h.result([signal], forecast: returned))
        expect(h.monitor.state.forecastCount == 1 && h.channel.payloads.count == 1,
               "Returning the same consumed authority signal after null does not create another reminder")
        h.monitor.stop()
        let reloaded = ResetNewsRepository(directory: h.directory, now: h.clock.date, calendar: { h.clock.calendar })
        let client = FakeNewsClient()
        let channel = FakeNewsNotifications()
        let clock = h.clock
        let restarted = ResetNewsMonitor(repository: reloaded, client: client,
            notifications: ResetNewsNotificationController(channel: channel), scheduler: FakeNewsScheduler(),
            defaults: h.defaults, now: { clock.date }, calendar: { clock.calendar }, notificationCenter: NotificationCenter())
        expect(restarted.state.forecastAvailability == .cached && restarted.state.forecastCount == 1,
               "Restart reads the persisted current signal as cache, without promoting internal history")
        restarted.updateGate(codexRunning: true, hudRunning: true, suspended: false)
        returned.updatedAt = clock.date
        client.complete(h.result([signal], forecast: returned))
        expect(restarted.state.forecastAvailability == .current && channel.payloads.isEmpty,
               "First fresh poll after restart honors the persisted notification ledger")
    }

    static func reverseResponsesAndSnapshotRollback() throws {
        let feed = try fixture("feed-mixed")
        let timeline = try fixture("timeline-mixed")
        let h = try RuntimeHarness()
        h.clock.date = ISO8601DateFormatter().date(from: "2026-10-02T03:00:00Z")!
        h.clock.calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        h.activate()
        let reversed = try fetched(feed, timeline, now: h.clock.date, reverseResponses: true)
        h.client.complete(reversed)
        expect(h.monitor.state.forecastCount == 1 && h.monitor.state.forecastAvailability == .current
            && h.channel.payloads.isEmpty, "Completing authority before context still establishes one silent initial signal")
        let next = h.source("9061")
        let accepted = h.snapshot([next], updatedAt: h.clock.date.addingTimeInterval(120))
        h.next(h.result([next], forecast: accepted))
        expect(h.monitor.state.items.first?.id == next.stableID && h.channel.payloads.count == 1,
               "A later authority snapshot can replace the initial signal once")
        let obsoleteNull = ResetForecastSnapshot(updatedAt: accepted.updatedAt.addingTimeInterval(-1), lastResetAt: nil, officialSignal: nil)
        h.next(h.result([], forecast: obsoleteNull))
        expect(h.repository.state.forecast == accepted && h.monitor.state.items.first?.id == next.stableID
            && h.monitor.state.forecastAvailability == .cached && h.channel.payloads.count == 1,
               "An older null response cannot erase an accepted newer signal or generate a reminder")
        let latestNull = ResetForecastSnapshot(updatedAt: h.clock.date, lastResetAt: nil, officialSignal: nil)
        h.next(h.result([], forecast: latestNull))
        expect(h.monitor.state.forecastCount == 0 && h.monitor.state.forecastAvailability == .current,
               "Only a newer valid null decision can clear the current signal")
        h.next(h.result([next], forecast: accepted))
        expect(h.monitor.state.items.isEmpty && h.repository.state.forecast == latestNull && h.channel.payloads.count == 1,
               "A delayed old signal cannot restore an already cleared current forecast")
    }

    static func staleContextCannotSuppressFreshAuthority() throws {
        let h = try RuntimeHarness()
        h.activate()
        h.client.complete(h.result([]))
        let signal = h.source("9071")
        h.next(h.result([signal], stale: true, forecastStale: false))
        expect(h.monitor.state.forecastAvailability == .current && h.monitor.state.forecastCount == 1
            && h.channel.payloads.count == 1 && h.channel.payloads.first?.itemIDs == [signal.stableID],
               "A fresh authority signal can notify even when historical context is stale")
        h.next(h.result([signal]))
        expect(h.channel.payloads.count == 1, "Context freshness recovery cannot replay the already delivered authority key")
    }

    static func conflictingSameVersionCannotUndoAuthority() throws {
        let h = try RuntimeHarness()
        h.activate()
        let signal = h.source("9081")
        let accepted = h.snapshot([signal])
        h.client.complete(h.result([signal], forecast: accepted))
        let conflictingNull = ResetForecastSnapshot(updatedAt: accepted.updatedAt, lastResetAt: nil, officialSignal: nil)
        h.next(h.result([], forecast: conflictingNull))
        expect(h.repository.state.forecast == accepted && h.monitor.state.forecastCount == 1
            && h.monitor.state.forecastAvailability == .cached && h.channel.payloads.isEmpty,
               "A different current-signal decision at the same version cannot overwrite accepted authority")
        var wordingOnly = accepted
        wordingOnly.officialSignal?.originalText += " This is the complete announcement."
        h.next(h.result([signal], forecast: wordingOnly))
        expect(h.monitor.state.forecastAvailability == .current && h.repository.state.forecast == wordingOnly
            && h.channel.payloads.isEmpty,
               "Same-version original-text enrichment with unchanged schedule identity is accepted silently")
        var conflictingCompletion = wordingOnly
        conflictingCompletion.lastResetAt = h.clock.date.addingTimeInterval(-60)
        h.next(h.result([signal], forecast: conflictingCompletion))
        expect(h.repository.state.forecast == wordingOnly && h.monitor.state.forecastCount == 1,
               "A conflicting same-version completion timestamp cannot mutate the accepted future signal")
    }

    static func pump(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        expect(condition(), "Asynchronous client completed")
    }
}
