import Foundation
@main struct Probe {
 static func main() throws {
  let dir = URL(fileURLWithPath: "/private/tmp/diagnostic-review-recheck.m1qIer/tail-store", isDirectory: true)
  let store = DiagnosticStore(directory: dir)
  _ = try store.startSession(UUID())
  var line = try DiagnosticEventEnvelope.encoder().encode(DiagnosticEventEnvelope(timestamp: Date(), sessionID: UUID(), sequence: 1, monotonicMilliseconds: 0, event: .lifecycle(.launch)))
  line.append(10)
  try store.append([line])
  let file = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys:nil).first { $0.pathExtension == "jsonl" }!
  let handle = try FileHandle(forWritingTo: file)
  try handle.seekToEnd()
  try handle.write(contentsOf: line.prefix(20))
  try handle.close()
  for attempt in 1...3 {
   do { try store.append([line]); print("recovery", attempt, "success") } catch { print("recovery", attempt, error) }
  }
  let snapshot = try store.snapshot(since:nil,generation:1,isEnabled:true)
  print("readable events", snapshot.eventsData.split(separator:10).count, "issues", snapshot.issues)
 }
}
