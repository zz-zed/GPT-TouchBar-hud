import Foundation
import Security
import CryptoKit
import Darwin

public struct HookInstallationReceipt: Codable {
    public let installedDigest: String
    public let previousDigest: String?
}

/// Called only after a user accepts the concrete config plan. The build never installs this helper.
public enum HookHelperInstaller {
    public static let signingIdentifier = "com.gpt-touchbar-hud.hook-emitter"
    private static let maximumBytes = 32 * 1024 * 1024
    public static func verify(_ url: URL) throws {
        let fd = try HookPaths.openRegular(url, maximum: maximumBytes, allowRootOwner: true); close(fd)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), nil) == errSecSuccess else { throw HookFailure.permission }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let fields = info as? [String: Any], fields[kSecCodeInfoIdentifier as String] as? String == signingIdentifier else { throw HookFailure.permission }
    }
    public static func install(bundledHelper: URL, destination: URL = HookPaths.stableHelper) throws -> HookInstallationReceipt {
        try verify(bundledHelper)
        let bytes = try HookPaths.read(bundledHelper, maximum: maximumBytes, allowRootOwner: true)
        let directory = destination.deletingLastPathComponent()
        // The common Library/Application Support parent already exists; only create our two dirs.
        try HookPaths.ensurePrivateDirectory(directory.deletingLastPathComponent())
        try HookPaths.ensurePrivateDirectory(directory)
        let receiptURL = directory.appendingPathComponent("installation.json")
        var previousDigest: String?
        if FileManager.default.fileExists(atPath: destination.path) {
            try verify(destination)
            let old = try HookPaths.read(destination, maximum: maximumBytes)
            if digest(old) == digest(bytes),
               let saved = try? JSONDecoder().decode(HookInstallationReceipt.self, from: HookPaths.read(receiptURL, maximum: 4096, privateOnly: true)),
               saved.installedDigest == digest(bytes) {
                return saved // Idempotent enable must preserve the previous-version rollback receipt.
            }
            if digest(old) != digest(bytes) {
                try HookPaths.atomicWrite(old, to: directory.appendingPathComponent("HookEmitter.previous"), mode: 0o700)
                previousDigest = digest(old)
            }
        }
        try HookPaths.atomicWrite(bytes, to: destination, mode: 0o700)
        try verify(destination)
        guard try HookPaths.read(destination, maximum: maximumBytes) == bytes else { throw HookFailure.io }
        let receipt = HookInstallationReceipt(installedDigest: digest(bytes), previousDigest: previousDigest)
        try HookPaths.atomicWrite(JSONEncoder().encode(receipt), to: receiptURL)
        return receipt
    }
    public static func rollback(destination: URL = HookPaths.stableHelper) throws {
        let directory = destination.deletingLastPathComponent()
        let receipt = try JSONDecoder().decode(HookInstallationReceipt.self, from: HookPaths.read(directory.appendingPathComponent("installation.json"), maximum: 4096, privateOnly: true))
        guard digest(try HookPaths.read(destination, maximum: maximumBytes)) == receipt.installedDigest,
              let previous = receipt.previousDigest else { throw HookFailure.changed }
        let previousURL = directory.appendingPathComponent("HookEmitter.previous")
        try verify(previousURL)
        let data = try HookPaths.read(previousURL, maximum: maximumBytes)
        guard digest(data) == previous else { throw HookFailure.changed }
        try HookPaths.atomicWrite(data, to: destination, mode: 0o700)
        try verify(destination)
        try HookPaths.atomicWrite(JSONEncoder().encode(HookInstallationReceipt(installedDigest: previous, previousDigest: nil)), to: directory.appendingPathComponent("installation.json"))
    }
    /// Config cleanup is separate. Remove only an unchanged executable belonging to this receipt.
    public static func uninstall(destination: URL = HookPaths.stableHelper) throws {
        let directory = destination.deletingLastPathComponent()
        let receipt = try JSONDecoder().decode(HookInstallationReceipt.self, from: HookPaths.read(directory.appendingPathComponent("installation.json"), maximum: 4096, privateOnly: true))
        guard digest(try HookPaths.read(destination, maximum: maximumBytes)) == receipt.installedDigest else { throw HookFailure.changed }
        let parent = try HookPaths.openDirectory(directory, privateOnly: true); defer { close(parent) }
        guard unlinkat(parent, destination.lastPathComponent, 0) == 0 else { throw HookFailure.io }
        // Keep config backups/previous helper/receipt for explicit review; never delete a user directory.
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
