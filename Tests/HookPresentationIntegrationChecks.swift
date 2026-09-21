import AppKit
import HookCore

/// Runs inside the serial notch/menu harness; fixed clocks exercise the real app controller.
enum HookPresentationIntegrationChecks {
    static func run(geometry: NotchHUDGeometry) throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) { NotchHUDTests.check(value(), message) }
        func event(_ id: String, _ date: Date) -> TaskCompletion {
            TaskCompletion(identity: TurnIdentity(task: TaskIdentity(session: "fixture"), turn: id), occurredAt: date)
        }
        let originalLanguage = DisplayLanguage.current
        defer { DisplayLanguage.current = originalLanguage }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        let bar = TouchBarRateLimitsView()
        host.contentView!.addSubview(bar)
        NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: host.contentView!.leadingAnchor), bar.topAnchor.constraint(equalTo: host.contentView!.topAnchor)])
        let notch = LegacyNotchHUDController()
        notch.animationsEnabled = false
        defer { notch.hide(); host.orderOut(nil) }
        var quota = RateLimitDisplayState.initial
        quota.fiveHour = LimitMeter(title: "5h", shortTitle: "5h", window: RateLimitWindow(usedPercent: 28, windowDurationMins: 300, resetsAt: nil))
        quota.weekly = LimitMeter(title: "7d", shortTitle: "7d", window: RateLimitWindow(usedPercent: 57, windowDurationMins: 10080, resetsAt: nil))
        let complete = TaskCoverage(gaps: [])
        let partial = TaskCoverage(gaps: [.initialCoverageUnknown])
        let inputs: [(String, TaskActivitySnapshot, String)] = [
            ("submitted", TaskActivitySnapshot(pendingVerificationCount: 1, submittedCount: 1), "…"),
            ("unknown", TaskActivitySnapshot(), "—"),
            ("zero", TaskActivitySnapshot(coverage: complete), "0"),
            ("full-count", TaskActivitySnapshot(confirmedRunningCount: 512, coverage: complete), "512"),
            ("partial", TaskActivitySnapshot(confirmedRunningCount: 512, coverage: partial, sourceHealth: [HookSourceHealth(state: .degraded)]), "512 ?")
        ]
        for language in DisplayLanguage.allCases {
            DisplayLanguage.current = language
            for (name, snapshot, expected) in inputs {
                // Deliberately conflicting legacy counters must never leak into any Hook surface.
                let summary = TaskStatusSummary(activity: snapshot, completionFeedbackVisible: false, runningCount: 999, recentlyCompletedCount: 9, unknownCount: 9)
                quota.taskStatus = summary
                if language == .english { check(HUDMetric.rows(for: quota).allSatisfy { $0.date == "Resets —" }, "missing reset time has one readable label") }
                let display = NotchTaskPresentation(summary)
                check(display.badge == expected && summary.badge == expected, "\(name): authority and full count agree")
                check(display.appearance == TaskStatusAppearance(summary), "\(name): notch/menu appearance agrees")
                check(display.title == summary.label, "\(name): label agrees")
                check(quota.displayedTaskStatus != nil, "\(name): explicit Hook state not filtered as legacy idle")
                check(NotchTaskPresentation(summary, enabled: false).badge.isEmpty, "\(name): display off always wins")
                if snapshot.hasUncertainty { check(display.note?.contains(language == .chinese ? "覆盖缺口" : "Coverage gaps") == true, "\(name): coverage explanation visible") }
                bar.update(with: quota)
                host.contentView!.layoutSubtreeIfNeeded()
                let badge = NotchHUDTests.descendants(bar).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "touchbar.task-badge" }!
                check(badge.stringValue == expected, "\(name): Touch Bar badge agrees")
                check(badge.frame.width >= badge.fittingSize.width, "\(name): Touch Bar count is not clipped")
                check(badge.convert(badge.bounds, to: bar).maxX < bar.bounds.maxX, "\(name): badge remains in bar")
                notch.update(quota)
                check(notch.show(in: geometry), "Hook fixture presents")
                check(!notch.isExpanded, "\(name): task update never expands")
                check(notch.view.summaryText.contains(expected) && notch.view.summaryText.contains("72%") && notch.view.summaryText.contains("43%"), "\(name): quotas survive Hook state")
                notch.toggleExpanded()
                check(notch.panel.frame.height >= notch.view.preferredHeight(width: notch.panel.frame.width), "\(name): detail scope and health fit")
                if name == "partial" || name == "submitted" {
                    try NotchHUDTests.snapshot(notch.view, "integrated-hooks-\(language.rawValue)-\(name)")
                    if name == "partial" { try NotchHUDTests.snapshot(bar, "integrated-touchbar-\(language.rawValue)-partial") }
                }
                notch.hide()
            }
        }
        DisplayLanguage.current = .chinese
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let feedback = TaskCompletionFeedbackController(now: { instant })
        var snapshot = TaskActivitySnapshot(confirmedRunningCount: 2, coverage: partial, updatedAt: instant)
        var source = TaskStatusSummary(activity: snapshot)
        feedback.receive(source, enabled: true)
        check(!feedback.isActive, "first delivery establishes baseline")
        instant += 1
        snapshot.updatedAt = instant
        snapshot.recentlyCompletedCount = 1
        snapshot.recentCompletions = [event("first", instant)]
        source.activity = snapshot
        feedback.receive(source, enabled: true)
        let originalDeadline = feedback.deadline
        check(feedback.isActive && originalDeadline == instant.addingTimeInterval(4), "new confirmed event gets exactly four seconds")
        let ongoing = feedback.applying(to: source)!
        check(NotchTaskPresentation(ongoing).badge == "2 ? ✓", "partial completion retains running and uncertainty")
        check(ongoing.badge == "2 ?" && TaskStatusAppearance(ongoing) == .running, "secondary feedback never declares overall success")
        quota.taskStatus = ongoing
        notch.update(quota); _ = notch.show(in: geometry)
        notch.toggleExpanded()
        try NotchHUDTests.snapshot(notch.view, "integrated-feedback-partial")
        notch.collapse(); notch.hide(); _ = notch.show(in: geometry)
        instant += 1
        feedback.receive(source, enabled: true)
        check(feedback.deadline == originalDeadline, "repeat snapshot and window operations do not extend feedback")
        quota.isRefreshing = true
        quota.taskStatus = feedback.applying(to: source)
        notch.update(quota)
        check(feedback.deadline == originalDeadline, "quota refresh does not restart feedback")
        notch.hide()
        instant += 3
        let expired = feedback.applying(to: source)!
        check(!feedback.isActive && NotchTaskPresentation(expired).badge == "2 ?", "hidden feedback expires without reopening")
        feedback.receive(source, enabled: true)
        check(feedback.deadline == nil, "expired repeat cannot re-arm timer")
        quota.taskStatus = feedback.applying(to: source)
        notch.update(quota); _ = notch.show(in: geometry)
        check(!notch.view.summaryText.contains("✓"), "reopen does not replay completion")
        notch.hide()
        instant += 1
        snapshot.confirmedRunningCount = 0
        snapshot.coverage = complete
        snapshot.recentlyCompletedCount = 2
        snapshot.recentCompletions.append(event("second", instant))
        snapshot.updatedAt = instant
        source.activity = snapshot
        feedback.receive(source, enabled: true)
        var shown = feedback.applying(to: source)!
        check(shown.badge == "✓" && shown.activityPresentation?.state == .completed && TaskStatusAppearance(shown) == .completed, "new certain completion agrees across badge/state/icon")
        instant += 4
        shown = feedback.applying(to: source)!
        check(shown.activity?.recentlyCompletedCount == 2, "feedback expiry preserves reducer facts")
        check(shown.badge == "0" && shown.activityPresentation?.state == .idle && TaskStatusAppearance(shown) == .idle, "thirty-second source retention does not restore primary completion")
        check(NotchTaskPresentation(shown).badge == "0" && !shown.label.contains("完成"), "notch title and badge agree after timeout")
        instant += 1
        snapshot.coverage = partial
        snapshot.updatedAt = instant
        snapshot.recentCompletions.append(event("uncertain", instant))
        source.activity = snapshot
        feedback.receive(source, enabled: true)
        check(!feedback.isActive && feedback.applying(to: source)?.badge == "—", "uncertain non-running snapshot cannot show whole-scope success")
        feedback.reset()
        feedback.receive(source, enabled: true)
        check(!feedback.isActive, "source/host restart takes a fresh baseline")
        snapshot.confirmedRunningCount = 1
        instant += 1
        snapshot.recentCompletions.append(event("third", instant))
        snapshot.updatedAt = instant
        source.activity = snapshot
        feedback.receive(source, enabled: true)
        check(feedback.isActive, "genuinely new event after baseline can show again")
        feedback.receive(source, enabled: false)
        check(!feedback.isActive && feedback.deadline == nil, "disable clears permission and scheduled expiry")
        feedback.receive(source, enabled: true)
        check(!feedback.isActive, "re-enable does not replay existing completions")
        let legacy = TaskStatusSummary(runningCount: 3)
        feedback.receive(legacy, enabled: true)
        let appliedLegacy = feedback.applying(to: legacy)!
        check(appliedLegacy.runningCount == legacy.runningCount && appliedLegacy.activity == nil
              && appliedLegacy.completionFeedbackVisible == false,
              "legacy source receives only the bounded feedback decision")
        let firstCompleted = TaskCompletionFeedbackController(now: { instant })
        snapshot.confirmedRunningCount = 0; snapshot.coverage = complete
        source.activity = snapshot
        firstCompleted.receive(source, enabled: true)
        check(firstCompleted.applying(to: source)?.badge == "0", "initial completed snapshot is history, not a new signal")

        // Continuation withdraws terminal identities; unrelated supported events retain their original deadline.
        let withdrawal = TaskCompletionFeedbackController(now: { instant })
        var continuing = TaskActivitySnapshot(confirmedRunningCount: 2, coverage: partial, updatedAt: instant)
        withdrawal.receive(TaskStatusSummary(activity: continuing), enabled: true)
        instant += 1
        let withdrawn = event("continued-turn", instant)
        let retained = event("other-completion", instant)
        continuing.recentCompletions = [withdrawn, retained]
        continuing.recentlyCompletedCount = 2
        continuing.updatedAt = instant
        withdrawal.receive(TaskStatusSummary(activity: continuing), enabled: true)
        let withdrawalDeadline = withdrawal.deadline
        check(withdrawal.activeCompletionIDs == Set([withdrawn.id, retained.id]), "controller tracks supported completion identities")
        instant += 0.2
        continuing.confirmedRunningCount = 3
        continuing.recentCompletions = [retained]
        continuing.recentlyCompletedCount = 1
        continuing.updatedAt = instant
        withdrawal.receive(TaskStatusSummary(activity: continuing), enabled: true)
        let remainingFeedback = withdrawal.applying(to: TaskStatusSummary(activity: continuing))!
        check(withdrawal.activeCompletionIDs == Set([retained.id]) && withdrawal.deadline == withdrawalDeadline, "continuation withdraws only invalid completion without extending others")
        check(NotchTaskPresentation(remainingFeedback).badge == "3 ? ✓", "other supported completion remains secondary to running work")
        instant += 0.2
        continuing.confirmedRunningCount = 4
        continuing.recentCompletions = []
        continuing.recentlyCompletedCount = 0
        withdrawal.receive(TaskStatusSummary(activity: continuing), enabled: true)
        let resumed = withdrawal.applying(to: TaskStatusSummary(activity: continuing))!
        check(!withdrawal.isActive && withdrawal.deadline == nil && withdrawal.activeCompletionIDs.isEmpty, "last continued completion immediately cancels permission and timer")
        check(NotchTaskPresentation(resumed).badge == "4 ?" && TaskStatusAppearance(resumed) == .running, "same-turn continuation removes checkmark while retaining running count")
        quota.taskStatus = resumed
        notch.update(quota); _ = notch.show(in: geometry)
        check(!notch.view.summaryText.contains("✓") && notch.view.summaryText.contains("4 ?"), "native notch immediately reflects completion withdrawal")
        notch.hide()
        continuing.recentCompletions = [withdrawn, retained]
        withdrawal.receive(TaskStatusSummary(activity: continuing), enabled: true)
        check(!withdrawal.isActive, "withdrawn history cannot replay as a new completion")

        // One actual main-run-loop expiry while no HUD is shown, not only fake-clock assertions.
        let real = TaskCompletionFeedbackController()
        var realSnapshot = TaskActivitySnapshot(confirmedRunningCount: 1, coverage: complete, updatedAt: Date())
        real.receive(TaskStatusSummary(activity: realSnapshot), enabled: true)
        realSnapshot.confirmedRunningCount = 0
        realSnapshot.recentlyCompletedCount = 1
        realSnapshot.recentCompletions = [event("real-timer", Date())]
        realSnapshot.updatedAt = Date()
        real.receive(TaskStatusSummary(activity: realSnapshot), enabled: true)
        var expirationRenders = 0
        real.onExpiration = { expirationRenders += 1 }
        check(real.isActive, "real controller armed")
        RunLoop.main.run(until: Date().addingTimeInterval(4.15))
        check(!real.isActive && real.deadline == nil && expirationRenders == 1, "single finite timer expires while hidden and requests one render")
        real.receive(TaskStatusSummary(activity: realSnapshot), enabled: true)
        check(!real.isActive && expirationRenders == 1, "post-expiry repeat does not restart")
    }
}
