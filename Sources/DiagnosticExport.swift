import Foundation
import CryptoKit
import Darwin

enum DiagnosticExportRange: String, CaseIterable, Codable {
    case thirtyMinutes, twoHours, all

    var title: String {
        switch self {
        case .thirtyMinutes: return "最近 30 分钟"
        case .twoHours: return "最近 2 小时"
        case .all: return "全部可用记录"
        }
    }

    func startDate(endingAt date: Date) -> Date? {
        switch self {
        case .thirtyMinutes: return date.addingTimeInterval(-1_800)
        case .twoHours: return date.addingTimeInterval(-7_200)
        case .all: return nil
        }
    }
}

/// Free text belongs to this one export only. It is never sent to the event recorder.
struct DiagnosticExportRequest {
    let range: DiagnosticExportRange
    let createdAt: Date
    let problemDescription: String
    let problemTime: Date?

    init(range: DiagnosticExportRange = .thirtyMinutes, createdAt: Date = Date(),
         problemDescription: String = "", problemTime: Date? = nil) {
        self.range = range
        self.createdAt = createdAt
        self.problemDescription = String(problemDescription.prefix(4_096))
        self.problemTime = problemTime
    }
}

enum DiagnosticExportError: String, Error {
    case busy, cancelled, timedOut, budgetExceeded, invalidated, unsafeDestination, writeFailed, invalidArchive, differentVolume

    var message: String {
        switch self {
        case .busy: return "已有诊断导出正在进行。"
        case .cancelled: return "诊断导出已取消。"
        case .timedOut: return "诊断导出超过 30 秒，已停止；可重试或缩短时间范围。"
        case .budgetExceeded: return "诊断快照和 ZIP 超过 25 MiB，已停止；请缩短时间范围。"
        case .invalidated: return "记录状态已变化或窗口已关闭；请重新生成预览。"
        case .unsafeDestination: return "保存位置包含符号链接或不可用文件，请选择其他位置。"
        case .writeFailed: return "诊断包写入失败，请检查可用空间和文件夹权限后重试。"
        case .invalidArchive: return "诊断包可读性校验未通过，未保存本次文件。"
        case .differentVolume: return "请先保存到用户资料所在磁盘，再用 Finder 移动诊断包。"
        }
    }
}

struct DiagnosticExportFile {
    let name: String
    let data: Data
    var text: String { String(decoding: data, as: UTF8.self) }
    var sha256: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Value snapshot: saving never re-reads events, environment, user text, or checks.
struct DiagnosticExportSnapshot {
    static let fileNames = ["summary.txt", "environment.json", "events.jsonl", "checks.json", "manifest.json"]
    let id: UUID
    let createdAt: Date
    let recordingGeneration: UInt64
    let files: [DiagnosticExportFile]
    let hasGaps: Bool
    var byteCount: Int { files.reduce(0) { $0 + $1.data.count } }
    var suggestedFileName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "GPT-TouchBar-HUD-diagnostics-\(formatter.string(from: createdAt))-\(id.uuidString.prefix(8)).zip"
    }
}

private struct DiagnosticExportChecks: Encodable {
    struct Finding: Encodable { let step: Int; let result: ConnectionDiagnosticFinding }
    let status: String
    let startedAt: Date?
    let finishedAt: Date?
    let findings: [Finding]

    init(_ report: ConnectionDiagnosticsReport?) {
        status = report == nil ? "notPerformed" : report!.isRunning ? "inProgress" : "finished"
        startedAt = report?.startedAt
        finishedAt = report?.finishedAt
        findings = report.map { report in
            ConnectionDiagnosticStep.allCases.map { Finding(step: $0.rawValue, result: report.findings[$0] ?? .waiting) }
        } ?? []
    }
}

