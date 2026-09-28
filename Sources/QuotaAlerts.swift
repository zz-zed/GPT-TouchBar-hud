import Foundation
import CryptoKit
import UserNotifications

struct QuotaAlertConfiguration: Equatable {
    static let allowedThresholds = [10, 20, 30, 50]
    var enabled = false
    var fiveHourThreshold = 20
    var weeklyThreshold = 20
    var soundEnabled = false

    var normalized: QuotaAlertConfiguration {
        var value = self
        if !Self.allowedThresholds.contains(value.fiveHourThreshold) { value.fiveHourThreshold = 20 }
        if !Self.allowedThresholds.contains(value.weeklyThreshold) { value.weeklyThreshold = 20 }
        return value
    }
}

struct QuotaAlertPayload: Equatable {
    let identifier: String
    let title: String
    let body: String
    let sound: Bool
}

protocol QuotaAlertNotificationChannel: AnyObject {
    var onOpen: (() -> Void)? { get set }
    func requestAuthorization(completion: @escaping (ResetNewsNotificationPermission) -> Void)
    func readPermission(completion: @escaping (ResetNewsNotificationPermission) -> Void)
    func add(_ payload: QuotaAlertPayload, completion: @escaping (Error?) -> Void)
    func removePending(prefix: String)
}

final class QuotaAlertSystemNotificationChannel: QuotaAlertNotificationChannel {
    var onOpen: (() -> Void)?
    private lazy var center = UNUserNotificationCenter.current()

    init() {
        HUDSystemNotificationRouter.shared.register(prefix: QuotaAlertMonitor.identifierPrefix) { [weak self] _ in self?.onOpen?() }
    }

    private func prepareRouter() {
        HUDSystemNotificationRouter.shared.install(on: center)
    }

    func requestAuthorization(completion: @escaping (ResetNewsNotificationPermission) -> Void) {
        prepareRouter()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async { completion(error == nil ? (granted ? .allowed : .denied) : .unavailable) }
        }
    }

    func readPermission(completion: @escaping (ResetNewsNotificationPermission) -> Void) {
        prepareRouter()
        center.getNotificationSettings { settings in
            let value: ResetNewsNotificationPermission
            switch settings.authorizationStatus {
            case .authorized, .provisional: value = .allowed
            case .denied: value = .denied
            case .notDetermined: value = .notRequested
            @unknown default: value = .unavailable
            }
            DispatchQueue.main.async { completion(value) }
        }
    }

    func add(_ payload: QuotaAlertPayload, completion: @escaping (Error?) -> Void) {
        prepareRouter()
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        if payload.sound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: payload.identifier, content: content, trigger: nil)) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    func removePending(prefix: String) {
        center.getPendingNotificationRequests { [weak self] requests in
            let identifiers = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            if !identifiers.isEmpty { self?.center.removePendingNotificationRequests(withIdentifiers: identifiers) }
        }
    }
}

/// Main-thread owner. Callers must provide an account key verified for this successful snapshot.
/// Only hashes and deduplication times are persisted; quota values and account metadata are not.
final class QuotaAlertMonitor {
    static let identifierPrefix = "quota-alert:"
    static let enabledPreferenceKey = "quotaAlertsEnabled"
    static let fiveHourPreferenceKey = "quotaAlertsFiveHourThreshold"
    static let weeklyPreferenceKey = "quotaAlertsWeeklyThreshold"
    static let soundPreferenceKey = "quotaAlertsSoundEnabled"
    static let recordsPreferenceKey = "quotaAlertsDeduplicationV1"
    static let recordLimit = 512
    static let retention: TimeInterval = 90 * 24 * 60 * 60
    static let maximumSnapshotAge: TimeInterval = 120

    private struct Record: Codable, Equatable {
        let key: String
        let resetAt: Date
        let consumedAt: Date
    }
    private struct Baseline {
        let cycle: String
        let remaining: Double
        let observedAt: Date
    }
    private enum Window: String { case fiveHour, weekly }

