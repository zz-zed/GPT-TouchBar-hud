import Foundation
import Darwin
import CryptoKit

public struct JournalFileIdentity: Equatable, Codable, Sendable {
    public let device: UInt64
    public let inode: UInt64
}

/// Hash only, never source bytes. Anchors are fixed-size verification metadata.
public struct JournalBoundaryAnchor: Equatable, Codable, Sendable {
    public let offset: UInt64
    public let length: Int
    public let sha256: String
}

public struct JournalCheckpoint: Equatable, Codable, Sendable {
    public let version: Int
    public let path: String
    public let identity: JournalFileIdentity
    public let generation: UInt64
    public let committedOffset: UInt64
    public let observedLength: UInt64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let prefixAnchor: JournalBoundaryAnchor
    public let boundaryAnchor: JournalBoundaryAnchor
    public let sessionAnchor: JournalBoundaryAnchor?
    public let verifiedSession: JournalSession?
}

public enum JournalResetReason: String, Codable, Sendable {
    case rotated, truncated, rewritten, invalidCheckpoint
}

public struct JournalReadBatch: Sendable {
    public let records: [JournalRecord]
    public let fetchedOffset: UInt64
    public let committedOffset: UInt64
    public let targetEOF: UInt64
    public let backlogBytes: UInt64
    public let generation: UInt64
    public let resetReason: JournalResetReason?
    public let reachedTarget: Bool
    public let cancelled: Bool
    public let bytesRead: Int
    public let session: JournalSession?
}

/// Worker-confined continuous reader. A budget limits work, never changes lifecycle
/// or skips bytes. Persist checkpoint together with engine state in one transaction.
/// A checkpoint excludes the partial decoder; restart rereads from its last LF.
public final class TaskJournalReader {
    public static let chunkBytes = 32 * 1024
    public static let anchorBytes = 256
    public let home: URL
    public let path: URL
    public let expectedSessionID: String?
    private var resume: JournalCheckpoint?
    private struct State {
        var identity: JournalFileIdentity
        var generation: UInt64
        var decoder: LifecycleStreamDecoder
        var length: UInt64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var prefixAnchor: JournalBoundaryAnchor
        var fetchedAnchor: JournalBoundaryAnchor
        var boundaryAnchor: JournalBoundaryAnchor
        var sessionAnchor: JournalBoundaryAnchor?
        var session: JournalSession?
        var targetEOF: UInt64?
    }
    private var state: State?
    public init(home: URL, path: URL, expectedSessionID: String? = nil, resume: JournalCheckpoint? = nil) {
        self.home = home; self.path = path; self.expectedSessionID = expectedSessionID; self.resume = resume
    }
    public var fetchedOffset: UInt64 { state?.decoder.fetchedOffset ?? 0 }
    public var committedOffset: UInt64 { state?.decoder.committedOffset ?? 0 }
    public var generation: UInt64 { state?.generation ?? resume?.generation ?? 1 }
    public var retainedByteCount: Int { state?.decoder.retainedByteCount ?? 0 }

