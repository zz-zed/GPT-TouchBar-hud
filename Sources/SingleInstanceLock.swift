import Foundation
import Darwin

/// Owns the process-wide launch lock. Keep it alive until the application exits.
final class SingleInstanceLock {
    private let descriptor: Int32

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(AppIdentity.appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("application-instance.lock")
    }

    /// Returns nil if another process owns the lock; other failures are reported.
    init?(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Child processes (app-server and the updater) must not retain our lock.
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Self.error(errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw Self.error(code)
        }
        descriptor = fd
    }

    deinit {
        // Closing releases the kernel lock, including after a crash. Do not unlink:
        // replacing the inode would let concurrent launches lock different files.
        close(descriptor)
    }

    private static func error(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
