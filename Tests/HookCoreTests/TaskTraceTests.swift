import Foundation
import Testing
@testable import HookCore

private final class TraceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [HookTaskTraceObservation] = []
    private var batches: [HookTaskTraceBatch] = []
    func append(_ value: HookTaskTraceObservation) { lock.lock(); observations.append(value); lock.unlock() }
    func append(_ value: HookTaskTraceBatch) { lock.lock(); batches.append(value); lock.unlock() }
    func reads() -> [HookTaskReadObservation] {
        lock.lock(); defer { lock.unlock() }
        return observations.compactMap { if case .read(let value) = $0 { return value }; return nil }
    }
    func decisions() -> [HookTaskDecisionObservation] {
        lock.lock(); defer { lock.unlock() }
        return observations.compactMap { if case .decision(let value) = $0 { return value }; return nil }
    }
    func discoveries() -> [HookTaskDiscoveryObservation] {
        lock.lock(); defer { lock.unlock() }
        return observations.compactMap { if case .discovery(let value) = $0 { return value }; return nil }
    }
    func inventories() -> [HookTaskInventoryObservation] {
        lock.lock(); defer { lock.unlock() }
        return observations.compactMap { if case .inventory(let value) = $0 { return value }; return nil }
    }
    func allBatches() -> [HookTaskTraceBatch] { lock.lock(); defer { lock.unlock() }; return batches }
}

private final class TraceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    private var epoch: UInt64 = 1
    func isEnabled() -> Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    func currentEpoch() -> UInt64 { lock.lock(); defer { lock.unlock() }; return epoch }
    func set(_ value: Bool) { lock.lock(); enabled = value; epoch += 1; lock.unlock() }
}

struct TaskTraceTests {
    /// Input truth is an explicit byte count including newline; the production parser does not define it.
    private func executionLine(bytes: Int, date: Date, turn: String = "t1") -> Data {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let prefix = Data("{\"type\":\"event_msg\",\"timestamp\":\"\(formatter.string(from: date))\",\"payload\":{\"type\":\"item_completed\",\"turn_id\":\"\(turn)\",\"private_body\":\"".utf8)
        let suffix = Data("\"}}\n".utf8)
        precondition(bytes >= prefix.count + suffix.count)
        return prefix + Data(repeating: 120, count: bytes - prefix.count - suffix.count) + suffix
    }

