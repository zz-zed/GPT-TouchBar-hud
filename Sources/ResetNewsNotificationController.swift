import Foundation
import UserNotifications
import ResetNewsCore

enum ResetNewsNotificationPermission: String, Equatable {
    case notRequested, allowed, denied, unavailable
}

struct ResetNewsNotificationPayload: Equatable {
    let identifier: String
    let itemIDs: [String]
    let title: String
    let body: String
    let sound: Bool
}

protocol ResetNewsNotificationChannel: AnyObject {
    var onOpen: (([String]) -> Void)? { get set }
    func requestAuthorization(completion: @escaping (ResetNewsNotificationPermission) -> Void)
    func readPermission(completion: @escaping (ResetNewsNotificationPermission) -> Void)
    func add(_ payload: ResetNewsNotificationPayload, completion: @escaping (Error?) -> Void)
    func removePending(prefix: String)
}

/// Both notification features share one delegate, so enabling one cannot steal the other's clicks.
/// Registering handlers does not touch the system center; enabled channels install the delegate.
final class HUDSystemNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = HUDSystemNotificationRouter()
    private var handlers: [String: ([AnyHashable: Any]) -> Void] = [:]

    func register(prefix: String, onOpen: @escaping ([AnyHashable: Any]) -> Void) {
        handlers[prefix] = onOpen
    }

    func install(on center: UNUserNotificationCenter) { center.delegate = self }

    /// Kept independent of UNNotificationResponse so routing is testable without a real notification.
    func open(identifier: String, actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              let prefix = handlers.keys.filter({ identifier.hasPrefix($0) }).max(by: { $0.count < $1.count }) else { return }
        handlers[prefix]?(userInfo)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.sound == nil ? [.banner, .list] : [.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async { [weak self] in self?.open(identifier: identifier, actionIdentifier: action, userInfo: info) }
        completionHandler()
    }
}

/// The channel itself is lazy; an enabled monitor requests permission through enable().
final class ResetNewsSystemNotificationChannel: ResetNewsNotificationChannel {
    var onOpen: (([String]) -> Void)?
    private lazy var center = UNUserNotificationCenter.current()

    init() {
        HUDSystemNotificationRouter.shared.register(prefix: ResetNewsNotificationController.identifierPrefix) { [weak self] info in
            guard let ids = info["resetNewsItemIDs"] as? [String] else { return }
            self?.onOpen?(ids)
        }
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

    func add(_ payload: ResetNewsNotificationPayload, completion: @escaping (Error?) -> Void) {
        prepareRouter()
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.userInfo = ["resetNewsItemIDs": payload.itemIDs]
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

final class ResetNewsNotificationController {
    static let identifierPrefix = "reset-news:"
    var onOpenDetails: (([String]) -> Void)?
    var onPermissionChange: ((ResetNewsNotificationPermission) -> Void)?
    var soundEnabled = false
    private(set) var permission: ResetNewsNotificationPermission = .notRequested
    private let channel: ResetNewsNotificationChannel
    private var permissionRequested = false
    private var authorizationInFlight = false
    private var permissionRefreshGeneration = 0
    private var active = false
    private var generation = 0

    init(channel: ResetNewsNotificationChannel = ResetNewsSystemNotificationChannel()) {
        self.channel = channel
        channel.onOpen = { [weak self] ids in self?.onOpenDetails?(ids) }
    }

    /// Called for enabled state, including the default-on setting and saved enabled preferences.
    func enable() {
        active = true
        guard !permissionRequested else { refreshPermission(); return }
        permissionRequested = true
        authorizationInFlight = true
        channel.requestAuthorization { [weak self] permission in
            guard let self else { return }
            self.authorizationInFlight = false
            self.permission = permission
            if self.active { self.onPermissionChange?(permission) }
        }
    }

    func resume() {
        active = true
        refreshPermission()
    }

    private func refreshPermission() {
        // Reading settings never prompts. Do not race the initial authorization sheet.
        guard permissionRequested, !authorizationInFlight else { return }
        permissionRefreshGeneration += 1
        let refreshGeneration = permissionRefreshGeneration
        let runtimeGeneration = generation
        channel.readPermission { [weak self] permission in
            guard let self, self.active, self.generation == runtimeGeneration,
                  self.permissionRefreshGeneration == refreshGeneration else { return }
            self.permission = permission
            self.onPermissionChange?(permission)
        }
    }

    func deliver(_ candidates: [ResetNewsItem], recovery: Bool = false, now: Date = Date(), calendar: Calendar = .current) {
        let items = ResetForecastPolicy(calendar: calendar).retaining(candidates, now: now)
        guard active, permission == .allowed, let first = items.first else { return }
        let requestGeneration = generation
        let title = "Codex 重置预告（\(items.count) 条新预告）"
        let payload = ResetNewsNotificationPayload(
            identifier: Self.identifierPrefix + (recovery ? "summary:" : "") + first.notificationKey,
            itemIDs: items.map(\.id), title: title,
            body: items.count > 1 ? first.summaryZH + "；另有 \(items.count - 1) 条新预告，点击查看本地详情。" : first.summaryZH,
            sound: soundEnabled)
        channel.add(payload) { [weak self] _ in
            guard let self else { return }
            // An asynchronous add can finish after stop's pending-request scan.
            if !self.active || requestGeneration != self.generation {
                self.channel.removePending(prefix: Self.identifierPrefix)
            }
        }
    }

    func stop() {
        active = false
        generation += 1
        // Do not instantiate the system notification center for a never-enabled feature.
        if permissionRequested { channel.removePending(prefix: Self.identifierPrefix) }
    }
}
