import AppKit
import HookCore

/// Real production monitoring, main delivery, view consumption and frozen export.
/// Windows are never presented; physical display remains explicitly unverified.
final class TracePipelineHarness {
    let root: URL
    let home: URL
    let recorder: DiagnosticRecorder
    let coordinator: TaskMonitoringCoordinator
    let hooks: HookConnectionController
    private let exporter: DiagnosticExportCoordinator
    private let touchBar: TouchBarRateLimitsView
    private let floating: CompactQuotaHUDView
    private let notch: NotchPresentationModel
    private let menu: NSStatusItem
    private let mainTrace: DiagnosticTaskDisplayObserver
    private let menuTrace: DiagnosticTaskDisplayObserver
    private let feedback = TaskCompletionFeedbackController()
    private var latestReference: DiagnosticTaskSnapshotReference?
    private var revision: UInt64 = 0
    private(set) var latest: TaskStatusSummary?
    private(set) var deliveries = 0
    private(set) var state = RateLimitDisplayState.initial
    var tasksEnabled = true

    init(root: URL) throws {
        _ = NSApplication.shared
        self.root = root.resolvingSymlinksInPath()
        home = self.root.appendingPathComponent("fixture-home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var config = DiagnosticRecorder.Configuration()
        config.flushDelay = 0.02
        config.aggregationWindow = 0
        recorder = DiagnosticRecorder(directory: self.root.appendingPathComponent("diagnostics"), configuration: config)
        recorder.start()
        let legacy = TaskStatusMonitor(home: home, diagnostics: recorder,
            scheduling: .init(pollInterval: 0.05, discoveryInterval: 0.15))
        hooks = HookConnectionController(directory: home.appendingPathComponent("ipc"), home: home)
        coordinator = TaskMonitoringCoordinator(legacy: legacy, hooks: hooks, diagnostics: recorder)
        exporter = DiagnosticExportCoordinator(recorder: recorder)
        touchBar = TouchBarRateLimitsView(diagnostics: recorder, consumer: .touchBarPersistent)
        floating = CompactQuotaHUDView(initialAppearance: .load(), onRefresh: {}, onClose: {}, contextMenuProvider: { NSMenu() }, diagnostics: recorder)
        notch = NotchPresentationModel(diagnostics: recorder)
        menu = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.isVisible = false
        mainTrace = DiagnosticTaskDisplayObserver(recorder, surface: .main, consumer: .main)
        menuTrace = DiagnosticTaskDisplayObserver(recorder, surface: .menuBar, consumer: .menuBar)
        coordinator.onDiagnosticSnapshot = { [weak self] reference in
            self?.latestReference = reference; self?.latest?.diagnosticSnapshot = reference
        }
        coordinator.onUpdate = { [weak self] summary in
            guard let self else { return }
            self.latest = summary; self.deliveries += 1
            if summary != nil { self.latestReference = summary?.diagnosticSnapshot }
            self.feedback.receive(summary, enabled: self.tasksEnabled)
            self.render(reason: .update)
            self.coordinator.recordDisplaySubmission()
        }
        feedback.onExpiration = { [weak self] in
            guard let self else { return }
            self.revision &+= 1; self.render(reason: .completionFeedbackExpired)
        }
    }
    func start(hooks: Bool) { coordinator.start(displayEnabled: true, experimental: hooks) }
    func stop() { coordinator.stop(); feedback.reset() }
    func pump(_ seconds: TimeInterval = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    func render(reason: DiagnosticTaskConsumptionReason = .quotaRefresh) {
        state = .initial
        state.taskStatus = tasksEnabled ? feedback.applying(to: latest) : nil
        state.taskTrace = .init(reference: latestReference, tasksEnabled: tasksEnabled,
            presentationRevision: revision, reason: reason)
        mainTrace.record(state, action: reason == .completionFeedbackExpired ? .presentationRevised : .received)
        touchBar.update(with: state); floating.update(with: state); notch.update(state, tasksEnabled: tasksEnabled)
        MenuBarPresentation(state: state, mode: .icon, panelVisible: false).apply(to: menu, taskTrace: menuTrace)
    }
    func export(name: String) throws -> (snapshot: DiagnosticExportSnapshot, zip: URL, events: [DiagnosticEventEnvelope]) {
        let result: Result<DiagnosticExportSnapshot, DiagnosticExportError> = wait {
            exporter.preview(request: .init(range: .all), report: nil, completion: $0)
        }
        let snapshot = try result.get()
        let zip = root.appendingPathComponent(name + ".zip")
        let saved: Result<Void, DiagnosticExportError> = wait { exporter.save(snapshot, to: zip, completion: $0) }
        try saved.get()
        let bytes = try Self.extract(zip, member: "events.jsonl")
        precondition(bytes == snapshot.files.first(where: { $0.name == "events.jsonl" })!.data, "ZIP must equal frozen preview")
        let decoder = DiagnosticEventEnvelope.decoder()
        let events = try bytes.split(separator: 10).map { try decoder.decode(DiagnosticEventEnvelope.self, from: Data($0)) }
        return (snapshot, zip, events)
    }
    func wait<T>(_ operation: (@escaping (T) -> Void) -> Void) -> T {
        var value: T?
        operation { value = $0 }
        let deadline = Date().addingTimeInterval(15)
        while value == nil && Date() < deadline { pump(0.002) }
        precondition(value != nil, "Bounded pipeline callback timed out")
        return value!
    }
    static func extract(_ zip: URL, member: String) throws -> Data {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zip.path, member]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); precondition(process.terminationStatus == 0, "Independent unzip must read frozen member")
        return data
    }
    deinit { coordinator.stop(); feedback.reset(); NSStatusBar.system.removeStatusItem(menu) }
}
