import AppKit
import SwiftUI

enum NotchPresentationState: String, CaseIterable { case compact, peek, expanded }
enum NotchDetailPage: Int, CaseIterable {
    case quota, activity, usage, messages
    var title: String {
        switch self {
        case .quota: return DisplayLanguage.text("额度", "Quota")
        case .activity: return DisplayLanguage.text("活动", "Activity")
        case .usage: return DisplayLanguage.text("用量", "Usage")
        case .messages: return DisplayLanguage.text("重置预告", "Reset forecasts")
        }
    }
}

final class NotchPresentationModel: ObservableObject {
    static let alwaysShowKey = "notch.alwaysShowQuota"
    static func savedAlwaysShowQuota(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: alwaysShowKey) != nil else { return true }
        return defaults.bool(forKey: alwaysShowKey)
    }
    @Published private(set) var state: NotchPresentationState = .compact
    @Published private(set) var size: CGSize = .zero
    @Published private(set) var layout: NotchLayout?
    @Published private(set) var detailsMounted = false
    @Published private(set) var detailsVisible = false
    @Published private(set) var pillsVisible = false
    @Published private(set) var page: NotchDetailPage = .quota
    @Published private(set) var hovering = false
    @Published private(set) var visible = false
    @Published private(set) var reduceMotion = false
    @Published private(set) var reduceTransparency = false
    @Published private(set) var increaseContrast = false
    @Published private(set) var material: HUDAppearance.Material = .classic
    @Published private(set) var lowPower = false
    var controlSurface: HUDAppearance.Surface {
        HUDAppearance.surface(for: material, reduceTransparency: reduceTransparency, increaseContrast: increaseContrast)
    }
    var usesGroupedControls: Bool { controlSurface != .classic }
    @Published private(set) var sweepFeedbackVisible = false
    @Published private(set) var content = NotchContentAdapter(.initial, tasksEnabled: true)
    @Published private(set) var resetNews = ResetNewsViewState()
    private(set) var resetNewsPageVisible = false
    var messagesVisible: Bool { visible && state == .expanded && detailsVisible && page == .messages }
    private(set) var alwaysShowQuota: Bool
    private(set) var menuDepth = 0
    private(set) var pointerCaptured = false
    let scheduler: NotchDelayScheduler
    private let feedbackScheduler: NotchDelayScheduler
    static let sweepFeedbackDuration: TimeInterval = 1.2
    var animationsEnabled = true
    var restingState: NotchPresentationState { alwaysShowQuota ? .peek : .compact }
    var motionEnabled: Bool { animationsEnabled && !reduceMotion }
    var sweepActive: Bool { visible && motionEnabled && !lowPower && !usesGroupedControls && !reduceTransparency && !increaseContrast && sweepFeedbackVisible }
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onHide: (() -> Void)?
    var onCheckMessages: (() -> Void)?
    var onMarkAllMessagesRead: (() -> Void)?
    var onMessageSettings: (() -> Void)?
    var onVisibleMessage: ((String) -> Void)?

    init(clock: NotchClock = NotchSystemClock(), alwaysShowQuota: Bool = true) {
        scheduler = NotchDelayScheduler(clock: clock)
        feedbackScheduler = NotchDelayScheduler(clock: clock)
        self.alwaysShowQuota = alwaysShowQuota
        state = restingState
        pillsVisible = alwaysShowQuota
    }
    func configure(_ layout: NotchLayout) {
        guard self.layout != layout else { return }
        reset(visible: visible)
        self.layout = layout
        size = layout.size(for: restingState)
    }
    func update(_ state: RateLimitDisplayState, tasksEnabled: Bool) {
        // No geometry or transition writes: data refresh cannot erase interaction intent.
        let next = NotchContentAdapter(state, tasksEnabled: tasksEnabled)
        let shouldSignal = next.isRefreshing != content.isRefreshing ||
            (next.hasError && next.state.errorMessage != content.state.errorMessage) ||
            (next.task.appearance == .completed && content.task.appearance != .completed)
        if !content.hasSamePresentation(as: next) { content = next }
        if shouldSignal { showSweepFeedback() }
    }
    func updateResetNews(_ state: ResetNewsViewState) {
        if resetNews != state { resetNews = state }
    }
    func resetNewsPageVisibilityChanged(_ visible: Bool) { resetNewsPageVisible = visible && messagesVisible }
    func resetNewsCardVisible(_ id: String) {
        guard messagesVisible, resetNewsPageVisible, resetNews.items.contains(where: { $0.id == id }),
              !resetNews.readIDs.contains(id) else { return }
        onVisibleMessage?(id)
    }
    func setMaterial(_ material: HUDAppearance.Material) {
        guard self.material != material else { return }
        self.material = material
        if usesGroupedControls { stopSweepFeedback() }
    }
    func setEnvironment(reduceMotion: Bool, reduceTransparency: Bool, lowPower: Bool, increaseContrast: Bool = false) {
        let motionChanged = self.reduceMotion != reduceMotion
        if self.reduceMotion != reduceMotion { self.reduceMotion = reduceMotion }
        if self.reduceTransparency != reduceTransparency { self.reduceTransparency = reduceTransparency }
        if self.increaseContrast != increaseContrast { self.increaseContrast = increaseContrast }
        if self.lowPower != lowPower { self.lowPower = lowPower }
        if reduceMotion || lowPower || reduceTransparency || increaseContrast { stopSweepFeedback() }
        if motionChanged && reduceMotion { transition(to: state, animated: false, force: true) }
    }
    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        if visible { self.visible = true } else { reset(visible: false) }
    }
    func reset(visible: Bool) {
        scheduler.cancelAll()
        stopSweepFeedback()
        withoutMotion {
            self.visible = visible
            hovering = false
            pointerCaptured = false
            menuDepth = 0
            state = restingState
            detailsVisible = false
            resetNewsPageVisible = false
            detailsMounted = false
            pillsVisible = alwaysShowQuota
            if let layout { size = layout.size(for: restingState) }
        }
    }
    func setAlwaysShowQuota(_ enabled: Bool) {
        guard alwaysShowQuota != enabled else { return }
        alwaysShowQuota = enabled
        if !hovering && state != .expanded { transition(to: restingState) }
    }
    func hover(_ inside: Bool) {
        guard visible, hovering != inside else { return }
        hovering = inside
        if inside {
            if state == .compact { transition(to: .peek) }
            showSweepFeedback()
        } else if menuDepth == 0 && !pointerCaptured { collapse() }
    }
    func click() {
        guard visible, state != .expanded else { return }
        transition(to: .expanded)
        showSweepFeedback()
    }
    func openResetForecasts() {
        guard visible else { return }
        // Only this explicit shoulder action selects the forecast page. Neither
        // data updates nor the general expansion gesture changes the page.
        click()
        selectPage(.messages)
    }
    func collapse(animated: Bool = true) { transition(to: restingState, animated: animated) }
    func outsideClick() { if menuDepth == 0 { collapse() } }
    func setCaptured(_ captured: Bool) {
        pointerCaptured = captured
        if !captured && !hovering && menuDepth == 0 { collapse() }
    }
    func beginMenu() { menuDepth += 1 }
    func endMenu() {
        menuDepth = max(0, menuDepth - 1)
        if menuDepth == 0 && !hovering && !pointerCaptured { collapse() }
    }
    func selectPage(_ page: NotchDetailPage) {
        guard state == .expanded, self.page != page else { return }
        animate(NotchMotion.page) { self.page = page }
        showSweepFeedback()
    }
    private func showSweepFeedback() {
        guard visible, motionEnabled, !lowPower, !usesGroupedControls, !reduceTransparency, !increaseContrast else { return }
        feedbackScheduler.cancelAll()
        if !sweepFeedbackVisible { sweepFeedbackVisible = true }
        feedbackScheduler.after(Self.sweepFeedbackDuration) { [weak self] in
            self?.sweepFeedbackVisible = false
        }
    }
    private func stopSweepFeedback() {
        feedbackScheduler.cancelAll()
        if sweepFeedbackVisible { sweepFeedbackVisible = false }
    }
    private func animate(_ animation: Animation, _ body: () -> Void) {
        if motionEnabled { withAnimation(animation, body) } else { withoutMotion(body) }
    }
    private func withoutMotion(_ body: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }
    private func transition(to target: NotchPresentationState, animated: Bool = true, force: Bool = false) {
        guard let layout, target != state || force else { return }
        scheduler.cancelAll()
        let previous = state
        state = target
        guard animated && motionEnabled && visible else {
            withoutMotion {
                size = layout.size(for: target)
                detailsMounted = target == .expanded
                detailsVisible = detailsMounted
                pillsVisible = target == .peek
            }
            return
        }
        if target == .expanded {
            detailsMounted = true
            animate(NotchMotion.open) { size = layout.size(for: target) }
            scheduler.after(0.22) { [weak self] in self?.animate(NotchMotion.content) { self?.detailsVisible = true } }
            scheduler.after(0.25) { [weak self] in self?.animate(.easeOut(duration: 0.08)) { self?.pillsVisible = false } }
        } else {
            animate(.easeOut(duration: 0.10)) { detailsVisible = false }
            if target == .compact { animate(.easeOut(duration: 0.08)) { pillsVisible = false } }
            let closing = previous == .expanded || target == .compact
            if closing {
                scheduler.after(0.02) { [weak self] in
                    self?.animate(NotchMotion.close) { self?.size = layout.size(for: target) }
                }
            } else { animate(NotchMotion.open) { size = layout.size(for: target) } }
            if target == .peek {
                scheduler.after(closing ? 0.02 : 0.06) { [weak self] in
                    self?.animate(.easeOut(duration: 0.18)) { self?.pillsVisible = true }
                }
            }
            // Keep the outgoing content in the tree through the entire fade.
            scheduler.after(0.10) { [weak self] in self?.detailsMounted = false }
        }
    }
}