    @Test(arguments: [262_143, 262_144, 262_145, 489 * 1_024, 601_826, 2 * 1_024 * 1_024])
    func actualReadReportsExactByteBoundaryIncludingNewline(inputBytes: Int) throws {
        let f = try Fixture(); let file = try f.log()
        let resolver = TaskEvidenceResolver(home: f.home)
        let capture = TraceCapture(); resolver.traceObserver = { capture.append($0) }
        let task = TaskIdentity(session: "s1")
        _ = resolver.resolve(task: task, now: f.now, liveSince: f.now)
        let initial = try #require(capture.reads().last)
        let headerSize = try Data(contentsOf: file).count
        #expect(initial.fileSize == UInt64(headerSize))
        #expect(initial.bytesRead == 2 * headerSize)
        #expect(initial.headerBytesRead == headerSize)
        try f.append("task_started", to: file, date: f.now.addingTimeInterval(1))
        _ = resolver.resolve(task: task, now: f.now.addingTimeInterval(1.1), liveSince: nil)
        let before = try #require(capture.reads().last?.offsetAfter)
        let input = executionLine(bytes: inputBytes, date: f.now.addingTimeInterval(2))
        #expect(input.count == inputBytes)
        try f.appendData(input, to: file)
        let report = resolver.resolve(task: task, now: f.now.addingTimeInterval(2.1), liveSince: nil)
        let read = try #require(capture.reads().last)
        #expect(read.offsetBefore == before)
        #expect(read.offsetAfter == before + UInt64(inputBytes))
        #expect(read.fileSize == before + UInt64(inputBytes))
        #expect(read.bytesRead == min(inputBytes, HookBudget.readBytes))
        #expect(read.headerBytesRead == 0)
        #expect(read.skippedBytes == UInt64(max(0, inputBytes - HookBudget.readBytes)))
        #expect(read.backlogBytes == 0)
        #expect(read.pendingAfter == 0)
        #expect(read.reasons.contains(.readBudgetSkip) == (inputBytes > HookBudget.readBytes))
        #expect(report.resetTasks.contains(task) == (inputBytes > HookBudget.readBytes))
        if inputBytes > HookBudget.readBytes {
            #expect(read.discardedPartialBytes == HookBudget.readBytes)
            #expect(read.reasons.contains(.discardedHalfLine))
            #expect(report.traceResetReasons[task] == .readBudgetSkip)
            #expect(report.evidence.isEmpty)
        } else { #expect(report.evidence.last?.kind == .execution) }
    }

    @Test func pendingHalfLineClearAndMultiLineTailHaveDifferentFacts() throws {
        let f = try Fixture(); let file = try f.log()
        let resolver = TaskEvidenceResolver(home: f.home); let capture = TraceCapture()
        resolver.traceObserver = { capture.append($0) }
        let task = TaskIdentity(session: "s1")
        _ = resolver.resolve(task: task, now: f.now, liveSince: nil)
        try f.appendData(Data(repeating: 120, count: HookBudget.readBytes), to: file)
        _ = resolver.resolve(task: task, now: f.now.addingTimeInterval(1), liveSince: nil)
        #expect(capture.reads().last?.pendingAfter == HookBudget.readBytes)
        try f.appendData(Data([120]), to: file)
        let clear = resolver.resolve(task: task, now: f.now.addingTimeInterval(2), liveSince: nil)
        let cleared = try #require(capture.reads().last)
        #expect(cleared.pendingBefore == HookBudget.readBytes)
        #expect(cleared.bytesRead == 1)
        #expect(cleared.discardedPartialBytes == HookBudget.readBytes + 1)
        #expect(cleared.pendingAfter == 0)
        #expect(cleared.reasons.contains(.pendingLineCleared))
        #expect(!cleared.reasons.contains(.readBudgetSkip))
        #expect(clear.resetTasks.isEmpty, "Current production clears the partial buffer without resetting live state in this branch")
        try f.appendData(Data([10]), to: file)
        _ = resolver.resolve(task: task, now: f.now.addingTimeInterval(3), liveSince: nil)
        let line = executionLine(bytes: 1_024, date: f.now.addingTimeInterval(4))
        let input = Array(repeating: line, count: 2_048).reduce(into: Data()) { $0.append($1) }
        #expect(input.count == 2 * 1_024 * 1_024)
        try f.appendData(input, to: file)
        let report = resolver.resolve(task: task, now: f.now.addingTimeInterval(4.1), liveSince: nil)
        let read = try #require(capture.reads().last)
        #expect(read.bytesRead == HookBudget.readBytes)
        #expect(read.skippedBytes == UInt64(input.count - HookBudget.readBytes))
        #expect(read.discardedPartialBytes == 1_024)
        #expect(report.evidence.count == 255, "The existing tail path discards its first full line too; diagnostics must preserve that fact")
    }

    @Test func actualReadRejectionsRotationAndDisabledParity() throws {
        let f = try Fixture(); let file = try f.log(records: [("task_started", "t1")])
        let resolver = TaskEvidenceResolver(home: f.home); let silent = TaskEvidenceResolver(home: f.home)
        let capture = TraceCapture(); resolver.traceObserver = { capture.append($0) }
        var reducer = TaskStateReducer(); var silentReducer = TaskStateReducer()
        reducer.traceObserver = { capture.append($0) }
        let task = TaskIdentity(session: "s1")
        func consume(_ report: EvidenceReport, reducer: inout TaskStateReducer, now: Date) {
            for reset in report.resetTasks { reducer.invalidate(.rotatedLog, now: now, task: reset, resetPositions: true, traceReason: report.traceResetReasons[reset]) }
            for value in report.evidence { reducer.apply(value, now: now) }
        }
        func read(_ date: Date) {
            let live = resolver.resolve(task: task, now: date, liveSince: nil)
            let plain = silent.resolve(task: task, now: date, liveSince: nil)
            #expect(live.evidence == plain.evidence)
            #expect(live.gaps == plain.gaps)
            #expect(live.bytesRead == plain.bytesRead)
            consume(live, reducer: &reducer, now: date); consume(plain, reducer: &silentReducer, now: date)
            #expect(reducer.snapshot(now: date) == silentReducer.snapshot(now: date))
        }
        read(f.now)
        #expect(capture.decisions().last?.reason == .historicalStart)
        try f.append("item_completed", to: file, date: f.now.addingTimeInterval(1)); read(f.now.addingTimeInterval(1.1))
        #expect(capture.decisions().last?.reason == .missingStart)
        try f.append("task_started", to: file, date: f.now.addingTimeInterval(2)); read(f.now.addingTimeInterval(2.1))
        #expect(capture.decisions().last?.countedAfter == true)
        try f.append("item_completed", to: file, date: f.now.addingTimeInterval(1.5)); read(f.now.addingTimeInterval(2.2))
        #expect(capture.decisions().last?.reason == .oldTimestamp)
        #expect(capture.decisions().last?.countedAfter == true)
        try f.append("task_complete", to: file, date: f.now.addingTimeInterval(3)); read(f.now.addingTimeInterval(3.1))
        try f.append("token_count", to: file, date: f.now.addingTimeInterval(4)); read(f.now.addingTimeInterval(4.1))
        #expect(capture.decisions().last?.reason == .terminalActivity)
        read(f.now.addingTimeInterval(4.3)) // Stable EOF confirms the logged terminal.
        #expect(reducer.snapshot(now: f.now.addingTimeInterval(4.3)).confirmedRunningCount == 0)
        let generation = capture.reads().last?.fileGeneration
        try HookPaths.atomicWrite(Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"s1\"}}\n".utf8), to: file)
        try f.append("item_completed", turn: "t2", to: file, date: f.now.addingTimeInterval(5)); read(f.now.addingTimeInterval(5.1))
        #expect(capture.reads().last?.reasons.contains(.fileReset) == true)
        #expect(capture.reads().last?.fileGeneration != generation)
        #expect(capture.decisions().last?.reason == .historicalBaseline)
        let rotatedGeneration = capture.reads().last?.fileGeneration
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"s1\"}}\n".utf8))
        try handle.close()
        read(f.now.addingTimeInterval(6))
        #expect(capture.reads().last?.reasons.contains(.fileReset) == true)
        #expect(capture.reads().last?.fileGeneration != rotatedGeneration)
    }

    @Test func cursorInventoryEvictionNamesOnlyAnActuallyHeldTask() throws {
        let f = try Fixture()
        for index in 0..<33 { _ = try f.log("s\(index)") }
        let capture = TraceCapture(); let resolver = TaskEvidenceResolver(home: f.home)
        resolver.traceObserver = { capture.append($0) }
        _ = resolver.recover(tasks: [], now: f.now)
        let held = Set(resolver.observedFiles.keys)
        let outside = try #require(Set((0..<33).map { TaskIdentity(session: "s\($0)") }).subtracting(held).first)
        _ = resolver.resolve(task: outside, now: f.now.addingTimeInterval(1), liveSince: nil)
        let eviction = try #require(capture.inventories().last { $0.reason == .cursorCapacity })
        #expect(held.contains(eviction.task))
        #expect(!eviction.added && eviction.inventoryCount == 32 && eviction.inventoryLimit == 32)
        #expect(resolver.observedFiles[outside] != nil)
    }

    #if LEGACY_TASK_TRACE_REFERENCE
    @Test @MainActor func dynamicGateAndEpochDoNotForceBusinessDelivery() async throws {
        let f = try Fixture(); let file = try f.log()
        let capture = TraceCapture(); let gate = TraceGate()
        let controller = HookConnectionController(directory: f.ipc, home: f.home)
        var latest: TaskActivitySnapshot?
        var updates = 0
        controller.onTrace = { capture.append($0) }
        controller.traceEnabled = gate.isEnabled
        controller.traceEpoch = gate.currentEpoch
        controller.onUpdate = { latest = $0; updates += 1 }
        controller.setTraceEnabled(true); controller.start(); defer { controller.stop() }
        try await waitUntil { latest != nil }
        try f.append("task_started", to: file, date: Date())
        try await waitUntil { latest?.confirmedRunningCount == 1 }
        let businessUpdates = updates
        let before = capture.allBatches().count
        try f.append("token_count", to: file, date: Date())
        try await waitUntil { capture.allBatches().count > before }
        #expect(updates == businessUpdates, "Trace must not force rendering a production-suppressed snapshot")
        #expect(capture.allBatches().last?.businessDelivery == false)
        let traceCount = capture.allBatches().count
        gate.set(false)
        try f.append("task_complete", to: file, date: Date())
        try await waitUntil { latest?.recentlyCompletedCount == 1 }
        #expect(capture.allBatches().count == traceCount, "Disabled trace produced an observation")
        gate.set(true)
        try f.append("task_started", turn: "t2", to: file, date: Date())
        try await waitUntil { latest?.confirmedRunningCount == 1 && capture.allBatches().count > traceCount }
        let restarted = Array(capture.allBatches().dropFirst(traceCount))
        #expect(restarted.allSatisfy { $0.traceEpoch == gate.currentEpoch() })
        #expect(restarted.flatMap(\.observations).allSatisfy {
            if case .decision(let value) = $0 { return value.kind != .complete }; return true
        }, "A new diagnostic epoch reused pending observations from the old epoch")
    }
    #endif

    #if LEGACY_TASK_TRACE_REFERENCE
    @Test @MainActor func queuedTraceReportsActualDiscardWithoutDeliveringBusinessUpdate() async throws {
        let f = try Fixture(); _ = try f.log()
        let capture = TraceCapture()
        let controller = HookConnectionController(directory: f.ipc, home: f.home)
        var updates = 0
        var discarded: [(UInt64, UInt64)] = []
        controller.onTrace = { capture.append($0) }
        controller.onTraceDiscarded = { discarded.append(($0, $1)) }
        controller.onUpdate = { _ in updates += 1 }
        controller.setTraceEnabled(true); controller.start()
        waitForWorker { !capture.allBatches().isEmpty }
        let old = try #require(capture.allBatches().first)
        controller.stop()
        try await waitUntil { !discarded.isEmpty }
        #expect(updates == 0)
        #expect(discarded.contains { $0.0 == old.generation && $0.1 == old.sequence })
    }
    #endif

    @Test(arguments: [33, 65]) func actualInventoryQueryReportsLimitWithoutClaimingUnseenIdentities(count: Int) throws {
        let f = try Fixture()
        for index in 0..<count { _ = try f.log("s\(index)") }
        let capture = TraceCapture(); let resolver = TaskEvidenceResolver(home: f.home)
        resolver.traceObserver = { capture.append($0) }
        let report = resolver.recover(tasks: [], now: f.now)
        let discovery = try #require(capture.discoveries().last)
        #expect(discovery.queryLimit == 33)
        #expect(discovery.returnedRows == 33)
        #expect(discovery.validRows == 33)
        #expect(discovery.queryComplete && discovery.coverageLimited)
        #expect(resolver.observedFiles.count == 32)
        #expect(report.gaps.contains(.recoveryBudget))
    }

    #if LEGACY_TASK_TRACE_REFERENCE
    @Test @MainActor func diagnosticAcceptanceCapturesKnownCountDefectInActualController() async throws {
        let f = try Fixture()
        // Independent fixture truth: three active tasks, all with one explicit live start.
        let sessions = ["s1", "s2", "s3"]
        let files = try sessions.map { try f.log($0) }
        let capture = TraceCapture()
        let controller = HookConnectionController(directory: f.ipc, home: f.home)
        var latest: TaskActivitySnapshot?
        var deliveries: [(UInt64, UInt64, Bool)] = []
        controller.onTrace = { capture.append($0) }
        controller.onTraceDelivery = { deliveries.append(($0, $1, $2)) }
        controller.onUpdate = { latest = $0 }
        controller.setTraceEnabled(true); controller.start(); defer { controller.stop() }
        try await waitUntil { latest != nil }
        for file in files { try f.append("task_started", to: file, date: Date()) }
        try await waitUntil { latest?.confirmedRunningCount == 3 }
        let bytes = 489 * 1_024
        try f.appendData(executionLine(bytes: bytes, date: Date()), to: files[0])
        try await waitUntil { latest?.confirmedRunningCount == 2 }
        let batches = capture.allBatches()
        let skipped = try #require(batches.first { batch in batch.observations.contains {
            if case .read(let value) = $0 { return value.task.session == "s1" && value.skippedBytes > 0 }; return false
        } })
        #expect(skipped.activity.confirmedRunningCount == 2)
        #expect(skipped.members.runningCount == skipped.activity.confirmedRunningCount)
        #expect(Set(skipped.members.members.filter(\.counted).map { $0.task.session }) == Set(["s2", "s3"]))
        #expect(skipped.observations.contains {
            if case .decision(let value) = $0 { return value.identity.task.session == "s1" && value.reason == .readBudgetSkip && value.countedBefore && !value.countedAfter }; return false
        })
        // Diagnostics pass because the existing defect is explained. Count correctness is still false.
        #expect(latest?.confirmedRunningCount != sessions.count, "This test must not describe the preserved production count defect as correct")
        try f.append("token_count", to: files[0], date: Date())
        try await waitUntil { capture.allBatches().contains { $0.observations.contains {
            if case .decision(let value) = $0 { return value.identity.task.session == "s1" && value.reason == .missingStart && !value.accepted }; return false
        } } }
        #expect(latest?.confirmedRunningCount == 2)
        #expect(deliveries.contains { $0.0 == skipped.generation && $0.1 == skipped.sequence && $0.2 })
        #expect(capture.allBatches().allSatisfy { $0.members.members.filter(\.counted).count == $0.activity.confirmedRunningCount })
    }
    #endif

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(condition(), "Production observation did not converge within 3 seconds")
    }
    private func waitForWorker(_ condition: () -> Bool) {
        // Intentionally leave main delivery queued to test the production stale-generation guard.
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }
}
