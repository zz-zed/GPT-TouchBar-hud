import Foundation
import UserNotifications

private final class AlertClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval = 60) { date = date.addingTimeInterval(seconds) }
}

private final class FakeQuotaAlertChannel: QuotaAlertNotificationChannel {
    var onOpen: (() -> Void)?
    var permission: ResetNewsNotificationPermission = .allowed
    var authorizationRequests = 0
    var permissionReads = 0
    var payloads: [QuotaAlertPayload] = []
    var removedPrefixes: [String] = []
    var pendingAdds: [(Error?) -> Void] = []
    var pendingPermissions: [(ResetNewsNotificationPermission) -> Void] = []
    var deferAdds = false
    var deferPermission = false
    var addError: Error?
    func requestAuthorization(completion: @escaping (ResetNewsNotificationPermission) -> Void) {
        authorizationRequests += 1
        if deferPermission { pendingPermissions.append(completion) } else { completion(permission) }
    }
    func readPermission(completion: @escaping (ResetNewsNotificationPermission) -> Void) {
        permissionReads += 1
        if deferPermission { pendingPermissions.append(completion) } else { completion(permission) }
    }
    func add(_ payload: QuotaAlertPayload, completion: @escaping (Error?) -> Void) {
        payloads.append(payload)
        if deferAdds { pendingAdds.append(completion) } else { completion(addError) }
    }
    func removePending(prefix: String) { removedPrefixes.append(prefix) }
}

private final class AlertHarness {
    let suite = "quota-alert-tests." + UUID().uuidString
    let clock = AlertClock()
    let channel = FakeQuotaAlertChannel()
    let defaults: UserDefaults
    var monitor: QuotaAlertMonitor!
    let firstReset: Date
    init(enabled: Bool = true) {
        defaults = UserDefaults(suiteName: suite)!
        firstReset = clock.date.addingTimeInterval(7 * 24 * 60 * 60)
        monitor = QuotaAlertMonitor(defaults: defaults, channel: channel, now: { [clock] in clock.date })
        if enabled { monitor.configure(QuotaAlertConfiguration(enabled: true)) }
    }
    deinit { defaults.removePersistentDomain(forName: suite) }
    func state(five: Double? = 50, weekly: Double? = nil, reset: Date? = nil) -> RateLimitDisplayState {
        var result = RateLimitDisplayState.initial
        func meter(_ remaining: Double?, minutes: Double) -> LimitMeter? {
            remaining.map { LimitMeter(title: "test", shortTitle: "test",
                window: RateLimitWindow(usedPercent: 100 - $0, windowDurationMins: minutes,
                    resetsAt: (reset ?? firstReset).timeIntervalSince1970)) }
        }
        result.fiveHour = meter(five, minutes: 300)
        result.weekly = meter(weekly, minutes: 10080)
        result.lastUpdated = clock.date
        return result
    }
    func send(five: Double? = 50, weekly: Double? = nil, account: String? = "account-a",
              limit: String = "codex", reset: Date? = nil) {
        monitor.update(state: state(five: five, weekly: weekly, reset: reset), accountKey: account, limitID: limit)
        clock.advance()
    }
}

