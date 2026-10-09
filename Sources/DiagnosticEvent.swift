import Foundation

/// A closed event vocabulary. Never pass server errors, paths, titles, or identifiers here.
protocol DiagnosticRecording {
    var taskTraceState: DiagnosticTaskTraceState { get }
    func record(_ event: DiagnosticEvent)
    func record(_ event: DiagnosticEvent, expectedGeneration: UInt64)
}
extension DiagnosticRecording {
    var taskTraceState: DiagnosticTaskTraceState { .disabled }
    func record(_ event: DiagnosticEvent, expectedGeneration: UInt64) {
        let state = taskTraceState
        guard state.enabled, state.generation == expectedGeneration else { return }
        record(event)
    }
}

struct NoopDiagnosticRecorder: DiagnosticRecording {
    func record(_ event: DiagnosticEvent) {}
}

enum DiagnosticExitReason: String, Codable { case manual, hostExit, update, system }

enum DiagnosticLifecyclePhase: String, Codable {
    case launch, shutdownRequested, sleep, wake, sessionSuspended, sessionResumed
    case screenLocked, screenUnlocked, previousShutdownConfirmed, previousShutdownUnconfirmed
}
enum DiagnosticConnectionLayer: String, Codable { case transport, store }
enum DiagnosticConnectionSource: String, Codable { case business, check }
enum DiagnosticConnectionPhase: String, Codable {
    case runtime, start, initialize, request, timeout, exit, retry, recovered, staleCallback
}
enum DiagnosticRequestKind: String, Codable { case initialize, account, rateLimits, other, accountRead, rateLimitsRead, tokenUsageRead }
enum DiagnosticResult: String, Codable {
    case success, unknown, unavailable, missing, failed, timeout, cancelled, rejected, truncated
    case incompatible, skipped, empty, stale, permissionDenied, ioFailure, unsupported
    case malformedResponse, serverError, missingResult, timedOut, responseTooLarge, stopped
}
enum DiagnosticTaskStage: String, Codable {
    case index, indexCached, candidates, read, aggregate, mainAccepted, mainDiscarded, uiSubmitted, mode
    case monitorStarted, monitorStopped, explicitStart
    case lifecycle, hooks, homeDefault, homeEnvironment, homeCustom
    case candidateRejected, missingLifecycleEvidence, staleWithoutTerminal, hookCoverage
}
enum DiagnosticTaskMode: String, Codable { case disabled, logs, hooks, unknown, legacy }
enum DiagnosticDisplaySurface: String, Codable { case touchBar, notch, floating }
enum DiagnosticDisplayAction: String, Codable { case capability, request, hide, skipped, mode, window, layout }
enum DiagnosticDisplayMode: String, Codable { case touchBar, notch, floating, both, disabled, automatic, unknown }
enum DiagnosticDisplayReason: String, Codable {
    case noHardware, unknownHardware, incompatibleAPI, disabled, sleeping, sessionInactive
    case screenLocked, noScreen, noContent, alreadyVisible, hidden, unavailable, suppressed, unknown
    case notRunning, screenAsleep, interfaceUnavailable, geometryUnavailable, layoutUnusable, inactiveSpace, occluded
}
enum DiagnosticComponent: String, Codable { case autoLauncher, quitMarker, updateProgress, instanceLock }
enum DiagnosticGapReason: String, Codable {
    case queueFull, oversizedEvent, encodingFailure, writeFailure, corruptedLine, unsafeFile, unreadableFile
    case retentionLimit, recordingDisabled, storeUnavailable, lockBusy, staleEpoch, unknownProtocol, unknownEvent, upgradeLimit, sequenceGap
}

/// All payloads are fixed enums, numbers, and booleans. Unknown counts remain nil.
enum DiagnosticEvent: Codable {
    case lifecycle(DiagnosticLifecyclePhase)
    case exitRequested(reason: DiagnosticExitReason)
    case connection(source: DiagnosticConnectionSource = .business, phase: DiagnosticConnectionPhase,
                    generation: UInt64 = 0, request: DiagnosticRequestKind? = nil,
                    result: DiagnosticResult = .success, durationMilliseconds: Int? = nil,
                    retryCount: Int? = nil, delayMilliseconds: Int? = nil, exitStatus: Int? = nil, layer: DiagnosticConnectionLayer = .transport)
    case taskTrace(DiagnosticTaskTraceEvent)
    case task(stage: DiagnosticTaskStage, batch: UInt64? = nil, result: DiagnosticResult = .success,
              runningCount: Int? = nil, unknownCount: Int? = nil, candidateCount: Int? = nil,
              failureCount: Int? = nil, truncatedCount: Int? = nil, mode: DiagnosticTaskMode? = nil)
    case display(surface: DiagnosticDisplaySurface, action: DiagnosticDisplayAction,
                 result: DiagnosticResult = .success, mode: DiagnosticDisplayMode? = nil,
                 visible: Bool? = nil, reason: DiagnosticDisplayReason? = nil)
    case componentFailure(component: DiagnosticComponent, result: DiagnosticResult)
    case gap(reason: DiagnosticGapReason, count: Int)
    case upgrade(stage: DiagnosticUpgradeStage, result: DiagnosticResult)
    case moduleRecovery(module: DiagnosticRecoveryModule, state: DiagnosticRecoveryState, observation: DiagnosticRecoveryObservation)

