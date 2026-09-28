import Foundation
import UserNotifications

struct AppUpdateNotificationPayload: Equatable {
    let identifier: String
    let version: String
    let title: String
    let body: String
}

protocol AppUpdateNotificationChannel: AnyObject {
    var onOpen: ((String) -> Void)? { get set }
    func requestAuthorization(completion: @escaping (ResetNewsNotificationPermission) -> Void)
    func readPermission(completion: @escaping (ResetNewsNotificationPermission) -> Void)
    func add(_ payload: AppUpdateNotificationPayload, completion: @escaping (Error?) -> Void)
    func remove(identifiers: [String])
    func removeAll(prefix: String, keeping identifier: String?)
}

final class AppUpdateSystemNotificationChannel: AppUpdateNotificationChannel {
    var onOpen: ((String) -> Void)?
    private lazy var center = UNUserNotificationCenter.current()
    private var cleanupGeneration = 0

    init() {
        HUDSystemNotificationRouter.shared.register(prefix: AppUpdateNotificationController.identifierPrefix) { [weak self] info in
            guard let version = info["appUpdateVersion"] as? String else { return }
            self?.onOpen?(version)
        }
    }

    private func prepareRouter() { HUDSystemNotificationRouter.shared.install(on: center) }

    func requestAuthorization(completion: @escaping (ResetNewsNotificationPermission) -> Void) {
        prepareRouter()
        center.requestAuthorization(options: [.alert]) { granted, error in
            DispatchQueue.main.async { completion(error == nil ? (granted ? .allowed : .denied) : .unavailable) }
        }
    }

    func readPermission(completion: @escaping (ResetNewsNotificationPermission) -> Void) {
        prepareRouter()
        center.getNotificationSettings { settings in
            let permission: ResetNewsNotificationPermission
            switch settings.authorizationStatus {
            case .authorized, .provisional: permission = .allowed
            case .denied: permission = .denied
            case .notDetermined: permission = .notRequested
            @unknown default: permission = .unavailable
            }
            DispatchQueue.main.async { completion(permission) }
        }
    }

    /// Content creation is separate from delivery so silence can be verified without system access.
    static func content(for payload: AppUpdateNotificationPayload) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.userInfo = ["appUpdateVersion": payload.version]
        content.sound = nil
        return content
    }

    func add(_ payload: AppUpdateNotificationPayload, completion: @escaping (Error?) -> Void) {
        prepareRouter()
        center.add(UNNotificationRequest(identifier: payload.identifier, content: Self.content(for: payload), trigger: nil)) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    func remove(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        prepareRouter()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removeAll(prefix: String, keeping identifier: String?) {
        prepareRouter()
        cleanupGeneration += 1
        let revision = cleanupGeneration
        // Enumeration is asynchronous. A later cleanup plan supersedes this one, and its retained
        // identifier protects a newly delivered version while old notifications are being removed.
        center.getPendingNotificationRequests { [weak self] requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(prefix) && $0 != identifier }
            DispatchQueue.main.async {
                guard let self, self.cleanupGeneration == revision else { return }
                if !ids.isEmpty { self.center.removePendingNotificationRequests(withIdentifiers: ids) }
            }
        }
        center.getDeliveredNotifications { [weak self] notifications in
            let ids = notifications.map { $0.request.identifier }.filter { $0.hasPrefix(prefix) && $0 != identifier }
            DispatchQueue.main.async {
                guard let self, self.cleanupGeneration == revision else { return }
                if !ids.isEmpty { self.center.removeDeliveredNotifications(withIdentifiers: ids) }
            }
        }
    }
}

/// Independent from automatic checking. The default-on preference never implies consent to a
/// system permission prompt; only setEnabled(true, userInitiated: true) requests authorization.
final class AppUpdateNotificationPreferences {
    static let enabledKey = "appUpdate.notificationsEnabled"
    static let consumedVersionKey = "appUpdate.notificationConsumedVersion"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var enabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var consumedVersion: String? {
        get { defaults.string(forKey: Self.consumedVersionKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.consumedVersionKey) }
            else { defaults.removeObject(forKey: Self.consumedVersionKey) }
        }
    }
}

