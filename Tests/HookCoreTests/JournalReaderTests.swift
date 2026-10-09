import Foundation
import Darwin
import Testing
@testable import HookCore

struct JournalReaderTests {
    private func event(_ type: String, turn: String = "t1", bodyBytes: Int = 0) -> Data {
        let body = String(repeating: "x", count: bodyBytes)
        return Data("{\"payload\":{\"body\":\"\(body)\",\"turn_id\":\"\(turn)\",\"type\":\"\(type)\"},\"timestamp\":\"2026-10-08T08:00:00.000Z\",\"type\":\"event_msg\"}\n".utf8)
    }
    private func drain(_ reader: TaskJournalReader, budget: Int = 256 * 1024) throws -> [JournalRecord] {
        var records: [JournalRecord] = []
        for _ in 0..<100_000 {
            let batch = try reader.read(byteBudget: budget)
            #expect(batch.bytesRead <= budget)
            #expect(reader.retainedByteCount <= 7 * LifecycleStreamDecoder.maximumScalarBytes)
            records += batch.records
            if batch.reachedTarget { return records }
        }
        Issue.record("reader did not converge")
        return records
    }

    @Test(arguments: [262_143, 262_145, 489_000, 601_826, 2_097_152, 16_777_216])
    func largeSingleRecordsPreserveLifecycle(bytes: Int) throws {
        let fixture = try Fixture(); let path = try fixture.log()
        let reader = TaskJournalReader(home: fixture.home, path: path, expectedSessionID: "s1")
        _ = try drain(reader)
        try fixture.appendData(event("task_started"), to: path)
        let started = try drain(reader).compactMap(\.event)
        #expect(started.map(\.type) == ["task_started"])
        try fixture.appendData(event("item_completed", bodyBytes: bytes), to: path)
        let first = try reader.read(byteBudget: 64 * 1024)
        #expect(first.records.isEmpty)
        #expect(first.fetchedOffset > first.committedOffset)
        #expect(first.backlogBytes > 0)
        let trailing = try drain(reader, budget: 64 * 1024).compactMap(\.event)
        #expect(trailing.map(\.type) == ["item_completed"])
        try fixture.appendData(event("task_complete", bodyBytes: bytes), to: path)
        let terminal = try drain(reader, budget: 64 * 1024).compactMap(\.event)
        #expect(terminal.map(\.type) == ["task_complete"])
        #expect(terminal.map(\.turnID) == ["t1"])
        #expect(reader.fetchedOffset == reader.committedOffset)
        #expect(reader.generation == 1)
    }

    @Test(arguments: [1, 2, 7, 31, 256, 8192])
    func utf8EscapesFieldOrderAndFalseBodyEventsAreChunkInvariant(budget: Int) throws {
        let fixture = try Fixture(); let path = try fixture.log()
        let escaped = #"{"payload":{"nested":{"type":"task_complete","turn_id":"fake"},"body":"中文😀\\\"task_complete\"\uD83D\uDE00","turn_id":"t\u0031","type":"task_started"},"type":"event_msg","timestamp":"2026-10-08T08:00:00Z"}"# + "\n"
        let falseRecord = #"{"type":"response_item","payload":{"type":"task_complete","turn_id":"fake","body":"event_msg"},"timestamp":"2026-10-08T08:00:01Z"}"# + "\n"
        try fixture.appendData(Data((escaped + falseRecord).utf8), to: path)
        let reader = TaskJournalReader(home: fixture.home, path: path, expectedSessionID: "s1")
        let records = try drain(reader, budget: budget)
        #expect(records.compactMap(\.issue).isEmpty)
        #expect(records.compactMap(\.event).map(\.type) == ["task_started"])
        #expect(records.compactMap(\.event).map(\.turnID) == ["t1"])
        #expect(records.last?.endOffset == reader.committedOffset)
        #expect(records.first?.startOffset == 0)
    }

    @Test func hugeMetadataAndKeysRemainBoundedAndClassifySubagent() throws {
        let fixture = try Fixture(); let path = fixture.home.appendingPathComponent("sessions/meta.jsonl")
        let huge = String(repeating: "k", count: 80_000)
        let data = Data("{\"\(huge)\":\"ignored\",\"payload\":{\"instructions\":\"\(huge)\",\"source\":{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"parent\"}}},\"id\":\"s1\"},\"type\":\"session_meta\"}\n".utf8)
        try data.write(to: path)
        let reader = TaskJournalReader(home: fixture.home, path: path, expectedSessionID: "s1")
        let records = try drain(reader, budget: 1024)
        #expect(records.count == 1)
        #expect(records.first?.session?.isSubagent == true)
        #expect(records.first?.session?.id == "s1")
        #expect(records.first?.issue == nil)
        #expect(try reader.checkpoint()?.verifiedSession?.isSubagent == true)
    }

