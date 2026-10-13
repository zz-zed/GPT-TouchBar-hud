import AppKit
import Darwin

/// A real terminateLater loop entered from a main-queue block, as in update handoff.
/// Each scenario uses its own accessory-free process and never touches the installed HUD.
private final class TerminationFixture: NSObject, NSApplicationDelegate {
    let scenario: String
    private var began = DispatchTime.now()
    private var replies = 0
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hud-termination-" + UUID().uuidString)
    private lazy var repository = ResetNewsRepository(directory: directory)

    init(scenario: String) { self.scenario = scenario }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            print("FAIL: native termination watchdog expired")
            exit(1)
        }
        repository.load { [self] in
            repository.replace(repository.state, now: Date()) { [self] saved in
                check(saved, "fixture cache must persist before shutdown")
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        began = .now()
        let cancels = scenario == "late-completion" || scenario == "duplicate-completion"
        let delay: Int = scenario == "completion" ? 1_000 : (scenario == "duplicate-completion" ? 200 : 50)
        let reply = MainRunLoopCompletion(deadline: .now() + .milliseconds(delay)) { [self] in
            check(Thread.isMainThread, "reply must stay on the main thread")
            replies += 1
            check(replies == 1, "termination reply must be sent only once")
            sender.reply(toApplicationShouldTerminate: !cancels)
        }
        let group = DispatchGroup()
        group.enter()
        repository.flush { group.leave() }
        group.enter()
        group.notify(queue: .global(qos: .utility)) { reply.complete() }
        switch scenario {
        case "completion":
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { group.leave() }
        case "deadline":
            break // An unresponsive writer must not prevent the real app from exiting.
        case "late-completion":
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { group.leave() }
        case "duplicate-completion":
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) {
                group.leave()
                reply.complete()
                reply.complete()
            }
        default:
            check(false, "unknown scenario")
        }
        if cancels {
            let timer = Timer(timeInterval: 0.35, repeats: false) { [self] _ in
                check(replies == 1, "late callbacks and deadline must not send another reply")
                try? FileManager.default.removeItem(at: directory)
                print("PASS: native termination \(scenario)")
                exit(0)
            }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .modalPanel)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1_000_000_000
        check(replies == 1, "real termination must follow one reply")
        check(elapsed < (scenario == "completion" ? 0.8 : 2), "reply must honor the bounded deadline")
        if scenario == "deadline" { check(elapsed >= 0.04, "stalled writer must wait for its deadline") }
        check(FileManager.default.fileExists(atPath: repository.fileURL.path), "cache must survive the shutdown fence")
        try? FileManager.default.removeItem(at: directory)
        print("PASS: native termination \(scenario)")
    }

    private func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); exit(1) }
    }
}

@main
private enum AppTerminationTests {
    static func main() {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 2 else { exit(1) }
        let app = NSApplication.shared
        let delegate = TerminationFixture(scenario: CommandLine.arguments[1])
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
