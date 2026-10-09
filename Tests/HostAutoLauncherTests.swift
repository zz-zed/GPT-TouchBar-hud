import Foundation

private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

private final class FakeLaunchctl {
    var loaded: Set<String> = []
    var calls: [[String]] = []
    var bootoutFails = false
    var bootstrapFails = false
    var printFails = false

    func run(_ arguments: [String]) throws -> HostLaunchctlResult {
        calls.append(arguments)
        let target = arguments[1]
        switch arguments[0] {
        case "bootout":
            if bootoutFails { return HostLaunchctlResult(status: 5, output: "Input/output error") }
            loaded.remove(target)
            return HostLaunchctlResult(status: 0, output: "")
        case "print":
            if printFails { return HostLaunchctlResult(status: 5, output: "Permission denied") }
            return loaded.contains(target)
                ? HostLaunchctlResult(status: 0, output: "loaded")
                : HostLaunchctlResult(status: 113, output: "Could not find service")
        case "bootstrap":
            if bootstrapFails { return HostLaunchctlResult(status: 5, output: "Input/output error") }
            loaded.insert("\(target)/\(AppIdentity.launchAgentLabel)")
            return HostLaunchctlResult(status: 0, output: "")
        default:
            preconditionFailure("Unexpected command: \(arguments)")
        }
    }
}

private struct Fixture {
    let root: URL
    let defaults = MemoryDefaults()
    let launchctl = FakeLaunchctl()
    let appURL: URL
    let agentsURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hud-launcher-test-\(UUID().uuidString)")
        appURL = root.appendingPathComponent("GPT & Test.app")
        agentsURL = root.appendingPathComponent("LaunchAgents")
        let resources = appURL.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentsURL, withIntermediateDirectories: true)
        try "#!/bin/zsh\n".write(to: resources.appendingPathComponent("gpt-touchbar-hud-launcher.sh"), atomically: true, encoding: .utf8)
        let info = ["CFBundleIdentifier": AppIdentity.bundleIdentifier]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
    }

    var manager: HostAutoLaunchManager {
        HostAutoLaunchManager(
            preferences: HostAutoLaunchPreferences(defaults: defaults),
            appBundleURL: appURL,
            launchAgentsDirectory: agentsURL,
            userID: 12345,
            runLaunchctl: launchctl.run
        )
    }

    var currentPlist: URL { agentsURL.appendingPathComponent("\(AppIdentity.launchAgentLabel).plist") }
    var target: String { "gui/12345/\(AppIdentity.launchAgentLabel)" }
    var legacyTarget: String { "gui/12345/\(AppIdentity.legacyLaunchAgentLabel)" }
    var legacyPlist: URL { agentsURL.appendingPathComponent("\(AppIdentity.legacyLaunchAgentLabel).plist") }

    func cleanup() throws { try FileManager.default.removeItem(at: root) }

    func writeLegacy(targetApp: URL) throws {
        let text = HostAutoLaunchManager.launchAgentPlist(
            scriptPath: targetApp.appendingPathComponent("Contents/Resources/gpt-touchbar-hud-launcher.sh").path,
            appPath: targetApp.path
        ).replacingOccurrences(of: AppIdentity.launchAgentLabel, with: AppIdentity.legacyLaunchAgentLabel)
        try text.write(to: legacyPlist, atomically: true, encoding: .utf8)
        launchctl.loaded.insert(legacyTarget)
    }
}

