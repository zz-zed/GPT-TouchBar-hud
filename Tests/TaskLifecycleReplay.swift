import Foundation
import HookCore

/// Development-only, read-only replay. Outputs counts; never writes log contents.
@main enum TaskLifecycleReplay {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2, let now = ISO8601DateFormatter().date(from: arguments[0]) else {
            throw NSError(domain: "Replay: supply UTC timestamp then rollout paths", code: 1)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (index, path) in arguments.dropFirst().enumerated() {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? file.close() }
            var pending = Data(), tail = Data()
            var acceptedBytes = 0
            var legacyFull = TaskLogCursor()
            var hooksFull = TaskStateReducer()
            let task = TaskIdentity(session: "replay-\(index + 1)")
            var position: UInt64 = 0
            while let bytes = try file.read(upToCount: TaskLogCursor.readLimit), !bytes.isEmpty {
                pending.append(bytes)
                var start = pending.startIndex
                while let end = pending[start...].firstIndex(of: 10) {
                    let line = Data(pending[start...end])
                    defer { start = pending.index(after: end) }
                    guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let stamp = root["timestamp"] as? String,
                          let date = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp), date <= now else { continue }
                    acceptedBytes += line.count
                    tail.append(line)
                    if tail.count > TaskLogCursor.readLimit { tail.removeFirst(tail.count - TaskLogCursor.readLimit) }
                    legacyFull.consume(line, allowsCompletionFeedback: false)
                    position += UInt64(line.count)
                    apply(root, date: date, position: position, task: task, to: &hooksFull)
                }
                pending = Data(pending[start...])
                // Offline replay accepts large tool records that exceed the production
                // tail budget. Fail explicitly instead of silently dropping a record.
                if pending.count > 16 * 1024 * 1024 {
                    throw NSError(domain: "Replay record exceeds 16 MiB", code: 2)
                }
            }
            var legacyTail = TaskLogCursor()
            legacyTail.consume(tail, discardFirstLine: acceptedBytes > TaskLogCursor.readLimit, allowsCompletionFeedback: false)
            var hooksTail = TaskStateReducer()
            var tailPosition: UInt64 = 0
            let lines = tail.split(separator: 10, omittingEmptySubsequences: false)
            for line in lines.dropFirst(acceptedBytes > TaskLogCursor.readLimit ? 1 : 0) {
                tailPosition += UInt64(line.count + 1)
                guard let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let stamp = root["timestamp"] as? String,
                      let date = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) else { continue }
                apply(root, date: date, position: tailPosition, task: task, to: &hooksTail)
            }
            hooksFull.tick(now: now); hooksTail.tick(now: now)
            let result: [String: Any] = [
                "fixture": index + 1,
                "acceptedBytes": acceptedBytes,
                "tailBytes": tail.count,
                "legacyFullRunning": legacyFull.summary(now: now).runningCount,
                "legacyTailRunning": legacyTail.summary(now: now).runningCount,
                "hooksFullRunning": hooksFull.snapshot(now: now).confirmedRunningCount,
                "hooksTailRunning": hooksTail.snapshot(now: now).confirmedRunningCount
            ]
            let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: output, as: UTF8.self))
        }
    }

    private static func apply(_ root: [String: Any], date: Date, position: UInt64, task: TaskIdentity, to reducer: inout TaskStateReducer) {
        guard root["type"] as? String == "event_msg", let payload = root["payload"] as? [String: Any],
              let type = payload["type"] as? String, let turn = payload["turn_id"] as? String, HookEvent.validID(turn) else { return }
        // Keep this decoder independent of the new policy so the same replay can compare older source.
        let kinds: [String: EvidenceKind] = ["task_started": .started, "task_complete": .complete,
            "turn_aborted": .aborted, "item_completed": .execution, "token_count": .execution]
        guard let kind = kinds[type] else { return }
        reducer.apply(TaskEvidence(identity: TurnIdentity(task: task, turn: turn), kind: kind, position: position,
                                   date: date, live: true, settled: true), now: date)
    }
}
