import Foundation
import HookCore
import Darwin

@main enum HookInstallerTests {
    static func main() throws {
        precondition(CommandLine.arguments.count == 3)
        let original = URL(fileURLWithPath: CommandLine.arguments[1]), replacement = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = URL(fileURLWithPath: "/private/tmp/hud-installer-\(UUID().uuidString)")
        try HookPaths.ensurePrivateDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("App/Hooks/HookEmitter")
        try HookHelperInstaller.verify(original); try HookHelperInstaller.verify(replacement)
        let originalData = try Data(contentsOf: original)
        let first = try HookHelperInstaller.install(bundledHelper: original, destination: destination)
        precondition(first.previousDigest == nil)
        let second = try HookHelperInstaller.install(bundledHelper: replacement, destination: destination)
        precondition(second.previousDigest == first.installedDigest && second.installedDigest != first.installedDigest)
        let repeated = try HookHelperInstaller.install(bundledHelper: replacement, destination: destination)
        precondition(repeated.previousDigest == first.installedDigest, "Idempotent enable lost rollback")
        try HookHelperInstaller.rollback(destination: destination)
        let restored = try Data(contentsOf: destination)
        precondition(restored == originalData)
        var info = stat(); precondition(lstat(destination.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        try HookPaths.atomicWrite(Data("user edit".utf8), to: destination, mode: 0o700)
        do { try HookHelperInstaller.uninstall(destination: destination); preconditionFailure("Changed file was deleted") }
        catch { /* Expected ownership mismatch. */ }
        precondition(FileManager.default.fileExists(atPath: destination.path))
        try HookPaths.atomicWrite(originalData, to: destination, mode: 0o700)
        try HookHelperInstaller.uninstall(destination: destination)
        precondition(!FileManager.default.fileExists(atPath: destination.path))
        print("PASS: signed helper install/upgrade/idempotency/rollback/permissions/exact-owned uninstall in temporary directories")
    }
}
