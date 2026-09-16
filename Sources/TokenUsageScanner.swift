import Foundation
import Darwin

/// Serial-use, in-memory index of append-only logs. No conversation text is
/// persisted: retain aggregates, metadata and an unfinished final line only.
final class TokenUsageScanner {
    private struct FileUsage {
        var size: Int = 0
        var modified = Date.distantPast
        var identity: AnyHashable?
        var pending = Data()
        var tail = Data()
        var total = 0
        var daily: [Date: Int] = [:]
    }

    private let directory: URL
    private var files: [URL: FileUsage] = [:]
    private var cachedCalendar: Calendar?
    private let marker = Data("\"token_count\"".utf8)
    private let fractionalDate = ISO8601DateFormatter()
    private let wholeDate = ISO8601DateFormatter()
    private(set) var lastReadBytes = 0

    init(directory: URL) {
        self.directory = directory
        fractionalDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        wholeDate.formatOptions = [.withInternetDateTime]
    }

    func read(now: Date = Date(), calendar: Calendar = .current) -> TokenUsageSummary? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]),
            let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        else { return nil }

        if cachedCalendar != calendar {
            files.removeAll()
            cachedCalendar = calendar
        }
        lastReadBytes = 0
        var seen = Set<URL>()
        var yesterdayTokens = 0
        var cumulativeTokens = 0
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            seen.insert(url)
            if let metadata = try? url.resourceValues(forKeys: keys), metadata.isRegularFile == true,
               let size = metadata.fileSize, let modified = metadata.contentModificationDate {
                let identity = metadata.fileResourceIdentifier as? AnyHashable
                let old = files[url]
                if old == nil || old?.size != size || old?.modified != modified || old?.identity != identity {
                    if let updated = scan(url, size: size, modified: modified, identity: identity, old: old, calendar: calendar) {
                        files[url] = updated
                    }
                }
            }
            guard var usage = files[url] else { continue }
            // Display a complete JSON record without a final newline, but don't
            // commit it until the newline arrives, avoiding double counting.
            consume(usage.pending, range: 0..<usage.pending.count, usage: &usage, calendar: calendar)
            yesterdayTokens += usage.daily[yesterday, default: 0]
            cumulativeTokens += usage.total
        }
        files = files.filter { seen.contains($0.key) }
        return TokenUsageSummary(yesterdayTokens: yesterdayTokens, cumulativeTokens: cumulativeTokens)
    }

    private func scan(_ url: URL, size: Int, modified: Date, identity: AnyHashable?, old: FileUsage?, calendar: Calendar) -> FileUsage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            var usage = FileUsage()
            if let old = old, old.identity == identity, size > old.size {
                // Verify the previous EOF before treating growth as an append.
                try handle.seek(toOffset: UInt64(old.size - old.tail.count))
                let tail = try handle.read(upToCount: old.tail.count) ?? Data()
                lastReadBytes += tail.count
                if tail == old.tail { usage = old }
            }
            try handle.seek(toOffset: UInt64(usage.size))
            var buffer = usage.pending
            var scanOffset = buffer.count
            while usage.size < size {
                let chunk = try handle.read(upToCount: min(256 * 1024, size - usage.size)) ?? Data()
                guard !chunk.isEmpty else { return nil }
                lastReadBytes += chunk.count
                usage.size += chunk.count
                usage.tail = Data((usage.tail + chunk).suffix(64))
                buffer.append(chunk)
                var consumed = 0
                buffer.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                    guard let base = bytes.baseAddress else { return }
                    while scanOffset < bytes.count,
                          let newline = memchr(base.advanced(by: scanOffset), 0x0A, bytes.count - scanOffset) {
                        let end = base.distance(to: UnsafeRawPointer(newline))
                        consume(buffer, range: consumed..<end, usage: &usage, calendar: calendar)
                        consumed = end + 1
                        scanOffset = consumed
                    }
                }
                if consumed > 0 { buffer = buffer.subdata(in: consumed..<buffer.count) }
                scanOffset = buffer.count
            }
            usage.pending = buffer
            usage.modified = modified
            usage.identity = identity
            return usage
        } catch {
            return nil // preserve the previous aggregate on transient I/O failure
        }
    }

    private func consume(_ data: Data, range: Range<Int>, usage: inout FileUsage, calendar: Calendar) {
        guard !range.isEmpty, data.range(of: marker, in: range) != nil,
              let object = try? JSONSerialization.jsonObject(with: data.subdata(in: range)),
              let event = object as? [String: Any],
              let payload = event["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any] else { return }
        if let total = info["total_token_usage"] as? [String: Any], let value = intValue(total["total_tokens"]) {
            usage.total = value
        }
        guard let timestamp = event["timestamp"] as? String,
              let date = fractionalDate.date(from: timestamp) ?? wholeDate.date(from: timestamp),
              let last = info["last_token_usage"] as? [String: Any], let value = intValue(last["total_tokens"])
        else { return }
        usage.daily[calendar.startOfDay(for: date), default: 0] += value
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