@main
enum HostAutoLauncherTests {
    private static var checks = 0

    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        checks += 1
    }

    private static func failed(_ result: Result<Void, Error>) -> Bool {
        if case .failure = result { return true }
        return false
    }

    static func main() throws {
        try testDefaultInstallAndPersistentOptOut()
        try testFailuresKeepPreferenceAndFiles()
        try testAbsentAndUnverifiableServices()
        try testRegistrationOwnership()
        try testLegacyScope()
        try testMissingExecutableDoesNotWait()
        try testCommandTimeout()
        try testSerializedBackgroundOperations()
        try testShellBehavior(sourceURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS: \(checks) host auto-launcher checks")
    }

    private static func testDefaultInstallAndPersistentOptOut() throws {
        let fixture = try Fixture()
        defer { try? fixture.cleanup() }
        check(fixture.manager.preferences.isEnabled, "Unconfigured users retain enabled startup")
        try fixture.manager.installOrUpdate().get()
        check(fixture.launchctl.loaded.contains(fixture.target), "Default startup registers the current agent")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.currentPlist), options: [], format: nil) as! [String: Any]
        let arguments = plist["ProgramArguments"] as! [String]
        check(arguments[2] == fixture.appURL.path, "Plist round trips paths containing ampersands and spaces")
        try fixture.manager.setEnabled(false).get()
        check(!fixture.manager.preferences.isEnabled, "Successful disable saves the opt-out")
        check(!fixture.launchctl.loaded.contains(fixture.target), "Disable removes the running registration")
        check(!FileManager.default.fileExists(atPath: fixture.currentPlist.path), "Disable removes only the managed plist")
        check(FileManager.default.fileExists(atPath: fixture.appURL.path), "Manual launch remains available")
        let before = fixture.launchctl.calls.count
        try fixture.manager.installOrUpdate().get()
        check(fixture.launchctl.calls.count == before, "A new manager on manual relaunch respects the saved opt-out")
        try fixture.manager.setEnabled(true).get()
        check(fixture.manager.preferences.isEnabled && fixture.launchctl.loaded.contains(fixture.target), "Explicit re-enable restores registration")
    }

    private static func testFailuresKeepPreferenceAndFiles() throws {
        let fixture = try Fixture()
        defer { try? fixture.cleanup() }
        try fixture.manager.installOrUpdate().get()
        fixture.launchctl.bootoutFails = true
        check(failed(fixture.manager.setEnabled(false)), "Failed bootout is reported")
        check(fixture.manager.preferences.isEnabled, "Failed disable does not claim the preference is off")
        check(FileManager.default.fileExists(atPath: fixture.currentPlist.path), "Failed disable preserves the plist")
        fixture.launchctl.bootoutFails = false
        try fixture.manager.setEnabled(false).get()
        fixture.launchctl.bootstrapFails = true
        check(failed(fixture.manager.setEnabled(true)), "Failed enable is reported")
        check(!fixture.manager.preferences.isEnabled, "Failed enable retains the saved opt-out")
    }

    private static func testAbsentAndUnverifiableServices() throws {
        let fixture = try Fixture()
        defer { try? fixture.cleanup() }
        fixture.launchctl.bootoutFails = true
        try fixture.manager.setEnabled(false).get()
        check(!fixture.manager.preferences.isEnabled, "Already absent service can be disabled despite bootout failure")
        fixture.defaults.set(true, forKey: HostAutoLaunchPreferences.enabledKey)
        fixture.launchctl.printFails = true
        check(failed(fixture.manager.setEnabled(false)), "Failure to inspect service is not confused with missing service")
        check(fixture.manager.preferences.isEnabled, "Unverified disable keeps its prior preference")
        check(!HostLaunchctlResult(status: 113, output: "Could not find domain").isMissingService, "Missing GUI domain is not proof of service absence")
    }

    private static func testRegistrationOwnership() throws {
        let fixture = try Fixture()
        defer { try? fixture.cleanup() }
        let unrelated = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>other.tool</string></dict></plist>"
        try unrelated.write(to: fixture.currentPlist, atomically: true, encoding: .utf8)
        check(failed(fixture.manager.setEnabled(false)), "An altered registration blocks deletion")
        check(failed(fixture.manager.installOrUpdate()), "An altered registration blocks overwrite")
        check(fixture.launchctl.calls.isEmpty, "Unowned registration triggers no launchctl mutation")
        let retained = try String(contentsOf: fixture.currentPlist, encoding: .utf8)
        check(retained == unrelated, "Unowned file remains intact")
        try FileManager.default.removeItem(at: fixture.currentPlist)
        let target = fixture.root.appendingPathComponent("keep-me.plist")
        try unrelated.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: fixture.currentPlist, withDestinationURL: target)
        check(failed(fixture.manager.setEnabled(false)), "Symlink registration is not followed or removed")
        check(FileManager.default.fileExists(atPath: target.path), "Symlink target remains intact")
    }

    private static func testLegacyScope() throws {
        let fixture = try Fixture()
        defer { try? fixture.cleanup() }
        let otherApp = fixture.root.appendingPathComponent("Old Tool.app")
        try fixture.writeLegacy(targetApp: otherApp)
        try fixture.manager.setEnabled(false).get()
        check(FileManager.default.fileExists(atPath: fixture.legacyPlist.path), "Independent legacy file is preserved")
        check(fixture.launchctl.loaded.contains(fixture.legacyTarget), "Independent legacy service is not unloaded")
        check(!fixture.launchctl.calls.contains { $0.contains(fixture.legacyTarget) }, "No launchctl call targets independent legacy service")
        try fixture.writeLegacy(targetApp: fixture.appURL)
        try fixture.manager.setEnabled(false).get()
        check(!FileManager.default.fileExists(atPath: fixture.legacyPlist.path), "Legacy label proven to launch current app is removed")
        check(!fixture.launchctl.loaded.contains(fixture.legacyTarget), "Owned legacy service is also disabled")
    }

    private static func testMissingExecutableDoesNotWait() throws {
        let fixture = try Fixture()
        defer { try? fixture.cleanup() }
        do {
            _ = try HostLaunchctlResult.run(arguments: [], executableURL: fixture.root.appendingPathComponent("no-such-launchctl"))
            preconditionFailure("Missing command must throw")
        } catch {
            check(true, "Missing executable throws without waiting for an unstarted Process")
        }
        let fakeCommand = fixture.root.appendingPathComponent("fake-launchctl")
        try "#!/bin/sh\necho fake-error >&2\nexit 5\n".write(to: fakeCommand, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCommand.path)
        let result = try HostLaunchctlResult.run(arguments: [], executableURL: fakeCommand)
        check(result.status == 5 && result.output.contains("fake-error"), "Command runner captures exit status and error output")
        try "#!/bin/sh\nprintf '%131072s' ''\n".write(to: fakeCommand, atomically: true, encoding: .utf8)
        let large = try HostLaunchctlResult.run(arguments: [], executableURL: fakeCommand)
        check(large.status == 0 && large.output.utf8.count == 64 * 1024,
              "Output beyond pipe capacity finishes and captured diagnostics remain bounded")
    }

    private static func testShellBehavior(sourceURL: URL) throws {
        let fixture = try Fixture()
        defer { try? fixture.cleanup() }
        let stub = fixture.root.appendingPathComponent("command-stub")
        let opened = fixture.root.appendingPathComponent("opened")
        let scriptURL = fixture.root.appendingPathComponent("launcher.zsh")
        let stubText = """
        #!/bin/zsh
        case "$1" in
          defaults) [[ "$HUD_TEST_PREFERENCE" == missing ]] && exit 1; print -r -- "$HUD_TEST_PREFERENCE" ;;
          pgrep)
            case "$3" in
              Codex|ChatGPT|GPT) [[ "$HUD_TEST_HOST" == running ]] ;;
              *) [[ "$HUD_TEST_APP" == running ]] ;;
            esac ;;
          open) print -r -- "$2" > "$HUD_TEST_OPENED" ;;
        esac
        """
        try stubText.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let isolated = source
            .replacingOccurrences(of: "$HOME/Library", with: "\(fixture.root.path)/Library")
            .replacingOccurrences(of: "/usr/bin/defaults", with: "\"\(stub.path)\" defaults")
            .replacingOccurrences(of: "/usr/bin/pgrep", with: "\"\(stub.path)\" pgrep")
            .replacingOccurrences(of: "/usr/bin/open", with: "\"\(stub.path)\" open")
        try isolated.write(to: scriptURL, atomically: true, encoding: .utf8)
        let lock = fixture.root.appendingPathComponent("Library/Application Support/GPT TouchBar HUD/manual-quit.lock")
        let legacyLock = fixture.root.appendingPathComponent("Library/Application Support/TouchBarCodexToken/manual-quit.lock")

        func run(preference: String, host: String = "running", app: String = "stopped") throws {
            if FileManager.default.fileExists(atPath: opened.path) { try FileManager.default.removeItem(at: opened) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path, fixture.appURL.path]
            var environment = ProcessInfo.processInfo.environment
            environment["HUD_TEST_PREFERENCE"] = preference
            environment["HUD_TEST_HOST"] = host
            environment["HUD_TEST_APP"] = app
            environment["HUD_TEST_OPENED"] = opened.path
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            check(process.terminationStatus == 0, "Isolated launcher exits normally")
        }

        try run(preference: "missing")
        check(FileManager.default.fileExists(atPath: opened.path), "Missing preference preserves default launch")
        try run(preference: "0")
        check(!FileManager.default.fileExists(atPath: opened.path), "Saved opt-out blocks a stale launcher")
        try run(preference: "1", app: "running")
        check(!FileManager.default.fileExists(atPath: opened.path), "Existing HUD process prevents duplicate launch")
        for url in [lock, legacyLock] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "quit".write(to: url, atomically: true, encoding: .utf8)
        }
        try run(preference: "1")
        check(!FileManager.default.fileExists(atPath: opened.path), "Manual quit lock suppresses launch within host session")
        try run(preference: "1", host: "stopped")
        check(!FileManager.default.fileExists(atPath: lock.path) && !FileManager.default.fileExists(atPath: legacyLock.path), "Final host exit clears current and legacy quit locks")
        try run(preference: "1")
        check(FileManager.default.fileExists(atPath: opened.path), "Host restart restores auto-launch after manual quit")
        try run(preference: "0", host: "stopped")
        try run(preference: "0")
        check(!FileManager.default.fileExists(atPath: opened.path), "Permanent opt-out remains after host restart")
    }

    private static func testCommandTimeout() throws {
        let fixture = try Fixture()
        defer { try? fixture.cleanup() }
        let command = fixture.root.appendingPathComponent("stalled-launchctl")
        let pidFile = fixture.root.appendingPathComponent("pid")
        try "#!/bin/sh\ntrap '' TERM\necho $$ > \"$1\"\nexec /bin/sleep 30\n"
            .write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        let started = Date()
        do {
            _ = try HostLaunchctlResult.run(arguments: [pidFile.path], executableURL: command, timeout: 0.5)
            preconditionFailure("Stalled command must time out")
        } catch HostAutoLaunchError.commandTimedOut {
            check(Date().timeIntervalSince(started) < 2, "An uncooperative command has a bounded wait")
        }
        let pid = Int32(try String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines))!
        check(kill(pid, 0) == -1 && errno == ESRCH, "Timeout reaps only the owned fixture, including a command ignoring TERM")
        var manager = fixture.manager
        manager.runLaunchctl = { _ in throw HostAutoLaunchError.commandTimedOut("bootout") }
        check(failed(manager.setEnabled(false)) && manager.preferences.isEnabled,
              "Timed-out registration never commits an unverified preference")
    }

    private static func testSerializedBackgroundOperations() throws {
        let fixture = try Fixture()
        defer { try? fixture.cleanup() }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let service = HostAutoLaunchService {
            var manager = fixture.manager
            manager.runLaunchctl = { arguments in
                precondition(!Thread.isMainThread, "System commands must run off main")
                if arguments[0] == "bootstrap" {
                    entered.signal()
                    precondition(release.wait(timeout: .now() + 2) == .success)
                }
                return try fixture.launchctl.run(arguments)
            }
            return manager
        }
        var completions: [Bool] = []
        service.setEnabled(true) { result in
            precondition(Thread.isMainThread)
            check(!failed(result), "Background enable succeeds")
            completions.append(true)
        }
        check(entered.wait(timeout: .now() + 2) == .success, "Slow registration started in the worker")
        service.setEnabled(false) { result in
            precondition(Thread.isMainThread)
            check(!failed(result), "Queued disable succeeds")
            completions.append(false)
        }
        var responsive = false
        DispatchQueue.main.async { responsive = true }
        let deadline = Date().addingTimeInterval(2)
        while !responsive && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        check(responsive && completions.isEmpty, "Main remains responsive while launchctl is blocked")
        release.signal()
        while completions.count < 2 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        check(completions == [true, false], "Rapid setting operations finish in submission order")
        check(!fixture.manager.preferences.isEnabled && !fixture.launchctl.loaded.contains(fixture.target),
              "The last verified operation owns the saved preference and final registration")
    }
}
