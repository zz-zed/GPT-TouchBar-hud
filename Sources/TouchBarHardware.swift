import Foundation
import Darwin

/// Built-in hardware capability, not AppKit API availability or current visibility.
/// Apple exposes no public Touch Bar presence API. Match the system model to the
/// published hardware catalog instead of probing private framework/driver state.
enum TouchBarHardware: Equatable {
    case present
    case absent
    case unknown

    /// Hardware cannot change while this process runs. No polling or child process.
    static let current = detect(modelIdentifier: readModelIdentifier())

    /// On a read failure, preserve existing settings rather than hiding valid controls.
    var shouldShowSettings: Bool { self != .absent }

    // Model identifiers: https://support.apple.com/108052
    // Covers the built-in Touch Bar MacBook Pro models introduced in 2016–2022.
    // Keep this catalog in sync if Apple introduces another Touch Bar model.
    private static let supportedModels: Set<String> = [
        "MacBookPro13,2", "MacBookPro13,3",
        "MacBookPro14,2", "MacBookPro14,3",
        "MacBookPro15,1", "MacBookPro15,2", "MacBookPro15,3", "MacBookPro15,4",
        "MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,3", "MacBookPro16,4",
        "MacBookPro17,1", "Mac14,7"
    ]

    static func detect(modelIdentifier: String?) -> TouchBarHardware {
        guard let model = modelIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else { return .unknown }
        if supportedModels.contains(model) { return .present }
        // A malformed/unrecognized identifier is a detection failure, not proof of absence.
        let pattern = #"^(Mac|MacBookPro|MacBookAir|MacBook|Macmini|iMac|iMacPro|MacPro|Xserve|VirtualMac)[0-9]+,[0-9]+$"#
        guard model.range(of: pattern, options: .regularExpression) != nil else { return .unknown }
        return .absent
    }

    static func readModelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0,
              size > 1, size <= 4096 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let status = bytes.withUnsafeMutableBytes { buffer in
            sysctlbyname("hw.model", buffer.baseAddress, &size, nil, 0)
        }
        guard status == 0, size > 1, size <= bytes.count, bytes[size - 1] == 0,
              !bytes.prefix(size - 1).contains(0) else { return nil }
        return String(bytes: bytes.prefix(size - 1), encoding: .utf8)
    }
}
