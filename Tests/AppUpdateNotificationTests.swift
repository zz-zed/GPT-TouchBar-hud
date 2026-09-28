import Foundation
import UserNotifications

private final class FakeUpdateNotificationChannel: AppUpdateNotificationChannel {
    var onOpen: ((String) -> Void)?
    var permission: ResetNewsNotificationPermission = .allowed
    var authorizationRequests = 0
    var permissionReads = 0
    var payloads: [AppUpdateNotificationPayload] = []
    var removed: [[String]] = []
    var cleanupPlans: [(prefix: String, keeping: String?)] = []
    var delayedPermission = false
    var delayedAdd = false
    var pendingPermissions: [(ResetNewsNotificationPermission) -> Void] = []
    var pendingAuthorizations: [(ResetNewsNotificationPermission) -> Void] = []
    var pendingAdds: [(Error?) -> Void] = []
    var deliveryError: Error?
    func requestAuthorization(completion: @escaping (ResetNewsNotificationPermission) -> Void) {
        authorizationRequests += 1
        if delayedPermission { pendingAuthorizations.append(completion) } else { completion(permission) }
    }
    func readPermission(completion: @escaping (ResetNewsNotificationPermission) -> Void) {
        permissionReads += 1
        if delayedPermission { pendingPermissions.append(completion) } else { completion(permission) }
    }
    func add(_ payload: AppUpdateNotificationPayload, completion: @escaping (Error?) -> Void) {
        payloads.append(payload)
        if delayedAdd { pendingAdds.append(completion) } else { completion(deliveryError) }
    }
    func remove(identifiers: [String]) { removed.append(identifiers) }
    func removeAll(prefix: String, keeping identifier: String?) { cleanupPlans.append((prefix, identifier)) }
}

private final class UpdateNotificationHarness {
    let suite = "app-update-notification-tests." + UUID().uuidString
    let defaults: UserDefaults
    let channel = FakeUpdateNotificationChannel()
    var controller: AppUpdateNotificationController!
    init(initial: String? = nil) {
        defaults = UserDefaults(suiteName: suite)!
        controller = AppUpdateNotificationController(defaults: defaults, channel: channel)
        controller.update(availableVersion: initial, currentVersion: "0.1.35")
    }
    deinit { defaults.removePersistentDomain(forName: suite) }
    func update(_ version: String? = "v0.1.36", origins: Set<AppUpdateCheckOrigin> = [.automatic],
                current: String = "0.1.35", skipped: String? = nil) {
        controller.update(availableVersion: version, currentVersion: current, skippedVersion: skipped, origins: origins)
    }
}