    var module: String {
        switch self {
        case .lifecycle, .exitRequested: return "lifecycle"
        case .connection: return "connection"
        case .task, .taskTrace: return "task"
        case .display: return "display"
        case .componentFailure: return "component"
        case .gap: return "storage"
        case .upgrade: return "update"
        case .moduleRecovery: return "recovery"
        }
    }
    var severity: String {
        switch self {
        case .componentFailure, .gap: return "error"
        case .moduleRecovery(_, let state, _): return state == .failed ? "error" : "info"
        case .upgrade(_, let result): return [.failed, .timeout, .permissionDenied, .ioFailure, .unavailable].contains(result) ? "error" : "info"
        case .connection(_, _, _, _, let result, _, _, _, _, _),
             .task(_, _, let result, _, _, _, _, _, _),
             .display(_, _, let result, _, _, _):
            return [.failed, .timeout, .permissionDenied, .ioFailure, .timedOut, .serverError, .malformedResponse, .missingResult, .responseTooLarge, .unavailable].contains(result) ? "error" : "info"
        default: return "info"
        }
    }
    var aggregationIdentity: DiagnosticEvent {
        switch self {
        case .connection(let source, let phase, _, let request, let result, _, _, _, _, let layer):
            return .connection(source: source, phase: phase, request: request, result: result, layer: layer)
        case .task(let stage, _, let result, _, _, _, _, _, let mode):
            return .task(stage: stage, result: result, mode: mode)
        case .display(let surface, let action, let result, let mode, _, let reason):
            return .display(surface: surface, action: action, result: result, mode: mode, reason: reason)
        default: return self
        }
    }

    var flushImmediately: Bool {
        if case .lifecycle(.shutdownRequested) = self { return true }
        if case .exitRequested = self { return true }
        return severity == "error"
    }
}

struct DiagnosticEventEnvelope: Codable {
    let schemaVersion: Int
    let timestamp: Date
    let sessionID: UUID
    let sequence: UInt64
    let monotonicMilliseconds: UInt64
    let module: String
    let severity: String
    let event: DiagnosticEvent
    let repetition: DiagnosticEventRepetition?
    let updateSessionID: UUID?
    let writerRole: DiagnosticWriterRole?
    let eventID: DiagnosticEventID?
    let processIdentity: DiagnosticProcessIdentity?
    let upgradeSourceIdentity: DiagnosticProcessIdentity?
    let upgradeTargetIdentity: DiagnosticProcessIdentity?

