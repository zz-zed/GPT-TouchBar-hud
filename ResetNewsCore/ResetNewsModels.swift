import Foundation
import CryptoKit

public enum ResetNewsSource: String, Codable, Equatable, Sendable {
    case feed, timeline
}

public struct ResetNewsOfficialWindow: Codable, Equatable, Sendable {
    public var label: String?
    public var startAt: Date?
    public var endAt: Date?
    public var targetAt: Date?
}

public struct ResetNewsSourceHints: Codable, Equatable, Sendable {
    public var group: String?
    public var type: String?
    public var preview: Bool?
    public var resetKind: String?
    public var audience: [String]
    public var scope: String?
    public var confidence: String?
    public var bankedState: String?
    public var announcementState: String?
    public var officialWindow: ResetNewsOfficialWindow?
}

/// The source adapter boundary. Dates remain nil when the source omits them.
public struct ResetNewsSourceItem: Codable, Equatable, Sendable {
    public var source: ResetNewsSource
    public var sourceID: String?
    public var url: URL?
    public var title: String?
    public var body: String
    public var publishedAt: Date?
    public var updatedAt: Date?
    public var status: ResetNewsStatus?
    public var structuredFacts: [ResetNewsFact]?
    public var hints: ResetNewsSourceHints?

    public init(source: ResetNewsSource, sourceID: String? = nil, url: URL? = nil,
                title: String? = nil, body: String, publishedAt: Date? = nil,
                updatedAt: Date? = nil, status: ResetNewsStatus? = nil, structuredFacts: [ResetNewsFact]? = nil,
                hints: ResetNewsSourceHints? = nil) {
        self.source = source
        self.sourceID = sourceID
        self.url = url
        self.title = title
        self.body = body
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.status = status
        self.structuredFacts = structuredFacts
        self.hints = hints
    }

    public var stableID: String {
        if let url, let postID = ResetNewsText.capture(#"/(?:status|statuses)/(\d+)"#, in: url.path) {
            return "post:\(postID)"
        }
        if let sourceID, !sourceID.isEmpty {
            if sourceID.allSatisfy(\.isNumber) { return "post:\(sourceID)" }
            return "source:\(sourceID)"
        }
        if let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.query = nil
            components.fragment = nil
            components.host = components.host?.lowercased().replacingOccurrences(of: "www.", with: "")
            if let canonical = components.string { return "url:\(canonical)" }
        }
        // With no source identity, content changes cannot safely be attributed to an existing post.
        let key = ResetNewsText.normalized([title, body].compactMap { $0 }.joined(separator: " "))
        return "content:\(ResetNewsText.digest(key))"
    }
}

public enum ResetNewsFactKind: String, Codable, Equatable, Sendable {
    case upcomingReset, resetAnnouncement, extraResetCredits
}

public enum ResetNewsConfidence: String, Codable, Equatable, Sendable {
    case explicit, tentative
}

public enum ResetNewsStatus: String, Codable, Equatable, Sendable {
    case active, cancelled, expired, superseded
}

/// Presentation provenance only. An absent value in older caches does not prove an exact reset time.
public enum ResetNewsTimePrecision: String, Codable, Equatable, Sendable {
    case exact, windowBoundary
}

public struct ResetNewsFact: Codable, Equatable, Sendable {
    public var kind: ResetNewsFactKind
    /// Canonical plan names, or "all". nil means the announcement did not specify a scope.
    public var scope: String?
    public var count: Int?
    public var effectiveAt: Date?
    public var effectiveAtPrecision: ResetNewsTimePrecision?
    public var timingText: String?
    public var expiresAt: Date?
    public var validityText: String?
    public var confidence: ResetNewsConfidence
    public var evidence: String