private struct DiagnosticExportManifest: Encodable {
    struct File: Encodable { let name: String; let size: Int; let sha256: String }
    let schemaVersion = 1
    let exportID: UUID
    let createdAt: Date
    let requestedRange: DiagnosticExportRange
    let requestedStart: Date?
    let requestedEnd: Date
    let actualStart: Date?
    let actualEnd: Date?
    let recordingEnabled: Bool
    let eventCount: DiagnosticOptionalCount
    let droppedCount: DiagnosticOptionalCount
    let gaps: [DiagnosticGap]
    let collectionFailures: [String]
    let coverageIncomplete: Bool
    let partialFailure: Bool
    let files: [File]
    let upgradeCoverage: [DiagnosticUpgradeCoverage]
    let taskTraceCoverage: DiagnosticTaskTraceCoverage
    let protocolCompatibility: String
}

/// Unknown acquisition is JSON null, distinct from a confirmed count of zero.
private struct DiagnosticOptionalCount: Encodable {
    let value: Int?
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value { try container.encode(value) } else { try container.encodeNil() }
    }
}

/// Lock is restricted to cancellation/deadline and the final atomic rename.
/// No file scanning or encoding occurs while holding the coordinator's lock.
private final class DiagnosticExportOperation {
    private let lock = NSLock()
    private var stopped: DiagnosticExportError?
    private var committed = false
    let deadline: TimeInterval
    private let uptime: () -> TimeInterval

    init(timeout: TimeInterval, uptime: @escaping () -> TimeInterval) {
        self.uptime = uptime
        deadline = uptime() + timeout
    }
    @discardableResult
    func stop(_ error: DiagnosticExportError) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !committed else { return false }
        stopped = stopped ?? error
        return true
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        try checkLocked()
    }
    private func checkLocked() throws {
        if let stopped { throw stopped }
        if uptime() >= deadline { throw DiagnosticExportError.timedOut }
    }
    func commit(_ action: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try checkLocked()
        try action()
        committed = true
    }
}

final class DiagnosticExportCoordinator {
    static let shared = DiagnosticExportCoordinator()
    static let maximumTemporaryBytes = 25 * 1_024 * 1_024
    private let queue = DispatchQueue(label: "com.gpt-touchbar.diagnostic-export", qos: .utility)
    private let lock = NSLock()
    private var active: DiagnosticExportOperation?
    private var completion: ((DiagnosticExportError) -> Void)?
    private let recorder: DiagnosticRecorder
    private let environment: () -> DiagnosticEnvironmentSnapshot
    private let uptime: () -> TimeInterval
    private let timeout: TimeInterval
    private let stagingDirectory: URL

    init(recorder: DiagnosticRecorder = .shared,
         environment: @escaping () -> DiagnosticEnvironmentSnapshot = DiagnosticEnvironmentSnapshot.current,
         timeout: TimeInterval = 30,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         stagingDirectory: URL? = nil) {
        self.recorder = recorder
        self.environment = environment
        self.timeout = min(30, max(0, timeout))
        self.uptime = uptime
        self.stagingDirectory = stagingDirectory ?? recorder.exportStagingDirectory
    }

    func cancel() { stop(.cancelled) }
    func invalidate() { stop(.invalidated) }
    private func stop(_ error: DiagnosticExportError) {
        lock.lock()
        let operation = active
        lock.unlock()
        if let operation, operation.stop(error) { fail(operation, error) }
    }

