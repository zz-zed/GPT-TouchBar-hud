import Foundation

public enum JournalDecodeIssue: String, Codable, Sendable {
    case malformedJSON, invalidUTF8, depthLimit, semanticLimit, invalidSemantic, duplicateField
}

public struct JournalEvent: Equatable, Codable, Sendable {
    public let type: String
    public let turnID: String
    public let timestamp: Date
    public init(type: String, turnID: String, timestamp: Date) {
        self.type = type; self.turnID = turnID; self.timestamp = timestamp
    }
}

public struct JournalSession: Equatable, Codable, Sendable {
    public let id: String
    public let source: String?
    public let isSubagent: Bool
    public init(id: String, source: String?, isSubagent: Bool) {
        self.id = id; self.source = source; self.isSubagent = isSubagent
    }
}

/// A complete JSONL record. Only allowlisted metadata survives decoding; ignored body
/// strings, object keys and values are validated without being retained.
public struct JournalRecord: Equatable, Sendable {
    public let startOffset: UInt64
    public let endOffset: UInt64
    public let event: JournalEvent?
    public let session: JournalSession?
    public let issue: JournalDecodeIssue?
}

/// Incremental JSON grammar/UTF-8 validation, independent of read block boundaries.
/// Memory is bounded by 256 container frames, a 4 KiB selected scalar and six selected
/// strings. Irrelevant keys retain at most 64 bytes; irrelevant values retain none.
/// A malformed record recovers at the next LF, never by searching for event text.
public struct LifecycleStreamDecoder {
    public static let maximumDepth = 256
    public static let maximumScalarBytes = 4096
    public private(set) var fetchedOffset: UInt64
    public private(set) var committedOffset: UInt64
    private var recordStart: UInt64
    private var parser = RecordParser()
    public init(offset: UInt64 = 0) {
        fetchedOffset = offset; committedOffset = offset; recordStart = offset
    }
    public var retainedByteCount: Int { parser.retainedByteCount }
    public mutating func consume(_ data: Data) -> [JournalRecord] {
        var records: [JournalRecord] = []
        for byte in data {
            fetchedOffset += 1
            if byte == 10 {
                let result = parser.finish()
                records.append(JournalRecord(startOffset: recordStart, endOffset: fetchedOffset,
                                             event: result.0, session: result.1, issue: result.2))
                committedOffset = fetchedOffset; recordStart = fetchedOffset; parser = RecordParser()
            } else { parser.feed(byte) }
        }
        return records
    }
}

private struct RecordParser {
    private enum Context { case root, payload, source, ignored }
    private enum Key: String { case type, timestamp, payload, turnID = "turn_id", id, source, subagent }
    private struct Frame {
        let object: Bool
        let context: Context
        // Object: 0 key/end, 1 key, 2 colon, 3 value, 4 comma/end.
        // Array: 0 value/end, 1 value, 4 comma/end.
        var phase: Int = 0
        var key: Key?
        var seen: Set<Key> = []
    }
    private enum Slot: Hashable { case recordType, timestamp, eventType, turnID, sessionID, source }
    private var frames: [Frame] = []
    private var rootStarted = false
    private var rootComplete = false
    private var issue: JournalDecodeIssue?
    private var semanticIssue: JournalDecodeIssue?
    private var fields: [Slot: String] = [:]
    private var subagent = false
    // Token: 0 none, 1 string, 2 number, 3 literal.
    private var token = 0
    private var keyString = false
    private var slot: Slot?
    private var stringBytes: [UInt8] = []
    private var capture = false
    private var keyOverflow = false
    private var escape = false
    private var unicodeDigits = 0
    private var unicodeValue: UInt32 = 0
    private var highSurrogate: UInt32?
    private var lowSurrogatePrefix = 0
    private var utf8Remaining = 0
    private var utf8Minimum: UInt8 = 0x80
    private var utf8Maximum: UInt8 = 0xbf
    private var numberState = 0
    private var literal: [UInt8] = []
    private var literalIndex = 0
    var retainedByteCount: Int { stringBytes.count + fields.values.reduce(0) { $0 + $1.utf8.count } }

