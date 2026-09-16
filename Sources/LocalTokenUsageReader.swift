import Foundation

enum LocalTokenUsageReader {
    // Accessed only from RateLimitStore's serial token-usage queue.
    private static let scanner = TokenUsageScanner(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true))

    static func read() -> TokenUsageSummary? { scanner.read() }
}
