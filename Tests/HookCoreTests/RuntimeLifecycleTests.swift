import Foundation
import Testing
@testable import HookCore

struct RuntimeLifecycleTests {
    @MainActor private func eventually(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<150 {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @Test @MainActor func immediateStartSuspendAndResumeRemainOperational() async throws {
        let fixture = try Fixture(); let path = try fixture.log()
        let controller = TaskEngineController(home: fixture.home, mode: .legacy)
        var snapshots: [TaskEngineSnapshot] = []
        controller.onUpdate = { snapshots.append($0) }
        defer { controller.stop() }
        controller.start()
        controller.suspend()
        #expect(try await eventually { snapshots.last?.activity.sourceHealth.first?.state == .suspended })
        controller.resume()
        #expect(try await eventually { snapshots.last?.activity.sourceHealth.first?.state == .connected })
        try fixture.append("task_started", to: path, date: Date())
        #expect(try await eventually { snapshots.last?.runningIDs == [TaskIdentity(session: "s1")] })
        #expect(snapshots.allSatisfy { $0.generation > 0 })
    }

    @Test @MainActor func immediateStartHostLossAndRapidRestartUseLatestGeneration() async throws {
        let fixture = try Fixture(); let path = try fixture.log()
        let controller = TaskEngineController(home: fixture.home, mode: .legacy)
        var snapshots: [TaskEngineSnapshot] = []
        controller.onUpdate = { snapshots.append($0) }
        defer { controller.stop() }
        controller.start()
        controller.hostUnavailable()
        #expect(try await eventually { snapshots.last?.activity.sourceHealth.first?.state == .unavailable })
        let pausedGeneration = snapshots.last?.generation ?? 0
        controller.resume()
        controller.stop()
        controller.start()
        #expect(try await eventually { (snapshots.last?.generation ?? 0) > pausedGeneration && snapshots.last?.activity.sourceHealth.first?.state == .connected })
        let restartedGeneration = snapshots.last?.generation ?? 0
        try fixture.append("task_started", to: path, date: Date())
        #expect(try await eventually { snapshots.last?.runningIDs == [TaskIdentity(session: "s1")] })
        #expect(snapshots.last?.generation == restartedGeneration)
        controller.stop()
        let delivered = snapshots.count
        try fixture.append("task_complete", to: path, date: Date())
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(snapshots.count == delivered)
    }
}
