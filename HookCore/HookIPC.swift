import Foundation
import Darwin

private func socketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard path.hasPrefix("/"), !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw HookFailure.unsafePath }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes + [0]) }
    return address
}
private func connectSocket(_ fd: Int32, _ address: inout sockaddr_un) -> Int32 {
    withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}
private func noSIGPIPE(_ fd: Int32) {
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
}
private func sameUser(_ fd: Int32) -> Bool {
    var uid: uid_t = 0, gid: gid_t = 0
    return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
}

public enum HookEmitter {
    public static func send(_ event: HookEvent, socketURL: URL, deadline: TimeInterval? = nil) -> Bool {
        let end = min(deadline ?? .infinity, ProcessInfo.processInfo.systemUptime + HookBudget.connectionSeconds)
        do {
            guard event.isValid else { return false }
            try HookPaths.validateSocket(socketURL)
            var address = try socketAddress(socketURL.path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }; defer { close(fd) }; noSIGPIPE(fd)
            let connected = connectSocket(fd, &address)
            guard connected == 0 || errno == EINPROGRESS else { return false }
            guard wait(fd, for: Int16(POLLOUT), until: end), sameUser(fd) else { return false }
            var error: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { return false }
            var data = try JSONEncoder().encode(event); data.append(10)
            guard data.count <= HookBudget.wireBytes else { return false }
            var sent = 0
            while sent < data.count {
                guard wait(fd, for: Int16(POLLOUT), until: end) else { return false }
                let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), data.count - sent) }
                guard count > 0 else { return false }; sent += count
            }
            var reply = Data()
            while reply.count < HookBudget.wireBytes {
                guard wait(fd, for: Int16(POLLIN), until: end) else { return false }
                var bytes = [UInt8](repeating: 0, count: 256)
                let count = Darwin.read(fd, &bytes, bytes.count)
                guard count > 0 else { return false }; reply.append(contentsOf: bytes.prefix(count))
                if let newline = reply.firstIndex(of: 10) {
                    let ack = try JSONDecoder().decode(HookAck.self, from: reply[..<newline])
                    return ack.version == 1 && UUID(uuidString: ack.generation) != nil
                }
            }
        } catch { return false }
        return false
    }
    static func wait(_ fd: Int32, for events: Int16, until deadline: TimeInterval) -> Bool {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(ceil(remaining * 1000)))
            if result < 0 && errno == EINTR { continue }
            return result > 0 && descriptor.revents & events != 0
        }
    }
    /// Only called by the separate executable. Its watchdog includes parsing and slow stdin.
    public static func run(socketURL: URL) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let deadline = ProcessInfo.processInfo.systemUptime + HookBudget.helperSeconds
        DispatchQueue.global().asyncAfter(deadline: .now() + HookBudget.helperSeconds) { neutralExit() }
        var input = Data()
        var valid = true
        while input.count < HookBudget.inputBytes && wait(STDIN_FILENO, for: Int16(POLLIN), until: deadline) {
            var bytes = [UInt8](repeating: 0, count: min(8192, HookBudget.inputBytes - input.count))
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 { valid = false; break }
            input.append(contentsOf: bytes.prefix(count))
            // Pipe EOF can be delivered as HUP without POLLIN on the next iteration.
            var probe = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            if poll(&probe, 1, 0) > 0 && probe.revents & Int16(POLLHUP) != 0 && probe.revents & Int16(POLLIN) == 0 { break }
        }
        if input.count == HookBudget.inputBytes {
            // Never read past the input budget, even to detect overflow. At the exact limit,
            // accept only a proven EOF; a still-open/ambiguous stream fails open neutrally.
            var info = stat()
            if fstat(STDIN_FILENO, &info) == 0 && info.st_mode & S_IFMT == S_IFREG {
                valid = valid && info.st_size <= HookBudget.inputBytes
            } else {
                var probe = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                valid = valid && poll(&probe, 1, 0) > 0 && probe.revents & Int16(POLLHUP) != 0 && probe.revents & Int16(POLLIN) == 0
            }
        }
        if valid, ProcessInfo.processInfo.systemUptime < deadline, let event = HookEvent.sanitize(input) {
            _ = send(event, socketURL: socketURL, deadline: deadline)
        }
        neutralExit()
    }
    private static func neutralExit() -> Never {
        _ = "{}\n".withCString { Darwin.write(STDOUT_FILENO, $0, 3) }
        _exit(0)
    }
}

/// All methods and callbacks run on the supplied serial queue. No per-connection threads.
public final class HookReceiver {
    private struct Client { let source: DispatchSourceRead; var data = Data(); let expiry: DispatchWorkItem }
    private let queue: DispatchQueue
    private let directory: URL
    private let onEvent: (HookEvent) -> Void
    private let onGap: (CoverageGap) -> Void
    private var listener: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var lockFD: Int32 = -1
    private var socketInode: ino_t?
    private var sequence: UInt64 = 0
    public let generation = UUID().uuidString
    public var socketURL: URL { directory.appendingPathComponent("events.sock") }
    public var connectionCount: Int { clients.count }