    init(timestamp: Date, sessionID: UUID, sequence: UInt64, monotonicMilliseconds: UInt64,
         event: DiagnosticEvent, repetition: DiagnosticEventRepetition? = nil,
         updateSessionID: UUID? = nil, writerRole: DiagnosticWriterRole? = nil,
         eventID: DiagnosticEventID? = nil, processIdentity: DiagnosticProcessIdentity? = nil,
         upgradeSourceIdentity: DiagnosticProcessIdentity? = nil, upgradeTargetIdentity: DiagnosticProcessIdentity? = nil) {
        schemaVersion = 1
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.sequence = sequence
        self.monotonicMilliseconds = monotonicMilliseconds
        module = event.module
        severity = event.severity
        self.event = event
        self.repetition = repetition
        self.updateSessionID = updateSessionID; self.writerRole = writerRole
        self.eventID = eventID; self.processIdentity = processIdentity
        self.upgradeSourceIdentity = upgradeSourceIdentity; self.upgradeTargetIdentity = upgradeTargetIdentity
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct DiagnosticEventRepetition: Codable {
    let first: Date
    let last: Date
    let count: Int
}

enum DiagnosticGapUnit: String, Codable { case droppedEvents, unconfirmedEvents, occurrences }

extension DiagnosticGapReason {
    var unit: DiagnosticGapUnit {
        switch self {
        case .queueFull, .oversizedEvent, .encodingFailure: return .droppedEvents
        case .writeFailure: return .unconfirmedEvents
        default: return .occurrences
        }
    }
}

struct DiagnosticGap: Codable {
    let reason: DiagnosticGapReason
    let count: Int
    let first: Date
    let last: Date
    let unit: DiagnosticGapUnit
    init(reason: DiagnosticGapReason, count: Int, first: Date, last: Date) {
        self.reason = reason; self.count = count; self.first = first; self.last = last
        unit = reason.unit
    }
}

struct DiagnosticStoreSnapshot {
    let eventsData: Data
    let earliest: Date?
    let latest: Date?
    let droppedCount: Int
    let issues: [DiagnosticGapReason]
    let gaps: [DiagnosticGap]
    let generation: UInt64
    let isEnabled: Bool
    var truncatedUpdateIDs: [UUID] = []
}


// Upgrade protocol v1. Restricted values are validated again during decoding; unknown keys are discarded.
struct DiagnosticVersion: Codable, Equatable {
    let rawValue: String
    init?(rawValue: String) {
        guard rawValue.utf8.count <= 35,
              rawValue.range(of: #"^[0-9]{1,8}(\.[0-9]{1,8}){0,3}$"#, options: .regularExpression) != nil,
              !rawValue.contains("\n"), !rawValue.contains("\r") else { return nil }
        self.rawValue = rawValue
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let safe = Self(rawValue: value) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid version")) }
        self = safe
    }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}
struct DiagnosticBuild: Codable, Equatable {
    let rawValue: String
    init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 16, rawValue.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        self.rawValue = rawValue
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let safe = Self(rawValue: value) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid build")) }
        self = safe
    }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}
struct DiagnosticProcessIdentity: Codable, Equatable {
    let version: DiagnosticVersion?
    let build: DiagnosticBuild?
    /// Captured once, before an installer can replace the bundle at its path.
    static let current = Self(version: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(DiagnosticVersion.init),
                              build: (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(DiagnosticBuild.init))
}
struct DiagnosticEventID: Codable, Hashable {
    let sessionID: UUID
    let sequence: UInt64
}
enum DiagnosticWriterRole: String, Codable { case oldHUD, installer, progressHelper, newHUD, restoredHUD }
enum DiagnosticUpgradeStage: String, Codable {
    case handoffPrepared, exitRequested, exitFlushCompleted
    case oldProcessExitObserved, oldProcessExitTimedOut
    case backupStarted, backupSucceeded, backupFailed
    case replaceStarted, replaceSucceeded, replaceFailed
    case launchRequested, launchFailed, launchReceiptObserved, launchTimedOut
    case rollbackStarted, rollbackRestoreSucceeded, rollbackRestoreFailed
    case rollbackLaunchRequested, rollbackLaunchReceiptObserved, rollbackLaunchTimedOut, rollbackLaunchFailed, rollbackFailed
    case appStarted, continuationAccepted, continuationRejected, unfinishedHandoffObserved
    case progressHelperInstallerLost, progressHelperLateReceiptObserved, duplicateLaunchObserved
}
enum DiagnosticRecoveryModule: String, Codable { case connection, taskMonitor, taskRecognition, taskAggregation, mainDelivery, touchBar, notch, floating, host }
enum DiagnosticRecoveryState: String, Codable { case success, failed, disabled, unknown, notObserved }
enum DiagnosticRecoveryObservation: String, Codable { case hostRunning, hostNotRunning, afterRestart, monitoringStarted, indexRead, taskStartObserved, aggregateProduced, mainAccepted, displaySubmitted, hostSameProcess, hostChangedProcess, hostUnknown }
enum DiagnosticWriteResult: String, Codable { case persisted, disabled, staleEpoch, lockBusy, budgetExceeded, failed }
enum DiagnosticFlushResult: String, Codable { case persisted, partial, disabled, failed }
struct DiagnosticUpgradeHandoff: Codable, Equatable {
    let protocolVersion: Int
    let updateSessionID: UUID
    let sourceSessionID: UUID
    let sourceIdentity: DiagnosticProcessIdentity
    let targetIdentity: DiagnosticProcessIdentity
    let createdAt: Date
    let recordingEnabled: Bool
    let clearEpoch: UUID
    init(updateSessionID: UUID, sourceSessionID: UUID, sourceIdentity: DiagnosticProcessIdentity,
         targetIdentity: DiagnosticProcessIdentity, createdAt: Date, recordingEnabled: Bool, clearEpoch: UUID) {
        protocolVersion = 1; self.updateSessionID = updateSessionID; self.sourceSessionID = sourceSessionID
        self.sourceIdentity = sourceIdentity; self.targetIdentity = targetIdentity; self.createdAt = createdAt
        self.recordingEnabled = recordingEnabled; self.clearEpoch = clearEpoch
    }
}
