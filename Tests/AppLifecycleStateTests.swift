#if HUD_SHARED_CORE_TESTS
@testable import HUDCoreTestSupport
#endif
@main
enum AppLifecycleStateTests {
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func main() {
        testInitialStateAndInvalidShutdownCompletion()
        testHostAndCodexRemainIndependent()
        testOverlappingPauseReasonsResumeOnlyAfterTheLastReason()
        testRepeatedStartKeepsCurrentFacts()
        testStagedStopIgnoresLateCallbacks()
        testExplicitRestartPreservesUnresolvedPauseReasons()
        print("PASS: \(checks) app lifecycle state checks")
    }

    private static func testInitialStateAndInvalidShutdownCompletion() {
        var state = AppLifecycleState()
        check(state.runtime == .stopped, "The runtime begins stopped")
        check(!state.runtimeRunning && !state.sessionSuspended, "Initial state has no runtime or pause reasons")
        check(!state.hostRunning && !state.codexRunning, "Initial host facts are unavailable")
        check(!state.quotaAlertsAllowed && !state.resetNewsWorkEnabled, "Stopped runtime closes both work gates")
        check(state.stop() == .none, "Stopping before start has no effects")
        check(state.finishStop() == .none, "Finishing a nonexistent shutdown has no effects")

        state.start(hostRunning: true, codexRunning: true)
        check(state.finishStop() == .none, "Shutdown completion cannot stop an active runtime")
        check(state.runtimeRunning, "Invalid shutdown completion leaves the runtime active")
    }

    private static func testHostAndCodexRemainIndependent() {
        var state = AppLifecycleState()
        let initial = state.start(hostRunning: true, codexRunning: false)
        check(initial.runtimeStarted && initial.hostStarted, "Starting with a supported host requests its initial work once")
        check(!initial.codexStarted, "A non-Codex host does not synthesize a Codex start")
        check(state.quotaAlertsAllowed && !state.resetNewsWorkEnabled, "ChatGPT-only host availability enables quota alerts only")

        let codexStart = state.updateCodexRunning(true)
        check(codexStart.codexStarted && !codexStart.hostStarted, "Starting Codex does not repeat aggregate host work")
        check(state.quotaAlertsAllowed && state.resetNewsWorkEnabled, "Codex enables reset news alongside quota alerts")
        check(state.updateCodexRunning(true) == .none, "Duplicate Codex starts have no effects")

        let codexStop = state.updateCodexRunning(false)
        check(codexStop.codexStopped && !codexStop.hostStopped, "Stopping Codex leaves another supported host running")
        check(state.hostRunning && !state.codexRunning, "Aggregate and Codex facts remain separate")
        check(state.quotaAlertsAllowed && !state.resetNewsWorkEnabled, "Stopping Codex closes only reset news work")

        let hostStop = state.updateHostRunning(false)
        check(hostStop.hostStopped && !hostStop.codexStopped, "The final host exit is a separate transition")
        check(!state.quotaAlertsAllowed && !state.resetNewsWorkEnabled, "Without either host both gates close")
        check(state.updateHostRunning(false) == .none, "Duplicate host exits have no effects")

        state.updateCodexRunning(true)
        check(!state.hostRunning && state.codexRunning, "Independent callbacks can temporarily report Codex before the aggregate host")
        check(!state.quotaAlertsAllowed && state.resetNewsWorkEnabled, "Each gate follows its own host fact during callback reconciliation")
        let hostStart = state.updateHostRunning(true)
        check(hostStart.hostStarted && !hostStart.codexStarted, "Reconciling the aggregate host does not repeat Codex work")
        check(state.quotaAlertsAllowed && state.resetNewsWorkEnabled, "Both gates open after both host facts reconcile")
    }

    private static func testOverlappingPauseReasonsResumeOnlyAfterTheLastReason() {
        var state = AppLifecycleState()
        state.start(hostRunning: true, codexRunning: true)
        let locked = state.setPause(.screenLocked, active: true)
        check(locked.becameSuspended && !locked.becameResumed, "The first pause suspends service work")
        check(!state.quotaAlertsAllowed && !state.resetNewsWorkEnabled, "Suspension closes both work gates")
        check(state.setPause(.screenLocked, active: true) == .none, "Duplicate lock notifications do not repeat suspension")

        let sleeping = state.setPause(.systemSleeping, active: true)
        let inactive = state.setPause(.sessionInactive, active: true)
        check(sleeping.didChange && !sleeping.becameSuspended, "Sleep adds a reason without repeating suspension")
        check(inactive.didChange && !inactive.becameSuspended, "Inactive session adds a third independent reason")
        check(state.pauseReasons == [.screenLocked, .systemSleeping, .sessionInactive], "All overlapping pause reasons are retained")

        let wake = state.setPause(.systemSleeping, active: false)
        check(!wake.becameResumed && state.sessionSuspended, "Wake does not resume a locked and inactive session")
        check(state.pauseReasons == [.screenLocked, .sessionInactive], "Wake clears only the sleep reason")
        check(!state.quotaAlertsAllowed && !state.resetNewsWorkEnabled, "Work gates remain closed after a partial wake")

        let unlock = state.setPause(.screenLocked, active: false)
        check(!unlock.becameResumed && state.sessionSuspended, "Unlock does not resume an inactive session")
        check(state.pauseReasons == [.sessionInactive], "Unlock clears only the screen-lock reason")
        check(!state.quotaAlertsAllowed && !state.resetNewsWorkEnabled, "Work gates remain closed until the user session is active")

        let active = state.setPause(.sessionInactive, active: false)
        check(active.becameResumed && !active.becameSuspended, "Removing the final reason resumes service work once")
        check(!state.sessionSuspended && state.pauseReasons.isEmpty, "The last reason leaves the session unsuspended")
        check(state.quotaAlertsAllowed && state.resetNewsWorkEnabled, "Both work gates reopen only after all reasons clear")
        check(state.setPause(.sessionInactive, active: false) == .none, "Duplicate activation does not repeat resume")
        check(state.setPause(.screenLocked, active: false) == .none, "A late duplicate unlock does not repeat resume")
    }