/// Main-thread owner. Version consumption is monotonic and recorded before permission/delivery,
/// so missing permission, disabled notifications, or failed delivery cannot cause a later replay.
final class AppUpdateNotificationController {
    static let identifierPrefix = "app-update:"
    private struct AvailableVersion {
        let tag: String
        let version: AppVersion
        var identifier: String { AppUpdateNotificationController.identifierPrefix + Self.canonical(version) }
        static func canonical(_ version: AppVersion) -> String {
            let parts = version.parts.count == 1 ? version.parts + [0] : version.parts
            return parts.map(String.init).joined(separator: ".")
        }
    }
    private struct CleanupPlan: Equatable { let retainedIdentifier: String? }

    private let preferences: AppUpdateNotificationPreferences
    private let channel: AppUpdateNotificationChannel
    private var available: AvailableVersion?
    private var consumed: AppVersion?
    private var installedVersion: AppVersion?
    private var initialized = false
    private var suppressCurrent = false
    private var generation = 0
    private var permissionGeneration = 0
    private var appliedPermissionGeneration = 0
    private var authorizationInFlight = false
    private var lastCleanup: CleanupPlan?
    private(set) var permission: ResetNewsNotificationPermission = .notRequested
    var enabled: Bool { preferences.enabled }
    var onStateChange: (() -> Void)?
    var onOpenRelease: ((String) -> Void)?

    init(defaults: UserDefaults = .standard,
         channel: AppUpdateNotificationChannel = AppUpdateSystemNotificationChannel()) {
        preferences = AppUpdateNotificationPreferences(defaults: defaults)
        self.channel = channel
        consumed = preferences.consumedVersion.flatMap(AppVersion.init)
        channel.onOpen = { [weak self] version in self?.open(version: version) }
    }

    func setEnabled(_ enabled: Bool, userInitiated: Bool = false) {
        let changed = preferences.enabled != enabled
        if changed {
            preferences.enabled = enabled
            generation += 1
            permissionGeneration += 1
            if !enabled {
                suppressCurrent = true
                if let available { consume(available.version); channel.remove(identifiers: [available.identifier]) }
                cleanup(keeping: nil)
            }
            onStateChange?()
        }
        if enabled && userInitiated { requestAuthorization() }
    }

    /// Safe for automatic startup and opening settings: this never requests permission.
    func refreshPermission() {
        guard enabled, !authorizationInFlight else { return }
        permissionGeneration += 1
        let revision = permissionGeneration
        channel.readPermission { [weak self] value in
            guard let self, self.enabled, self.permissionGeneration == revision else { return }
            self.applyPermission(value, revision: revision)
        }
    }

    private func requestAuthorization() {
        guard !authorizationInFlight else { return }
        authorizationInFlight = true
        permissionGeneration += 1
        let revision = permissionGeneration
        channel.requestAuthorization { [weak self] value in
            guard let self else { return }
            self.authorizationInFlight = false
            guard self.enabled else { return }
            guard self.permissionGeneration == revision else { self.refreshPermission(); return }
            self.applyPermission(value, revision: revision)
        }
    }