    private let defaults: UserDefaults
    private let channel: QuotaAlertNotificationChannel
    private let now: () -> Date
    private var records: [Record]
    private var baselines: [Window: Baseline] = [:]
    private var accountScope: String?
    private var suspended = false
    private var generation = 0
    private var permissionGeneration = 0
    private var authorizationInFlight = false
    private var channelUsed = false
    private(set) var configuration: QuotaAlertConfiguration
    private(set) var permission: ResetNewsNotificationPermission = .notRequested
    var onStateChange: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    init(defaults: UserDefaults = .standard,
         channel: QuotaAlertNotificationChannel = QuotaAlertSystemNotificationChannel(),
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.channel = channel
        self.now = now
        configuration = QuotaAlertConfiguration(
            enabled: defaults.bool(forKey: Self.enabledPreferenceKey),
            fiveHourThreshold: defaults.object(forKey: Self.fiveHourPreferenceKey) as? Int ?? 20,
            weeklyThreshold: defaults.object(forKey: Self.weeklyPreferenceKey) as? Int ?? 20,
            soundEnabled: defaults.bool(forKey: Self.soundPreferenceKey)).normalized
        let data = defaults.data(forKey: Self.recordsPreferenceKey)
        records = data.flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
        channel.onOpen = { [weak self] in self?.onOpenSettings?() }
        pruneRecords(at: now())
        if configuration.enabled { authorize() }
    }

    func configure(_ value: QuotaAlertConfiguration) {
        let next = value.normalized
        guard next != configuration else { return }
        let wasEnabled = configuration.enabled
        let changedThreshold = next.fiveHourThreshold != configuration.fiveHourThreshold
            || next.weeklyThreshold != configuration.weeklyThreshold
        configuration = next
        defaults.set(next.enabled, forKey: Self.enabledPreferenceKey)
        defaults.set(next.fiveHourThreshold, forKey: Self.fiveHourPreferenceKey)
        defaults.set(next.weeklyThreshold, forKey: Self.weeklyPreferenceKey)
        defaults.set(next.soundEnabled, forKey: Self.soundPreferenceKey)
        // A threshold edit starts a silent baseline and never clears this cycle's consumed record.
        if wasEnabled != next.enabled || changedThreshold { invalidateBaseline() }
        if !next.enabled { removePending() }
        else if !wasEnabled { authorize() }
        onStateChange?()
    }

    /// Use on host loss, identity uncertainty, or a data-source change, including failed refreshes.
    func invalidateBaseline() {
        generation += 1
        baselines.removeAll()
        accountScope = nil
    }

    func suspend() {
        guard !suspended else { return }
        suspended = true
        invalidateBaseline()
        removePending()
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        invalidateBaseline()
        if configuration.enabled { refreshPermission() }
    }

    func refreshPermission() {
        guard configuration.enabled, !authorizationInFlight else { return }
        channelUsed = true
        permissionGeneration += 1
        let revision = permissionGeneration
        channel.readPermission { [weak self] value in
            guard let self, self.configuration.enabled, self.permissionGeneration == revision else { return }
            self.applyPermission(value)
        }
    }

    private func authorize() {
        guard !authorizationInFlight else { return }
        channelUsed = true
        authorizationInFlight = true
        permissionGeneration += 1
        channel.requestAuthorization { [weak self] value in
            guard let self else { return }
            self.authorizationInFlight = false
            guard self.configuration.enabled else { return }
            self.applyPermission(value)
        }
    }

    private func applyPermission(_ value: ResetNewsNotificationPermission) {
        guard permission != value else { return }
        permission = value
        // Permission becoming available cannot replay activity observed while it was unavailable.
        invalidateBaseline()
        onStateChange?()
    }