    private static func testRepeatedStartKeepsCurrentFacts() {
        var state = AppLifecycleState()
        state.start(hostRunning: true, codexRunning: false)
        state.setPause(.systemSleeping, active: true)
        let before = state
        check(state.start(hostRunning: false, codexRunning: true) == .none, "Repeated start requests have no effects")
        check(state == before, "Repeated start cannot overwrite host facts or pause reasons")
    }

    private static func testStagedStopIgnoresLateCallbacks() {
        var state = AppLifecycleState()
        state.start(hostRunning: true, codexRunning: true)
        state.setPause(.screenLocked, active: true)
        let stop = state.stop()
        check(stop.runtimeStopped && stop.didChange, "The first stop requests runtime shutdown once")
        check(!stop.hostStopped && !stop.codexStopped, "Runtime shutdown does not synthesize host exits")
        check(!stop.becameResumed, "Stopping a paused runtime does not synthesize a resume")
        check(state.runtime == .stopping && !state.runtimeRunning, "Work becomes inactive before service shutdown finishes")
        check(!state.quotaAlertsAllowed && !state.resetNewsWorkEnabled, "Stopping immediately closes every work gate")
        check(state.stop() == .none, "Repeated stop while stopping has no effects")
        check(state.start(hostRunning: false, codexRunning: false) == .none, "A runtime cannot restart during shutdown")
        let stopping = state
        check(state.updateHostRunning(false) == .none, "Late host callbacks are ignored while stopping")
        check(state.updateCodexRunning(false) == .none, "Late Codex callbacks are ignored while stopping")
        check(state.setPause(.screenLocked, active: false) == .none, "Late unlock callbacks are ignored while stopping")
        check(state.setPause(.systemSleeping, active: true) == .none, "Late sleep callbacks are ignored while stopping")
        check(state == stopping, "Late callbacks cannot mutate a stopping runtime")

        let finished = state.finishStop()
        check(finished.didChange && !finished.runtimeStopped, "Completing shutdown records the phase without repeating shutdown effects")
        check(state.runtime == .stopped, "Shutdown completion reaches stopped")
        check(state.stop() == .none && state.finishStop() == .none, "Repeated shutdown calls are idempotent after completion")
        let stopped = state
        check(state.updateHostRunning(false) == .none, "Late host callbacks are ignored after stop")
        check(state.updateCodexRunning(false) == .none, "Late Codex callbacks are ignored after stop")
        check(state.setPause(.screenLocked, active: false) == .none, "Late unlock callbacks are ignored after stop")
        check(state.setPause(.sessionInactive, active: true) == .none, "Late activation changes are ignored after stop")
        check(state == stopped, "Late callbacks cannot reactivate or mutate a stopped runtime")
        check(!state.quotaAlertsAllowed && !state.resetNewsWorkEnabled, "Stopped runtime keeps both work gates closed")
    }

    private static func testExplicitRestartPreservesUnresolvedPauseReasons() {
        var state = AppLifecycleState()
        state.start(hostRunning: true, codexRunning: true)
        state.setPause(.screenLocked, active: true)
        state.stop()
        state.finishStop()

        let restarted = state.start(hostRunning: true, codexRunning: false)
        check(restarted.runtimeStarted && restarted.hostStarted && !restarted.codexStarted, "Explicit restart starts a new runtime with fresh host facts")
        check(state.runtimeRunning && state.hostRunning && !state.codexRunning, "Restart uses supplied host facts rather than stopped observations")
        check(state.pauseReasons == [.screenLocked] && state.sessionSuspended, "Restart preserves the unresolved lock reason")
        check(!restarted.becameResumed && !state.quotaAlertsAllowed && !state.resetNewsWorkEnabled, "Restart cannot resume work while still locked")
        let unlock = state.setPause(.screenLocked, active: false)
        check(unlock.becameResumed && state.quotaAlertsAllowed, "An explicit unlock after restart resumes quota alerts")
        check(!state.resetNewsWorkEnabled, "Resuming the session does not imply that Codex is running")
        check(state.setPause(.screenLocked, active: false) == .none, "Repeated unlock after restart remains idempotent")
    }
}
