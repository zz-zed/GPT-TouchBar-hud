import AppKit

final class AppDisplayCoordinator {
    private let contextProvider: () -> PresentationContext
    private var isStopped = false
    let menu: StatusMenuController
    let persistentTouchBar: PersistentTouchBarController
    private let mainTaskTrace = DiagnosticTaskDisplayObserver(DiagnosticRuntimeRecorder.shared, surface: .main, consumer: .main)
    private var taskPresentationRevision: UInt64 = 0
    private(set) var latestQuotaState = RateLimitDisplayState.initial
    private var latestTaskStatus: TaskStatusSummary?
    private var latestTaskDiagnosticSnapshot: DiagnosticTaskSnapshotReference?
    private var latestResetNewsState = ResetNewsViewState()
    private(set) var displaySnapshot = AppDisplaySnapshot(state: .initial, news: ResetNewsViewState())
    var taskStatusEnabled: Bool { UserDefaults.standard.object(forKey: "taskStatusEnabled") as? Bool ?? true }
    private var hudPreferences = HUDPresentationPreferences()
    private var hudDisplayMode: HUDDisplayMode {
        get { hudPreferences.mode }
        set { hudPreferences.mode = newValue; hudPreferences.save() }
    }
    private var hudRequestedVisible: Bool {
        get { hudPreferences.isVisible }
        set { hudPreferences.isVisible = newValue; hudPreferences.save() }
    }
    private var menuDisplayMode = MenuBarDisplayMode.load()
    private var displayTarget = DisplayTargetResolver()
    private var sessionSuspended = false
    private(set) var hudAppearance = HUDAppearance.load()
    var onRefreshQuota: (() -> Void)?
    var onCheckResetNews: (() -> Void)?
    var onMarkAllRead: (() -> Void)?
    var onVisibleMessage: ((String) -> Void)?
    var onOpenPreferences: (() -> Void)?
    var onOpenResetNewsPreferences: (() -> Void)?
    var onTaskStatusChanged: (() -> Void)?
    var onSnapshot: ((AppDisplaySnapshot) -> Void)?
    private lazy var completionFeedback: TaskCompletionFeedbackController = {
        let controller = TaskCompletionFeedbackController()
        controller.onExpiration = { [weak self] in
            guard let self else { return }
            self.taskPresentationRevision &+= 1
            self.renderDisplayState(reason: .completionFeedbackExpired)
        }
        return controller
    }()
    private lazy var resetNewsPopover: ResetNewsPopoverController = {
        let controller = ResetNewsPopoverController()
        controller.model.onCheck = { [weak self] in self?.onCheckResetNews?() }
        controller.model.onMarkAllRead = { [weak self] in self?.onMarkAllRead?() }
        controller.model.onSettings = { [weak self] in self?.openResetNewsPreferences() }
        controller.model.onVisibleItem = { [weak self] id in self?.onVisibleMessage?(id) }
        return controller
    }()
    private lazy var notchHUD: NotchHUDController = {
        let controller = NotchHUDController(diagnostics: DiagnosticRuntimeRecorder.shared)
        controller.onRefresh = { [weak self] in self?.onRefreshQuota?() }
        controller.onSettings = { [weak self] in self?.onOpenPreferences?() }
        controller.onHide = { [weak self] in self?.closeHUD() }
        controller.onVisibilityChanged = { [weak self] in self?.renderDisplayState() }
        controller.onCheckMessages = { [weak self] in self?.onCheckResetNews?() }
        controller.onMarkAllMessagesRead = { [weak self] in self?.onMarkAllRead?() }
        controller.onMessageSettings = { [weak self] in self?.openResetNewsPreferences() }
        controller.onVisibleMessage = { [weak self] id in self?.onVisibleMessage?(id) }
        return controller
    }()
    private lazy var hudController: CompactHUDViewController = CompactHUDViewController(initialAppearance: hudAppearance,
        onRefresh: { [weak self] in self?.onRefreshQuota?() },
        onClose: { [weak self] in self?.closeHUD() },
        onPresentTouchBar: { [weak self] in self?.persistentTouchBar.presentNow() ?? false },
        contextMenuProvider: { [weak self] in
            guard let self else { return NSMenu() }
            return self.menu.makeHUDContextMenu(anchor: self.hudController.messageAnchorView)
        }, diagnostics: DiagnosticRuntimeRecorder.shared)
    private lazy var hudWindow = CompactHUDPanel(contentViewController: hudController)