    public init(directory: URL, queue: DispatchQueue, onEvent: @escaping (HookEvent) -> Void,
                onGap: @escaping (CoverageGap) -> Void) {
        self.directory = directory; self.queue = queue; self.onEvent = onEvent; self.onGap = onGap
    }
    public func start() throws {
        try HookPaths.ensurePrivateDirectory(directory)
        let parent = try HookPaths.openDirectory(directory, privateOnly: true); defer { close(parent) }
        lockFD = openat(parent, "receiver.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        var lockInfo = stat()
        guard lockFD >= 0, fstat(lockFD, &lockInfo) == 0, lockInfo.st_uid == getuid(), lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_nlink == 1, lockInfo.st_mode & 0o777 == 0o600, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD); lockFD = -1 }; throw HookFailure.exists
        }
        do {
            var existing = stat()
            if fstatat(parent, "events.sock", &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                try HookPaths.validateSocket(socketURL)
                let probe = socket(AF_UNIX, SOCK_STREAM, 0); guard probe >= 0 else { throw HookFailure.io }
                noSIGPIPE(probe); var address = try socketAddress(socketURL.path)
                let connected = connectSocket(probe, &address); let failure = errno; close(probe)
                guard connected < 0 && failure == ECONNREFUSED else { throw HookFailure.exists }
                var current = stat()
                guard fstatat(parent, "events.sock", &current, AT_SYMLINK_NOFOLLOW) == 0,
                      current.st_ino == existing.st_ino, unlinkat(parent, "events.sock", 0) == 0 else { throw HookFailure.changed }
            }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw HookFailure.io }
            noSIGPIPE(fd); var address = try socketAddress(socketURL.path)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0 else { close(fd); throw HookFailure.io }
            guard fchmodat(parent, "events.sock", 0o600, AT_SYMLINK_NOFOLLOW) == 0, listen(fd, Int32(HookBudget.connections)) == 0 else {
                close(fd); throw HookFailure.io
            }
            var info = stat(); _ = fstatat(parent, "events.sock", &info, AT_SYMLINK_NOFOLLOW); socketInode = info.st_ino
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptConnections(fd) }
            source.setCancelHandler { close(fd) }
            listener = source; source.resume()
        } catch { close(lockFD); lockFD = -1; throw error }
    }
    public func stop() {
        for fd in Array(clients.keys) { closeClient(fd) }
        listener?.cancel(); listener = nil
        if let inode = socketInode, let parent = try? HookPaths.openDirectory(directory, privateOnly: true) {
            var info = stat()
            if fstatat(parent, "events.sock", &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_ino == inode { unlinkat(parent, "events.sock", 0) }
            close(parent)
        }
        socketInode = nil
        if lockFD >= 0 { close(lockFD); lockFD = -1 }
    }
    private func acceptConnections(_ fd: Int32) {
        // Bound one dispatch drain too; a flood must not monopolize the worker.
        for _ in 0..<32 {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }; noSIGPIPE(client)
            guard clients.count < HookBudget.connections, sameUser(client) else { close(client); onGap(.capacity); continue }
            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            let expiry = DispatchWorkItem { [weak self] in self?.onGap(.disconnected); self?.closeClient(client) }
            source.setEventHandler { [weak self] in self?.readClient(client) }
            source.setCancelHandler { close(client) }
            clients[client] = Client(source: source, expiry: expiry)
            source.resume(); queue.asyncAfter(deadline: .now() + HookBudget.connectionSeconds, execute: expiry)
        }
    }
    private func readClient(_ fd: Int32) {
        guard var client = clients[fd] else { return }
        var bytes = [UInt8](repeating: 0, count: HookBudget.wireBytes + 1)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0 else { closeClient(fd); return }
        client.data.append(contentsOf: bytes.prefix(count))
        guard client.data.count <= HookBudget.wireBytes else { onGap(.protocolError); closeClient(fd); return }
        clients[fd] = client
        guard let end = client.data.firstIndex(of: 10) else { return }
        guard end == client.data.count - 1, let event = try? JSONDecoder().decode(HookEvent.self, from: client.data[..<end]), event.isValid else {
            onGap(.protocolError); closeClient(fd); return
        }
        sequence &+= 1
        if var reply = try? JSONEncoder().encode(HookAck(version: 1, generation: generation, sequence: sequence)) {
            reply.append(10)
            _ = reply.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        }
        closeClient(fd)
        onEvent(event) // ACK precedes disk reconciliation; failure never controls the host.
    }
    private func closeClient(_ fd: Int32) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        client.expiry.cancel(); client.source.cancel()
    }
}
