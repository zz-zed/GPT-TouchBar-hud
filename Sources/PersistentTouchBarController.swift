import AppKit

/// Owns a bar independently of the HUD, key window and first responder.
final class PersistentTouchBarController: NSObject, NSTouchBarDelegate {
    private static let enabledKey = "persistentTouchBarEnabled"
    private static let limitsIdentifier = NSTouchBarItem.Identifier("io.github.zz-zed.GPTTouchBarHUD.persistent.limits")

    private let presenter: SystemTouchBarPresenting
    private let diagnostics: DiagnosticRecording
    private let taskTrace: DiagnosticTaskDisplayObserver
    private var lastPresentationObservation: DiagnosticDisplayReason?
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
    private var messageForecastCount: Int?
    private var messagesAvailable = false
    var onOpenMessages: (() -> Void)? { didSet { limitsView?.onOpenMessages = onOpenMessages } }
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
        presenter: SystemTouchBarPresenting? = nil,
        defaults: UserDefaults = .standard,
        notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        diagnostics: DiagnosticRecording = NoopDiagnosticRecorder()
    ) {
        self.presenter = presenter ?? SystemTouchBarPresenter(diagnostics: diagnostics)
        self.diagnostics = diagnostics
        taskTrace = DiagnosticTaskDisplayObserver(diagnostics, surface: .touchBar, consumer: .touchBarPersistent)
        self.defaults = defaults
        self.notifications = notifications
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        super.init()
        diagnostics.record(.display(surface: .touchBar, action: .capability,
                                    result: self.presenter.isAvailable ? .success : .incompatible,
                                    reason: self.presenter.isAvailable ? nil : .interfaceUnavailable))
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observe(NSWorkspace.didActivateApplicationNotification) { $0.schedulePresentation() }
        observe(NSWorkspace.sessionDidResignActiveNotification) {
            $0.isSessionActive = false
            $0.observePresentation(reason: .sessionInactive)
            $0.dismiss()
        }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) {
            $0.isSessionActive = true
            $0.schedulePresentation()
        }
        observe(NSWorkspace.screensDidSleepNotification) {
            $0.isScreenAwake = false
            $0.observePresentation(reason: .screenAsleep)
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
        observePresentation(reason: .notRunning)
        dismiss()
        observers.forEach { notifications.removeObserver($0) }
        observers.removeAll()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        diagnostics.record(.display(surface: .touchBar, action: .mode, mode: enabled ? .touchBar : .disabled))
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            _ = presentNow()
        } else {
            observePresentation(reason: .disabled)
            dismiss()
        }
    }

    /// Returns whether system presentation owns the request, even while suspended.
    /// The HUD must not steal keyboard focus just because the screen is asleep.
    @discardableResult
    func presentNow() -> Bool {
        guard isRunning, usesSystemPresentation else {
            observePresentation(reason: !isRunning ? .notRunning : (!isEnabled ? .disabled : .interfaceUnavailable))
            return false
        }
        guard isSessionActive, isScreenAwake else {
            observePresentation(reason: !isSessionActive ? .sessionInactive : .screenAsleep)
            return true
        }
        pendingPresentation?.cancel()
        pendingPresentation = nil
        observePresentation(reason: nil)
        presenter.present(quotaBar)
        hasPresented = true
        return true
    }

    func update(with state: RateLimitDisplayState) {
        currentState = state
        if limitsView == nil {
            taskTrace.record(state, action: .skipped,
                reason: !isEnabled ? .disabled : (!isAvailable ? .noInterface : (!isScreenAwake ? .sleeping : .notLoaded)))
        }
        if limitsView == nil { TaskPresentationTrace.record(state, surface: .touchBar, action: .notLoaded) }
        limitsView?.update(with: state)
    }
    func updateMessages(forecastCount: Int?, available: Bool) {
        messageForecastCount = forecastCount
        messagesAvailable = available
        limitsView?.updateMessages(forecastCount: forecastCount, available: available)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.limitsIdentifier else { return nil }
        let view = TouchBarRateLimitsView(diagnostics: diagnostics, consumer: .touchBarPersistent)
        view.update(with: currentState)
        view.onOpenMessages = onOpenMessages
        view.updateMessages(forecastCount: messageForecastCount, available: messagesAvailable)
        limitsView = view
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = view
        view.observeVisibility(of: item)
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

    private func observePresentation(reason: DiagnosticDisplayReason?) {
        // Application-activation requests repeat frequently; record only changed outcomes.
        guard reason != lastPresentationObservation || (!hasPresented && reason == nil) else { return }
        lastPresentationObservation = reason
        diagnostics.record(.display(surface: .touchBar, action: reason == nil ? .request : .skipped,
                                    result: reason == nil ? .success : .skipped, reason: reason))
    }

    private func dismiss() {
        pendingPresentation?.cancel()
        pendingPresentation = nil
        if hasPresented {
            diagnostics.record(.display(surface: .touchBar, action: .hide))
            presenter.dismiss(quotaBar)
            hasPresented = false
        }
    }

    deinit {
        pendingPresentation?.cancel()
        observers.forEach { notifications.removeObserver($0) }
    }
}
