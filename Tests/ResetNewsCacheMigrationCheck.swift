import Foundation
import ResetNewsCore

/// Only run on a caller-created temporary copy, never the live application's cache directory.
@main enum ResetNewsCacheMigrationCheck {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        precondition(directory.path.hasPrefix("/private/tmp/reset-forecast-migration.")
            || directory.path.hasPrefix("/tmp/reset-forecast-migration."), "Migration verification requires its isolated temporary directory")
        let now = CommandLine.arguments.count > 2 ? ISO8601DateFormatter().date(from: CommandLine.arguments[2])! : Date()
        let file = directory.appendingPathComponent("state-v1.json")
        let before = try JSONDecoder().decode(ResetNewsStoredState.self, from: Data(contentsOf: file))
        let policy = ResetForecastPolicy()
        let expected = policy.retaining(before.items, now: now)
        let repository = ResetNewsRepository(directory: directory, now: now)
        repository.load {}
        let deadline = Date().addingTimeInterval(5)
        while !repository.isLoaded && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        precondition(repository.isLoaded, "Asynchronous migration completed")
        let after = try JSONDecoder().decode(ResetNewsStoredState.self, from: Data(contentsOf: file))
        precondition(after == repository.state && after.items == expected)
        let readableIDs = Set(after.items.map(\.id) + (after.forecast?.item(now: now).map { [$0.id] } ?? []))
        precondition(after.readIDs.isSubset(of: readableIDs))
        precondition(after.items.allSatisfy { $0.facts.allSatisfy { $0.kind == .upcomingReset }
            && ($0.sourceSnapshots ?? []).allSatisfy { $0.facts.allSatisfy { $0.kind == .upcomingReset } } })
        precondition(Set(after.notified.map(\.key)).isSubset(of: Set(before.notified.map(\.key))))
        precondition(after.baselineSources == before.baselineSources)
        if before.forecast == nil {
            precondition(after.forecast == nil && after.forecastBaselineEstablished != true,
                         "Legacy candidates cannot establish current authority or its baseline")
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        print("Migration copy: \(file.path)")
        print("Before: \(before.items.count) items; IDs=\(before.items.map(\.id).joined(separator: ","))")
        print("After: \(after.items.count) internal candidates; currentAuthority=\(after.forecast == nil ? "unknown" : "cached"); readIDs=\(after.readIDs.count); ledger=\(before.notified.count)→\(after.notified.count)")
        for item in after.items {
            print("\(item.id): \(policy.firstDate(item).map(formatter.string) ?? "unknown"); facts=\(item.facts.count); exactTime=\(item.facts.contains { $0.effectiveAt != nil })")
        }
        print("PASS: isolated migration retained compatible candidates and ledger without promoting legacy history to current authority")
    }
}