    public func read(byteBudget: Int = 256 * 1024, targetEOF: UInt64? = nil,
                     cancelled: () -> Bool = { false }) throws -> JournalReadBatch {
        guard byteBudget >= 0 else { throw HookFailure.budget }
        if cancelled() {
            let target = state?.targetEOF ?? targetEOF ?? fetchedOffset
            return batch(records: [], target: target, reset: nil, cancelled: true, bytes: 0)
        }
        try validatePath()
        let fd = try HookPaths.openRegular(path)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0 else { throw HookFailure.io }
        let identity = Self.identity(info), size = UInt64(info.st_size)
        var reset: JournalResetReason?
        var current: State
        if let existing = state {
            if existing.identity != identity { reset = .rotated }
            else if size < existing.decoder.fetchedOffset || size < existing.length { reset = .truncated }
            else if try (size == existing.length && !Self.sameModification(info, seconds: existing.modifiedSeconds, nanos: existing.modifiedNanoseconds))
                        || !matches(existing.prefixAnchor, fd: fd)
                        || !matches(existing.fetchedAnchor, fd: fd)
                        || !(existing.sessionAnchor.map { try matches($0, fd: fd) } ?? true) { reset = .rewritten }
            if reset != nil { current = try fresh(fd: fd, info: info, generation: existing.generation &+ 1) }
            else { current = existing }
        } else if let checkpoint = resume {
            if try valid(checkpoint, fd: fd, info: info) {
                current = State(identity: identity, generation: checkpoint.generation,
                                decoder: LifecycleStreamDecoder(offset: checkpoint.committedOffset), length: size,
                                modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                                prefixAnchor: checkpoint.prefixAnchor, fetchedAnchor: checkpoint.boundaryAnchor,
                                boundaryAnchor: checkpoint.boundaryAnchor, sessionAnchor: checkpoint.sessionAnchor,
                                session: checkpoint.verifiedSession, targetEOF: nil)
            } else {
                reset = .invalidCheckpoint
                current = try fresh(fd: fd, info: info, generation: checkpoint.generation &+ 1)
            }
        } else { current = try fresh(fd: fd, info: info, generation: 1) }
        // A changed file starts a new range; a stale caller target never constrains it.
        let target: UInt64
        if reset != nil { target = size }
        else { target = min(size, current.targetEOF ?? targetEOF ?? size) }
        guard target >= current.decoder.fetchedOffset else { throw HookFailure.changed }
        current.targetEOF = target
        var records: [JournalRecord] = []
        var bytesRead = 0
        var stopped = false
        while current.decoder.fetchedOffset < target && bytesRead < byteBudget {
            if cancelled() { stopped = true; break }
            let amount = Int(min(UInt64(min(Self.chunkBytes, byteBudget - bytesRead)), target - current.decoder.fetchedOffset))
            let data = try readAt(fd, offset: current.decoder.fetchedOffset, count: amount)
            guard !data.isEmpty else { throw HookFailure.changed }
            let decoded = current.decoder.consume(data)
            for record in decoded {
                if current.session == nil {
                    // Index identity must agree with the first physical record.
                    if let session = record.session,
                       expectedSessionID.map({ session.id == $0 }) ?? true,
                       record.startOffset == 0 {
                        current.session = session
                        current.sessionAnchor = try anchor(fd, end: record.endOffset)
                    } else if expectedSessionID != nil { throw HookFailure.malformed }
                } else if let session = record.session, session != current.session {
                    throw HookFailure.changed
                }
            }
            records.append(contentsOf: decoded); bytesRead += data.count
        }
        // Detect truncation or in-place writes during a read before publishing its bytes.
        var after = stat()
        guard fstat(fd, &after) == 0, Self.identity(after) == identity,
              after.st_size >= 0, UInt64(after.st_size) >= current.decoder.fetchedOffset,
              !(after.st_size == info.st_size && !Self.sameModification(after, seconds: Int64(info.st_mtimespec.tv_sec), nanos: Int64(info.st_mtimespec.tv_nsec)))
        else { throw HookFailure.changed }
        current.length = UInt64(after.st_size)
        current.modifiedSeconds = Int64(after.st_mtimespec.tv_sec)
        current.modifiedNanoseconds = Int64(after.st_mtimespec.tv_nsec)
        // Only bytes actually read become anchors. All rereads here are <= 256 bytes.
        current.prefixAnchor = try anchor(fd, end: min(current.decoder.fetchedOffset, UInt64(Self.anchorBytes)))
        current.fetchedAnchor = try anchor(fd, end: current.decoder.fetchedOffset)
        current.boundaryAnchor = try anchor(fd, end: current.decoder.committedOffset)
        if current.decoder.fetchedOffset == target { current.targetEOF = nil }
        state = current; resume = nil
        return batch(records: records, target: target, reset: reset, cancelled: stopped, bytes: bytesRead)
    }