    func preview(request: DiagnosticExportRequest, report: ConnectionDiagnosticsReport?,
                 completion: @escaping (Result<DiagnosticExportSnapshot, DiagnosticExportError>) -> Void) {
        guard let operation = begin(failure: { completion(.failure($0)) }) else { return }
        recorder.captureSnapshot(since: request.range.startDate(endingAt: request.createdAt), until: request.createdAt) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                defer { self.end(operation) }
                do {
                    try operation.check()
                    let snapshot = try self.makeSnapshot(request: request, report: report, result: result, operation: operation)
                    try operation.check()
                    guard snapshot.recordingGeneration == self.recorder.recordingGeneration else { throw DiagnosticExportError.invalidated }
                    self.finish(operation) { completion(.success(snapshot)) }
                } catch { self.fail(operation, Self.classify(error)) }
            }
        }
    }

    func save(_ snapshot: DiagnosticExportSnapshot, to destination: URL,
              completion: @escaping (Result<Void, DiagnosticExportError>) -> Void) {
        guard let operation = begin(failure: { completion(.failure($0)) }) else { return }
        queue.async { [self] in
            defer { end(operation) }
            do {
                try operation.check()
                guard snapshot.recordingGeneration == recorder.recordingGeneration else { throw DiagnosticExportError.invalidated }
                guard snapshot.byteCount * 2 + DiagnosticZIP.overhead(snapshot.files) <= Self.maximumTemporaryBytes else { throw DiagnosticExportError.budgetExceeded }
                let archive = try DiagnosticZIP.archive(snapshot.files, checkpoint: operation.check)
                guard archive.count + snapshot.byteCount <= Self.maximumTemporaryBytes else { throw DiagnosticExportError.budgetExceeded }
                try DiagnosticZIP.validate(archive, files: snapshot.files, checkpoint: operation.check)
                try Self.write(archive, destination: destination, stagingDirectory: stagingDirectory,
                               reservedBytes: snapshot.byteCount + archive.count, operation: operation, validate: { data in
                    try DiagnosticZIP.validate(data, files: snapshot.files, checkpoint: operation.check)
                }, generationValid: { snapshot.recordingGeneration == recorder.recordingGeneration })
                finish(operation) { completion(.success(())) }
            } catch { fail(operation, Self.classify(error)) }
        }
    }

    private func begin(failure: @escaping (DiagnosticExportError) -> Void) -> DiagnosticExportOperation? {
        lock.lock()
        guard active == nil else { lock.unlock(); DispatchQueue.main.async { failure(.busy) }; return nil }
        let operation = DiagnosticExportOperation(timeout: timeout, uptime: uptime)
        active = operation
        completion = failure
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self, weak operation] in
            guard let self, let operation else { return }
            if operation.stop(.timedOut) { self.fail(operation, .timedOut) }
        }
        return operation
    }

    private func finish(_ operation: DiagnosticExportOperation, deliver: @escaping () -> Void) {
        lock.lock()
        guard active === operation, completion != nil else { lock.unlock(); return }
        completion = nil
        lock.unlock()
        DispatchQueue.main.async(execute: deliver)
    }
    private func fail(_ operation: DiagnosticExportOperation, _ error: DiagnosticExportError) {
        lock.lock()
        guard active === operation, completion != nil else { lock.unlock(); return }
        let callback = completion
        completion = nil
        lock.unlock()
        DispatchQueue.main.async { callback?(error) }
    }
    /// A timed-out or cancelled source may still be returning. Keep its slot reserved
    /// until its worker exits, so another snapshot cannot stack memory or disk work.
    private func end(_ operation: DiagnosticExportOperation) {
        lock.lock(); defer { lock.unlock() }
        guard active === operation else { return }
        active = nil
        completion = nil
    }
    private static func classify(_ error: Error) -> DiagnosticExportError { error as? DiagnosticExportError ?? .writeFailed }

    private func makeSnapshot(request: DiagnosticExportRequest, report: ConnectionDiagnosticsReport?,
                              result: Result<DiagnosticStoreSnapshot, Error>, operation: DiagnosticExportOperation) throws -> DiagnosticExportSnapshot {
        if case .failure(let error) = result, (error as? DiagnosticStoreError) == .cancelled {
            throw DiagnosticExportError.invalidated
        }
        let id = UUID()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let environment = environment()
        try operation.check()
        let store = try? result.get()
        let events = store?.eventsData ?? Data()
        let upgrades = DiagnosticUpgradeCoverage.collect(events: events, truncated: Set(store?.truncatedUpdateIDs ?? []))
        let earliest = store?.earliest
        let latest = store?.latest
        let dropped = store?.droppedCount
        let failures = store == nil ? ["eventReadFailed"] : []
        let start = request.range.startDate(endingAt: request.createdAt)
        let partial = !failures.isEmpty || store?.issues.contains { $0 != .recordingDisabled && $0 != .retentionLimit } == true
        let incomplete = earliest == nil || start.map { earliest! > $0 } == true || (dropped ?? 0) > 0 || partial
            || store?.issues.contains(.recordingDisabled) == true || store?.issues.contains(.retentionLimit) == true
        let taskCoverage = DiagnosticTaskTraceCoverage.collect(events: events,
            globalRecordingGap: partial || (dropped ?? 0) > 0 || store?.issues.contains(.retentionLimit) == true
                || store?.issues.contains(.recordingDisabled) == true)
        let formatter = ISO8601DateFormatter()
        var summary = ["GPT TouchBar HUD 本地诊断包", "快照时间：\(formatter.string(from: request.createdAt))",
                       "请求范围：\(request.range.title)",
                       "实际事件覆盖：\(earliest.map(formatter.string(from:)) ?? "无可用记录") → \(latest.map(formatter.string(from:)) ?? "无可用记录")",
                       "覆盖不足：\(incomplete ? "是" : "否")；丢弃事件：\(dropped.map(String.init) ?? "未知")；采集部分失败：\(partial ? "是" : "否")",
                       "说明：事件时间范围不能证明期间完整记录；未确认正常结束不等于崩溃。",
                       "本包仅保存在本机；包含下面预览内容。", "", environment.summaryText]
        if let store {
            summary.append("本地记录：\(store.isEnabled ? "开启" : "关闭")")
            if !store.issues.isEmpty { summary.append("记录缺口：\(store.issues.map(\.rawValue).joined(separator: ", "))") }
        } else { summary.append("记录读取失败：eventReadFailed；其余文件仍可导出。") }
        for upgrade in upgrades { summary += ["", upgrade.summary] }
        summary += ["", taskCoverage.summary]
        if !request.problemDescription.isEmpty { summary += ["", "用户本次填写的问题说明：", request.problemDescription] }
        if let problemTime = request.problemTime { summary.append("用户填写的发生时间：\(formatter.string(from: problemTime))") }
        summary += ["", report?.text ?? "当前检查：未执行。打开窗口和导出不会主动检查。"]
        var files = [DiagnosticExportFile(name: "summary.txt", data: Data(summary.joined(separator: "\n").utf8)),
                     DiagnosticExportFile(name: "environment.json", data: try encoder.encode(environment)),
                     DiagnosticExportFile(name: "events.jsonl", data: events),
                     DiagnosticExportFile(name: "checks.json", data: try encoder.encode(DiagnosticExportChecks(report)))]
        try operation.check()
        let manifest = DiagnosticExportManifest(exportID: id, createdAt: request.createdAt, requestedRange: request.range,
            requestedStart: start, requestedEnd: request.createdAt, actualStart: earliest, actualEnd: latest,
            recordingEnabled: store?.isEnabled ?? recorder.isEnabled,
            eventCount: .init(value: store == nil ? nil : events.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }),
            droppedCount: .init(value: dropped),
            gaps: store?.gaps ?? [], collectionFailures: failures,
            coverageIncomplete: incomplete || (taskCoverage.eventCount > 0 && !taskCoverage.evidenceComplete), partialFailure: partial,
            files: files.map { .init(name: $0.name, size: $0.data.count, sha256: $0.sha256) },
            upgradeCoverage: upgrades,
            taskTraceCoverage: taskCoverage,
            protocolCompatibility: store?.issues.contains(.unknownProtocol) == true || store?.issues.contains(.unknownEvent) == true
                ? "unsupportedRecordsSkipped" : "recognizedRecordsOnly")
        files.append(DiagnosticExportFile(name: "manifest.json", data: try encoder.encode(manifest)))
        let snapshot = DiagnosticExportSnapshot(id: id, createdAt: request.createdAt,
            recordingGeneration: store?.generation ?? recorder.recordingGeneration, files: files,
            hasGaps: incomplete || partial || (dropped ?? 0) > 0 || upgrades.contains { $0.rangeTruncated || $0.missingProducers.count > 0 }
                || (taskCoverage.eventCount > 0 && !taskCoverage.evidenceComplete))
        // ZIP uses stored members and fixed headers, so its exact size is predictable.
        guard snapshot.byteCount * 2 + DiagnosticZIP.overhead(files) <= Self.maximumTemporaryBytes else { throw DiagnosticExportError.budgetExceeded }
        return snapshot
    }

    private static func write(_ archive: Data, destination: URL, stagingDirectory: URL, reservedBytes: Int,
                              operation: DiagnosticExportOperation,
                              validate: (Data) throws -> Void, generationValid: () -> Bool) throws {
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty,
              destination.lastPathComponent != ".", destination.lastPathComponent != ".." else { throw DiagnosticExportError.unsafeDestination }
        let directory = try openDirectory(destination.deletingLastPathComponent(), operation: operation)
        defer { close(directory) }
        guard stagingDirectory.lastPathComponent == "export-staging" else { throw DiagnosticExportError.unsafeDestination }
        let root = try openDirectory(stagingDirectory.deletingLastPathComponent(), operation: operation)
        defer { close(root) }
        if mkdirat(root, "export-staging", mode_t(0o700)) != 0 && errno != EEXIST { throw DiagnosticExportError.writeFailed }
        let staging = openat(root, "export-staging", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard staging >= 0 else { throw DiagnosticExportError.unsafeDestination }
        defer { close(staging) }
        var stagingInfo = stat()
        guard fstat(staging, &stagingInfo) == 0, (stagingInfo.st_mode & S_IFMT) == S_IFDIR,
              stagingInfo.st_uid == geteuid(), fchmod(staging, mode_t(0o700)) == 0 else { throw DiagnosticExportError.unsafeDestination }
        let leftovers = try temporaryBytes(in: staging, operation: operation)
        guard leftovers <= maximumTemporaryBytes - reservedBytes else { throw DiagnosticExportError.budgetExceeded }
        var info = stat()
        let name = destination.lastPathComponent
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw DiagnosticExportError.unsafeDestination }
        } else if errno != ENOENT { throw DiagnosticExportError.writeFailed }
        let temporary = "export-\(UUID().uuidString.lowercased()).tmp"
        let fd = openat(staging, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw DiagnosticExportError.writeFailed }
        defer { close(fd); unlinkat(staging, temporary, 0) }
        try archive.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try operation.check()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(64 * 1_024, bytes.count - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DiagnosticExportError.writeFailed }
                offset += count
            }
        }
        guard fsync(fd) == 0, lseek(fd, 0, SEEK_SET) == 0 else { throw DiagnosticExportError.writeFailed }
        var readBack = Data(count: archive.count)
        try readBack.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try operation.check()
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), min(64 * 1_024, bytes.count - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DiagnosticExportError.invalidArchive }
                offset += count
            }
        }
        try validate(readBack)
        guard readBack == archive else { throw DiagnosticExportError.invalidArchive }
        try operation.commit {
            guard generationValid() else { throw DiagnosticExportError.invalidated }
            if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
               (info.st_mode & S_IFMT) != S_IFREG { throw DiagnosticExportError.unsafeDestination }
            guard renameat(staging, temporary, directory, name) == 0 else {
                if errno == EXDEV { throw DiagnosticExportError.differentVolume }
                throw DiagnosticExportError.writeFailed
            }
        }
    }

    private static func openDirectory(_ url: URL, operation: DiagnosticExportOperation) throws -> Int32 {
        guard url.isFileURL, url.pathComponents.first == "/",
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { throw DiagnosticExportError.unsafeDestination }
        // Preserve /private/tmp: standardizedFileURL may rewrite it to the /tmp symlink.
        // Open each parent with O_NOFOLLOW; substitution cannot redirect a later openat.
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw DiagnosticExportError.writeFailed }
        do {
          for component in url.pathComponents where component != "/" {
            try operation.check()
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw DiagnosticExportError.unsafeDestination }
            close(directory)
            directory = next
          }
          return directory
        } catch {
          close(directory)
          throw error
        }
    }

    private static func temporaryBytes(in directory: Int32, operation: DiagnosticExportOperation) throws -> Int {
        let copy = dup(directory)
        guard copy >= 0 else { throw DiagnosticExportError.writeFailed }
        guard let stream = fdopendir(copy) else { close(copy); throw DiagnosticExportError.writeFailed }
        defer { closedir(stream) }
        var total = 0
        while let entry = readdir(stream) {
            try operation.check()
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            guard name.hasPrefix("export-"), name.hasSuffix(".tmp"), name.count == 47,
                  UUID(uuidString: String(name.dropFirst(7).dropLast(4))) != nil else { continue }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid(),
                  info.st_size >= 0 else { throw DiagnosticExportError.unsafeDestination }
            guard info.st_size <= maximumTemporaryBytes - total else { throw DiagnosticExportError.budgetExceeded }
            total += Int(info.st_size)
        }
        return total
    }
}