    public init(kind: ResetNewsFactKind, scope: String? = nil, count: Int? = nil,
                effectiveAt: Date? = nil, effectiveAtPrecision: ResetNewsTimePrecision? = nil,
                timingText: String? = nil, expiresAt: Date? = nil,
                validityText: String? = nil, confidence: ResetNewsConfidence = .explicit,
                evidence: String = "") {
        self.kind = kind
        self.scope = scope
        self.count = count
        self.effectiveAt = effectiveAt
        self.effectiveAtPrecision = effectiveAtPrecision
        self.timingText = timingText
        self.expiresAt = expiresAt
        self.validityText = validityText
        self.confidence = confidence
        self.evidence = evidence
    }

    var materialKey: String {
        // Display precision does not change the schedule or replay an already-consumed notification.
        let fields = [kind.rawValue, scope ?? "", count.map(String.init) ?? "",
                      effectiveAt.map { String($0.timeIntervalSince1970) } ?? "",
                      effectiveAt == nil ? ResetNewsText.normalized(timingText ?? "") : "",
                      expiresAt.map { String($0.timeIntervalSince1970) } ?? "",
                      expiresAt == nil ? ResetNewsText.normalized(validityText ?? "") : "",
                      confidence.rawValue]
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

public struct ResetNewsItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sources: [ResetNewsSource]
    public var sourceURL: URL?
    public var originalText: String
    public var facts: [ResetNewsFact]
    public var status: ResetNewsStatus
    public var publishedAt: Date?
    public var firstSeenAt: Date
    public var updatedAt: Date?
    public var materialRevision: Int
    /// Last accepted copy from each endpoint. nil supports caches written before provenance was recorded.
    public var sourceSnapshots: [ResetNewsSourceSnapshot]?

    public init(id: String, sources: [ResetNewsSource], sourceURL: URL? = nil, originalText: String,
                facts: [ResetNewsFact], status: ResetNewsStatus = .active, publishedAt: Date? = nil,
                firstSeenAt: Date, updatedAt: Date? = nil, materialRevision: Int = 1,
                sourceSnapshots: [ResetNewsSourceSnapshot]? = nil) {
        self.id = id
        self.sources = sources
        self.sourceURL = sourceURL
        self.originalText = originalText
        self.facts = facts
        self.status = status
        self.publishedAt = publishedAt
        self.firstSeenAt = firstSeenAt
        self.updatedAt = updatedAt
        self.materialRevision = materialRevision
        self.sourceSnapshots = sourceSnapshots
    }

    public var notificationKey: String { "\(id):revision:\(materialRevision)" }
    public var summaryZH: String { ResetNewsSummary.chinese(self) }
    var materialKey: String { status.rawValue + ":" + facts.map(\.materialKey).sorted().joined(separator: "|") }
}

/// A bounded, nonrecursive source copy keeps partial refreshes independent of the other endpoint's availability.
public struct ResetNewsSourceSnapshot: Codable, Equatable, Sendable {
    public var source: ResetNewsSource
    public var sourceURL: URL?
    public var originalText: String
    public var facts: [ResetNewsFact]
    public var status: ResetNewsStatus
    public var publishedAt: Date?
    public var updatedAt: Date?
    public var statusWasExplicit: Bool

    init(item: ResetNewsItem, source: ResetNewsSource, statusWasExplicit: Bool) {
        self.source = source
        sourceURL = item.sourceURL
        originalText = item.originalText
        facts = item.facts
        status = item.status
        publishedAt = item.publishedAt
        updatedAt = item.updatedAt
        self.statusWasExplicit = statusWasExplicit
    }

    var versionAt: Date { updatedAt ?? publishedAt ?? .distantPast }

    func item(id: String, firstSeenAt: Date) -> ResetNewsItem {
        ResetNewsItem(id: id, sources: [source], sourceURL: sourceURL, originalText: originalText,
                      facts: facts, status: status, publishedAt: publishedAt, firstSeenAt: firstSeenAt, updatedAt: updatedAt)
    }
}

enum ResetNewsText {
    static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func capture(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              group < match.numberOfRanges, let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
