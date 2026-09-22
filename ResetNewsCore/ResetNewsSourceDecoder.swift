import Foundation
import CoreFoundation

public enum ResetNewsDecodingError: Error, Equatable {
    case unsupportedEnvelope
}

public struct ResetNewsSourceBatch: Codable, Equatable, Sendable {
    public var items: [ResetNewsSourceItem]
    public var stale: Bool
    public var fetchedAt: Date?
    public var identityValidated: Bool
    public var rejectedIdentityCount: Int
}

/// Accepts source payloads without tying the rules or persistence format to an API schema.
public struct ResetNewsSourceDecoder: Sendable {
    public init() {}

    public func decode(_ data: Data, source: ResetNewsSource) throws -> [ResetNewsSourceItem] {
        try decodeBatch(data, source: source).items
    }

    public func decodeBatch(_ data: Data, source: ResetNewsSource) throws -> ResetNewsSourceBatch {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let envelope = records(in: json) else { throw ResetNewsDecodingError.unsupportedEnvelope }
        let records = envelope.records
        let contentKeys = ["full_text", "text", "body", "content", "description", "summary", "title", "headline"]
        guard envelope.count == 0 || records.contains(where: { content($0, contentKeys) != nil }) else {
            throw ResetNewsDecodingError.unsupportedEnvelope
        }
        let root = json as? [String: Any] ?? [:]
        let profile = root["profile"] as? [String: Any]
        let rootIdentityValid = source != .feed || (profile?["handle"] as? String == "thsottiaux" && root["source_scope"] as? String == "timeline")
        var rejected = 0
        let items: [ResetNewsSourceItem] = records.compactMap { record in
            let text = content(record, ["full_text", "text", "body", "content", "description", "summary"])
            let title = content(record, ["title", "headline"])
            guard text != nil || title != nil else { return nil }
            let rawURL = string(record, ["source_url", "sourceUrl", "tweet_url", "tweetUrl", "url", "link", "permalink", "original_url"])
            let url = rawURL.flatMap(URL.init(string:)).flatMap { value -> URL? in
                guard value.scheme == "https" || value.scheme == "http" else { return nil }
                return value
            }
            let sourceID = string(record, ["tweet_id", "tweetId", "id_str", "post_id", "postId", "id"])
            guard rootIdentityValid, let sourceID, !sourceID.isEmpty, sourceID.allSatisfy(\.isNumber),
                  let url, url.scheme == "https", url.host == "x.com", url.user == nil, url.password == nil,
                  url.port == nil, url.query == nil, url.fragment == nil,
                  url.path == "/thsottiaux/status/\(sourceID)" else {
                rejected += 1
                return nil
            }
            return ResetNewsSourceItem(
                source: source,
                sourceID: sourceID,
                url: url, title: title, body: text ?? "",
                publishedAt: date(record, ["announced_at", "at", "declared_at", "published_at", "publishedAt", "created_at", "createdAt", "pubDate", "timestamp"]),
                updatedAt: date(record, ["updated_at", "updatedAt", "modified_at"]),
                status: status(record),
                structuredFacts: structuredFacts(record, text: text ?? title ?? ""),
                hints: hints(record)
            )
        }
        return ResetNewsSourceBatch(items: items, stale: root["stale"] as? Bool ?? false,
                                    fetchedAt: date(root, ["fetched_at", "updated_at"]),
                                    identityValidated: rootIdentityValid,
                                    rejectedIdentityCount: rejected)
    }

    private func records(in value: Any) -> (records: [[String: Any]], count: Int)? {
        if let values = value as? [Any] {
            let records: [[String: Any]] = values.compactMap { value in
                guard let record = value as? [String: Any] else { return nil }
                return flattened(record)
            }
            return (records, values.count)
        }
        guard let object = value as? [String: Any] else { return nil }
        if object["tweets"] != nil || object["events"] != nil {
            var found: [[String: Any]] = []
            var count = 0
            for key in ["tweets", "events"] where object[key] != nil {
                guard let values = object[key] as? [Any] else { return nil }
                count += values.count
                found.append(contentsOf: values.compactMap { ($0 as? [String: Any]).map(flattened) })
            }
            return (found, count)
        }
        for key in ["items", "events", "posts", "tweets", "entries", "results", "data", "feed", "timeline"] {
            if let nested = object[key], let found = records(in: nested) { return found }
        }
        let record = flattened(object)
        if content(record, ["full_text", "text", "body", "content", "description", "summary", "title", "headline"]) != nil {
            return ([record], 1)
        }
        return nil
    }

    private func flattened(_ object: [String: Any]) -> [String: Any] {
        var result = object
        for key in ["legacy", "tweet", "post"] {
            if let nested = object[key] as? [String: Any] {
                for (name, value) in nested where result[name] == nil { result[name] = value }
            }
        }
        return result
    }

