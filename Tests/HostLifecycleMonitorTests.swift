import AppKit

@main
enum HostLifecycleMonitorTests {
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func main() {
        testReducerSeparatesCodexFromAggregateHost()
        testReducerSuppressesDuplicateChanges()
        testApplicationClassification()
        testMonitorCallbacksAndLifecycleAreDeterministic()
        print("PASS: \(checks) host lifecycle checks")
    }

    private static func testReducerSeparatesCodexFromAggregateHost() {
        var reducer = HostLifecycleStateReducer()
        reducer.reset(to: HostLifecycleSnapshot(hostIsRunning: true, codexIsRunning: false))

        check(
            reducer.transition(to: HostLifecycleSnapshot(hostIsRunning: true, codexIsRunning: true)) == [.codexStarted],
            "Starting Codex while ChatGPT is running only emits the Codex start"
        )
        check(
            reducer.transition(to: HostLifecycleSnapshot(hostIsRunning: true, codexIsRunning: false)) == [.codexStopped],
            "Stopping Codex while ChatGPT is running only emits the Codex stop"
        )
        check(
            reducer.transition(to: HostLifecycleSnapshot(hostIsRunning: false, codexIsRunning: false)) == [.hostStopped],
            "Stopping the final supported host preserves the aggregate host callback"
        )
        check(
            reducer.transition(to: HostLifecycleSnapshot(hostIsRunning: true, codexIsRunning: true)) == [.hostStarted, .codexStarted],
            "Starting Codex as the first host emits both aggregate and Codex starts"
        )
    }

    private static func testReducerSuppressesDuplicateChanges() {
        var reducer = HostLifecycleStateReducer()
        let running = HostLifecycleSnapshot(hostIsRunning: true, codexIsRunning: true)

        check(reducer.transition(to: running).isEmpty, "The first snapshot establishes a baseline")
        check(reducer.transition(to: running).isEmpty, "Repeated running snapshots do not emit callbacks")
    }

    private static func testApplicationClassification() {
        let codex = HostApplicationIdentity(
            bundleIdentifier: "com.openai.codex",
            bundlePath: nil,
            localizedName: nil
        )
        let chatGPT = HostApplicationIdentity(
            bundleIdentifier: "com.openai.chat",
            bundlePath: "/Applications/ChatGPT.app",
            localizedName: "ChatGPT"
        )
        let gpt = HostApplicationIdentity(
            bundleIdentifier: nil,
            bundlePath: "/Applications/GPT.app",
            localizedName: "GPT"
        )
        let unrelated = HostApplicationIdentity(
            bundleIdentifier: "com.example.editor",
            bundlePath: "/Applications/Editor.app",
            localizedName: "Editor"
        )

        check(HostLifecycleMonitor.isSupportedHost(codex), "Codex remains part of the aggregate host set")
        check(HostLifecycleMonitor.isCodexHost(codex), "Codex is identified independently")
        check(HostLifecycleMonitor.isSupportedHost(chatGPT), "ChatGPT remains a supported aggregate host")
        check(!HostLifecycleMonitor.isCodexHost(chatGPT), "ChatGPT does not count as Codex")
        check(HostLifecycleMonitor.isSupportedHost(gpt), "GPT remains a supported aggregate host")
        check(!HostLifecycleMonitor.isCodexHost(gpt), "GPT does not count as Codex")
        check(!HostLifecycleMonitor.isSupportedHost(unrelated), "Unrelated apps remain unsupported")
    }

    private static func testMonitorCallbacksAndLifecycleAreDeterministic() {
        var snapshot = HostLifecycleSnapshot(hostIsRunning: true, codexIsRunning: false)
        var poll: (() -> Void)?
        var timerCreations = 0
        var stateReads = 0
        var changes: [HostLifecycleChange] = []

        let monitor = HostLifecycleMonitor(
            notificationCenter: NotificationCenter(),
            runningStateProvider: {
                stateReads += 1
                return snapshot
            },
            pollTimerFactory: { action in
                timerCreations += 1
                poll = action
                return Timer(timeInterval: 60, repeats: true) { _ in action() }
            }
        )
        monitor.onHostStarted = { changes.append(.hostStarted) }
        monitor.onHostStopped = { changes.append(.hostStopped) }
        monitor.onCodexStarted = { changes.append(.codexStarted) }
        monitor.onCodexStopped = { changes.append(.codexStopped) }

        monitor.start()
        monitor.start()
        check(timerCreations == 1, "Repeated start calls create one polling timer")
        check(stateReads == 1, "Repeated start calls establish one baseline")

        snapshot = HostLifecycleSnapshot(hostIsRunning: true, codexIsRunning: true)
        poll?()
        poll?()
        check(changes == [.codexStarted], "Codex start is delivered once while ChatGPT stays running")
        check(monitor.hostIsRunningNow(), "Synchronous aggregate query uses the current snapshot")
        check(monitor.codexIsRunningNow(), "Synchronous Codex query uses the current snapshot")

        snapshot = HostLifecycleSnapshot(hostIsRunning: true, codexIsRunning: false)
        poll?()
        poll?()
        check(changes == [.codexStarted, .codexStopped], "Codex stop is delivered once while ChatGPT stays running")

        let readsBeforeStop = stateReads
        monitor.stop()
        monitor.stop()
        poll?()
        check(stateReads == readsBeforeStop, "A stale poll callback is inert after stop")

        monitor.start()
        check(timerCreations == 2, "The monitor can be started again after stopping")
        check(changes == [.codexStarted, .codexStopped], "Restart establishes a baseline without synthetic changes")
        monitor.stop()
    }
}
