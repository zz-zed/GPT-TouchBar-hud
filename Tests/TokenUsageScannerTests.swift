import Foundation

@main
enum TokenUsageScannerTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("touchbar-token-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let scanner = TokenUsageScanner(directory: directory)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z")!
        func read() -> TokenUsageSummary { scanner.read(now: now, calendar: calendar)! }
        func event(_ timestamp: String, _ total: Int, _ last: Int) -> String {
            "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(total)},\"last_token_usage\":{\"total_tokens\":\(last)}}}}"
        }
        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }
        let old = event("2026-09-13T12:00:00Z", 100, 100)
        let yesterday = event("2026-09-14T12:00:00.125Z", 150, 50)
        // A large unrelated Unicode record crosses multiple reader chunks.
        let noise = "{\"text\":\"" + String(repeating: "历史文本", count: 100_000) + "\"}\n"
        try (noise + old + "\n" + yesterday + "\n").write(to: file, atomically: true, encoding: .utf8)
        check(read() == TokenUsageSummary(yesterdayTokens: 50, cumulativeTokens: 150), "Cold scan and both timestamp formats")
        check(scanner.lastReadBytes > 1_000_000, "Fixture crosses chunk boundaries")
        check(read() == TokenUsageSummary(yesterdayTokens: 50, cumulativeTokens: 150), "Warm scan matches")
        check(scanner.lastReadBytes == 0, "Unchanged files read zero content bytes")

        let today = event("2026-09-15T01:00:00Z", 180, 30)
        try append(today + "\n")
        check(read() == TokenUsageSummary(yesterdayTokens: 50, cumulativeTokens: 180), "Append preserves history")
        check(scanner.lastReadBytes <= today.utf8.count + 65, "Append reads only new bytes and EOF fingerprint")
        let partial = event("2026-09-15T02:00:00Z", 200, 20)
        let split = partial.index(partial.startIndex, offsetBy: partial.count / 2)
        try append(String(partial[..<split]))
        check(read().cumulativeTokens == 180, "An incomplete record is deferred")
        try append(String(partial[split...]))
        check(read().cumulativeTokens == 200, "Complete record without newline is displayed")
        check(read().cumulativeTokens == 200 && scanner.lastReadBytes == 0, "Unterminated record is not repeatedly counted")
        try append("\n")
        check(read().cumulativeTokens == 200, "Newline commits the record exactly once")
        let tomorrow = now.addingTimeInterval(86400)
        check(scanner.read(now: tomorrow, calendar: calendar)?.yesterdayTokens == 50, "Midnight uses cached daily totals")
        check(scanner.lastReadBytes == 0, "Midnight does not reread historical logs")

        // A truncate/overwrite must discard the previous totals.
        try (event("2026-09-14T23:30:00Z", 7, 7) + "\n").write(to: file, atomically: false, encoding: .utf8)
        check(read() == TokenUsageSummary(yesterdayTokens: 7, cumulativeTokens: 7), "Truncation resets cache")
        // Larger overwrite on the same inode must fail the EOF fingerprint.
        try (noise + event("2026-09-14T23:30:00Z", 9, 9) + "\n").write(to: file, atomically: false, encoding: .utf8)
        check(read() == TokenUsageSummary(yesterdayTokens: 9, cumulativeTokens: 9), "Larger rewrite resets cache")
        try (event("2026-09-14T23:30:00Z", 4, 4) + "\n").write(to: file, atomically: true, encoding: .utf8)
        check(read() == TokenUsageSummary(yesterdayTokens: 4, cumulativeTokens: 4), "Atomic replacement resets cache")
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        check(read().yesterdayTokens == 0, "Time-zone changes rebuild day boundaries")
        let secondFile = directory.appendingPathComponent("second.jsonl")
        try (event("2026-09-14T01:00:00Z", 6, 6) + "\ninvalid JSON\n").write(to: secondFile, atomically: true, encoding: .utf8)
        check(read() == TokenUsageSummary(yesterdayTokens: 6, cumulativeTokens: 10), "New files and malformed lines")
        try FileManager.default.removeItem(at: file)
        check(read() == TokenUsageSummary(yesterdayTokens: 6, cumulativeTokens: 6), "Removed logs stop contributing")
        print("PASS: \(checks) token accounting and incremental-I/O checks")
    }
}
