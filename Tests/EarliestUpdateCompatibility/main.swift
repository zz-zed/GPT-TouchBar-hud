import Foundation

struct ContractFailure: Error { let message: String }

func verifyContract() throws {
    guard CommandLine.arguments.count == 4 else { throw ContractFailure(message: "Expected version, architecture and checksums path") }
    let version = CommandLine.arguments[1]
    let architecture = CommandLine.arguments[2]
    let checksumText = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
    let filename = "GPT-TouchBar-HUD-\(version)-\(architecture).dmg"
    let tag = "v" + version
    let repository = "zz-zed/GPT-TouchBar-hud"
    let base = "https://github.com/\(repository)/releases/download/\(tag)/"
    var checks: [String] = []
    func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw ContractFailure(message: name) }
        checks.append(name)
    }
    func release(name: String = "", url: String = "", checksumURL: String? = nil) throws -> AppRelease {
        let actualName = name.isEmpty ? filename : name
        let object: [String: Any] = ["tag_name": tag, "draft": false, "prerelease": false,
            "assets": [["name": actualName, "browser_download_url": url.isEmpty ? base + actualName : url, "size": 1],
                       ["name": "SHA256SUMS.txt", "browser_download_url": checksumURL ?? base + "SHA256SUMS.txt", "size": 1]]]
        return try JSONDecoder().decode(AppRelease.self, from: JSONSerialization.data(withJSONObject: object))
    }
    try check(AppRelease.repository == repository, "repository retained")
    try check(AppRelease.page.absoluteString == "https://github.com/\(repository)/releases/latest", "latest URL retained")
    let current = try release()
    try check(current.installer(architecture: architecture)?.name == filename, "historical asset name accepted")
    try check(current.checksums?.name == "SHA256SUMS.txt", "checksum asset accepted")
    try check(current.installer(architecture: architecture == "arm64" ? "x86_64" : "arm64") == nil, "wrong architecture rejected")
    try check(try release(name: "GPT-HUD-\(version)-\(architecture).dmg").installer(architecture: architecture) == nil, "renamed asset rejected")
    for (name, url) in [
        ("wrong scheme", base.replacingOccurrences(of: "https:", with: "http:") + filename),
        ("wrong host", base.replacingOccurrences(of: "github.com", with: "example.com") + filename),
        ("wrong repository", base.replacingOccurrences(of: repository, with: "other/repository") + filename),
        ("wrong tag", base.replacingOccurrences(of: tag + "/", with: "v0.0.1/") + filename),
        ("credentials", base.replacingOccurrences(of: "https://", with: "https://user:password@") + filename),
    ] {
        try check(try release(url: url).installer(architecture: architecture) == nil, name + " rejected")
    }
    try check(try release(checksumURL: "https://example.com/SHA256SUMS.txt").checksums == nil, "untrusted checksum asset rejected")
    guard let digest = AppRelease.checksum(in: checksumText, filename: filename) else {
        throw ContractFailure(message: "Supplied checksum file lacks one valid entry for " + filename)
    }
    try check(digest.count == 64, "supplied checksum entry parsed")
    try check(AppRelease.checksum(in: digest.uppercased() + " *" + filename, filename: filename) == digest, "uppercase and binary marker accepted")
    try check(AppRelease.checksum(in: digest + "  " + filename + "\n" + digest + "  " + filename, filename: filename) == nil, "duplicate checksum rejected")
    try check(AppRelease.checksum(in: "invalid  " + filename, filename: filename) == nil, "invalid digest rejected")
    try check(AppRelease.checksum(in: digest + "  another.dmg", filename: filename) == nil, "wrong checksum filename rejected")
    try check(AppVersion(version) == AppVersion(tag), "v-prefixed version equivalent")
    guard let target = AppVersion(version), let earliest = AppVersion("0.1.22") else { throw ContractFailure(message: "Invalid comparison version") }
    try check(target >= earliest, "target version not older than earliest updater")
    let result: [String: Any] = ["check_count": checks.count, "checks": checks,
                               "selected_asset": filename, "parsed_checksum": digest,
                               "scope": "historical release model only; not complete v0.1.22 installation"]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

do { try verifyContract() }
catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