    func update(availableVersion: String?, currentVersion: String, skippedVersion: String? = nil,
                origins: Set<AppUpdateCheckOrigin> = []) {
        let isInitialSync = !initialized
        initialized = true
        installedVersion = AppVersion(currentVersion)
        guard let installedVersion else { clearAvailable(); return }
        if let consumed, installedVersion >= consumed { consume(installedVersion) }
        let candidate = availableVersion.flatMap { tag in AppVersion(tag).map { AvailableVersion(tag: tag, version: $0) } }
        guard let candidate, candidate.version > installedVersion else {
            clearAvailable()
            return
        }
        if let skipped = skippedVersion.flatMap(AppVersion.init), skipped == candidate.version {
            consume(candidate.version)
            clearAvailable(forceCleanup: true)
            return
        }
        if available?.version != candidate.version {
            // The parent owns the accepted Latest result, including withdrawal or cache rollback.
            // Keep its target authoritative; the consumed high-water mark still prevents replay.
            if let available { channel.remove(identifiers: [available.identifier]) }
            generation += 1
            available = candidate
            suppressCurrent = false
            cleanup(keeping: enabled ? candidate.identifier : nil)
        } else {
            available = candidate // Preserve the current source's tag spelling for the parent callback.
        }

        if origins.contains(.manual) {
            consume(candidate.version)
            generation += 1
            suppressCurrent = true
            channel.remove(identifiers: [candidate.identifier])
            cleanup(keeping: nil)
            return
        }
        if origins.isEmpty {
            // The initial persisted availability is a silent baseline. Routine state refreshes
            // must not consume a new automatic result before its explicit origin arrives.
            if isInitialSync { consume(candidate.version) }
            return
        }
        guard origins.contains(.automatic) else { return }
        let previouslyConsumed = consumed.map { candidate.version <= $0 } ?? false
        consume(candidate.version)
        guard enabled, !suppressCurrent, !previouslyConsumed, !authorizationInFlight else { return }
        let revision = generation
        permissionGeneration += 1
        let permissionRevision = permissionGeneration
        channel.readPermission { [weak self] value in
            guard let self, self.enabled, self.generation == revision,
                  !self.authorizationInFlight,
                  self.available?.version == candidate.version, !self.suppressCurrent else { return }
            // A settings read cannot cancel this delivery. If a newer read has already completed,
            // honor that permission instead of letting the older reply overwrite it.
            self.applyPermission(value, revision: permissionRevision)
            guard self.permission == .allowed else { return }
            self.deliver(candidate, generation: revision)
        }
    }

    private func deliver(_ candidate: AvailableVersion, generation revision: Int) {
        guard enabled, generation == revision, available?.version == candidate.version, !suppressCurrent else { return }
        let payload = AppUpdateNotificationPayload(identifier: candidate.identifier, version: candidate.tag,
            title: "GPT TouchBar HUD 有新版本 \(candidate.tag)",
            body: "点击查看版本说明，可选择安装、稍后或跳过此版本。")
        channel.add(payload) { [weak self] _ in
            guard let self else { return }
            if !self.enabled || self.generation != revision || self.available?.version != candidate.version || self.suppressCurrent {
                self.channel.remove(identifiers: [candidate.identifier])
            }
        }
    }

    private func open(version: String) {
        guard enabled, !suppressCurrent, let available,
              AppVersion(version) == available.version,
              let installedVersion, available.version > installedVersion else { return }
        generation += 1
        suppressCurrent = true
        consume(available.version)
        channel.remove(identifiers: [available.identifier])
        cleanup(keeping: nil)
        onOpenRelease?(available.tag)
    }

    private func clearAvailable(forceCleanup: Bool = false) {
        let hadAvailable = available != nil
        if hadAvailable { generation += 1 }
        if let available { channel.remove(identifiers: [available.identifier]) }
        available = nil
        suppressCurrent = false
        if hadAvailable || forceCleanup || consumed != nil { cleanup(keeping: nil) }
    }

    private func cleanup(keeping identifier: String?) {
        let plan = CleanupPlan(retainedIdentifier: identifier)
        guard lastCleanup != plan else { return }
        lastCleanup = plan
        channel.removeAll(prefix: Self.identifierPrefix, keeping: identifier)
    }

    private func consume(_ version: AppVersion) {
        guard consumed.map({ version > $0 }) ?? true else { return }
        consumed = version
        preferences.consumedVersion = AvailableVersion.canonical(version)
    }

    private func applyPermission(_ value: ResetNewsNotificationPermission, revision: Int) {
        guard revision >= appliedPermissionGeneration else { return }
        appliedPermissionGeneration = revision
        guard value != permission else { return }
        permission = value
        onStateChange?()
    }
}