@main
enum AppUpdateNotificationTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label)
        checks += 1
    }

    static func backgroundAndPermissions() {
        let h = UpdateNotificationHarness()
        check(h.controller.enabled, "Update notifications default on")
        check(h.channel.authorizationRequests == 0 && h.channel.permissionReads == 0 && h.channel.cleanupPlans.isEmpty,
              "Construction and empty baseline do not touch notification channel")
        for _ in 0..<5 { h.update(nil, origins: []) }
        check(h.channel.cleanupPlans.isEmpty, "Repeated empty state does not enumerate system notifications")
        h.channel.permission = .notRequested
        h.controller.refreshPermission()
        check(h.channel.permissionReads == 1 && h.channel.authorizationRequests == 0, "Startup reads existing permission without prompting")
        h.update()
        check(h.channel.payloads.isEmpty && h.channel.authorizationRequests == 0, "Automatic discovery cannot request permission")
        check(h.defaults.string(forKey: AppUpdateNotificationPreferences.consumedVersionKey) == "0.1.36",
              "Unavailable permission consumes version before any delivery")
        h.channel.permission = .allowed
        h.controller.setEnabled(true, userInitiated: true)
        check(h.channel.authorizationRequests == 1 && h.controller.permission == .allowed,
              "Explicit settings action requests permission even when default preference is already on")
        h.update()
        check(h.channel.payloads.isEmpty, "Granting permission does not backfill old version")
        h.update("v0.1.37")
        check(h.channel.payloads.count == 1 && h.channel.payloads[0].version == "v0.1.37", "Next new version notifies using granted permission")
        let content = AppUpdateSystemNotificationChannel.content(for: h.channel.payloads[0])
        check(content.sound == nil && content.userInfo["appUpdateVersion"] as? String == "v0.1.37",
              "Update notification is always silent and carries only version click metadata")
        h.update("v0.1.37")
        h.update("0.1.37.0")
        check(h.channel.payloads.count == 1, "Repeated and equivalent version spellings notify once")
        h.update("v0.1.36")
        check(h.channel.payloads.count == 1, "Older release cannot produce a delayed notification")

        let denied = UpdateNotificationHarness()
        denied.channel.permission = .denied
        denied.update()
        check(denied.controller.permission == .denied && denied.channel.payloads.isEmpty,
              "Denied system permission is exposed for persistent UI fallback")
        check(denied.channel.authorizationRequests == 0, "Denied background discovery never prompts")
    }

    static func manualAndBaselines() {
        let h = UpdateNotificationHarness()
        h.update(origins: [.manual, .automatic])
        check(h.channel.payloads.isEmpty && h.channel.permissionReads == 0, "Manual coalesced check wins and emits no notification")
        h.update()
        check(h.channel.payloads.isEmpty, "Manual result is already presented for this version")
        h.update("v0.1.37")
        check(h.channel.payloads.count == 1, "A later automatic version remains eligible")
        h.update("v0.1.37", origins: [.manual])
        check(h.channel.removed.last == ["app-update:0.1.37"] && h.channel.cleanupPlans.last?.keeping == nil,
              "Manual presentation clears existing system notification")
        var opened = 0
        h.controller.onOpenRelease = { _ in opened += 1 }
        h.channel.onOpen?("v0.1.37")
        check(opened == 0, "An already manually presented notification cannot reopen the modal")

        let cached = UpdateNotificationHarness(initial: "v0.1.36")
        cached.update()
        check(cached.channel.payloads.isEmpty && cached.channel.permissionReads == 0,
              "Cached startup availability is a silent consumed baseline")
        cached.update("v0.1.37", origins: [])
        cached.update("v0.1.37")
        check(cached.channel.payloads.count == 1, "Routine originless state sync cannot consume a new automatic result")

        let inFlight = UpdateNotificationHarness()
        inFlight.channel.delayedPermission = true
        inFlight.update()
        inFlight.update(origins: [])
        inFlight.channel.pendingPermissions[0](.allowed)
        check(inFlight.channel.payloads.count == 1, "Ordinary same-version refresh cannot cancel pending automatic delivery")
    }

    static func preferencesAndPersistence() {
        let h = UpdateNotificationHarness()
        h.controller.setEnabled(false)
        check(!h.controller.enabled && h.channel.authorizationRequests == 0, "Disabling is an independent persistent preference")
        h.update()
        check(h.channel.payloads.isEmpty && h.channel.permissionReads == 0, "Disabled notifications do not probe permission or deliver")
        h.controller.setEnabled(true)
        h.update()
        check(h.channel.payloads.isEmpty && h.channel.authorizationRequests == 0, "Programmatic enabling never prompts or replays")
        h.update("v0.1.37")
        check(h.channel.payloads.count == 1, "Enabled preference applies to future discovered versions")
        h.controller = AppUpdateNotificationController(defaults: h.defaults, channel: h.channel)
        h.update("v0.1.37")
        check(h.channel.payloads.count == 1, "Per-version suppression survives controller restart")
        h.update("v0.1.36")
        check(h.channel.payloads.count == 1, "Persisted high-water mark suppresses older versions")
        check(h.defaults.object(forKey: "appUpdate.automaticChecksEnabled") == nil,
              "Notification preference never modifies automatic check preference")
        h.controller.setEnabled(false)
        check(h.channel.removed.last == ["app-update:0.1.36"] && h.channel.cleanupPlans.last?.keeping == nil,
              "Turning off removes both current and older module notifications")
        h.controller = AppUpdateNotificationController(defaults: h.defaults, channel: h.channel)
        check(!h.controller.enabled, "Disabled choice persists across restart")
    }

    static func clearingAndClicks() {
        let h = UpdateNotificationHarness()
        h.update()
        var opened: [String] = []
        h.controller.onOpenRelease = { opened.append($0) }
        h.channel.onOpen?("v0.1.35")
        check(opened.isEmpty, "Old notification click cannot open an obsolete version")
        h.channel.onOpen?("0.1.36")
        check(opened == ["v0.1.36"], "Click opens current release using source tag")
        check(h.channel.removed.last == ["app-update:0.1.36"], "Opening removes that version's notification")
        h.channel.onOpen?("v0.1.36")
        check(opened.count == 1, "Repeated click does not reopen release presentation")
        h.update("v0.1.37")
        check(h.channel.cleanupPlans.last?.keeping == "app-update:0.1.37", "New version cleanup retains only its own notification")
        h.update("v0.1.37", skipped: "0.1.37")
        h.channel.onOpen?("v0.1.37")
        check(opened.count == 1 && h.channel.cleanupPlans.last?.keeping == nil, "Skipping clears module notifications and invalidates clicks")
        h.update("v0.1.37")
        check(h.channel.payloads.count == 2, "Removing skip later does not replay old notification")
        h.update("v0.1.38")
        h.update(nil, current: "0.1.38")
        let cleanups = h.channel.cleanupPlans.count
        h.update(nil, current: "0.1.38")
        check(h.channel.cleanupPlans.count == cleanups, "Upgrade cleanup is idempotent")
        h.channel.onOpen?("v0.1.38")
        check(opened.count == 1, "Installed version cannot be opened from stale notification")
        check(h.channel.cleanupPlans.allSatisfy { $0.prefix == AppUpdateNotificationController.identifierPrefix },
              "Cleanup targets only update notifications")

        let absent = UpdateNotificationHarness()
        absent.update()
        absent.update(nil)
        absent.channel.onOpen?("v0.1.36")
        check(absent.channel.cleanupPlans.last?.keeping == nil, "No available version clears update notifications")
        let invalid = UpdateNotificationHarness()
        invalid.update("unknown")
        invalid.update("v0.1.36", current: "unknown")
        check(invalid.channel.payloads.isEmpty, "Invalid release or installed version never notifies")
    }

    static func asynchronousRaces() {
        let h = UpdateNotificationHarness()
        h.channel.delayedPermission = true
        h.update()
        h.update("v0.1.37")
        h.channel.pendingPermissions[0](.allowed)
        check(h.channel.payloads.isEmpty, "Old permission callback cannot deliver superseded version")
        h.channel.pendingPermissions[1](.allowed)
        check(h.channel.payloads.count == 1 && h.channel.payloads[0].version == "v0.1.37", "Current permission callback delivers latest version")
        h.update("v0.1.36")
        var opened: String?
        h.controller.onOpenRelease = { opened = $0 }
        h.channel.onOpen?("v0.1.37")
        check(opened == nil && h.channel.removed.last == ["app-update:0.1.37"],
              "Parent rollback to older Latest clears previous notification and invalidates its click")
        check(h.channel.payloads.count == 1 && h.channel.permissionReads == 2,
              "Rollback keeps consumed high-water mark and does not notify older version")

        for order in [[0, 1], [1, 0]] {
            let settings = UpdateNotificationHarness()
            settings.channel.delayedPermission = true
            settings.update()
            settings.controller.refreshPermission()
            for index in order { settings.channel.pendingPermissions[index](.allowed) }
            check(settings.channel.payloads.count == 1 && settings.controller.permission == .allowed,
                  "Settings permission read preserves one automatic delivery for callback order \(order)")
        }
        let permissionRevoked = UpdateNotificationHarness()
        permissionRevoked.channel.delayedPermission = true
        permissionRevoked.update()
        permissionRevoked.controller.refreshPermission()
        permissionRevoked.channel.pendingPermissions[1](.denied)
        permissionRevoked.channel.pendingPermissions[0](.allowed)
        check(permissionRevoked.channel.payloads.isEmpty && permissionRevoked.controller.permission == .denied,
              "Newer denied permission is not overwritten by delayed automatic permission result")

        let manual = UpdateNotificationHarness()
        manual.channel.delayedPermission = true
        manual.update()
        manual.update(origins: [.manual])
        manual.channel.pendingPermissions[0](.allowed)
        check(manual.channel.payloads.isEmpty, "Manual presentation invalidates pending automatic delivery")
        let disabled = UpdateNotificationHarness()
        disabled.channel.delayedPermission = true
        disabled.update()
        disabled.controller.setEnabled(false)
        disabled.channel.pendingPermissions[0](.allowed)
        check(disabled.channel.payloads.isEmpty && disabled.controller.permission == .notRequested,
              "Disabling ignores outstanding permission callback")

        let add = UpdateNotificationHarness()
        add.channel.delayedAdd = true
        add.update()
        add.update("v0.1.37")
        add.channel.pendingAdds[0](nil)
        check(add.channel.removed.last == ["app-update:0.1.36"], "Late add cleanup removes only superseded version")
        add.controller.setEnabled(false)
        add.channel.pendingAdds[1](nil)
        check(add.channel.removed.last == ["app-update:0.1.37"], "Late add after disabling removes its exact notification")

        let failed = UpdateNotificationHarness()
        failed.channel.deliveryError = NSError(domain: "test", code: 1)
        failed.update()
        failed.update()
        check(failed.channel.payloads.count == 1, "Delivery failure never causes notification replay")
        let reentrant = UpdateNotificationHarness()
        reentrant.controller.onStateChange = { reentrant.controller.setEnabled(false) }
        reentrant.update()
        check(reentrant.channel.payloads.isEmpty, "Permission-state callback may disable before delivery without a stale add")

        let authorization = UpdateNotificationHarness()
        authorization.channel.delayedPermission = true
        authorization.controller.setEnabled(true, userInitiated: true)
        authorization.update()
        check(authorization.channel.permissionReads == 0, "Background result cannot race an active user permission request")
        authorization.controller.setEnabled(false)
        authorization.controller.setEnabled(true, userInitiated: true)
        authorization.channel.pendingAuthorizations[0](.allowed)
        check(authorization.channel.authorizationRequests == 1 && authorization.channel.permissionReads == 1,
              "Rapid off/on uses a fresh permission read after the outstanding request")
        authorization.channel.pendingPermissions[0](.allowed)
        authorization.update()
        check(authorization.controller.permission == .allowed && authorization.channel.payloads.isEmpty,
              "Late permission grant updates settings without replaying consumed version")
    }

    static func routing() {
        let router = HUDSystemNotificationRouter()
        var calls: [String] = []
        router.register(prefix: "reset-news:") { _ in calls.append("news") }
        router.register(prefix: "quota-alert:") { _ in calls.append("quota") }
        router.register(prefix: "app-update:") { info in calls.append(info["appUpdateVersion"] as? String ?? "missing") }
        router.open(identifier: "app-update:0.1.36", actionIdentifier: UNNotificationDefaultActionIdentifier,
                    userInfo: ["appUpdateVersion": "v0.1.36"])
        router.open(identifier: "reset-news:one", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: [:])
        router.open(identifier: "quota-alert:one", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: [:])
        check(calls == ["v0.1.36", "news", "quota"], "All three channels retain separate click routes")
        router.open(identifier: "app-update:0.1.36", actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: [:])
        check(calls.count == 3, "Dismissing update notification never opens notes")
    }

    static func main() {
        backgroundAndPermissions()
        manualAndBaselines()
        preferencesAndPersistence()
        clearingAndClicks()
        asynchronousRaces()
        routing()
        print("PASS: \(checks) app update notification checks; isolated preferences and fake delivery only")
    }
}
