import Foundation
import Darwin

public enum HookFailure: Error { case unsafePath, permission, exists, io, malformed, changed, budget, unavailable }

/// Uses directory FDs and O_NOFOLLOW at every component. Never resolves untrusted symlinks.
public enum HookPaths {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gpt-touchbar-hud-hooks", isDirectory: true)
    }
    public static var stableHelper: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GPTTouchBarHUD/Hooks/HookEmitter")
    }
    static func components(_ url: URL) throws -> [String] {
        let path = url.path
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw HookFailure.unsafePath }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains(".."), !parts.contains(".") else { throw HookFailure.unsafePath }
        return parts
    }
    public static func openDirectory(_ url: URL, privateOnly: Bool = false) throws -> Int32 {
        let parts = try components(url)
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw HookFailure.io }
        for part in parts {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd); fd = next
            guard fd >= 0 else { throw HookFailure.unsafePath }
        }
        var info = stat()
        guard fstat(fd, &info) == 0,
              !privateOnly || (info.st_uid == getuid() && (info.st_mode & 0o777) == 0o700) else {
            close(fd); throw HookFailure.permission
        }
        return fd
    }
    public static func ensurePrivateDirectory(_ url: URL) throws {
        let parent = try openDirectory(url.deletingLastPathComponent())
        defer { close(parent) }
        if mkdirat(parent, url.lastPathComponent, 0o700) != 0 && errno != EEXIST { throw HookFailure.io }
        let fd = try openDirectory(url, privateOnly: true); close(fd)
    }
    public static func openRegular(_ url: URL, maximum: Int? = nil, privateOnly: Bool = false, allowRootOwner: Bool = false) throws -> Int32 {
        let parent = try openDirectory(url.deletingLastPathComponent())
        defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw HookFailure.unsafePath }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, (info.st_uid == getuid() || (allowRootOwner && info.st_uid == 0)),
              info.st_nlink == 1, maximum.map({ info.st_size <= $0 }) ?? true,
              !privateOnly || info.st_mode & 0o777 == 0o600 else { close(fd); throw HookFailure.permission }
        return fd
    }
    public static func read(_ url: URL, maximum: Int, privateOnly: Bool = false, allowRootOwner: Bool = false) throws -> Data {
        let fd = try openRegular(url, maximum: maximum, privateOnly: privateOnly, allowRootOwner: allowRootOwner)
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: maximum + 1)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count >= 0 && count <= maximum else { throw HookFailure.budget }
        return Data(bytes.prefix(count))
    }
    /// Caller supplies validated data. Atomic replacement stays in the same directory.
    public static func atomicWrite(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let parent = try openDirectory(url.deletingLastPathComponent())
        defer { close(parent) }
        var old = stat()
        if fstatat(parent, url.lastPathComponent, &old, AT_SYMLINK_NOFOLLOW) == 0 {
            guard old.st_mode & S_IFMT == S_IFREG, old.st_uid == getuid(), old.st_nlink == 1 else { throw HookFailure.unsafePath }
        } else if errno != ENOENT { throw HookFailure.io }
        let temp = ".hook-\(UUID().uuidString).tmp"
        let fd = openat(parent, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw HookFailure.io }
        defer { close(fd); unlinkat(parent, temp, 0) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                guard count > 0 else { throw HookFailure.io }; written += count
            }
        }
        guard fchmod(fd, mode) == 0, fsync(fd) == 0,
              renameat(parent, temp, parent, url.lastPathComponent) == 0 else { throw HookFailure.io }
    }
    static func validateSocket(_ url: URL) throws {
        let parent = try openDirectory(url.deletingLastPathComponent(), privateOnly: true)
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else { throw HookFailure.permission }
    }
}
