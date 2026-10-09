import Foundation
import Darwin

/// Environment strings are admitted by field-specific grammars; paths are reduced to categories.
/// Capture on the export worker, never during an AppKit layout or production polling cycle.
struct DiagnosticEnvironmentSnapshot: Codable, Sendable {
    enum Status: String, Codable, Sendable { case known, unknown }
    struct Field: Codable, Sendable {
        let status: Status
        let value: String?
        fileprivate init(_ value: String?) {
            self.value = value
            status = value == nil ? .unknown : .known
        }
    }
    enum Architecture: String, Codable, Sendable { case arm64, x86_64, unknown }
    enum Location: String, Codable, Sendable { case applications, downloads, other, unknown }
    enum Host: String, Codable, Sendable { case chatGPT, codex, gpt, unknown }
    let schemaVersion: Int
    let capturedAt: Date
    let appVersion: Field
    let appBuild: Field
    let buildSource: Field
    let operatingSystemVersion: Field
    let operatingSystemBuild: Field
    let model: Field
    let hardwareArchitecture: Field
    let processArchitecture: Field
    let rosetta: Field
    let host: Field
    let hostVersion: Field
    let location: Field

    init(capturedAt: Date, appVersion: String?, appBuild: String?, buildSource: String?,
         operatingSystemVersion: String?, operatingSystemBuild: String?, model: String?,
         hardwareArchitecture: Architecture, processArchitecture: Architecture, translated: Bool?,
         host: Host, hostVersion: String?, location: Location) {
        schemaVersion = 1
        self.capturedAt = capturedAt
        self.appVersion = Field(Self.admit(appVersion, #"^[0-9]{1,8}(\.[0-9]{1,8}){0,3}$"#))
        self.appBuild = Field(Self.admit(appBuild, #"^[0-9]{1,10}$"#))
        self.buildSource = Field(Self.admit(buildSource, #"^[a-f0-9]{40}([a-f0-9]{24})?$"#))
        self.operatingSystemVersion = Field(Self.admit(operatingSystemVersion, #"^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"#))
        self.operatingSystemBuild = Field(Self.admit(operatingSystemBuild, #"^[0-9]{1,3}[A-Z][0-9]{1,6}[a-z]?$"#))
        self.model = Field(Self.admit(model, #"^(Mac|MacBookPro|MacBookAir|MacBook|Macmini|iMac|iMacPro|MacPro|Xserve|VirtualMac)[0-9]{1,3},[0-9]{1,3}$"#))
        self.hardwareArchitecture = Field(hardwareArchitecture == .unknown ? nil : hardwareArchitecture.rawValue)
        self.processArchitecture = Field(processArchitecture == .unknown ? nil : processArchitecture.rawValue)
        self.rosetta = Field(translated.map { $0 ? "translated" : "native" })
        self.host = Field(host == .unknown ? nil : host.rawValue)
        self.hostVersion = Field(Self.admit(hostVersion, #"^[0-9]{1,8}(\.[0-9]{1,8}){0,3}$"#))
        self.location = Field(location == .unknown ? nil : location.rawValue)
    }

    static func current() -> Self {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = Architecture.arm64
        #elseif arch(x86_64)
        let architecture = Architecture.x86_64
        #else
        let architecture = Architecture.unknown
        #endif
        let arm = integer("hw.optional.arm64")
        let hardware: Architecture = arm == 1 ? .arm64 : (arm == 0 ? .x86_64 : .unknown)
        let translation: Bool? = architecture == .arm64 ? false : integer("sysctl.proc_translated").map { $0 == 1 }
        var selectedHost = Host.unknown
        var hostVersion: String?
        // Match runtime discovery order and executable presence; never export these paths.
        for (name, kind) in [("ChatGPT", Host.chatGPT), ("Codex", .codex), ("GPT", .gpt)] {
            let root = URL(fileURLWithPath: "/Applications/\(name).app")
            let runtimes = ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"]
            if runtimes.contains(where: { FileManager.default.isExecutableFile(atPath: root.appendingPathComponent($0).path) }) {
                selectedHost = kind
                hostVersion = Bundle(url: root)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                break
            }
        }
        return Self(capturedAt: Date(),
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                    appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                    buildSource: Bundle.main.object(forInfoDictionaryKey: "HUDSourceSHA256") as? String,
                    operatingSystemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                    operatingSystemBuild: string("kern.osversion"), model: string("hw.model"),
                    hardwareArchitecture: hardware, processArchitecture: architecture, translated: translation,
                    host: selectedHost, hostVersion: hostVersion, location: locationCategory(Bundle.main.bundleURL))
    }

    static func locationCategory(_ url: URL) -> Location {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return .applications }
        if path.hasPrefix(home + "/Downloads/") { return .downloads }
        // /Volumes can also be a physical volume. Do not claim DMG without mount evidence.
        return .other
    }

    var summaryText: String {
        ["App：\(appVersion.value ?? "未知") (Build \(appBuild.value ?? "未知"))",
         "macOS：\(operatingSystemVersion.value ?? "未知") / \(operatingSystemBuild.value ?? "未知")",
         "机型：\(model.value ?? "未知")；硬件/进程：\(hardwareArchitecture.value ?? "未知") / \(processArchitecture.value ?? "未知")",
         "Rosetta：\(rosetta.value ?? "未知")；宿主：\(host.value ?? "未知") \(hostVersion.value ?? "未知")",
         "运行位置：\(location.value ?? "未知")；构建来源：\(buildSource.value ?? "未知")"].joined(separator: "\n")
    }

    private static func admit(_ value: String?, _ pattern: String) -> String? {
        guard let value, value.utf8.count <= 64, value.range(of: pattern, options: .regularExpression) != nil,
              !value.contains("\n"), !value.contains("\r") else { return nil }
        return value
    }
    private static func integer(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else { return nil }
        return value
    }
    private static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1, size < 128 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0, size <= bytes.count,
              bytes[size - 1] == 0 else { return nil }
        return String(bytes: bytes.prefix(size - 1), encoding: .utf8)
    }
}