    /// No I/O: fixed-size anchors were captured with the corresponding decoded state.
    public func checkpoint() throws -> JournalCheckpoint? {
        guard let current = state, current.decoder.committedOffset > 0,
              expectedSessionID == nil || current.session != nil else { return nil }
        return JournalCheckpoint(version: 1, path: path.path, identity: current.identity, generation: current.generation,
                                 committedOffset: current.decoder.committedOffset, observedLength: current.length,
                                 modifiedSeconds: current.modifiedSeconds, modifiedNanoseconds: current.modifiedNanoseconds,
                                 prefixAnchor: current.prefixAnchor, boundaryAnchor: current.boundaryAnchor,
                                 sessionAnchor: current.sessionAnchor, verifiedSession: current.session)
    }
    private func batch(records: [JournalRecord], target: UInt64, reset: JournalResetReason?, cancelled: Bool, bytes: Int) -> JournalReadBatch {
        JournalReadBatch(records: records, fetchedOffset: fetchedOffset, committedOffset: committedOffset,
                         targetEOF: target, backlogBytes: target > fetchedOffset ? target - fetchedOffset : 0,
                         generation: generation, resetReason: reset, reachedTarget: fetchedOffset >= target,
                         cancelled: cancelled, bytesRead: bytes, session: state?.session)
    }
    private func validatePath() throws {
        let parts = try HookPaths.components(path)
        let root = try HookPaths.components(home)
        guard parts.count > root.count + 1, Array(parts.prefix(root.count)) == root,
              ["sessions", "archived_sessions"].contains(parts[root.count]), path.path.hasSuffix(".jsonl"),
              expectedSessionID.map(HookEvent.validID) ?? true else { throw HookFailure.unsafePath }
    }
    private func fresh(fd: Int32, info: stat, generation: UInt64) throws -> State {
        let empty = try anchor(fd, end: 0)
        return State(identity: Self.identity(info), generation: max(1, generation), decoder: LifecycleStreamDecoder(),
                     length: UInt64(info.st_size), modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                     modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec), prefixAnchor: empty, fetchedAnchor: empty,
                     boundaryAnchor: empty, sessionAnchor: nil, session: nil, targetEOF: nil)
    }
    private func valid(_ value: JournalCheckpoint, fd: Int32, info: stat) throws -> Bool {
        guard value.version == 1, value.path == path.path, value.identity == Self.identity(info), value.generation > 0,
              value.committedOffset > 0, value.committedOffset <= UInt64(info.st_size),
              value.observedLength >= value.committedOffset, value.observedLength <= UInt64(info.st_size),
              (0...Self.anchorBytes).contains(value.boundaryAnchor.length),
              value.boundaryAnchor.offset <= UInt64.max - UInt64(value.boundaryAnchor.length),
              value.boundaryAnchor.offset + UInt64(value.boundaryAnchor.length) == value.committedOffset,
              value.prefixAnchor.offset == 0,
              expectedSessionID.map({ value.verifiedSession?.id == $0 }) ?? true,
              UInt64(info.st_size) != value.observedLength || Self.sameModification(info, seconds: value.modifiedSeconds, nanos: value.modifiedNanoseconds)
        else { return false }
        guard try matches(value.prefixAnchor, fd: fd), try matches(value.boundaryAnchor, fd: fd),
              try value.sessionAnchor.map({ try matches($0, fd: fd) }) ?? true else { return false }
        let last = try readAt(fd, offset: value.committedOffset - 1, count: 1)
        return last.first == 10
    }
    private static func identity(_ info: stat) -> JournalFileIdentity {
        JournalFileIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
    }
    private static func sameModification(_ info: stat, seconds: Int64, nanos: Int64) -> Bool {
        Int64(info.st_mtimespec.tv_sec) == seconds && Int64(info.st_mtimespec.tv_nsec) == nanos
    }
    private func anchor(_ fd: Int32, end: UInt64) throws -> JournalBoundaryAnchor {
        let length = Int(min(end, UInt64(Self.anchorBytes)))
        let offset = end - UInt64(length)
        let data = try readAt(fd, offset: offset, count: length)
        guard data.count == length else { throw HookFailure.changed }
        return JournalBoundaryAnchor(offset: offset, length: length, sha256: Self.digest(data))
    }
    private func matches(_ value: JournalBoundaryAnchor, fd: Int32) throws -> Bool {
        guard (0...Self.anchorBytes).contains(value.length), value.sha256.count == 64,
              value.offset <= UInt64(Int64.max) - UInt64(value.length) else { return false }
        let data = try readAt(fd, offset: value.offset, count: value.length)
        return data.count == value.length && Self.digest(data) == value.sha256
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func readAt(_ fd: Int32, offset: UInt64, count: Int) throws -> Data {
        guard offset <= UInt64(Int64.max), count >= 0 else { throw HookFailure.io }
        if count == 0 { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        var result: Int
        repeat { result = pread(fd, &bytes, count, off_t(offset)) } while result < 0 && errno == EINTR
        guard result >= 0 else { throw HookFailure.io }
        return Data(bytes.prefix(result))
    }
}
