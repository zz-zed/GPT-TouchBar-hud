import Foundation
import Darwin

/// A closed bridge for the source executable copied into the private update channel.
/// It never accepts a diagnostics output path, starts a HUD recorder, or reads the replaced app.
enum DiagnosticInstallerBridge {
    static let argument = "--record-update-diagnostic"
    private static let preparedLock = NSLock()
    private static var activeHandoff: DiagnosticUpgradeHandoff?
    static var preparedHandoff: DiagnosticUpgradeHandoff? {
        preparedLock.lock(); defer { preparedLock.unlock() }
        return activeHandoff
    }

    struct Bootstrap: Codable {
        let handoff: DiagnosticUpgradeHandoff
        let installerSessionID: UUID
    }

    private static func matches(_ identity: DiagnosticProcessIdentity, version: String) -> Bool {
        guard let identityVersion = identity.version, let current = AppVersion(identityVersion.rawValue),
              let expected = AppVersion(version) else { return false }
        return current == expected
    }

    static func prepare(handoff: DiagnosticUpgradeHandoff, channel: AppUpdateProgressChannel,
                        expectedSourceIdentity: DiagnosticProcessIdentity,
                        diagnosticDirectory: URL = DiagnosticStore.defaultDirectory) throws {
        guard handoff.updateSessionID.uuidString == channel.context.sessionID,
              handoff.sourceIdentity == expectedSourceIdentity,
              matches(handoff.sourceIdentity, version: channel.context.sourceVersion),
              matches(handoff.targetIdentity, version: channel.context.targetVersion),
              (try? AppUpdateProgressChannel.load(directory: channel.directory,
                 sessionID: channel.context.sessionID)) != nil else { throw AppUpdateProgressChannel.ChannelError.invalid }
        try channel.write(Bootstrap(handoff: handoff, installerSessionID: UUID()), name: "diagnostic-handoff.json")
        let metadata = try DiagnosticUpgradePrivateMetadata(channelDirectory: channel.directory,
            targetPath: URL(fileURLWithPath: channel.context.targetPath))
        try? DiagnosticProcessStore(directory: diagnosticDirectory).saveCandidate(
            DiagnosticUpgradeCandidate(handoff: handoff, metadata: metadata))
        preparedLock.lock(); activeHandoff = handoff; preparedLock.unlock()
    }

    static func protectedBootstrap(channel: AppUpdateProgressChannel) -> Bootstrap? {
        guard (try? AppUpdateProgressChannel.load(directory: channel.directory, sessionID: channel.context.sessionID))?.context == channel.context else { return nil }
        let file = channel.directory.appendingPathComponent("diagnostic-handoff.json")
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 16_384 else { return nil }
        var data = Data(count: Int(info.st_size))
        let bytesRead = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard bytesRead == data.count,
              let value = try? JSONDecoder().decode(Bootstrap.self, from: data),
              value.handoff.protocolVersion == 1,
              value.handoff.updateSessionID.uuidString == channel.context.sessionID,
              matches(value.handoff.sourceIdentity, version: channel.context.sourceVersion),
              matches(value.handoff.targetIdentity, version: channel.context.targetVersion)
        else { return nil }
        return value
    }

    private static func sameHandoff(_ lhs: DiagnosticUpgradeHandoff, _ rhs: DiagnosticUpgradeHandoff) -> Bool {
        // The private registry uses ISO8601 seconds; the channel preserves Date precision.
        lhs.protocolVersion == rhs.protocolVersion && lhs.updateSessionID == rhs.updateSessionID &&
        lhs.sourceSessionID == rhs.sourceSessionID && lhs.clearEpoch == rhs.clearEpoch &&
        lhs.sourceIdentity == rhs.sourceIdentity && lhs.targetIdentity == rhs.targetIdentity &&
        lhs.recordingEnabled == rhs.recordingEnabled && abs(lhs.createdAt.timeIntervalSince(rhs.createdAt)) < 1
    }

