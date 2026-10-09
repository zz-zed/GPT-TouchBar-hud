import Foundation
import Darwin
@main struct Probe {
 static func line() throws -> Data {
  var data = try DiagnosticEventEnvelope.encoder().encode(DiagnosticEventEnvelope(timestamp: Date(), sessionID: UUID(), sequence: 1, monotonicMilliseconds: 0, event: .lifecycle(.launch)))
  data.append(10); return data
 }
 static func main() throws {
  let base = URL(fileURLWithPath: "/private/tmp/diagnostic-review-recheck.m1qIer", isDirectory: true)
  let fifoDir = base.appendingPathComponent("fifo-store")
  let store = DiagnosticStore(directory: fifoDir)
  _ = try store.startSession(UUID()); let data = try line(); try store.append([data])
  let file = try FileManager.default.contentsOfDirectory(at: fifoDir, includingPropertiesForKeys:nil).first { $0.pathExtension == "jsonl" }!
  try FileManager.default.removeItem(at:file)
  guard mkfifo(file.path, 0o600) == 0 else { fatalError("mkfifo") }
  let finished = DispatchSemaphore(value:0)
  DispatchQueue.global().async { do { try store.append([data]); print("fifo append success") } catch { print("fifo append error", error) }; finished.signal() }
  print("fifo append returned within 1 sec:", finished.wait(timeout:.now()+1) == .success)
  // Unblock the writer; opening the read end pairs with its blocked open and fstat then rejects it.
  let reader = open(file.path, O_RDONLY | O_NONBLOCK)
  _ = finished.wait(timeout:.now()+1)
  if reader >= 0 { close(reader) }
  let retentionDir = base.appendingPathComponent("disabled-retention")
  var config = DiagnosticStore.Configuration(); config.maximumAge = 2
  let initial = DiagnosticStore(directory:retentionDir,configuration:config)
  _ = try initial.startSession(UUID()); try initial.append([line()])
  let markerBefore = try Data(contentsOf: retentionDir.appendingPathComponent("session-state.json"))
  let recorder = DiagnosticRecorder(directory:retentionDir,storeConfiguration:config)
  let started = DispatchSemaphore(value:0)
  recorder.setEnabled(false) { started.signal() }; _ = started.wait(timeout:.now()+1)
  Thread.sleep(forTimeInterval:3)
  let retained = try FileManager.default.contentsOfDirectory(at:retentionDir,includingPropertiesForKeys:nil).filter { $0.pathExtension == "jsonl" }.count
  print("disabled fresh process retained expired event files:", retained)
  let markerAfter = try Data(contentsOf: retentionDir.appendingPathComponent("session-state.json"))
  print("disabled existing marker unchanged:", markerBefore == markerAfter)
  let missingDir = base.appendingPathComponent("must-stay-missing")
  let missing = DiagnosticRecorder(directory:missingDir,storeConfiguration:config)
  let missingStarted = DispatchSemaphore(value:0)
  missing.setEnabled(false) { missingStarted.signal() }
  _ = missingStarted.wait(timeout:.now()+1)
  print("disabled missing directory remains absent:", !FileManager.default.fileExists(atPath:missingDir.path))
 }
}
