import Foundation

public enum ResetForecastPendingClaim: String, Codable, Equatable, Sendable {
    case done
    case onItsWay = "on_its_way"
}

/// Optional feed context, never an independent source of current availability.
public struct ResetForecastTimingReply: Codable, Equatable, Sendable {
    public let sourceID: String
    public let sourceURL: URL
    public let parentID: String
    public let originalText: String
    public let publishedAt: Date

    public static func decodeFeed(_ data: Data) -> ResetForecastTimingReply? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["stale"] as? Bool == false,
              (root["profile"] as? [String: Any])?["handle"] as? String == "thsottiaux",
              root["source_scope"] as? String == "timeline",
              let signal = root["signal"] as? [String: Any], signal["active"] as? Bool == true,
              signal["kind"] as? String == "signal", let id = signal["tweet_id"] as? String,
              let tweets = root["tweets"] as? [[String: Any]],
              let tweet = tweets.first(where: { $0["id"] as? String == id }),
              tweet["is_reply"] as? Bool == true, tweet["replying_to"] as? String == "thsottiaux",
              let parent = tweet["in_reply_to_tweet_id"] as? String,
              let rawURL = tweet["url"] as? String, signal["url"] as? String == rawURL,
              let url = URL(string: rawURL), ResetForecastSignal.validIdentity(id, url: url),
              let at = tweet["at"] as? String, signal["at"] as? String == at,
              let publishedAt = ResetNewsDate.parse(at),
              let fetched = root["fetched_at"] as? String, let fetchedAt = ResetNewsDate.parse(fetched),
              publishedAt <= fetchedAt,
              let text = tweet["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return .init(sourceID: id, sourceURL: url, parentID: parent, originalText: text, publishedAt: publishedAt)
    }
}

extension ResetForecastSnapshot {
    /// Feed timing is context; it does not create a conflicting authority revision.
    public func hasSameClaim(as other: ResetForecastSnapshot?) -> Bool {
        guard var first = officialSignal, var second = other?.officialSignal else { return false }
        first.timingReply = nil
        second.timingReply = nil
        return first == second
    }

    /// Same already-seen source post gaining canonical pending metadata on upgrade.
    public func refinesLegacyClaim(_ other: ResetForecastSnapshot?) -> Bool {
        guard var current = officialSignal, let previous = other?.officialSignal,
              current.pendingClaim != nil, previous.pendingClaim == nil, previous.timingReply == nil else { return false }
        current.pendingClaim = nil
        current.timingReply = nil
        return current == previous
    }

    public func supplementingTiming(with reply: ResetForecastTimingReply) -> ResetForecastSnapshot {
        guard var signal = officialSignal, signal.pendingClaim == .onItsWay,
              reply.parentID == signal.sourceID, reply.sourceID != signal.sourceID,
              reply.publishedAt >= signal.publishedAt, reply.publishedAt <= updatedAt,
              !ResetNewsRuleEngine().lastResetActionIsTerminal(in: reply.originalText) else { return self }
        let timing = ResetNewsRuleEngine().timingDetails(reply.originalText)
        let fact = ResetNewsFact(kind: .upcomingReset, effectiveAt: timing.effective,
            effectiveAtPrecision: timing.effective == nil ? nil : .exact, timingText: timing.text)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let resolved = ResetForecastTiming.resolve(fact, publishedAt: reply.publishedAt, calendar: calendar),
              resolved.precision == .deadline || resolved.precision == .exact else { return self }
        signal.timingReply = reply
        var result = self
        result.officialSignal = signal
        return result
    }
}