    private func string(_ record: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let text = record[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            if let number = record[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
            if let nested = record[key] as? [String: Any], let text = nested["text"] as? String { return text }
        }
        return nil
    }

    private func content(_ record: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            let value = record[key] as? String ?? (record[key] as? [String: Any])?["text"] as? String
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return nil
    }

    private func date(_ record: [String: Any], _ keys: [String]) -> Date? {
        guard let value = string(record, keys) else { return nil }
        return ResetNewsDate.parse(value)
    }

    private func structuredFacts(_ record: [String: Any], text: String) -> [ResetNewsFact]? {
        let group = string(record, ["group", "type"])
        let resetKind = string(record, ["reset_kind"])
        let banked = string(record, ["banked_state"])
        let explicitBankedState = banked.map { ["announced", "arriving", "available"].contains($0) } ?? false
        guard group != nil || resetKind == "banked" || record["explicit_reset_claim"] as? Bool == true || explicitBankedState else { return nil }
        // An operator's observed quota change does not establish a new official announcement.
        if string(record, ["source"]) == "operator-observed" { return [] }
        let engine = ResetNewsRuleEngine()
        let audience = (record["audience"] as? [String] ?? []).map { $0.lowercased() }.sorted()
        let scope = string(record, ["scope"]) == "global" ? "all" : (audience.isEmpty ? engine.audience(in: text) : audience.joined(separator: ","))
        let confidence: ResetNewsConfidence = string(record, ["confidence"]) == "high"
            || string(record, ["announcement_state"]) == "announced"
            || record["explicit_reset_claim"] as? Bool == true
            || explicitBankedState ? .explicit : .tentative
        let window = record["official_window"] as? [String: Any] ?? [:]
        let exactTarget = date(record, ["effective_at"]) ?? date(window, ["target_at"])
        let effectiveAt = exactTarget ?? date(window, ["end_at", "start_at"])
        let precision: ResetNewsTimePrecision? = exactTarget != nil ? .exact : (effectiveAt != nil ? .windowBoundary : nil)
        let timingText = string(window, ["label"])
        let status = status(record)
        let withdrawn = status == .cancelled || status == .superseded || status == .expired
        if group == "credits" || explicitBankedState || resetKind == "banked" {
            // Delivery state describes the announcement, never this local account's balance.
            // Unknown state still supplies a list item; notification eligibility is decided by confidence.
            let explicitAction = hasExplicitCreditAction(text)
            guard withdrawn || !deniesCreditGrant(text) || explicitAction else { return [] }
            let creditConfidence: ResetNewsConfidence = confidence == .explicit || explicitAction ? .explicit : .tentative
            let timing = engine.timingDetails(text)
            return [ResetNewsFact(kind: .extraResetCredits, scope: scope, count: engine.creditCount(text),
                                  expiresAt: date(record, ["expires_at"]) ?? timing.expiry,
                                  validityText: timing.validity, confidence: creditConfidence, evidence: text)]
        }
        if group == "reset" || record["explicit_reset_claim"] as? Bool == true {
            guard withdrawn || !ResetNewsText.matches(#"\b(?:not|never|no|won't|won’t)\b.{0,35}\breset\b|不会重置|没有重置"#, in: text) else { return [] }
            let kind: ResetNewsFactKind = record["preview"] as? Bool == true ? .upcomingReset : .resetAnnouncement
            return [ResetNewsFact(kind: kind, scope: scope, effectiveAt: effectiveAt, effectiveAtPrecision: precision, timingText: timingText,
                                  confidence: confidence, evidence: text)]
        }
        return nil
    }

    private func hasExplicitCreditAction(_ text: String) -> Bool {
        let clauses = text.replacingOccurrences(of: #"[;。；\n]+|\.(?=\s|$)"#, with: "\n", options: .regularExpression)
            .components(separatedBy: "\n")
        return clauses.contains { clause in
            let action = ResetNewsText.matches(#"\b(?:giving|granted|credited|getting|providing|announced|added|landed|arriving|available|redeemable)\b"#, in: clause)
            let creditContext = ResetNewsText.matches(#"\b(?:banked\s+resets?|reset\s+credits?|extra\s+resets?|another\s+one)\b"#, in: clause)
            let negatedAction = ResetNewsText.matches(#"\b(?:not|never|no|isn't|isn’t|aren't|aren’t)\b.{0,25}\b(?:available|redeemable|arriving|landed|giving|granted|credited|getting|providing|announced|added)\b"#, in: clause)
            return action && creditContext && !negatedAction && !ResetNewsRuleEngine().isNegatedOrSpeculative(clause)
        }
    }

    private func status(_ record: [String: Any]) -> ResetNewsStatus? {
        guard let value = string(record, ["status", "announcement_state"])?.lowercased() else { return nil }
        if ["completed", "executed", "done"].contains(value) { return .expired }
        return ResetNewsStatus(rawValue: value)
    }

    private func deniesCreditGrant(_ text: String) -> Bool {
        ResetNewsText.matches(#"\b(?:no|not|never|won't|won’t)\b.{0,35}\b(?:extra|additional|bonus|reset\s+credits?)\b|\b(?:banked\s+resets?|reset\s+credits?)\b.{0,25}\bnot\s+(?:available|provided|granted)\b|没有额外|不会发放|不再提供|无法领取"#, in: text)
    }

    private func hints(_ record: [String: Any]) -> ResetNewsSourceHints {
        let window = record["official_window"] as? [String: Any]
        return ResetNewsSourceHints(group: string(record, ["group"]), type: string(record, ["type"]),
                                    preview: record["preview"] as? Bool, resetKind: string(record, ["reset_kind"]),
                                    audience: record["audience"] as? [String] ?? [], scope: string(record, ["scope"]),
                                    confidence: string(record, ["confidence"]), bankedState: string(record, ["banked_state"]),
                                    announcementState: string(record, ["announcement_state"]),
                                    officialWindow: window.map { value in
            ResetNewsOfficialWindow(label: string(value, ["label"]), startAt: date(value, ["start_at"]),
                                    endAt: date(value, ["end_at"]), targetAt: date(value, ["target_at"]))
        })
    }
}

enum ResetNewsDate {
    static func parse(_ value: String) -> Date? {
        if let seconds = Double(value), seconds.isFinite, seconds > 0 {
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1_000 : seconds)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE MMM dd HH:mm:ss Z yyyy", "EEE, dd MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