    mutating func feed(_ byte: UInt8) {
        guard issue == nil else { return }
        if token == 1 { stringByte(byte); return }
        if token == 2 {
            if numberByte(byte) { return }
            guard issue == nil else { return }
        } else if token == 3 {
            if literalIndex < literal.count {
                guard byte == literal[literalIndex] else { fail(.malformedJSON); return }
                literalIndex += 1; return
            }
            guard isDelimiter(byte) else { fail(.malformedJSON); return }
            token = 0
        }
        if byte == 32 || byte == 9 || byte == 13 { return }
        guard !rootComplete else { fail(.malformedJSON); return }
        if !rootStarted {
            guard byte == 123 else { fail(.malformedJSON); return }
            rootStarted = true; frames.append(Frame(object: true, context: .root)); return
        }
        guard let frame = frames.last else { fail(.malformedJSON); return }
        if frame.object {
            switch frame.phase {
            case 0, 1:
                if byte == 125 && frame.phase == 0 { closeContainer(); return }
                guard byte == 34 else { fail(.malformedJSON); return }
                beginString(key: true, selected: nil)
            case 2:
                guard byte == 58 else { fail(.malformedJSON); return }
                frames[frames.count - 1].phase = 3
            case 3: beginValue(byte)
            default:
                if byte == 125 { closeContainer() }
                else if byte == 44 { frames[frames.count - 1].phase = 1; frames[frames.count - 1].key = nil }
                else { fail(.malformedJSON) }
            }
        } else {
            if frame.phase == 4 {
                if byte == 93 { closeContainer() }
                else if byte == 44 { frames[frames.count - 1].phase = 1 }
                else { fail(.malformedJSON) }
            } else if byte == 93 && frame.phase == 0 { closeContainer() }
            else { beginValue(byte) }
        }
    }
    mutating func finish() -> (JournalEvent?, JournalSession?, JournalDecodeIssue?) {
        if token == 2 {
            if ![1, 2, 4, 7].contains(numberState) { fail(.malformedJSON) }
            token = 0
        } else if token == 3 && literalIndex == literal.count { token = 0 }
        if token != 0 || !rootComplete || !frames.isEmpty { fail(.malformedJSON) }
        if let issue { return (nil, nil, issue) }
        guard let type = fields[.recordType] else { return (nil, nil, nil) }
        guard type == "event_msg" || type == "session_meta" else { return (nil, nil, nil) }
        if let semanticIssue { return (nil, nil, semanticIssue) }
        if type == "session_meta" {
            guard let id = fields[.sessionID], HookEvent.validID(id) else { return (nil, nil, .invalidSemantic) }
            return (nil, JournalSession(id: id, source: fields[.source], isSubagent: subagent), nil)
        }
        guard let eventType = fields[.eventType], TaskLifecyclePolicy.kind(for: eventType) != nil else { return (nil, nil, nil) }
        guard let turn = fields[.turnID], HookEvent.validID(turn), let timestamp = fields[.timestamp],
              let date = Self.date(timestamp) else { return (nil, nil, .invalidSemantic) }
        return (JournalEvent(type: eventType, turnID: turn, timestamp: date), nil, nil)
    }
    private static func date(_ value: String) -> Date? {
        // Reuse formatters on this synchronous worker thread. No formatter crosses a
        // thread or suspension point, and parsing many tiny records stays inexpensive.
        let storage = Thread.current.threadDictionary
        let fractionalKey = "GPTTouchBarHUD.JournalDateFormatter.fractional.v1"
        let wholeKey = "GPTTouchBarHUD.JournalDateFormatter.whole.v1"
        let fractional: ISO8601DateFormatter
        if let existing = storage[fractionalKey] as? ISO8601DateFormatter { fractional = existing }
        else {
            fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            storage[fractionalKey] = fractional
        }
        if let result = fractional.date(from: value) { return result }
        let whole: ISO8601DateFormatter
        if let existing = storage[wholeKey] as? ISO8601DateFormatter { whole = existing }
        else {
            whole = ISO8601DateFormatter(); whole.formatOptions = [.withInternetDateTime]
            storage[wholeKey] = whole
        }
        return whole.date(from: value)
    }
    private mutating func fail(_ value: JournalDecodeIssue) { if issue == nil { issue = value } }
    private func selectedSlot(_ frame: Frame) -> Slot? {
        switch (frame.context, frame.key) {
        case (.root, .type): return .recordType
        case (.root, .timestamp): return .timestamp
        case (.payload, .type): return .eventType
        case (.payload, .turnID): return .turnID
        case (.payload, .id): return .sessionID
        case (.payload, .source): return .source
        default: return nil
        }
    }
    private mutating func beginValue(_ byte: UInt8) {
        guard let frame = frames.last else { fail(.malformedJSON); return }
        let selected = selectedSlot(frame)
        var context = Context.ignored
        if frame.context == .root && frame.key == .payload {
            if byte != 123 { semanticIssue = .invalidSemantic }
            context = .payload
        } else if frame.context == .payload && frame.key == .source && byte == 123 { context = .source }
        if selected != nil && byte != 34 && !(selected == .source && byte == 123) { semanticIssue = .invalidSemantic }
        frames[frames.count - 1].phase = 4
        if byte == 123 || byte == 91 {
            guard frames.count < LifecycleStreamDecoder.maximumDepth else { fail(.depthLimit); return }
            frames.append(Frame(object: byte == 123, context: byte == 123 ? context : .ignored)); return
        }
        if byte == 34 { beginString(key: false, selected: selected); return }
        if byte == 45 || (48...57).contains(byte) {
            token = 2
            numberState = byte == 45 ? 0 : (byte == 48 ? 1 : 2)
            return
        }
        switch byte {
        case 116: literal = [116,114,117,101]
        case 102: literal = [102,97,108,115,101]
        case 110: literal = [110,117,108,108]
        default: fail(.malformedJSON); return
        }
        token = 3; literalIndex = 1
    }
    private mutating func closeContainer() {
        frames.removeLast()
        if frames.isEmpty { rootComplete = true }
    }
    private mutating func beginString(key: Bool, selected: Slot?) {
        token = 1; keyString = key; slot = selected; capture = key || selected != nil
        stringBytes = capture ? [34] : []; keyOverflow = false; escape = false
        unicodeDigits = 0; unicodeValue = 0; highSurrogate = nil; lowSurrogatePrefix = 0
        utf8Remaining = 0; utf8Minimum = 0x80; utf8Maximum = 0xbf
    }
    private mutating func stringByte(_ byte: UInt8) {
        if capture {
            let limit = keyString ? 66 : LifecycleStreamDecoder.maximumScalarBytes + 2
            if stringBytes.count < limit { stringBytes.append(byte) }
            else if keyString { keyOverflow = true; capture = false; stringBytes.removeAll(keepingCapacity: true) }
            else { semanticIssue = .semanticLimit; capture = false; stringBytes.removeAll(keepingCapacity: true) }
        }
        if utf8Remaining > 0 {
            guard byte >= utf8Minimum && byte <= utf8Maximum else { fail(.invalidUTF8); return }
            utf8Remaining -= 1; utf8Minimum = 0x80; utf8Maximum = 0xbf; return
        }
        if unicodeDigits > 0 {
            guard let hex = hexValue(byte) else { fail(.malformedJSON); return }
            unicodeValue = unicodeValue * 16 + hex; unicodeDigits -= 1
            if unicodeDigits == 0 {
                if highSurrogate != nil {
                    guard (0xdc00...0xdfff).contains(unicodeValue) else { fail(.malformedJSON); return }
                    highSurrogate = nil
                } else if (0xd800...0xdbff).contains(unicodeValue) {
                    highSurrogate = unicodeValue; lowSurrogatePrefix = 1
                } else if (0xdc00...0xdfff).contains(unicodeValue) { fail(.malformedJSON) }
            }
            return
        }
        if lowSurrogatePrefix > 0 {
            if lowSurrogatePrefix == 1 {
                guard byte == 92 else { fail(.malformedJSON); return }
                lowSurrogatePrefix = 2
            } else {
                guard byte == 117 else { fail(.malformedJSON); return }
                lowSurrogatePrefix = 0; unicodeDigits = 4; unicodeValue = 0
            }
            return
        }
        if escape {
            escape = false
            if byte == 117 { unicodeDigits = 4; unicodeValue = 0 }
            else if ![34,92,47,98,102,110,114,116].contains(byte) { fail(.malformedJSON) }
            return
        }
        if byte == 34 { finishString(); return }
        if byte == 92 { escape = true; return }
        guard byte >= 32 else { fail(.malformedJSON); return }
        if byte < 0x80 { return }
        switch byte {
        case 0xc2...0xdf: utf8Remaining = 1
        case 0xe0: utf8Remaining = 2; utf8Minimum = 0xa0
        case 0xe1...0xec, 0xee...0xef: utf8Remaining = 2
        case 0xed: utf8Remaining = 2; utf8Maximum = 0x9f
        case 0xf0: utf8Remaining = 3; utf8Minimum = 0x90
        case 0xf1...0xf3: utf8Remaining = 3
        case 0xf4: utf8Remaining = 3; utf8Maximum = 0x8f
        default: fail(.invalidUTF8)
        }
    }
    private mutating func finishString() {
        token = 0
        let value = capture ? (try? JSONSerialization.jsonObject(with: Data(stringBytes), options: .fragmentsAllowed)) as? String : nil
        if keyString {
            let key = !keyOverflow ? value.flatMap(Key.init(rawValue:)) : nil
            guard !frames.isEmpty else { fail(.malformedJSON); return }
            let index = frames.count - 1
            // Duplicate allowlisted keys are ambiguous regardless of field order.
            if let key, frames[index].context != .ignored {
                if !frames[index].seen.insert(key).inserted { semanticIssue = .duplicateField }
                if frames[index].context == .source && key == .subagent { subagent = true }
            }
            frames[index].key = key; frames[index].phase = 2
        } else if let slot, let value { fields[slot] = value }
        stringBytes.removeAll(keepingCapacity: true); slot = nil
    }
    private func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 48...57: return UInt32(byte - 48)
        case 65...70: return UInt32(byte - 55)
        case 97...102: return UInt32(byte - 87)
        default: return nil
        }
    }
    private func isDelimiter(_ byte: UInt8) -> Bool { [32,9,13,44,93,125].contains(byte) }
    /// Returns false only when a valid number ended before this delimiter.
    private mutating func numberByte(_ byte: UInt8) -> Bool {
        let digit = (48...57).contains(byte)
        switch numberState {
        case 0:
            if digit { numberState = byte == 48 ? 1 : 2; return true }
        case 1, 2:
            if digit && numberState == 2 { return true }
            if byte == 46 { numberState = 3; return true }
            if byte == 101 || byte == 69 { numberState = 5; return true }
        case 3:
            if digit { numberState = 4; return true }
        case 4:
            if digit { return true }
            if byte == 101 || byte == 69 { numberState = 5; return true }
        case 5:
            if byte == 43 || byte == 45 { numberState = 6; return true }
            if digit { numberState = 7; return true }
        case 6:
            if digit { numberState = 7; return true }
        default:
            if digit { return true }
        }
        guard [1,2,4,7].contains(numberState), isDelimiter(byte) else { fail(.malformedJSON); return true }
        token = 0; return false
    }
}
