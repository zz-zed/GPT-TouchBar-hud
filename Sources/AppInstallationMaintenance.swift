import Foundation
import Darwin

/// A separate lock for filesystem maintenance; the application-instance lock
/// deliberately does not cover an installer that outlives the application.
final class AppInstallationMaintenanceLock {
    enum Purpose { case update, migration }
    enum LockError: Error { case unsafePath, busy, invalidMigrationMarker(String), system(Int32) }
    private let descriptor: Int32
    let handoffInput: FileHandle

    init(directory: URL, purpose: Purpose = .update) throws {
        let directory = directory.standardizedFileURL
        guard directory.resolvingSymlinksInPath().path == directory.path else { throw LockError.unsafePath }
        let path = directory.appendingPathComponent(".GPTTouchBarHUD-maintenance.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw LockError.system(errno) }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == getuid(), attributes.st_mode & 0o777 == 0o600,
              attributes.st_nlink == 1 else {
            close(fd); throw LockError.unsafePath
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; close(fd)
            if code == EWOULDBLOCK { throw LockError.busy }
            throw LockError.system(code)
        }
        if purpose == .update {
            do { try Self.rejectUnfinishedMigration(in: directory) }
            catch { close(fd); throw error }
        }
        descriptor = fd
        // Process duplicates this open file description to the installer's stdin.
        // The shell retains the lock after the app exits; ordinary execs do not
        // inherit our original CLOEXEC descriptor. No update command reads stdin.
        handoffInput = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }

    deinit { close(descriptor) } // Never unlink a lock inode while contenders exist.
    private static func rejectUnfinishedMigration(in directory: URL) throws {
        for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where entry.lastPathComponent.hasPrefix(".GPTTouchBarHUD-migration-") {
            let record = entry.appendingPathComponent("transaction.json")
            guard (try? FileManager.default.attributesOfItem(atPath: record.path)) != nil else { continue }
            let a = try FileManager.default.attributesOfItem(atPath: entry.path)
            guard a[.type] as? FileAttributeType == .typeDirectory else { throw LockError.invalidMigrationMarker("directoryType") }
            guard (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw LockError.invalidMigrationMarker("directoryOwner") }
            guard (a[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw LockError.invalidMigrationMarker("directoryMode") }
            let supplied = (entry.path as NSString).standardizingPath
            let resolved = (entry.resolvingSymlinksInPath().path as NSString).standardizingPath
            guard supplied == resolved else { throw LockError.invalidMigrationMarker("directoryLink") }
            let handle = open(record.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard handle >= 0 else { throw LockError.invalidMigrationMarker("open") }
            let file = FileHandle(fileDescriptor: handle, closeOnDealloc: true)
            var value = stat()
            guard fstat(handle, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
                  value.st_uid == getuid(), value.st_mode & 0o777 == 0o600, value.st_nlink == 1, value.st_size <= 65536 else {
                throw LockError.invalidMigrationMarker("attributes")
            }
            guard let json = try JSONSerialization.jsonObject(with: file.readDataToEndOfFile()) as? [String: Any],
                  let phase = json["phase"] as? String else { throw LockError.invalidMigrationMarker("json") }
            guard phase == "committed" else { throw LockError.busy }
        }
    }

}
