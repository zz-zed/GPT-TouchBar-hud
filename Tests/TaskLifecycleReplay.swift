import Foundation
import HookCore

/// Read-only inspection through the production bounded reader. Historical records do
/// not establish current execution; this tool deliberately emits no inferred live count.
@main enum TaskLifecycleReplay {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2, let cutoff = ISO8601DateFormatter().date(from: arguments[0]) else {
            throw NSError(domain: "Replay: supply UTC timestamp then rollout paths", code: 1)
        }
        for (index, path) in arguments.dropFirst().enumerated() {
            let url = URL(fileURLWithPath: path)
            let parts = url.pathComponents
            guard let rootIndex = parts.firstIndex(where: { $0 == "sessions" || $0 == "archived_sessions" }) else {
                throw HookFailure.unsafePath
            }
            let home = URL(fileURLWithPath: NSString.path(withComponents: Array(parts.prefix(rootIndex))))
            let reader = TaskJournalReader(home: home, path: url)
            var target: UInt64?
            var bytes = 0, records = 0, issues = 0
            var latest: JournalEvent?
            while true {
                let batch = try reader.read(targetEOF: target)
                target = batch.targetEOF; bytes += batch.bytesRead
                for record in batch.records {
                    if record.issue != nil { issues += 1 }
                    guard let event = record.event, event.timestamp <= cutoff else { continue }
                    records += 1
                    if TaskLifecyclePolicy.kind(for: event.type) != .execution,
                       latest.map({ event.timestamp >= $0.timestamp }) ?? true { latest = event }
                }
                if batch.reachedTarget { break }
            }
            let output: [String: Any] = ["fixture": index + 1, "readBytes": bytes,
                "committedOffset": reader.committedOffset, "lifecycleRecords": records,
                "malformedRecords": issues, "lastLifecycleEvent": latest?.type ?? "unknown",
                "currentExecution": "unconfirmedHistoricalReplay", "capability": "continuousLogsOnly"]
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
        }
    }
}