    @Test func malformedAndDepthLimitedRecordsRecoverAtNextNewline() throws {
        let fixture = try Fixture(); let path = try fixture.log()
        let invalid = [
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1",},"timestamp":"2026-10-08T08:00:00Z"}"#,
            #"{"ignored":01}"#, #"{"ignored":1e+}"#, #"{"ignored":tru}"#,
            #"{"ignored":"\uD800bad"}"#, #"{"ignored":"\uDC00"}"#,
            #"{"ignored":[1,]}"#, #"{"ignored":true false}"#,
            "{\"ignored\":" + String(repeating: "[", count: 300) + "0" + String(repeating: "]", count: 300) + "}"
        ]
        try fixture.appendData(Data((invalid.joined(separator: "\n") + "\n").utf8), to: path)
        try fixture.appendData(event("task_started"), to: path)
        let records = try drain(TaskJournalReader(home: fixture.home, path: path, expectedSessionID: "s1"), budget: 17)
        #expect(records.compactMap(\.issue).count == invalid.count)
        #expect(records.compactMap(\.issue).contains(.depthLimit))
        #expect(records.compactMap(\.event).map(\.type) == ["task_started"])
    }

    @Test func ignoredBodyInvalidUTF8CannotSmuggleLifecycle() throws {
        let fixture = try Fixture(); let path = try fixture.log()
        var data = Data(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"bad","body":""#.utf8)
        data += Data([0xed, 0xa0, 0x80])
        data += Data(#""},"timestamp":"2026-10-08T08:00:00Z"}"#.utf8) + Data([10])
        try fixture.appendData(data + event("task_started", turn: "good"), to: path)
        let records = try drain(TaskJournalReader(home: fixture.home, path: path, expectedSessionID: "s1"), budget: 1)
        #expect(records.compactMap(\.issue) == [.invalidUTF8])
        #expect(records.compactMap(\.event).map(\.turnID) == ["good"])
    }

    @Test func semanticLimitsAndDuplicateKeysAreExplicitIssues() throws {
        let fixture = try Fixture(); let path = try fixture.log()
        let duplicate = #"{"type":"event_msg","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"},"timestamp":"2026-10-08T08:00:00Z"}"# + "\n"
        let oversized = event("task_started", turn: String(repeating: "a", count: 5000))
        try fixture.appendData(Data(duplicate.utf8) + oversized + event("task_complete"), to: path)
        let records = try drain(TaskJournalReader(home: fixture.home, path: path, expectedSessionID: "s1"), budget: 113)
        #expect(records.compactMap(\.issue) == [.duplicateField, .semanticLimit])
        #expect(records.compactMap(\.event).map(\.type) == ["task_complete"])
    }

    @Test func checkpointReplaysOnlyIncompleteRecordAndCapturedEOFDoesNotChaseAppend() throws {
        let fixture = try Fixture(); let path = try fixture.log()
        let reader = TaskJournalReader(home: fixture.home, path: path, expectedSessionID: "s1")
        _ = try drain(reader)
        let prior = reader.committedOffset
        let start = event("task_started", bodyBytes: 4096)
        try fixture.appendData(start, to: path)
        let first = try reader.read(byteBudget: 103)
        #expect(first.committedOffset == prior)
        let checkpoint = try #require(try reader.checkpoint())
        #expect(checkpoint.committedOffset == prior)
        try fixture.appendData(event("task_complete"), to: path)
        let restored = TaskJournalReader(home: fixture.home, path: path, expectedSessionID: "s1", resume: checkpoint)
        let encoded = try JSONEncoder().encode(checkpoint)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("xxxx"))
        #expect(try JSONDecoder().decode(JournalCheckpoint.self, from: encoded) == checkpoint)
        let originalRemainder = try reader.read(byteBudget: 16_384, targetEOF: first.targetEOF)
        #expect(originalRemainder.records.compactMap(\.event).map(\.type) == ["task_started"])
        #expect(originalRemainder.targetEOF == first.targetEOF)
        #expect(originalRemainder.reachedTarget)
        #expect(try drain(reader).compactMap(\.event).map(\.type) == ["task_complete"])
        #expect(try drain(restored).compactMap(\.event).map(\.type) == ["task_started", "task_complete"])
    }

    @Test func partialFinalRecordWaitsForNewlineWithoutCommittingIt() throws {
        let fixture = try Fixture(); let path = try fixture.log()
        let reader = TaskJournalReader(home: fixture.home, path: path, expectedSessionID: "s1")
        _ = try drain(reader); let previous = reader.committedOffset
        let line = event("task_started")
        try fixture.appendData(line.dropLast(), to: path)
        let partial = try reader.read()
        #expect(partial.reachedTarget)
        #expect(partial.records.isEmpty)
        #expect(partial.committedOffset == previous)
        try fixture.appendData(Data([10]), to: path)
        #expect(try drain(reader).compactMap(\.event).map(\.type) == ["task_started"])
    }

    @Test func cancellationStopsBeforeIOAndDuringBoundedBatches() throws {
        let fixture = try Fixture(); let path = try fixture.log()
        try fixture.appendData(event("task_started", bodyBytes: 200_000), to: path)
        let reader = TaskJournalReader(home: fixture.home, path: path, expectedSessionID: "s1")
        #expect(try reader.read(cancelled: { true }).bytesRead == 0)
        var checks = 0
        let batch = try reader.read(byteBudget: 256 * 1024, cancelled: { checks += 1; return checks > 2 })
        #expect(batch.cancelled)
        #expect(batch.bytesRead == TaskJournalReader.chunkBytes)
        #expect(batch.fetchedOffset > batch.committedOffset)
        #expect(try drain(reader).compactMap(\.event).map(\.type) == ["task_started"])
    }

    @Test func rotationTruncationAndRewriteInvalidateGeneration() throws {
        let fixture = try Fixture(); let path = try fixture.log()
        let reader = TaskJournalReader(home: fixture.home, path: path, expectedSessionID: "s1")
        let original = try Data(contentsOf: path)
        _ = try drain(reader)
        try fixture.appendData(event("task_started"), to: path); _ = try drain(reader)
        let handle = try FileHandle(forWritingTo: path)
        try handle.truncate(atOffset: UInt64(original.count)); try handle.close()
        let truncated = try reader.read()
        #expect(truncated.resetReason == .truncated)
        #expect(truncated.generation == 2)
        try original.write(to: path, options: .atomic)
        let rotated = try reader.read()
        #expect(rotated.resetReason == .rotated)
        #expect(rotated.generation == 3)
        let checkpoint = try #require(try reader.checkpoint())
        let replacement = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "vscode", with: "unknown").utf8)
        let writer = try FileHandle(forWritingTo: path)
        try writer.write(contentsOf: replacement); try writer.truncate(atOffset: UInt64(replacement.count)); try writer.close()
        let rewritten = try reader.read()
        #expect(rewritten.resetReason == .rewritten)
        #expect(rewritten.generation == 4)
        let restored = TaskJournalReader(home: fixture.home, path: path, expectedSessionID: "s1", resume: checkpoint)
        #expect(try restored.read().resetReason == .invalidCheckpoint)
    }

    @Test func pathSymlinkAndSessionMismatchAreRejected() throws {
        let fixture = try Fixture(); let path = try fixture.log()
        let mismatch = TaskJournalReader(home: fixture.home, path: path, expectedSessionID: "other")
        #expect(throws: (any Error).self) { _ = try mismatch.read() }
        let link = fixture.home.appendingPathComponent("sessions/link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        #expect(throws: (any Error).self) { _ = try TaskJournalReader(home: fixture.home, path: link).read() }
        let outside = fixture.root.appendingPathComponent("outside.jsonl")
        try Data().write(to: outside)
        #expect(throws: (any Error).self) { _ = try TaskJournalReader(home: fixture.home, path: outside).read() }
    }
    @Test(arguments: [262_143, 262_145, 489_000, 601_826, 2_097_152, 16_777_216])
    func exactSizedMultilineIncrementsDoNotSkipRecords(bytes: Int) throws {
        let fixture = try Fixture(); let path = try fixture.log()
        let reader = TaskJournalReader(home: fixture.home, path: path, expectedSessionID: "s1")
        _ = try drain(reader)
        let begin = event("task_started", turn: "multi")
        let end = event("task_complete", turn: "multi")
        var data = begin
        let filler = Data("{\"ignored\":\"\(String(repeating: "x", count: 1000))\"}\n".utf8)
        while data.count + filler.count + end.count + 3 <= bytes { data += filler }
        let remaining = bytes - data.count - end.count
        data += Data(("{}" + String(repeating: " ", count: remaining - 3) + "\n").utf8)
        data += end
        #expect(data.count == bytes)
        try fixture.appendData(data, to: path)
        let records = try drain(reader, budget: 32767)
        #expect(records.compactMap(\.issue).isEmpty)
        #expect(records.compactMap(\.event).map(\.type) == ["task_started", "task_complete"])
        #expect(records.compactMap(\.event).map(\.turnID) == ["multi", "multi"])
    }

    @Test func sameLengthRewriteAndCorruptOffsetCheckpointAreSafe() throws {
        let fixture = try Fixture(); let path = try fixture.log()
        let reader = TaskJournalReader(home: fixture.home, path: path, expectedSessionID: "s1")
        _ = try drain(reader)
        let valid = try #require(try reader.checkpoint())
        var value = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        var anchor = try #require(value["boundaryAnchor"] as? [String: Any])
        anchor["offset"] = UInt64.max
        value["boundaryAnchor"] = anchor
        let corrupted = try JSONDecoder().decode(JournalCheckpoint.self, from: JSONSerialization.data(withJSONObject: value))
        let restored = TaskJournalReader(home: fixture.home, path: path, expectedSessionID: "s1", resume: corrupted)
        #expect(try restored.read().resetReason == .invalidCheckpoint)
        let data = try Data(contentsOf: path)
        let replacement = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "vscode", with: "abcdef").utf8)
        #expect(replacement.count == data.count)
        let writer = try FileHandle(forWritingTo: path)
        try writer.write(contentsOf: replacement); try writer.close()
        let changed = try reader.read()
        #expect(changed.resetReason == .rewritten)
        #expect(changed.session?.source == "abcdef")
    }

}