    func update(state: RateLimitDisplayState, accountKey: String?, limitID: String) {
        let date = now()
        guard configuration.enabled, !suspended else { invalidateBaseline(); return }
        guard let accountKey, !accountKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !limitID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              state.errorMessage == nil, !state.isRefreshing, let updated = state.lastUpdated,
              updated.timeIntervalSince1970.isFinite,
              date.timeIntervalSince(updated) >= -5,
              date.timeIntervalSince(updated) <= Self.maximumSnapshotAge else {
            invalidateBaseline()
            return
        }
        let scope = Self.digest([accountKey, limitID])
        if accountScope != scope {
            invalidateBaseline()
            accountScope = scope
            removePending()
        }
        pruneRecords(at: date)
        observe(state.fiveHour, window: .fiveHour, threshold: configuration.fiveHourThreshold, scope: scope, updated: updated, now: date)
        observe(state.weekly, window: .weekly, threshold: configuration.weeklyThreshold, scope: scope, updated: updated, now: date)
    }

    private func observe(_ meter: LimitMeter?, window: Window, threshold: Int,
                         scope: String, updated: Date, now date: Date) {
        guard let meter, meter.usedPercent.isFinite, (0...100).contains(meter.usedPercent),
              meter.remainingPercent.isFinite, let reset = meter.resetDate,
              reset.timeIntervalSince1970.isFinite, reset > date,
              reset.timeIntervalSince1970 < Double(Int64.max) else {
            baselines[window] = nil
            return
        }
        let cycle = Self.digest([scope, window.rawValue, String(Int64(reset.timeIntervalSince1970.rounded()))])
        let previous = baselines[window]
        // Ignore duplicate or out-of-order successful snapshots; they cannot form a new crossing.
        if let previous, previous.cycle == cycle, updated <= previous.observedAt { return }
        baselines[window] = Baseline(cycle: cycle, remaining: meter.remainingPercent, observedAt: updated)
        guard let previous, previous.cycle == cycle,
              updated.timeIntervalSince(previous.observedAt) <= Self.maximumSnapshotAge,
              previous.remaining > Double(threshold), meter.remainingPercent <= Double(threshold),
              !records.contains(where: { $0.key == cycle }) else { return }

        // Consume before attempting delivery: denied permission or a failed delivery must not replay later.
        records.append(Record(key: cycle, resetAt: reset, consumedAt: date))
        pruneRecords(at: date)
        persistRecords()
        guard permission == .allowed else { return }
        let label = window == .fiveHour ? "5 小时" : "每周"
        let percent = Int(meter.remainingPercent.rounded())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "MM/dd HH:mm"
        let payload = QuotaAlertPayload(identifier: Self.identifierPrefix + cycle,
            title: "\(label)额度剩余 \(percent)%",
            body: "已降至你设置的 \(threshold)% 提醒线。账号显示的重置时间：\(formatter.string(from: reset))。点击调整额度提醒。",
            sound: configuration.soundEnabled)
        let revision = generation
        channel.add(payload) { [weak self] _ in
            guard let self else { return }
            if !self.configuration.enabled || self.suspended || self.generation != revision {
                self.channel.removePending(prefix: payload.identifier)
            }
        }
    }

    private func pruneRecords(at date: Date) {
        let previous = records
        records = records.filter {
            $0.key.count == 64 && $0.key.allSatisfy { $0.isHexDigit }
                && $0.resetAt.timeIntervalSince1970.isFinite && $0.consumedAt.timeIntervalSince1970.isFinite
                && $0.resetAt > date.addingTimeInterval(-24 * 60 * 60)
                && $0.consumedAt >= date.addingTimeInterval(-Self.retention)
                && $0.consumedAt <= date.addingTimeInterval(5)
        }.sorted { $0.consumedAt > $1.consumedAt }
        if records.count > Self.recordLimit { records = Array(records.prefix(Self.recordLimit)) }
        if records != previous { persistRecords() }
    }

    private func persistRecords() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.recordsPreferenceKey) }
    }

    private func removePending() {
        if channelUsed { channel.removePending(prefix: Self.identifierPrefix) }
    }

    private static func digest(_ components: [String]) -> String {
        // Length framing prevents scope collisions even if a caller's key contains separators.
        let value = components.map { "\($0.utf8.count):" + $0 }.joined()
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
