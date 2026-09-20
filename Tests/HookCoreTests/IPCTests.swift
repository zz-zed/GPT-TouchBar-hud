import Foundation
import Darwin
import Testing
@testable import HookCore

struct IPCTests {
    @Test func localReceiverACKAndGenerationAndStaleSocketRecovery() throws {
        let f = try Fixture(); let queue = DispatchQueue(label: "test.ipc")
        var events: [HookEvent] = [], gaps: [CoverageGap] = []
        let receiver = HookReceiver(directory: f.ipc, queue: queue, onEvent: { events.append($0) }, onGap: { gaps.append($0) })
        try queue.sync { try receiver.start() }; defer { queue.sync { receiver.stop() } }
        #expect(HookEmitter.send(HookEvent(kind: .submitted, session: "s", turn: "t"), socketURL: receiver.socketURL))
        queue.sync { #expect(events.count == 1); #expect(gaps.isEmpty) }
        let second = HookReceiver(directory: f.ipc, queue: queue, onEvent: { _ in }, onGap: { _ in })
        #expect(throws: HookFailure.self) { try queue.sync { try second.start() } }
        var socketInfo = stat(); #expect(lstat(receiver.socketURL.path, &socketInfo) == 0)
        #expect(socketInfo.st_mode & 0o777 == 0o600)
        queue.sync { receiver.stop() }
        // Bind and close leaves a provably inactive socket; the next receiver safely reclaims it.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(fd) }
        try bind(fd, receiver.socketURL)
        chmod(receiver.socketURL.path, 0o600)
        shutdown(fd, SHUT_RDWR)
        // Bound-but-not-listening AF_UNIX is ECONNREFUSED, not an active listener.
        try queue.sync { try second.start() }; queue.sync { second.stop() }
        #expect(receiver.generation != second.generation)
    }
    @Test func oversizedWireAndTooManyConnectionsExposeGap() throws {
        let f = try Fixture(); let queue = DispatchQueue(label: "test.ipc.limits")
        var gaps: [CoverageGap] = []
        let receiver = HookReceiver(directory: f.ipc, queue: queue, onEvent: { _ in }, onGap: { gaps.append($0) })
        try queue.sync { try receiver.start() }; defer { queue.sync { receiver.stop() } }
        let fd = try connect(receiver.socketURL); defer { close(fd) }
        let data = Data(repeating: 120, count: 4097)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        try #require(waitUntil { queue.sync { gaps.contains(.protocolError) && receiver.connectionCount == 0 } })
        var clients: [Int32] = []
        defer { clients.forEach { close($0) } }
        // Fill accepted application slots, not the kernel's pending-connect backlog.
        // A burst of 18 connects can be refused by listen(16) before the receiver
        // gets scheduled, without exercising its capacity rejection at all.
        for expectedCount in 1...HookBudget.connections {
            clients.append(try connect(receiver.socketURL))
            try #require(waitUntil { queue.sync { receiver.connectionCount == expectedCount } })
        }
        queue.sync {
            #expect(receiver.connectionCount == HookBudget.connections)
            #expect(!gaps.contains(.disconnected))
        }
        clients.append(try connect(receiver.socketURL))
        try #require(waitUntil { queue.sync { gaps.contains(.capacity) } })
        queue.sync { #expect(receiver.connectionCount <= HookBudget.connections); #expect(gaps.contains(.capacity)) }
    }
    @Test func emitterDeadlineWithUnresponsivePeer() throws {
        let f = try Fixture(); let url = f.ipc.appendingPathComponent("events.sock")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(fd) }
        try bind(fd, url); chmod(url.path, 0o600); #expect(listen(fd, 2) == 0)
        let start = ProcessInfo.processInfo.systemUptime
        #expect(!HookEmitter.send(HookEvent(kind: .stop, session: "s", turn: "t"), socketURL: url))
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        #expect(elapsed < 0.3)
        #expect(elapsed >= 0.18)
    }
    @Test func absentReceiverFailsOpenAndUnsafeSocketRejected() throws {
        let f = try Fixture()
        #expect(!HookEmitter.send(HookEvent(kind: .stop, session: "s", turn: "t"), socketURL: f.ipc.appendingPathComponent("events.sock")))
        try HookPaths.atomicWrite(Data(), to: f.ipc.appendingPathComponent("events.sock"))
        #expect(!HookEmitter.send(HookEvent(kind: .stop, session: "s", turn: "t"), socketURL: f.ipc.appendingPathComponent("events.sock")))
    }
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        repeat {
            if condition() { return true }
            usleep(1_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return condition()
    }
    private struct SocketFailure: Error, CustomStringConvertible {
        let operation: String
        let code: Int32
        var description: String { "\(operation) failed: errno=\(code) (\(String(cString: strerror(code))))" }
    }
    private func bind(_ fd: Int32, _ url: URL) throws {
        var address = try address(url)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw SocketFailure(operation: "bind", code: errno) }
    }
    private func connect(_ url: URL) throws -> Int32 {
        var address = try address(url)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketFailure(operation: "socket", code: errno) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { let code = errno; close(fd); throw SocketFailure(operation: "connect", code: code) }; return fd
    }
    private func address(_ url: URL) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(url.path.utf8) + [0]; guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw HookFailure.unsafePath }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }; return address
    }
}
