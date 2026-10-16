/// Lifecycle facts used by the application coordinator. This value performs no
/// service, notification, or presentation work; callers apply its transitions.
struct AppLifecycleState: Equatable {
    enum Runtime: Equatable {
        case stopped
        case active
        case stopping
    }

    enum PauseReason: Hashable {
        case screenLocked
        case systemSleeping
        case sessionInactive
    }

    struct Transition: Equatable {
        static let none = Transition()

        let didChange: Bool
        let runtimeStarted: Bool
        let runtimeStopped: Bool
        let hostStarted: Bool
        let hostStopped: Bool
        let codexStarted: Bool
        let codexStopped: Bool
        let becameSuspended: Bool
        let becameResumed: Bool

        var isEmpty: Bool { !didChange }

        fileprivate init(
            didChange: Bool = false,
            runtimeStarted: Bool = false,
            runtimeStopped: Bool = false,
            hostStarted: Bool = false,
            hostStopped: Bool = false,
            codexStarted: Bool = false,
            codexStopped: Bool = false,
            becameSuspended: Bool = false,
            becameResumed: Bool = false
        ) {
            self.didChange = didChange
            self.runtimeStarted = runtimeStarted
            self.runtimeStopped = runtimeStopped
            self.hostStarted = hostStarted
            self.hostStopped = hostStopped
            self.codexStarted = codexStarted
            self.codexStopped = codexStopped
            self.becameSuspended = becameSuspended
            self.becameResumed = becameResumed
        }
    }

    private(set) var runtime: Runtime = .stopped
    private(set) var hostRunning = false
    private(set) var codexRunning = false
    private(set) var pauseReasons: Set<PauseReason> = []

    var runtimeRunning: Bool { runtime == .active }
    var sessionSuspended: Bool { !pauseReasons.isEmpty }

    /// Aggregate supported-host availability controls quota work.
    var quotaWorkEnabled: Bool {
        runtimeRunning && hostRunning && !sessionSuspended
    }

    /// Reset news requires Codex specifically, independently of other hosts.
    var resetNewsWorkEnabled: Bool {
        runtimeRunning && codexRunning && !sessionSuspended
    }

    /// Explicit starts establish current host facts and emit initial host starts.
    /// A restart retains pause reasons: stopping does not prove the screen was
    /// unlocked, the system woke, or the user session became active.
    @discardableResult
    mutating func start(hostRunning: Bool, codexRunning: Bool) -> Transition {
        guard runtime == .stopped else { return .none }
        runtime = .active
        self.hostRunning = hostRunning
        self.codexRunning = codexRunning
        return Transition(didChange: true, runtimeStarted: true,
                          hostStarted: hostRunning, codexStarted: codexRunning)
    }

    /// Closes work gates before the caller starts shutting services down.
    /// Host facts are retained; runtimeStopped, rather than a synthetic host exit,
    /// identifies this transition. Late callbacks are inert from this point.
    @discardableResult
    mutating func stop() -> Transition {
        guard runtime == .active else { return .none }
        runtime = .stopping
        return Transition(didChange: true, runtimeStopped: true)
    }

    /// Marks completion of the caller's existing service shutdown sequence.
    @discardableResult
    mutating func finishStop() -> Transition {
        guard runtime == .stopping else { return .none }
        runtime = .stopped
        return Transition(didChange: true)
    }

    @discardableResult
    mutating func updateHostRunning(_ running: Bool) -> Transition {
        guard runtimeRunning, hostRunning != running else { return .none }
        hostRunning = running
        return Transition(didChange: true, hostStarted: running, hostStopped: !running)
    }

    @discardableResult
    mutating func updateCodexRunning(_ running: Bool) -> Transition {
        guard runtimeRunning, codexRunning != running else { return .none }
        codexRunning = running
        return Transition(didChange: true, codexStarted: running, codexStopped: !running)
    }

    @discardableResult
    mutating func setPause(_ reason: PauseReason, active: Bool) -> Transition {
        guard runtimeRunning, pauseReasons.contains(reason) != active else { return .none }
        let wasSuspended = sessionSuspended
        if active {
            pauseReasons.insert(reason)
        } else {
            pauseReasons.remove(reason)
        }
        return Transition(didChange: true,
                          becameSuspended: !wasSuspended && sessionSuspended,
                          becameResumed: wasSuspended && !sessionSuspended)
    }
}
