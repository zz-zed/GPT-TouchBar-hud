import AppKit

/// Owns a bar independently of the HUD, key window and first responder.
final class PersistentTouchBarController: NSObject, NSTouchBarDelegate {
    private static let enabledKey = "persistentTouchBarEnabled"
    private static let limitsIdentifier = NSTouchBarItem.Identifier("com.jackchen.TouchBarCodexToken.persistent.limits")

    private let presenter: SystemTouchBarPresenting
    private let defaults: UserDefaults
    private let notifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var pendingPresentation: DispatchWorkItem?
    private var isRunning = false
    private var isSessionActive = true
    private var isScreenAwake = true
    private var hasPresented = false
    private var currentState = RateLimitDisplayState.initial
    private var limitsView: TouchBarRateLimitsView?
    private lazy var quotaBar: NSTouchBar = {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.limitsIdentifier, .flexibleSpace]
        return bar
    }()

    private(set) var isEnabled: Bool
    var isAvailable: Bool { presenter.isAvailable }
    var usesSystemPresentation: Bool { isEnabled && isAvailable }

    init(
        presenter: SystemTouchBarPresenting = SystemTouchBarPresenter(),
        defaults: UserDefaults = .standard,
        notifications: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.presenter = presenter
        self.defaults = defaults
        self.notifications = notifications
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        super.init()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observe(NSWorkspace.didActivateApplicationNotification) { $0.schedulePresentation() }
        observe(NSWorkspace.sessionDidResignActiveNotification) {
            $0.isSessionActive = false
            $0.dismiss()
        }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) {
            $0.isSessionActive = true
            $0.schedulePresentation()
        }
        observe(NSWorkspace.screensDidSleepNotification) {
            $0.isScreenAwake = false
            $0.dismiss()
        }
        observe(NSWorkspace.screensDidWakeNotification) {
            $0.isScreenAwake = true
            $0.schedulePresentation()
        }
        _ = presentNow()
    }

    func stop() {
        isRunning = false
        dismiss()
        observers.forEach { notifications.removeObserver($0) }
        observers.removeAll()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            _ = presentNow()
        } else {
            dismiss()
        }
    }

    /// Returns whether system presentation owns the request, even while suspended.
    /// The HUD must not steal keyboard focus just because the screen is asleep.
    @discardableResult
    func presentNow() -> Bool {
        guard isRunning, usesSystemPresentation else { return false }
        guard isSessionActive, isScreenAwake else { return true }
        pendingPresentation?.cancel()
        pendingPresentation = nil
        presenter.present(quotaBar)
        hasPresented = true
        return true
    }

    func update(with state: RateLimitDisplayState) {
        currentState = state
        limitsView?.update(with: state)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.limitsIdentifier else { return nil }
        let view = TouchBarRateLimitsView()
        view.update(with: currentState)
        limitsView = view
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = view
        return item
    }

    private func observe(_ name: Notification.Name, action: @escaping (PersistentTouchBarController) -> Void) {
        observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            action(self)
        })
    }

    private func schedulePresentation() {
        pendingPresentation?.cancel()
        guard isRunning, usesSystemPresentation, isSessionActive, isScreenAwake else { return }
        // Let the newly active app finish updating its responder chain first.
        let work = DispatchWorkItem { [weak self] in self?.presentNow() }
        pendingPresentation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func dismiss() {
        pendingPresentation?.cancel()
        pendingPresentation = nil
        if hasPresented {
            presenter.dismiss(quotaBar)
            hasPresented = false
        }
    }

    deinit {
        pendingPresentation?.cancel()
        observers.forEach { notifications.removeObserver($0) }
    }
}