/// Minimal ZIP writer: five fixed UTF-8 names, stored members, CRC32, no recursive input.
enum DiagnosticZIP {
    static func overhead(_ files: [DiagnosticExportFile]) -> Int { 22 + files.reduce(0) { $0 + 76 + 2 * $1.name.utf8.count } }
    static func archive(_ files: [DiagnosticExportFile], checkpoint: () throws -> Void = {}) throws -> Data {
        guard files.map(\.name) == DiagnosticExportSnapshot.fileNames else { throw DiagnosticExportError.invalidArchive }
        var output = Data()
        output.reserveCapacity(files.reduce(overhead(files)) { $0 + $1.data.count })
        var central = Data()
        for file in files {
            try checkpoint()
            let name = Data(file.name.utf8)
            let crc = try crc32(file.data, checkpoint: checkpoint)
            let offset = output.count
            output.appendLE(UInt32(0x04034b50)); output.appendLE(UInt16(20)); output.appendLE(UInt16(0x0800))
            output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(33))
            output.appendLE(crc); output.appendLE(UInt32(file.data.count)); output.appendLE(UInt32(file.data.count))
            output.appendLE(UInt16(name.count)); output.appendLE(UInt16(0)); output.append(name); output.append(file.data)
            central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16(0x0314)); central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(33))
            central.appendLE(crc); central.appendLE(UInt32(file.data.count)); central.appendLE(UInt32(file.data.count))
            central.appendLE(UInt16(name.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0o100600 << 16))
            central.appendLE(UInt32(offset)); central.append(name)
        }
        let offset = output.count
        output.append(central)
        output.appendLE(UInt32(0x06054b50)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0))
        output.appendLE(UInt16(files.count)); output.appendLE(UInt16(files.count))
        output.appendLE(UInt32(central.count)); output.appendLE(UInt32(offset)); output.appendLE(UInt16(0))
        try checkpoint()
        return output
    }

    static func validate(_ archive: Data, files: [DiagnosticExportFile], checkpoint: () throws -> Void = {}) throws {
        guard archive.count >= 22, archive.count <= DiagnosticExportCoordinator.maximumTemporaryBytes,
              files.map(\.name) == DiagnosticExportSnapshot.fileNames else { throw DiagnosticExportError.invalidArchive }
        // Parsing is bounds checked and confirms each central/local entry, CRC and exact content.
        let bytes = [UInt8](archive)
        func value(_ offset: Int, _ width: Int) throws -> UInt32 {
            guard offset >= 0, width <= 4, offset <= bytes.count - width else { throw DiagnosticExportError.invalidArchive }
            return (0..<width).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        let end = bytes.count - 22
        guard try value(end, 4) == 0x06054b50, try value(end + 4, 4) == 0,
              try value(end + 8, 2) == 5, try value(end + 10, 2) == 5, try value(end + 20, 2) == 0 else { throw DiagnosticExportError.invalidArchive }
        var position = Int(try value(end + 16, 4))
        let centralSize = Int(try value(end + 12, 4))
        guard position + centralSize == end else { throw DiagnosticExportError.invalidArchive }
        var expectedLocal = 0
        for file in files {
            try checkpoint()
            let name = Array(file.name.utf8)
            let crc = try crc32(file.data, checkpoint: checkpoint)
            guard try value(position, 4) == 0x02014b50, try value(position + 10, 2) == 0,
                  try value(position + 16, 4) == crc, try value(position + 20, 4) == file.data.count,
                  try value(position + 24, 4) == file.data.count, try value(position + 28, 2) == name.count,
                  try value(position + 30, 4) == 0, try value(position + 42, 4) == expectedLocal else { throw DiagnosticExportError.invalidArchive }
            guard position + 46 + name.count <= end,
                  Array(bytes[(position + 46)..<(position + 46 + name.count)]) == name else { throw DiagnosticExportError.invalidArchive }
            let local = expectedLocal
            guard try value(local, 4) == 0x04034b50, try value(local + 8, 2) == 0,
                  try value(local + 14, 4) == crc, try value(local + 18, 4) == file.data.count,
                  try value(local + 22, 4) == file.data.count, try value(local + 26, 2) == name.count,
                  try value(local + 28, 2) == 0 else { throw DiagnosticExportError.invalidArchive }
            let content = local + 30 + name.count
            guard content + file.data.count <= position,
                  Array(bytes[(local + 30)..<content]) == name,
                  Data(bytes[content..<(content + file.data.count)]) == file.data else { throw DiagnosticExportError.invalidArchive }
            expectedLocal = content + file.data.count
            position += 46 + name.count
        }
        guard position == end, expectedLocal + centralSize == end else { throw DiagnosticExportError.invalidArchive }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1 }
        return value
    }
    private static func crc32(_ data: Data, checkpoint: () throws -> Void) throws -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for (index, byte) in data.enumerated() {
            if index % 65_536 == 0 { try checkpoint() }
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

/// Derived exclusively from the frozen, filtered whitelist events. Never opens a recovery directory.
struct DiagnosticUpgradeCoverage: Encodable {
    let updateSessionID: UUID
    let protocolVersion = 1
    let producers: [String]
    let missingProducers: [String]
    let source: DiagnosticProcessIdentity?
    let target: DiagnosticProcessIdentity?
    let observedProcesses: [DiagnosticProcessIdentity]
    let installation: String
    let recovery: [String: String]
    let rangeTruncated: Bool
    let clockDiscontinuity: Bool
    let businessGapStart: Date?
    let businessGapEnd: Date?

    static func collect(events: Data, truncated: Set<UUID>) -> [Self] {
        let decoder = DiagnosticEventEnvelope.decoder()
        let decoded = events.split(separator: 10).compactMap { try? decoder.decode(DiagnosticEventEnvelope.self, from: Data($0)) }
        let grouped = Dictionary(grouping: decoded.filter { $0.updateSessionID != nil }, by: { $0.updateSessionID! })
        return grouped.keys.sorted(by: { $0.uuidString < $1.uuidString }).map { id in
            let values = grouped[id]!
            let roles = Set(values.compactMap { $0.writerRole?.rawValue })
            var clockJump = false
            for process in Dictionary(grouping: values, by: \.sessionID).values {
                let ordered = process.sorted { $0.sequence < $1.sequence }
                for (a, b) in zip(ordered, ordered.dropFirst()) {
                    // Installer CLI invocations have separate clocks, so their monotonic clocks are not comparable.
                    if a.writerRole == .installer { if b.timestamp < a.timestamp { clockJump = true }; continue }
                    if b.monotonicMilliseconds < a.monotonicMilliseconds { clockJump = true; continue }
                    let wall = b.timestamp.timeIntervalSince(a.timestamp)
                    let monotonic = Double(b.monotonicMilliseconds - a.monotonicMilliseconds) / 1_000
                    if wall < 0 || abs(wall - monotonic) > 5 { clockJump = true }
                }
            }
            let stages = values.compactMap { value -> (DiagnosticUpgradeStage, DiagnosticEventEnvelope)? in
                if case .upgrade(let stage, _) = value.event { return (stage, value) }; return nil
            }
            let stageSet = Set(stages.map { $0.0 })
            let oldExit = stages.first { $0.0 == .oldProcessExitObserved }?.1.timestamp
            let newStart = stages.first { $0.0 == .appStarted && $0.1.writerRole == .newHUD }?.1.timestamp
            if let oldExit, let newStart, newStart < oldExit { clockJump = true }
            let gapKnown = oldExit != nil && newStart != nil && !clockJump
            var recovery: [String: String] = [:]
            for value in values.sorted(by: { $0.timestamp < $1.timestamp }) {
                if case .moduleRecovery(let module, let state, _) = value.event { recovery[module.rawValue] = state.rawValue }
            }
            let outcome: String
            if stageSet.contains(.rollbackRestoreFailed) || stageSet.contains(.rollbackLaunchFailed) || stageSet.contains(.rollbackFailed) { outcome = "rollbackFailed" }
            else if stageSet.contains(.rollbackLaunchReceiptObserved) { outcome = "restoredLaunchConfirmed" }
            else if stageSet.contains(.rollbackLaunchTimedOut) { outcome = "restoredLaunchUnconfirmed" }
            else if stageSet.contains(.rollbackStarted) { outcome = "rollbackObserved" }
            else if stageSet.contains(.launchReceiptObserved) || stageSet.contains(.progressHelperLateReceiptObserved) { outcome = "launchReceiptConfirmed" }
            else if stageSet.contains(.launchTimedOut) { outcome = "launchUnconfirmed" }
            else if stageSet.contains(.oldProcessExitTimedOut) || stageSet.contains(.backupFailed) || stageSet.contains(.replaceFailed) || stageSet.contains(.launchFailed) { outcome = "failed" }
            else { outcome = "unknown" }
            var identities: [DiagnosticProcessIdentity] = []
            for identity in values.compactMap(\.processIdentity) where !identities.contains(identity) { identities.append(identity) }
            return Self(updateSessionID: id, producers: roles.sorted(),
                missingProducers: ["oldHUD", "installer", "newHUD"].filter { !roles.contains($0) },
                source: values.compactMap(\.upgradeSourceIdentity).first,
                target: values.compactMap(\.upgradeTargetIdentity).first,
                observedProcesses: identities, installation: outcome, recovery: recovery,
                rangeTruncated: truncated.contains(id), clockDiscontinuity: clockJump,
                businessGapStart: gapKnown ? oldExit : nil, businessGapEnd: gapKnown ? newStart : nil)
        }
    }

    var summary: String {
        let formatter = ISO8601DateFormatter()
        func label(_ identity: DiagnosticProcessIdentity?) -> String {
            "\(identity?.version?.rawValue ?? "未知") (Build \(identity?.build?.rawValue ?? "未知"))"
        }
        let gap: String
        if let businessGapStart, let businessGapEnd {
            gap = "\(formatter.string(from: businessGapStart)) → \(formatter.string(from: businessGapEnd))（退出观察至新版开始记录；非完整停机时长）"
        } else { gap = clockDiscontinuity ? "未知（时钟或顺序不一致）" : "未知（缺少可比较的两侧边界）" }
        return ["升级会话：\(updateSessionID.uuidString)",
            "来源：\(label(source))；目标：\(label(target))",
            "已观察运行版本：\(observedProcesses.map { label($0) }.joined(separator: "、"))",
            "安装结果：\(installation)（启动回执不代表业务恢复）",
            "生产者：\(producers.joined(separator: ", "))；未观察到：\(missingProducers.isEmpty ? "无" : missingProducers.joined(separator: ", "))",
            "HUD 业务采集空窗：\(gap)",
            "时间范围截断：\(rangeTruncated ? "是；选择全部可用记录后重新预览" : "未发现范围外事件；不保证阶段完整")",
            "恢复观察：\(recovery.keys.sorted().map { "\($0)=\(recovery[$0]!)" }.joined(separator: ", "))",
            "任务读取与任务开始识别分别报告；Touch Bar 成功仅表示请求已发出。",
            "首次从不支持诊断的来源版本升级，旧进程及旧助手没有本协议事件；不补写历史。"].joined(separator: "\n")
    }
}
