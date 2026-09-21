import AppKit
import SwiftUI

enum NotchPresentationState: String, CaseIterable { case compact, peek, expanded }
enum NotchDetailPage: Int, CaseIterable {
    case quota, activity, usage
    var title: String {
        switch self {
        case .quota: return DisplayLanguage.text("额度", "Quota")
        case .activity: return DisplayLanguage.text("活动", "Activity")
        case .usage: return DisplayLanguage.text("用量", "Usage")
        }
    }
}

final class NotchPresentationModel: ObservableObject {
    static let alwaysShowKey = "notch.alwaysShowQuota"
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
    @Published private(set) var lowPower = false
    @Published private(set) var content = NotchContentAdapter(.initial, tasksEnabled: true)
    private(set) var alwaysShowQuota = false
    private(set) var menuDepth = 0
    private(set) var pointerCaptured = false
    let scheduler: NotchDelayScheduler
    var animationsEnabled = true
    var restingState: NotchPresentationState { alwaysShowQuota ? .peek : .compact }
    var motionEnabled: Bool { animationsEnabled && !reduceMotion }
    var sweepActive: Bool { visible && !reduceMotion && (!lowPower || hovering || content.isRefreshing || content.hasError) }
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onHide: (() -> Void)?

    init(clock: NotchClock = NotchSystemClock(), alwaysShowQuota: Bool = false) {
        scheduler = NotchDelayScheduler(clock: clock)
        self.alwaysShowQuota = alwaysShowQuota
        state = restingState
    }
    func configure(_ layout: NotchLayout) {
        guard self.layout != layout else { return }
        reset(visible: visible)
        self.layout = layout
        size = layout.size(for: restingState)
    }
    func update(_ state: RateLimitDisplayState, tasksEnabled: Bool) {
        // No geometry or transition writes: data refresh cannot erase interaction intent.
        content = NotchContentAdapter(state, tasksEnabled: tasksEnabled)
    }
    func setEnvironment(reduceMotion: Bool, reduceTransparency: Bool, lowPower: Bool) {
        let motionChanged = self.reduceMotion != reduceMotion
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.lowPower = lowPower
        if motionChanged && reduceMotion { transition(to: state, animated: false, force: true) }
    }
    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        if visible { self.visible = true } else { reset(visible: false) }
    }
    func reset(visible: Bool) {
        scheduler.cancelAll()
        withoutMotion {
            self.visible = visible
            hovering = false
            pointerCaptured = false
            menuDepth = 0
            state = restingState
            detailsVisible = false
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
        } else if menuDepth == 0 && !pointerCaptured { collapse() }
    }
    func click() {
        guard visible, state != .expanded else { return }
        transition(to: .expanded)
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
