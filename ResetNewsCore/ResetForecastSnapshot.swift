import Foundation

/// A successfully decoded null signal means no current preview. A missing or malformed signal is an error.
public struct ResetForecastSnapshot: Codable, Equatable, Sendable {
    public var updatedAt: Date
    public var lastResetAt: Date?
    public var officialSignal: ResetForecastSignal?

    public init(updatedAt: Date, lastResetAt: Date?, officialSignal: ResetForecastSignal?) {
        self.updatedAt = updatedAt
        self.lastResetAt = lastResetAt
        self.officialSignal = officialSignal
    }

    public func item(now: Date, calendar: Calendar = .current) -> ResetNewsItem? {
        // A recent confirmed reset does not retire an unrelated future arrangement.
        officialSignal?.item(now: now, calendar: calendar)
    }

    public var notificationKey: String? { officialSignal?.notificationKey }
}

/// The source's current official signal, with original post identity and timing provenance.
public struct ResetForecastSignal: Codable, Equatable, Sendable {
    public var sourceID: String
    public var sourceURL: URL
    public var originalText: String
    public var publishedAt: Date
    public var officialWindow: ResetNewsOfficialWindow?
    public var effectiveAt: Date?

    public init(sourceID: String, sourceURL: URL, originalText: String, publishedAt: Date,
                officialWindow: ResetNewsOfficialWindow? = nil, effectiveAt: Date? = nil) {
        self.sourceID = sourceID
        self.sourceURL = sourceURL
        self.originalText = originalText
        self.publishedAt = publishedAt
        self.officialWindow = officialWindow
        self.effectiveAt = effectiveAt
    }

    public func item(now: Date, calendar: Calendar = .current) -> ResetNewsItem? {
        guard Self.validIdentity(sourceID, url: sourceURL), publishedAt.timeIntervalSince1970.isFinite,
              publishedAt <= now, !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !ResetNewsRuleEngine().lastResetActionIsTerminal(in: originalText) else { return nil }
        if let end = expiresAt(calendar: calendar), now >= end { return nil }
        return evidenceItem(calendar: calendar)
    }

    /// Historical evidence remains readable after the current-preview window has ended.
    public func evidenceItem(calendar: Calendar = .current) -> ResetNewsItem {
        ResetNewsItem(id: "post:\(sourceID)", sources: [.forecast], sourceURL: sourceURL,
            originalText: originalText, facts: [forecastFact], publishedAt: publishedAt, firstSeenAt: publishedAt)
    }

    /// Ends display eligibility, without claiming that the announced reset was completed.
    public func expiresAt(calendar: Calendar = .current) -> Date? {
        let fact = forecastFact
        let timing = ResetForecastTiming.resolve(fact, publishedAt: publishedAt, calendar: calendar)
        var candidates: [Date] = []
        if let timing, timing.precision == .exact || timing.precision == .deadline { candidates.append(timing.date) }
        if let end = officialWindow?.endAt { candidates.append(end) }
        else if let target = officialWindow?.targetAt { candidates.append(target) }
        else if let end = timing?.dayEnd { candidates.append(end) }
        return candidates.min()
    }

    /// Source fetch times, translated copy and unrelated prose do not create another reminder.
    public var notificationKey: String {
        let fact = forecastFact
        var fields = [sourceID, fact.materialKey]
        if let window = fact.officialWindow {
            fields += [window.startAt, window.endAt, window.targetAt].map {
                $0.map { String($0.timeIntervalSince1970) } ?? ""
            }
        }
        if fact.effectiveAt == nil, fact.officialWindow?.targetAt == nil, fact.officialWindow?.endAt == nil,
           fact.officialWindow?.startAt == nil, fact.timingText != nil {
            // Relative source dates depend on publication, never on the latest snapshot time.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = fact.sourceTimeZone.flatMap(ResetForecastTiming.timeZone) ?? TimeZone(secondsFromGMT: 0)!
            if let timing = ResetForecastTiming.resolve(fact, publishedAt: publishedAt, calendar: calendar) {
                fields.append(String(timing.date.timeIntervalSince1970))
                fields.append(timing.dayEnd.map { String($0.timeIntervalSince1970) } ?? "")
            }
        }
        let material = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return "forecast:post:\(sourceID):\(ResetNewsText.digest(material))"
    }

    private var forecastFact: ResetNewsFact {
        let engine = ResetNewsRuleEngine()
        let evidence = engine.upcomingResetEvidence(in: originalText) ?? originalText
        let originalTiming = engine.timingDetails(evidence)
        var timingWindow = officialWindow
        // A start alone is not the reset's arrival time or the end of its announcement window.
        if timingWindow?.endAt == nil, timingWindow?.targetAt == nil { timingWindow?.startAt = nil }
        let date = effectiveAt ?? timingWindow?.targetAt ?? timingWindow?.endAt
            ?? originalTiming.effective
        let precision: ResetNewsTimePrecision?
        if effectiveAt != nil || (originalTiming.effective != nil && timingWindow?.targetAt == nil
            && timingWindow?.endAt == nil) {
            precision = .exact
        } else if timingWindow?.targetAt != nil, timingWindow?.targetKind?.lowercased() == "exact" {
            precision = .exact
        } else if timingWindow?.targetAt != nil, timingWindow?.targetKind?.lowercased() == "deadline" {
            precision = .deadline
        } else {
            precision = date == nil ? nil : .windowBoundary
        }
        // The original clock is more precise than an unrecognised or date-only window label.
        let text = originalTiming.text ?? officialWindow?.label
        return ResetNewsFact(kind: .upcomingReset, scope: engine.audience(in: evidence), effectiveAt: date,
            effectiveAtPrecision: precision, timingText: text, confidence: .explicit, evidence: evidence,
            officialWindow: timingWindow, sourceTimeZone: officialWindow?.timeZone)
    }

