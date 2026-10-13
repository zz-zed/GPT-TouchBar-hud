import AppKit
import CoreFoundation

/// A bounded, one-shot shutdown reply that also runs inside AppKit's termination loop.
/// The main dispatch queue cannot reenter a block that is still calling terminate(_:).
final class MainRunLoopCompletion {
    private var completion: (() -> Void)?
    private var timeout: Timer?

    init(deadline: DispatchTime, completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        self.completion = completion
        let now = DispatchTime.now().uptimeNanoseconds
        let remaining = deadline.uptimeNanoseconds > now ? deadline.uptimeNanoseconds - now : 0
        // Retain the gate until its deadline even if a shutdown participant never responds.
        let timer = Timer(timeInterval: Double(remaining) / 1_000_000_000, repeats: false) { [self] _ in finish() }
        timeout = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
    }

    /// May be called by an I/O queue. Always defer the reply until terminateLater has returned.
    func complete() {
        Self.perform { [self] in finish() }
    }

    /// Deliver ordered I/O acknowledgements without depending on main-queue reentrancy.
    static func perform(_ block: @escaping () -> Void) {
        let runLoop = CFRunLoopGetMain()
        let modes = [RunLoop.Mode.common.rawValue, RunLoop.Mode.modalPanel.rawValue] as CFArray
        CFRunLoopPerformBlock(runLoop, modes, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func finish() {
        precondition(Thread.isMainThread)
        guard let completion else { return }
        self.completion = nil
        timeout?.invalidate()
        timeout = nil
        completion()
    }
}
