import Foundation
import Darwin

@main
enum SingleInstanceLockProbe {
    static func main() {
        do { try run() }
        catch { exit(EXIT_FAILURE) }
    }

    private static func run() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        // The parent releases every contender through stdin after all are spawned.
        _ = readLine()
        guard let lock = try SingleInstanceLock(url: url) else {
            print("duplicate")
            return
        }
        try withExtendedLifetime(lock) {
            print("owner")
            fflush(stdout)
            if readLine() == "spawn-child" {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/bin/sleep")
                child.arguments = ["30"]
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.nullDevice
                try child.run()
                print("child \(child.processIdentifier)")
                fflush(stdout)
                _ = readLine()
            }
        }
    }
}