    static func validIdentity(_ id: String, url: URL) -> Bool {
        !id.isEmpty && id.allSatisfy(\.isNumber) && url.scheme == "https" && url.host == "x.com"
            && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil
            && url.path == "/thsottiaux/status/\(id)"
    }
}

public enum ResetForecastDecodingError: Error, Equatable {
    case invalidEnvelope
    case missingField(String)
    case invalidField(String)
    case invalidIdentity
}

/// Adapter for the public forecast endpoint. Optional unknown fields do not alter source semantics.
public struct ResetForecastSnapshotDecoder: Sendable {
    public init() {}

    public func decode(_ data: Data) throws -> ResetForecastSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResetForecastDecodingError.invalidEnvelope
        }
        let updatedAt = try requiredDate(root, key: "updated_at")
        guard root.keys.contains("last_reset_at") else { throw ResetForecastDecodingError.missingField("last_reset_at") }
        let lastResetAt = try optionalDate(root, key: "last_reset_at")
        if let lastResetAt, lastResetAt > updatedAt { throw ResetForecastDecodingError.invalidField("last_reset_at") }
        guard let rawSignal = root["official_signal"] else { throw ResetForecastDecodingError.missingField("official_signal") }
        let signal: ResetForecastSignal?
        if rawSignal is NSNull { signal = nil }
        else {
            guard let record = rawSignal as? [String: Any] else { throw ResetForecastDecodingError.invalidField("official_signal") }
            let id = try requiredString(record, key: "tweet_id")
            let rawURL = try requiredString(record, key: "url")
            guard let url = URL(string: rawURL), ResetForecastSignal.validIdentity(id, url: url) else {
                throw ResetForecastDecodingError.invalidIdentity
            }
            let publishedAt = try requiredDate(record, key: "at")
            guard publishedAt <= updatedAt else { throw ResetForecastDecodingError.invalidField("at") }
            let text = try requiredString(record, key: "summary")
            signal = ResetForecastSignal(sourceID: id, sourceURL: url,
                originalText: text, publishedAt: publishedAt,
                officialWindow: try window(record["window"], originalText: text, publishedAt: publishedAt))
        }
        return ResetForecastSnapshot(updatedAt: updatedAt, lastResetAt: lastResetAt, officialSignal: signal)
    }

    private func requiredString(_ object: [String: Any], key: String) throws -> String {
        guard let value = object[key] else { throw ResetForecastDecodingError.missingField(key) }
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResetForecastDecodingError.invalidField(key)
        }
        return text
    }

    private func optionalString(_ object: [String: Any], key: String) throws -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw ResetForecastDecodingError.invalidField(key) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private func requiredDate(_ object: [String: Any], key: String) throws -> Date {
        let text = try requiredString(object, key: key)
        guard let date = ResetNewsDate.parse(text), date.timeIntervalSince1970.isFinite else {
            throw ResetForecastDecodingError.invalidField(key)
        }
        return date
    }

    private func optionalDate(_ object: [String: Any], key: String) throws -> Date? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let text = value as? String, let date = ResetNewsDate.parse(text), date.timeIntervalSince1970.isFinite else {
            throw ResetForecastDecodingError.invalidField(key)
        }
        return date
    }

    private func window(_ value: Any?, originalText: String, publishedAt: Date) throws -> ResetNewsOfficialWindow? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any] else { throw ResetForecastDecodingError.invalidField("window") }
        let start = try optionalDate(object, key: "start_at")
        let end = try optionalDate(object, key: "end_at")
        let target = try optionalDate(object, key: "target_at")
        let label = try optionalString(object, key: "label")
        let kind = try optionalString(object, key: "target_kind")
        let zone = try optionalString(object, key: "time_zone")
        if let start, let end, start > end { throw ResetForecastDecodingError.invalidField("window.range") }
        if let target, (start.map { target < $0 } == true || end.map { target > $0 } == true) {
            throw ResetForecastDecodingError.invalidField("window.target_at")
        }
        if end == nil, target == nil {
            let engine = ResetNewsRuleEngine()
            let timing = engine.timingDetails(engine.upcomingResetEvidence(in: originalText) ?? originalText)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let originalFact = ResetNewsFact(kind: .upcomingReset, effectiveAt: timing.effective,
                effectiveAtPrecision: timing.effective == nil ? nil : .exact,
                timingText: timing.text, sourceTimeZone: zone)
            let originalDate = ResetForecastTiming.resolve(originalFact, publishedAt: publishedAt, calendar: calendar)
            let expresslyUndated = start == nil && label.map {
                ResetNewsText.matches(#"\btiming\s+unspecified\b|时间待定|时间未定"#, in: $0)
            } == true
            guard originalDate != nil || expresslyUndated else { throw ResetForecastDecodingError.invalidField("window") }
        }
        // Unknown optional fields may fall back to dated original text; they cannot create indefinite previews.
        guard start != nil || end != nil || target != nil || label != nil else {
            return nil
        }
        return ResetNewsOfficialWindow(label: label, startAt: start, endAt: end, targetAt: target,
            targetKind: kind, timeZone: zone)
    }
}