    /// Missing arguments use only registered source handoffs, never a directory scan or newest-version guess.
    static func uniquePendingChannel(target: URL, identity: DiagnosticProcessIdentity, now: Date = Date(),
                                     diagnosticDirectory: URL = DiagnosticStore.defaultDirectory) -> AppUpdateProgressChannel? {
        let target = target.standardizedFileURL
        guard target.resolvingSymlinksInPath() == target,
              let candidates = try? DiagnosticProcessStore(directory: diagnosticDirectory, now: { now }).candidates() else { return nil }
        let channels = candidates.compactMap { candidate -> AppUpdateProgressChannel? in
            guard candidate.metadata.targetPath == target.path,
                  let channel = try? AppUpdateProgressChannel.load(directory: URL(fileURLWithPath: candidate.metadata.channelDirectory),
                      sessionID: candidate.handoff.updateSessionID.uuidString),
                  channel.context.targetPath == target.path,
                  let bootstrap = protectedBootstrap(channel: channel), sameHandoff(bootstrap.handoff, candidate.handoff),
                  now.timeIntervalSince(candidate.handoff.createdAt) >= -300,
                  now.timeIntervalSince(candidate.handoff.createdAt) <= 72 * 60 * 60,
                  let state = channel.readValue("install.json", as: AppUpdateProgress.self),
                  state.sessionID == channel.context.sessionID,
                  ![.succeeded, .canceled].contains(state.phase) else { return nil }
            let expected: DiagnosticProcessIdentity
            switch state.step {
            case .launching: expected = candidate.handoff.targetIdentity
            case .restoring, .waitingForExit, .backingUp, .replacing: expected = candidate.handoff.sourceIdentity
            default: return nil
            }
            guard expected == identity, identity.version != nil else { return nil }
            return channel
        }
        return channels.count == 1 ? channels[0] : nil
    }

    /// Called before the existing helper/NSApplication entry. Only tests inject a directory.
    static func recordIfRequested(arguments: [String], executableURL: URL? = Bundle.main.executableURL,
                                  diagnosticDirectory: URL = DiagnosticStore.defaultDirectory) -> Bool {
        guard arguments.count > 1, arguments[1] == argument else { return false }
        guard arguments.count == 6,
              let sequence = UInt64(arguments[5]), sequence > 0, sequence <= 64,
              let stage = DiagnosticUpgradeStage(rawValue: arguments[4]), installerStages.contains(stage),
              let channel = try? AppUpdateProgressChannel.load(directory: URL(fileURLWithPath: arguments[2]), sessionID: arguments[3]),
              executableURL?.standardizedFileURL == channel.directory.appendingPathComponent("progress-helper"),
              let bootstrap = protectedBootstrap(channel: channel),
              let writer = try? DiagnosticUpgradeWriter.bootstrapFromProtectedHandoff(bootstrap.handoff,
                role: .installer, identity: bootstrap.handoff.sourceIdentity,
                directory: diagnosticDirectory, writerSessionID: bootstrap.installerSessionID) else { return true }
        _ = writer.record(stage: stage, result: result(for: stage), sequence: sequence)
        return true
    }

    static func result(for stage: DiagnosticUpgradeStage) -> DiagnosticResult {
        switch stage {
        case .oldProcessExitTimedOut, .launchTimedOut, .rollbackLaunchTimedOut: return .timeout
        case .backupFailed, .replaceFailed, .launchFailed, .rollbackRestoreFailed, .rollbackLaunchFailed, .rollbackFailed: return .failed
        case .progressHelperInstallerLost: return .unavailable
        default: return .success
        }
    }

    static let installerStages: Set<DiagnosticUpgradeStage> = [
        .oldProcessExitObserved, .oldProcessExitTimedOut,
        .backupStarted, .backupSucceeded, .backupFailed,
        .replaceStarted, .replaceSucceeded, .replaceFailed,
        .launchRequested, .launchFailed, .launchReceiptObserved, .launchTimedOut,
        .rollbackStarted, .rollbackRestoreSucceeded, .rollbackRestoreFailed,
        .rollbackLaunchRequested, .rollbackLaunchReceiptObserved, .rollbackLaunchTimedOut,
        .rollbackLaunchFailed, .rollbackFailed
    ]
}