    init(menu: StatusMenuController, persistentTouchBar: PersistentTouchBarController,
         contextProvider: @escaping () -> PresentationContext = { PresentationContext() }) {
        self.contextProvider = contextProvider
        self.menu = menu; self.persistentTouchBar = persistentTouchBar
        menu.configurationProvider = { [weak self] in self?.menuConfiguration ?? StatusMenuConfiguration() }
        menu.onWillOpen = { [weak self] in self?.notchHUD.collapse(); self?.renderDisplayState() }
        menu.onRefreshQuota = { [weak self] in self?.onRefreshQuota?() }
        menu.onRefreshAll = { [weak self] in
            self?.onRefreshQuota?()
            if self?.latestResetNewsState.enabled == true { self?.onCheckResetNews?() }
        }
        menu.onForecast = { [weak self] in self?.openMenuForecast() }
        menu.onForecastRetry = { [weak self] in self?.onCheckResetNews?() }
        menu.onForecastFromContext = { [weak self] anchor in self?.openResetNews(relativeTo: anchor) }
        menu.onToggleHUD = { [weak self] in self?.setVisible(!(self?.hudRequestedVisible ?? false)) }
        menu.onHideHUD = { [weak self] in self?.closeHUD() }
        menu.onCollapse = { [weak self] in self?.notchHUD.collapse() }
        menu.onSelectDisplayMode = { [weak self] in self?.setDisplayMode($0) }
        menu.onSelectMenuMode = { [weak self] in self?.setMenuMode($0) }
        menu.onTogglePersistent = { [weak self] in
            guard let self else { return }
            self.setPersistentEnabled(!self.persistentTouchBar.isEnabled)
        }
        menu.onPreferences = { [weak self] in self?.onOpenPreferences?() }
        hudController.onOpenMessages = { [weak self] in
            guard let self else { return }; self.openResetNews(relativeTo: self.hudController.messageAnchorView)
        }
        hudController.onOpenTouchBarMessages = { [weak self] in self?.openResetNews() }
        persistentTouchBar.onOpenMessages = { [weak self] in self?.openResetNews() }
    }
    private var menuConfiguration: StatusMenuConfiguration {
        StatusMenuConfiguration(hudDisplayMode: hudDisplayMode, menuDisplayMode: menuDisplayMode,
            hudRequestedVisible: hudRequestedVisible, panelVisible: notchHUD.isVisible || hudWindow.isVisible,
            notchExpanded: notchHUD.isExpanded, persistentEnabled: persistentTouchBar.isEnabled,
            persistentAvailable: persistentTouchBar.isAvailable, usesSystemPresentation: persistentTouchBar.usesSystemPresentation)
    }
    func start() {
        isStopped = false
        hudPreferences.applyStartupVisibility(hasGeometry: !DisplayTargetResolver.candidates().isEmpty)
        recordDisplayPreference(); menu.configureStatusItem()
    }
    func receiveQuota(_ state: RateLimitDisplayState) { guard !isStopped else { return }; latestQuotaState = state; renderDisplayState(reason: .quotaRefresh) }
    func receiveTask(_ status: TaskStatusSummary?) {
        guard !isStopped else { return }
        latestTaskStatus = status
        if status != nil { latestTaskDiagnosticSnapshot = status?.diagnosticSnapshot }
        completionFeedback.receive(status, enabled: taskStatusEnabled)
        renderDisplayState(reason: .update)
    }
    func receiveDiagnosticSnapshot(_ reference: DiagnosticTaskSnapshotReference?) {
        guard !isStopped else { return }
        latestTaskStatus?.diagnosticSnapshot = reference
        latestTaskDiagnosticSnapshot = reference
    }
    func receiveNews(_ state: ResetNewsViewState) { guard !isStopped else { return }; latestResetNewsState = state; renderResetNews() }
    private func makeSnapshot(reason: DiagnosticTaskConsumptionReason) -> AppDisplaySnapshot {
        var state = latestQuotaState
        state.taskStatus = taskStatusEnabled ? completionFeedback.applying(to: latestTaskStatus) : nil
        state.taskTrace = DiagnosticTaskDisplayContext(reference: taskStatusEnabled ? latestTaskStatus?.diagnosticSnapshot : latestTaskDiagnosticSnapshot,
            tasksEnabled: taskStatusEnabled, presentationRevision: taskPresentationRevision, reason: reason)
        return AppDisplaySnapshot(state: state, news: latestResetNewsState, context: contextProvider())
    }
    func renderDisplayState(reason: DiagnosticTaskConsumptionReason = .layoutRefresh) {
        guard !isStopped else { return }
        displaySnapshot = makeSnapshot(reason: reason)
        let state = displaySnapshot.state
        mainTaskTrace.record(state, action: reason == .completionFeedbackExpired ? .presentationRevised : .received)
        menu.update(displaySnapshot)
        hudController.update(with: state, context: displaySnapshot.context)
        notchHUD.update(state, taskDisplayEnabled: taskStatusEnabled, metrics: displaySnapshot.metrics, context: displaySnapshot.context)
        persistentTouchBar.update(with: state, context: displaySnapshot.context)
        dispatchForecast()
        onSnapshot?(displaySnapshot)
    }
    func renderResetNews() {
        // News also publishes calendar/timezone changes. Keep quota dates on the
        // same captured context while each renderer suppresses equal output.
        renderDisplayState()
    }
    private func dispatchForecast() {
        let snapshot = displaySnapshot
        hudController.updateMessages(snapshot.forecast.indicator)
        persistentTouchBar.updateMessages(snapshot.forecast.indicator)
        notchHUD.updateResetNews(snapshot.news, forecast: snapshot.forecast, context: snapshot.context)
        resetNewsPopover.update(snapshot.news, forecast: snapshot.forecast, context: snapshot.context)
    }
    func hostDidStart() {
        if hudRequestedVisible && !sessionSuspended { presentSelectedHUD() } else { hudWindow.orderOut(nil) }
        menu.updateMenuState(); renderDisplayState()
    }
    func setSessionSuspended(_ suspended: Bool) {
        sessionSuspended = suspended
        if suspended { hidePanels() }
        else { environmentChanged(); return }
        renderDisplayState()
    }
    func environmentChanged() {
        guard !isStopped else { return }
        DiagnosticRuntimeRecorder.shared.record(.display(surface: .notch, action: .layout))
        notchHUD.environmentChanged()
        if hudRequestedVisible && !sessionSuspended { presentSelectedHUD() }
        renderDisplayState()
    }
    func frontApplicationChanged() { guard !isStopped else { return }; notchHUD.environmentChanged() }
    func stop() { isStopped = true; menu.stop(); resetCompletionFeedback(); hidePanels() }
    func hidePanels() { notchHUD.hide(); hudWindow.orderOut(nil); resetNewsPopover.close() }
    func resetCompletionFeedback() { completionFeedback.reset() }
    func setAlwaysShowQuota(_ enabled: Bool) { notchHUD.setAlwaysShowQuota(enabled) }
    func setTaskStatusEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "taskStatusEnabled")
        resetCompletionFeedback(); onTaskStatusChanged?(); renderDisplayState()
    }
    func setPersistentEnabled(_ enabled: Bool) {
        persistentTouchBar.setEnabled(enabled); menu.updateMenuState(); renderDisplayState()
    }
    func setVisible(_ visible: Bool) { if visible { showHUDWindow() } else { closeHUD() } }
    func setAppearance(_ appearance: HUDAppearance) { hudAppearance = appearance; applyHUDAppearance() }
    func openResetNewsPreferences() {
        resetNewsPopover.close(); notchHUD.collapse(animated: false); onOpenResetNewsPreferences?()
    }
    func openResetNews(relativeTo source: NSView? = nil, itemIDs: [String] = []) {
        guard !isStopped, !sessionSuspended, let anchor = source.flatMap({ $0.window?.isVisible == true && $0.window?.isOnActiveSpace == true && !$0.isHidden ? $0 : nil }) ?? menu.statusItem.button else { return }
        renderResetNews()
        resetNewsPopover.update(latestResetNewsState, forecast: displaySnapshot.forecast, context: displaySnapshot.context)
        resetNewsPopover.show(relativeTo: anchor, itemIDs: itemIDs)
    }

    func openMenuForecast() {
        guard !isStopped, displaySnapshot.forecast.hasForecastDetails, !sessionSuspended else { return }
        menu.statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self, let anchor = self.menu.statusItem.button, !self.isStopped, !self.sessionSuspended else { return }
            self.renderResetNews()
            self.resetNewsPopover.update(self.latestResetNewsState, forecast: self.displaySnapshot.forecast, context: self.displaySnapshot.context)
            self.resetNewsPopover.show(relativeTo: anchor, onBack: { [weak self] in
                guard let self, !self.isStopped, !self.sessionSuspended else { return }
                DispatchQueue.main.async { [weak self] in self?.menu.statusItem.button?.performClick(nil) }
            })
        }
    }

    func setDisplayMode(_ mode: HUDDisplayMode) {
        hudDisplayMode = mode
        recordDisplayPreference()
        notchHUD.environmentChanged()
        if hudRequestedVisible && !sessionSuspended { presentSelectedHUD() }
        renderDisplayState()
    }

    func recordDisplayPreference() {
        let mode: DiagnosticDisplayMode
        switch hudDisplayMode {
        case .automatic: mode = .automatic
        case .floating: mode = .floating
        case .notch: mode = .notch
        }
        DiagnosticRuntimeRecorder.shared.record(.display(surface: .notch, action: .mode,
                                                   mode: mode, reason: hudRequestedVisible ? nil : .hidden))
    }

    func setMenuMode(_ mode: MenuBarDisplayMode) {
        menuDisplayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: MenuBarDisplayMode.defaultsKey)
        renderDisplayState()
    }

    func showHUDWindow() {
        hudRequestedVisible = true
        recordDisplayPreference()
        if !sessionSuspended { presentSelectedHUD() }
        renderDisplayState()
    }

    func presentSelectedHUD() {
        guard !isStopped, !sessionSuspended else { return }
        let geometry = displayTarget.resolve(DisplayTargetResolver.candidates())
        if hudPreferences.usesNotch(hasGeometry: geometry != nil) && notchHUD.show(in: geometry) {
            hudWindow.orderOut(nil)
        } else {
            notchHUD.hide()
            hudController.prepareToShow()
            hudWindow.orderFrontPinned()
            DiagnosticRuntimeRecorder.shared.record(.display(surface: .floating, action: .request))
            hudWindow.recoverPositionIfOffscreen()
        }
        menu.updateMenuState()
    }

    func closeHUD() {
        hudRequestedVisible = false
        recordDisplayPreference()
        notchHUD.hide()
        hudWindow.orderOut(nil)
        menu.updateMenuState()
        renderDisplayState()
    }

    func applyHUDAppearance() {
        hudAppearance.save()
        hudController.updateAppearance(hudAppearance)
        notchHUD.updateAppearance(hudAppearance)
        menu.updateMenuState()
    }

}