@main
enum QuotaAlertTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label)
        checks += 1
    }

    static func basicCrossings() {
        let h = AlertHarness(enabled: false)
        check(!h.monitor.configuration.enabled && h.channel.authorizationRequests == 0, "Default-off never requests notification permission")
        check(h.monitor.configuration.fiveHourThreshold == 20 && h.monitor.configuration.weeklyThreshold == 20,
              "Both default thresholds are 20 percent")
        h.send(five: 80)
        h.send(five: 10)
        check(h.channel.payloads.isEmpty, "Disabled never delivers")
        h.monitor.configure(QuotaAlertConfiguration(enabled: true))
        check(h.channel.authorizationRequests == 1 && h.monitor.permission == .allowed, "Enabling requests authorization")
        h.send(five: 10)
        check(h.channel.payloads.isEmpty, "Enabling below threshold is a silent baseline")
        h.send(five: 55)
        h.send(five: 20)
        check(h.channel.payloads.count == 1, "Crossing down to exact threshold delivers")
        check(!h.channel.payloads[0].sound && h.channel.payloads[0].title.contains("20%"), "Silent by default with actual quota")
        h.send(five: 19)
        h.send(five: 55)
        h.send(five: 10)
        check(h.channel.payloads.count == 1, "Repeated and rebound crossings are deduplicated in one cycle")
        h.send(five: 10, weekly: 60)
        h.send(five: 10, weekly: 20)
        check(h.channel.payloads.count == 2 && h.channel.payloads[1].title.contains("每周"), "Weekly quota has independent deduplication")
        let newReset = h.firstReset.addingTimeInterval(300)
        h.send(five: 10, reset: newReset)
        check(h.channel.payloads.count == 2, "A new cycle's first low sample does not replay")
        h.send(five: 80, reset: newReset)
        h.send(five: 10, reset: newReset)
        check(h.channel.payloads.count == 3, "A new cycle permits a new observed crossing")
        var opened = false
        h.monitor.onOpenSettings = { opened = true }
        h.channel.onOpen?()
        check(opened, "Notification click opens quota settings")
    }

    static func identityAndPersistence() throws {
        let h = AlertHarness()
        h.send(five: 90)
        h.send(five: 10)
        let persisted = h.defaults.data(forKey: QuotaAlertMonitor.recordsPreferenceKey)!
        let text = String(data: persisted, encoding: .utf8)!
        check(!text.contains("account-a") && !text.contains("remaining") && !text.contains("tokens"), "No account metadata or quota history is persisted")
        let json = try JSONSerialization.jsonObject(with: persisted) as! [[String: Any]]
        check(Set(json[0].keys) == Set(["key", "resetAt", "consumedAt"]), "Deduplication stores only hash and times")
        check((json[0]["key"] as? String)?.count == 64, "Deduplication identity is SHA-256")
        h.monitor = QuotaAlertMonitor(defaults: h.defaults, channel: h.channel, now: { [clock = h.clock] in clock.date })
        h.send(five: 80)
        h.send(five: 10)
        check(h.channel.payloads.count == 1, "Same cycle remains deduplicated across app restart")
        h.send(five: 80)
        h.send(five: 10, account: "account-b")
        check(h.channel.payloads.count == 1, "Account change cannot form a crossing with another account's data")
        h.send(five: 70, account: "account-b")
        h.send(five: 10, account: "account-b")
        check(h.channel.payloads.count == 2, "Different verified accounts have independent cycles")
        h.send(five: 70, account: "account-b")
        h.send(five: 10, account: "account-b", limit: "other-bucket")
        check(h.channel.payloads.count == 2, "Changing limit bucket rebuilds baseline")
        h.send(five: 60, account: "account-b", limit: "other-bucket")
        h.send(five: 10, account: "account-b", limit: "other-bucket")
        check(h.channel.payloads.count == 3, "Different buckets have independent deduplication")
    }

    static func invalidSnapshots() {
        let mutations: [(String, (inout RateLimitDisplayState, AlertHarness) -> Void)] = [
            ("failed refresh", { state, _ in state.errorMessage = "failure" }),
            ("in-progress refresh", { state, _ in state.isRefreshing = true }),
            ("missing timestamp", { state, _ in state.lastUpdated = nil }),
            ("stale timestamp", { state, h in state.lastUpdated = h.clock.date.addingTimeInterval(-121) }),
            ("future timestamp", { state, h in state.lastUpdated = h.clock.date.addingTimeInterval(10) }),
            ("missing meter", { state, _ in state.fiveHour = nil }),
            ("missing reset", { state, _ in state.fiveHour = LimitMeter(title: "", shortTitle: "", window: RateLimitWindow(usedPercent: 90, windowDurationMins: 300, resetsAt: nil)) }),
            ("expired reset", { state, h in state.fiveHour = LimitMeter(title: "", shortTitle: "", window: RateLimitWindow(usedPercent: 90, windowDurationMins: 300, resetsAt: h.clock.date.addingTimeInterval(-1).timeIntervalSince1970)) }),
            ("invalid percentage", { state, h in state.fiveHour = LimitMeter(title: "", shortTitle: "", window: RateLimitWindow(usedPercent: 110, windowDurationMins: 300, resetsAt: h.firstReset.timeIntervalSince1970)) }),
            ("nonfinite percentage", { state, h in state.fiveHour = LimitMeter(title: "", shortTitle: "", window: RateLimitWindow(usedPercent: .nan, windowDurationMins: 300, resetsAt: h.firstReset.timeIntervalSince1970)) })
        ]
        for (label, mutate) in mutations {
            let h = AlertHarness()
            h.send(five: 70)
            var invalid = h.state(five: 10)
            mutate(&invalid, h)
            h.monitor.update(state: invalid, accountKey: "account-a", limitID: "codex")
            h.clock.advance()
            h.send(five: 10)
            check(h.channel.payloads.isEmpty, "No catch-up notification after \(label)")
            h.send(five: 70)
            h.send(five: 10)
            check(h.channel.payloads.count == 1, "Later valid crossing still works after \(label)")
        }
        for account: String? in [nil, "", " \n"] {
            let h = AlertHarness()
            h.send(five: 70)
            h.send(five: 10, account: account)
            h.send(five: 10)
            check(h.channel.payloads.isEmpty, "Unverified or empty identity invalidates baseline")
        }
        let h = AlertHarness()
        h.send(five: 70)
        h.clock.advance(200)
        h.send(five: 10)
        check(h.channel.payloads.isEmpty, "A long observation gap cannot cause a catch-up alert")
        h.send(five: 70)
        var duplicate = h.state(five: 10)
        duplicate.lastUpdated = h.clock.date.addingTimeInterval(-60)
        h.monitor.update(state: duplicate, accountKey: "account-a", limitID: "codex")
        check(h.channel.payloads.isEmpty, "Duplicate timestamp cannot form a crossing")
        h.send(five: 10)
        check(h.channel.payloads.count == 1, "A newer snapshot can form the actual crossing")
    }

    static func lifecycleAndPreferences() {
        let h = AlertHarness()
        var stateChanges = 0
        h.monitor.onStateChange = { stateChanges += 1 }
        h.send(five: 80)
        h.monitor.resume()
        h.send(five: 10)
        check(h.channel.payloads.count == 1 && stateChanges == 0, "Repeated resume preserves baseline and snapshot updates do not publish preference changes")
        let cycle = h.firstReset.addingTimeInterval(100)
        h.send(five: 80, reset: cycle)
        h.monitor.suspend()
        h.monitor.suspend()
        h.send(five: 10, reset: cycle)
        h.monitor.resume()
        h.send(five: 10, reset: cycle)
        check(h.channel.payloads.count == 1, "Sleep and resume do not replay a missed crossing")
        h.send(five: 80, reset: cycle)
        h.monitor.configure(QuotaAlertConfiguration(enabled: false))
        h.monitor.configure(QuotaAlertConfiguration(enabled: true))
        h.send(five: 10, reset: cycle)
        check(h.channel.payloads.count == 1, "Disabling and enabling starts a silent baseline")
        h.send(five: 40, reset: cycle)
        h.monitor.configure(QuotaAlertConfiguration(enabled: true, fiveHourThreshold: 50, weeklyThreshold: 30, soundEnabled: true))
        h.send(five: 40, reset: cycle)
        check(h.channel.payloads.count == 1, "Moving threshold across current quota does not notify")
        h.send(five: 60, reset: cycle)
        h.send(five: 40, reset: cycle)
        check(h.channel.payloads.count == 2 && h.channel.payloads[1].sound, "A later crossing uses new threshold and selected sound")
        h.monitor.configure(QuotaAlertConfiguration(enabled: true, fiveHourThreshold: 10))
        h.send(five: 40, reset: cycle)
        h.send(five: 5, reset: cycle)
        check(h.channel.payloads.count == 2, "Threshold changes never replay an already consumed cycle")
        h.monitor.configure(QuotaAlertConfiguration(enabled: true, fiveHourThreshold: 17, weeklyThreshold: 99))
        check(h.monitor.configuration.fiveHourThreshold == 20 && h.monitor.configuration.weeklyThreshold == 20,
              "Unsupported thresholds normalize to safe defaults")
        check(h.defaults.integer(forKey: QuotaAlertMonitor.fiveHourPreferenceKey) == 20,
              "Normalized settings are persisted")
    }

    static func permissionAndRaces() {
        let h = AlertHarness(enabled: false)
        h.channel.permission = .denied
        h.monitor.configure(QuotaAlertConfiguration(enabled: true))
        h.send(five: 80)
        h.send(five: 10)
        check(h.channel.payloads.isEmpty && h.monitor.permission == .denied, "Denied permission is surfaced without delivery")
        h.channel.permission = .allowed
        h.monitor.refreshPermission()
        h.send(five: 10)
        h.send(five: 80)
        h.send(five: 10)
        check(h.channel.payloads.isEmpty, "Granting permission cannot replay a consumed denied crossing")
        let newReset = h.firstReset.addingTimeInterval(300)
        h.channel.deferAdds = true
        h.send(five: 80, reset: newReset)
        h.send(five: 10, reset: newReset)
        let oldID = h.channel.payloads[0].identifier
        h.monitor.suspend()
        h.monitor.resume()
        let newerReset = h.firstReset.addingTimeInterval(600)
        h.send(five: 80, reset: newerReset)
        h.send(five: 10, reset: newerReset)
        h.channel.pendingAdds[0](nil)
        check(h.channel.removedPrefixes.last == oldID, "Late add cleanup only removes its own old notification")
        check(h.channel.removedPrefixes.allSatisfy { $0.hasPrefix(QuotaAlertMonitor.identifierPrefix) },
              "Quota cleanup never removes forecast notifications")
        let failed = AlertHarness()
        failed.channel.addError = NSError(domain: "test", code: 1)
        failed.send(five: 70)
        failed.send(five: 10)
        failed.send(five: 70)
        failed.send(five: 10)
        check(failed.channel.payloads.count == 1, "Failed delivery is not retried or replayed in the cycle")
        let deferred = AlertHarness(enabled: false)
        deferred.channel.deferPermission = true
        deferred.monitor.configure(QuotaAlertConfiguration(enabled: true))
        deferred.monitor.configure(QuotaAlertConfiguration(enabled: false))
        deferred.channel.pendingPermissions[0](.allowed)
        check(deferred.monitor.permission == .notRequested, "Disabled monitor ignores delayed permission callback")
    }

    static func boundedPersistence() throws {
        let h = AlertHarness()
        for index in 0..<(QuotaAlertMonitor.recordLimit + 8) {
            h.send(five: 70, account: "account-\(index)")
            h.send(five: 10, account: "account-\(index)")
        }
        var json = try JSONSerialization.jsonObject(with: h.defaults.data(forKey: QuotaAlertMonitor.recordsPreferenceKey)!) as! [[String: Any]]
        check(json.count == QuotaAlertMonitor.recordLimit, "Persistent metadata has a strict entry bound")
        h.clock.advance(QuotaAlertMonitor.retention + 1)
        h.send(five: 70, reset: h.clock.date.addingTimeInterval(3600))
        json = try JSONSerialization.jsonObject(with: h.defaults.data(forKey: QuotaAlertMonitor.recordsPreferenceKey)!) as! [[String: Any]]
        check(json.isEmpty, "Expired metadata is pruned")
    }

    static func notificationRouting() {
        let router = HUDSystemNotificationRouter()
        var news: [String] = []
        var quotaOpens = 0
        router.register(prefix: "reset-news:") { news = $0["resetNewsItemIDs"] as? [String] ?? [] }
        router.register(prefix: "quota-alert:") { _ in quotaOpens += 1 }
        router.open(identifier: "reset-news:one", actionIdentifier: UNNotificationDefaultActionIdentifier,
                    userInfo: ["resetNewsItemIDs": ["one", "two"]])
        router.open(identifier: "quota-alert:one", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: [:])
        check(news == ["one", "two"] && quotaOpens == 1, "One router preserves both forecast and quota click handlers")
        router.open(identifier: "quota-alert:two", actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: [:])
        router.open(identifier: "unknown:one", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: [:])
        check(quotaOpens == 1 && news == ["one", "two"], "Dismissal and unknown identifiers have no click action")
    }

    static func main() throws {
        basicCrossings()
        try identityAndPersistence()
        invalidSnapshots()
        lifecycleAndPreferences()
        permissionAndRaces()
        try boundedPersistence()
        notificationRouting()
        print("PASS: \(checks) quota alert checks; fake notifications and isolated preferences only")
    }
}
