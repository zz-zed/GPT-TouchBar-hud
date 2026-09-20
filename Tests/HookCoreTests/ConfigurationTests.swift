import Foundation
import Darwin
import Testing
@testable import HookCore

struct ConfigurationTests {
    @Test func mergeBackupReadbackCleanupAndRollback() throws {
        let f = try Fixture(); let target = f.root.appendingPathComponent("hooks.json")
        let original = Data("{\"description\":\"keep\",\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo keep\",\"timeout\":2}]}]}}".utf8)
        try HookPaths.atomicWrite(original, to: target)
        let helper = f.root.appendingPathComponent("space ' quote/HookEmitter")
        let socket = f.ipc.appendingPathComponent("events.sock")
        let plan = try HookConfiguration.plan(target: target, helper: helper, socket: socket)
        let backup = try #require(try HookConfiguration.apply(plan))
        #expect(try HookPaths.read(backup, maximum: 4096, privateOnly: true) == original)
        #expect(plan.ownedCommand.contains("'\\''"))
        let again = try HookConfiguration.plan(target: target, helper: helper, socket: socket)
        #expect(again.proposed == plan.proposed)
        try HookConfiguration.rollback(plan, backup: backup)
        #expect(try HookPaths.read(target, maximum: 4096) == original)
        _ = try HookConfiguration.apply(plan)
        let cleanup = try HookConfiguration.plan(target: target, helper: helper, socket: socket, removing: true)
        _ = try HookConfiguration.apply(cleanup)
        let decoded = try JSONSerialization.jsonObject(with: HookPaths.read(target, maximum: 4096)) as? NSDictionary
        #expect(decoded?.isEqual(try JSONSerialization.jsonObject(with: original)) == true)
    }
    @Test func preserveEditedDefinitionsAndRejectStalePlan() throws {
        let f = try Fixture(); let target = f.root.appendingPathComponent("hooks.json")
        let helper = f.root.appendingPathComponent("HookEmitter"), socket = f.ipc.appendingPathComponent("events.sock")
        let initial = try HookConfiguration.plan(target: target, helper: helper, socket: socket)
        _ = try HookConfiguration.apply(initial)
        let edited = String(decoding: initial.proposed, as: UTF8.self).replacingOccurrences(of: "\"timeout\" : 1", with: "\"timeout\" : 2")
        try HookPaths.atomicWrite(Data(edited.utf8), to: target)
        #expect(throws: HookFailure.self) { _ = try HookConfiguration.apply(initial) }
        #expect(throws: HookFailure.self) { _ = try HookConfiguration.plan(target: target, helper: helper, socket: socket) }
        let cleanup = try HookConfiguration.plan(target: target, helper: helper, socket: socket, removing: true)
        #expect(cleanup.proposed == Data(edited.utf8))
    }
    @Test func symlinksPermissionsAndHardlinksRejected() throws {
        let f = try Fixture(); let target = f.root.appendingPathComponent("hooks.json")
        let real = f.root.appendingPathComponent("real.json")
        try HookPaths.atomicWrite(Data("{}".utf8), to: real)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: real)
        #expect(throws: HookFailure.self) { _ = try HookConfiguration.plan(target: target, helper: f.root.appendingPathComponent("helper"), socket: f.ipc.appendingPathComponent("events.sock")) }
        #expect(throws: HookFailure.self) { try HookPaths.atomicWrite(Data("{}".utf8), to: target) }
        let linkDir = f.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: f.ipc)
        #expect(throws: HookFailure.self) { try HookPaths.ensurePrivateDirectory(linkDir) }
        chmod(f.ipc.path, 0o755)
        #expect(throws: HookFailure.self) { try HookPaths.ensurePrivateDirectory(f.ipc) }
        let hard = f.root.appendingPathComponent("hard.json"); try FileManager.default.linkItem(at: real, to: hard)
        #expect(throws: HookFailure.self) { _ = try HookPaths.read(real, maximum: 4096) }
    }
    @Test func unsupportedHostPreflightIsBoundedAndWritesNoUserConfig() throws {
        let f = try Fixture(); let runtime = f.root.appendingPathComponent("silent-runtime")
        try HookPaths.atomicWrite(Data("#!/bin/sh\nexec /bin/sleep 5\n".utf8), to: runtime, mode: 0o700)
        let target = f.root.appendingPathComponent("hooks.json")
        let plan = try HookConfiguration.plan(target: target, helper: f.root.appendingPathComponent("helper"), socket: f.ipc.appendingPathComponent("events.sock"))
        let started = ProcessInfo.processInfo.systemUptime
        #expect(throws: HookFailure.self) { _ = try HookHostPreflight.discover(runtime: runtime, plan: plan, timeout: 0.15) }
        #expect(ProcessInfo.processInfo.systemUptime - started < 0.7)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
    @Test func allowlistNeverForwardsConversationOrUnsupportedFields() throws {
        let data = Data("{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\",\"turn_id\":\"t1\",\"stop_hook_active\":true,\"prompt\":\"PRIVATE_PROMPT\",\"last_assistant_message\":\"PRIVATE_REPLY\",\"tool_input\":{\"cmd\":\"SECRET_TOOL\"},\"transcript_path\":\"/secret\"}".utf8)
        let event = try #require(HookEvent.sanitize(data))
        let wire = try JSONEncoder().encode(event)
        #expect(wire.count <= 4096)
        let text = String(decoding: wire, as: UTF8.self)
        #expect(!text.contains("PRIVATE") && !text.contains("SECRET") && !text.contains("secret"))
        #expect(event.continued)
        #expect(HookEvent.sanitize(Data(repeating: 32, count: 1_048_577)) == nil)
        #expect(HookEvent.sanitize(Data("{\"hook_event_name\":\"SubagentStop\",\"session_id\":\"s1\",\"turn_id\":\"t1\"}".utf8)) == nil)
        #expect(!HookEvent(kind: .stop, session: "../s", turn: "t").isValid)
    }
}
