import Foundation
import Testing
@testable import HookCore

struct ControllerTests {
    @Test @MainActor func acceptedStartPrecedesItsSnapshot() async throws {
        let f = try Fixture(); let file = try f.log()
        let controller = HookConnectionController(directory: f.ipc, home: f.home)
        var latest: TaskActivitySnapshot?
        var starts = 0
        var startPrecededSnapshot = false
        controller.onTaskStartObserved = { starts += 1 }
        controller.onUpdate = { snapshot in
            if snapshot.confirmedRunningCount > 0 { startPrecededSnapshot = starts == 1 }
            latest = snapshot
        }
        controller.start(); defer { controller.stop() }
        try await waitUntil { latest != nil }
        #expect(HookEmitter.send(HookEvent(kind: .submitted, session: "s1", turn: "t1"), socketURL: f.ipc.appendingPathComponent("events.sock")))
        try f.append("task_started", to: file, date: Date())
        try await waitUntil { latest?.confirmedRunningCount == 1 }
        #expect(starts == 1)
        #expect(startPrecededSnapshot)
    }
    @Test @MainActor func endToEndResumeStopContinuationAndRestart() async throws {
        let f = try Fixture(); let file = try f.log()
        let controller = HookConnectionController(directory: f.ipc, home: f.home)
        var latest: TaskActivitySnapshot?
        var latestEngine: TaskEngineSnapshot?
        var reads: HookMeasurements?
        controller.onUpdate = { latest = $0 }; controller.onMeasurements = { reads = $0 }
        controller.onEngineSnapshot = { latestEngine = $0 }
        controller.start(); defer { controller.stop() }
        try await waitUntil { latest != nil }
        #expect(latest?.compactText == "—")
        #expect(HookEmitter.send(HookEvent(kind: .submitted, session: "s1", turn: "t1"), socketURL: f.ipc.appendingPathComponent("events.sock")))
        try f.append("task_started", to: file, date: Date())
        try await waitUntil { latest?.confirmedRunningCount == 1 }
        #expect(latest?.compactText == "1 ?")
        #expect(HookEmitter.send(HookEvent(kind: .stop, session: "s1", turn: "t1"), socketURL: f.ipc.appendingPathComponent("events.sock")))
        try f.append("task_complete", to: file, date: Date())
        try await waitUntil { latest?.recentlyCompletedCount == 1 }
        let completion = latest?.recentCompletions.first
        #expect(latest?.showsCompletion == false)
        try f.append("task_started", to: file, date: Date())
        try await waitUntil { latest?.confirmedRunningCount == 1 }
        #expect(latest?.recentlyCompletedCount == 0)
        controller.suspend()
        try await waitUntil { latest?.sourceHealth.first?.state == .suspended }
        #expect(latest?.confirmedRunningCount == 0)
        controller.resume()
        // Health now describes the shared continuous log source, not receipt of an
        // optional Hook. A restored active record is still pending verification.
        try await waitUntil { latest?.sourceHealth.first?.state == .connected }
        #expect(latest?.confirmedRunningCount == 0)
        try f.append("task_complete", to: file, date: Date())
        try await waitUntil { latestEngine?.records[TaskIdentity(session: "s1")]?.phase == .completed }
        #expect(latest?.recentlyCompletedCount == 0)
        #expect(latest?.recentCompletions.isEmpty == true, "Recovery may confirm terminal history but must not replay completion feedback")
        #expect(completion != nil, "The earlier live-generation completion was observed")
        let terminal = latest?.recentCompletions
        // Allow the deliberately coalesced metadata cache write to finish before a restart.
        try await Task.sleep(nanoseconds: 180_000_000)
        controller.stop(); controller.start()
        try await waitUntil { latest?.recentCompletions == terminal && latest?.sourceHealth.first?.state == .connected }
        #expect(latest?.confirmedRunningCount == 0)
        #expect((reads?.bytesRead ?? .max) < HookBudget.recoveryBytes)
    }
    @Test @MainActor func missingLogAfterActivityBecomesUnknownAndStopDropsCallbacks() async throws {
        let f = try Fixture(); let file = try f.log()
        let controller = HookConnectionController(directory: f.ipc, home: f.home)
        var latest: TaskActivitySnapshot?; var deliveries = 0
        controller.onUpdate = { latest = $0; deliveries += 1 }
        controller.start(); defer { controller.stop() }
        try await waitUntil { latest != nil }
        try f.append("task_started", to: file, date: Date())
        try await waitUntil { latest?.confirmedRunningCount == 1 }
        try FileManager.default.removeItem(at: file)
        try await waitUntil { latest?.confirmedRunningCount == 0 }
        #expect(latest?.compactText == "—")
        #expect(latest?.recentlyCompletedCount == 0)
        controller.stop(); let count = deliveries
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(deliveries == count)
    }
    @Test @MainActor func hostLossCannotBeRevivedByOldWorkOrDelayedAppend() async throws {
        let f = try Fixture(); let file = try f.log()
        let controller = HookConnectionController(directory: f.ipc, home: f.home)
        var latest: TaskActivitySnapshot?
        controller.onUpdate = { latest = $0 }; controller.start(); defer { controller.stop() }
        try await waitUntil { latest != nil }
        try f.append("task_started", to: file, date: Date())
        try await waitUntil { latest?.confirmedRunningCount == 1 }
        controller.hostUnavailable()
        try await waitUntil { latest?.sourceHealth.first?.state == .unavailable }
        try f.append("task_started", turn: "t2", to: file, date: Date())
        _ = HookEmitter.send(HookEvent(kind: .submitted, session: "s1", turn: "t2"), socketURL: f.ipc.appendingPathComponent("events.sock"))
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(latest?.confirmedRunningCount == 0)
        #expect(latest?.sourceHealth.first?.state == .unavailable)
        controller.resume()
        try await waitUntil { latest?.sourceHealth.first?.state == .connected }
        #expect(latest?.confirmedRunningCount == 0)
        try f.append("task_started", turn: "t3", to: file, date: Date())
        try await waitUntil { latest?.confirmedRunningCount == 1 }
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(condition(), "State did not converge within 2 seconds")
    }
}
