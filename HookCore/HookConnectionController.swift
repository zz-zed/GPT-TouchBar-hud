import Foundation

public struct HookMeasurements: Sendable {
    public init() {}
    public var bytesRead = 0
    public var filesRead = 0
    public var reconciliations = 0
    public var hooksReceived = 0
}

/// Compatibility facade: Hook notifications only accelerate the same continuous engine.
public final class HookConnectionController {
    public var onDiagnosticSnapshot: ((UInt64, UInt64) -> Void)?
    public var onUpdate: ((TaskActivitySnapshot) -> Void)?
    public var onEngineSnapshot: ((TaskEngineSnapshot) -> Void)?
    public var onMeasurements: ((HookMeasurements) -> Void)?
    private let runtime: TaskEngineController
    public init(directory: URL = HookPaths.defaultDirectory,
                home: URL = TaskEngineController.defaultHome,
                checkpointURL: URL? = nil,
                sink: TaskObservationSink = TaskObservationRelay.shared) {
        runtime = TaskEngineController(home: home, mode: .hooks, directory: directory,
                                       checkpointURL: checkpointURL, sink: sink)
        runtime.onUpdate = { [weak self] snapshot in
            self?.onUpdate?(snapshot.activity)
        }
        runtime.onEngineSnapshot = { [weak self] in self?.onEngineSnapshot?($0) }
        runtime.onDiagnosticSnapshot = { [weak self] in self?.onDiagnosticSnapshot?($0, $1) }
        runtime.onMeasurements = { [weak self] in self?.onMeasurements?($0) }
    }
    public func start() { runtime.start() }
    public func stop() { runtime.stop() }
    public func suspend() { runtime.suspend() }
    public func resume() { runtime.resume() }
    public func hostUnavailable() { runtime.hostUnavailable() }
}
