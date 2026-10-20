import Foundation
import Darwin

/// Isolated process fixture. It never starts NSApplication or any application service.
@main enum InstallationMaintenanceProbe {
    static func write(_ value: String, _ name: String, in directory: URL) throws {
        try Data(value.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    static func waitFor(_ name: String, in directory: URL) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) { return true }
            usleep(20_000)
        }
        return false
    }

    static func lockDescriptors(in directory: URL) -> [Int32] {
        var identity = stat()
        guard lstat(directory.appendingPathComponent(".GPTTouchBarHUD-maintenance.lock").path, &identity) == 0 else { return [] }
        return (0..<512).compactMap { raw in
            let fd = Int32(raw)
            var candidate = stat()
            guard fstat(fd, &candidate) == 0, candidate.st_dev == identity.st_dev,
                  candidate.st_ino == identity.st_ino else { return nil }
            return fd
        }
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { exit(64) }
        let mode = arguments[1]
        let directory = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        switch mode {
        case "--try":
            do {
                let lock = try AppInstallationMaintenanceLock(directory: directory)
                withExtendedLifetime(lock) { print("acquired") }
            } catch AppInstallationMaintenanceLock.LockError.busy { exit(3) }
        case "--owner":
            guard arguments.count == 5 else { exit(64) }
            let lock = try AppInstallationMaintenanceLock(directory: directory)
            let originalFlags = fcntl(lock.handoffInput.fileDescriptor, F_GETFD)
            guard originalFlags & FD_CLOEXEC != 0 else { exit(65) }
            try write(String(lock.handoffInput.fileDescriptor), "owner-lock-fd", in: directory)
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
            shell.arguments = [arguments[3], arguments[4], directory.path, URL(fileURLWithPath: arguments[0]).standardizedFileURL.path]
            shell.standardInput = lock.handoffInput
            shell.standardOutput = FileHandle.nullDevice
            shell.standardError = FileHandle.nullDevice
            try shell.run()
            try write(String(shell.processIdentifier), "shell-pid", in: directory)
            withExtendedLifetime(lock) {}
            // Deliberately exit without waiting, like the application at update handoff.
            exit(0)
        case "--descendant", "--launched":
            let prefix = mode == "--descendant" ? "descendant" : "launched"
            let descriptors = lockDescriptors(in: directory)
            try write(descriptors.map(String.init).joined(separator: ","), prefix + "-lock-fds", in: directory)
            try write(String(fcntl(STDIN_FILENO, F_GETFD)), prefix + "-stdin-flags", in: directory)
            try write(String(getpid()), prefix + "-pid", in: directory)
            try write("ready", prefix + "-started", in: directory)
            guard waitFor(prefix + "-release", in: directory) else { exit(66) }
            try write("finished", prefix + "-finished", in: directory)
        case "--inspect":
            try write(lockDescriptors(in: directory).map(String.init).joined(separator: ","), "plain-lock-fds", in: directory)
        case "--cloexec":
            let lock = try AppInstallationMaintenanceLock(directory: directory)
            guard fcntl(lock.handoffInput.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0 else { exit(65) }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
            child.arguments = ["--inspect", directory.path]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            child.waitUntilExit()
            guard child.terminationStatus == 0 else { exit(67) }
            withExtendedLifetime(lock) {}
        default: exit(64)
        }
    }
}
