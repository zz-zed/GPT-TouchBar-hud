import Foundation
import Testing
@testable import HookCore

struct ControllerTests {
    @Test @MainActor func endToEndResumeStopContinuationAndRestart() async throws {
        let f = try Fixture(); let file = try f.log()
        let controller = HookConnectionController(directory: f.ipc, home: f.home)
        var latest: TaskActivitySnapshot?
        var reads: HookMeasurements?
        controller.onUpdate = { latest = $0 }; controller.onMeasurements = { reads = $0 }
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
        try await waitUntil { latest?.sourceHealth.first?.state == .awaitingEvents }
        #expect(latest?.confirmedRunningCount == 0)
        try f.append("task_complete", to: file, date: Date())
        try await waitUntil { latest?.recentlyCompletedCount == 1 }
        #expect(latest?.recentCompletions.first?.id != completion?.id)
        let terminal = latest?.recentCompletions
        // Allow the deliberately coalesced metadata cache write to finish before a restart.
        try await Task.sleep(nanoseconds: 180_000_000)
        controller.stop(); controller.start()
        try await waitUntil { latest?.recentCompletions == terminal && latest?.sourceHealth.first?.state == .awaitingEvents }
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
        try await waitUntil { latest?.sourceHealth.first?.state == .awaitingEvents }
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
