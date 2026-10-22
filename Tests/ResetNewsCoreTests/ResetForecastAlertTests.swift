import Foundation
import Testing
@testable import ResetNewsCore

struct ResetForecastAlertTests {
    private let now = ResetNewsDate.parse("2026-10-22T07:30:00Z")!
    private let deadline = ResetNewsDate.parse("2026-10-22T18:00:00Z")!
    private var shanghai: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ResetNews/\(name).json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    private func body(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func forecast(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> ResetForecastSnapshot {
        var root = try fixture("forecast-active-watch-20261022")
        var alert = root["latest_alert"] as! [String: Any]
        change(&alert)
        root["latest_alert"] = alert
        return try ResetForecastSnapshotDecoder().decode(body(root))
    }
    private func reply(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> ResetForecastTimingReply? {
        var root = try fixture("feed-timing-reply-20261022")
        change(&root)
        return ResetForecastTimingReply.decodeFeed(try body(root))
    }

    @Test func capturedPendingWatchIsVisibleWithoutInventingATime() throws {
        let snapshot = try forecast()
        let item = try #require(snapshot.item(now: now, calendar: shanghai))
        #expect(snapshot.officialSignal?.pendingClaim == .onItsWay)
        #expect(item.id == "post:2113162277688070445")
        #expect(item.facts.first?.timingText == nil)
        let headline = ResetForecastHeadline(fact: item.facts[0], publishedAt: item.publishedAt, now: now, calendar: shanghai)
        #expect(headline.headline == "重置待确认")
        #expect(headline.confirmationNote != nil)
        #expect(snapshot.lastResetAt == ResetNewsDate.parse("2026-10-20T06:33:48Z"))
    }

    @Test func directTimingReplyUsesItsPublicationDayInPST() throws {
        let original = try forecast()
        let reply = try #require(try reply())
        let snapshot = original.supplementingTiming(with: reply)
        let signal = try #require(snapshot.officialSignal)
        #expect(signal.timingReply?.sourceID == "2113162413008884099")
        #expect(signal.expiresAt(calendar: shanghai) == deadline)
        let item = try #require(snapshot.item(now: now, calendar: shanghai))
        #expect(item.publishedAt == reply.publishedAt)
        let headline = ResetForecastHeadline(fact: item.facts[0], publishedAt: item.publishedAt, now: now, calendar: shanghai)
        #expect(headline.kind == .deadline)
        #expect(headline.summary == "预计明天 02:00 前")
        #expect(headline.dateText?.contains("10月23日") == true)
        #expect(headline.confirmationNote != nil)
        #expect(headline.basisText?.contains("未来") != true)
        #expect(snapshot.item(now: deadline, calendar: shanghai) == nil)
        #expect(snapshot.lastResetAt == original.lastResetAt)
        #expect(snapshot.notificationKey != original.notificationKey)
        let reloaded = try JSONDecoder().decode(ResetForecastSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(reloaded == snapshot)
        #expect(reloaded.notificationKey == snapshot.notificationKey)
        var pacific = shanghai
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(signal.expiresAt(calendar: pacific) == deadline)
    }

    @Test(arguments: ["done", "on_its_way"])
    func pendingClaimDoesNotPretendResetIsConfirmed(_ pending: String) throws {
        let snapshot = try forecast { $0["pending"] = pending; $0["summary"] = "We have reset Codex limits. It is done." }
        let item = try #require(snapshot.item(now: now))
        #expect(item.facts[0].kind == .upcomingReset)
        #expect(item.facts[0].awaitingResetConfirmation == true)
    }

    @Test(arguments: [("watch", "expired"), ("reset", "confirmed")])
    func terminalAlertClearsLegacySignal(_ pair: (String, String)) throws {
        var root = try fixture("forecast-active-watch-20261022")
        let alert = root["latest_alert"] as! [String: Any]
        root["official_signal"] = ["tweet_id": alert["id"]!, "url": alert["url"]!,
            "at": alert["source_at"]!, "summary": "Codex limits will reset tomorrow."]
        var terminal = alert
        terminal["kind"] = pair.0; terminal["state"] = pair.1
        root["latest_alert"] = terminal
        let snapshot = try ResetForecastSnapshotDecoder().decode(body(root))
        #expect(snapshot.item(now: now) == nil)
        #expect(snapshot.notificationKey == nil)
    }

    @Test(arguments: [("watch", "confirmed"), ("watch", "activ"), ("reset", "active"), ("unknown", "active")])
    func invalidAlertStateIsAnErrorInsteadOfAnEmptySuccess(_ pair: (String, String)) {
        #expect(throws: (any Error).self) { try forecast { $0["kind"] = pair.0; $0["state"] = pair.1 } }
    }

    @Test(arguments: ["url", "id", "source_at", "summary", "pending"])
    func malformedActiveAlertCannotClearCache(_ field: String) {
        #expect(throws: (any Error).self) { try forecast { $0[field] = field == "summary" ? "" : "invalid" } }
    }

    @Test func onlyAbsentAlertFallsBackToLegacySignal() throws {
        var root = try fixture("forecast-active-watch-20261022")
        let alert = root.removeValue(forKey: "latest_alert") as! [String: Any]
        root["official_signal"] = ["tweet_id": alert["id"]!, "url": alert["url"]!,
            "at": alert["source_at"]!, "summary": "Codex limits will reset tomorrow."]
        let withoutAlert = try ResetForecastSnapshotDecoder().decode(body(root))
        root["latest_alert"] = NSNull()
        #expect(withoutAlert.officialSignal != nil)
        #expect(try ResetForecastSnapshotDecoder().decode(body(root)).officialSignal == nil)
    }

    @Test func normalActiveWatchKeepsItsAnnouncedDeadline() throws {
        let snapshot = try forecast {
            $0.removeValue(forKey: "pending")
            $0["summary"] = "Codex limits land tomorrow before 10am PST."
            $0["score"] = 93
            $0["window"] = ["end_at": "2026-10-22T18:00:00Z", "target_at": "2026-10-22T18:00:00Z", "target_kind": "deadline"]
        }
        #expect(snapshot.officialSignal?.expiresAt(calendar: shanghai) == deadline)
        #expect(snapshot.item(now: now)?.facts.first?.awaitingResetConfirmation == nil)
    }

    @Test(arguments: ["identity", "stale", "inactive", "notReply", "wrongURL", "mismatchedDate", "missingParent"])
    func invalidFeedCannotSupplyTiming(_ kind: String) throws {
        let value = try reply { root in
            var signal = root["signal"] as! [String: Any]
            var tweet = (root["tweets"] as! [[String: Any]])[0]
            switch kind {
            case "identity": root["profile"] = ["handle": "other"]
            case "stale": root["stale"] = true
            case "inactive": signal["active"] = false
            case "notReply": tweet["is_reply"] = false
            case "wrongURL": tweet["url"] = "https://x.com/other/status/2113162413008884099"
            case "mismatchedDate": tweet["at"] = "2026-10-22T07:00:00Z"
            default: tweet.removeValue(forKey: "in_reply_to_tweet_id")
            }
            root["signal"] = signal; root["tweets"] = [tweet]
        }
        #expect(value == nil)
    }

    @Test func unrelatedReplyCannotPromoteOrChangeAWatch() throws {
        let original = try forecast()
        let other = try #require(reply { root in
            var tweets = root["tweets"] as! [[String: Any]]
            tweets[0]["in_reply_to_tweet_id"] = "99999"
            root["tweets"] = tweets
        })
        #expect(original.supplementingTiming(with: other) == original)
        let expired = try forecast { $0["state"] = "expired" }
        #expect(expired.supplementingTiming(with: try #require(try reply())) == expired)
    }
    @Test func absoluteTimestampReplyKeepsExactPrecision() throws {
        let direct = try #require(try reply { root in
            var tweets = root["tweets"] as! [[String: Any]]
            tweets[0]["text"] = "Lands at 2026-10-23T10:00:00Z."
            root["tweets"] = tweets
        })
        let snapshot = try forecast().supplementingTiming(with: direct)
        #expect(snapshot.officialSignal?.timingReply != nil)
        #expect(snapshot.officialSignal?.expiresAt(calendar: shanghai) == ResetNewsDate.parse("2026-10-23T10:00:00Z"))
    }

    @Test(arguments: ["id", "source_at", "summary"])
    func terminalAlertStillRequiresValidEvidence(_ field: String) {
        #expect(throws: (any Error).self) {
            try forecast { $0["kind"] = "reset"; $0["state"] = "confirmed"; $0.removeValue(forKey: field) }
        }
    }

    @Test func futureTerminalAlertCannotClearCurrentPreview() {
        #expect(throws: (any Error).self) {
            try forecast { $0["state"] = "expired"; $0["source_at"] = "2026-10-23T08:00:00Z" }
        }
    }

}
