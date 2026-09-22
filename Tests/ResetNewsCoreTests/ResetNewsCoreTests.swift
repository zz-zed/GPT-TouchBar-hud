import Foundation
import Testing
@testable import ResetNewsCore

private let instant = Date(timeIntervalSince1970: 1_790_032_800)

private func post(_ text: String, id: String = "100", source: ResetNewsSource = .feed,
                  publishedAt: Date? = instant, facts: [ResetNewsFact]? = nil) -> ResetNewsSourceItem {
    ResetNewsSourceItem(source: source, sourceID: id, url: URL(string: "https://x.com/thsottiaux/status/\(id)"),
                        body: text, publishedAt: publishedAt, structuredFacts: facts)
}

struct ResetNewsRuleTests {
    @Test func explicitUpcomingResetKeepsUnresolvedTime() throws {
        let item = try #require(ResetNewsRuleEngine().evaluate(post("Codex limits will reset tomorrow for all users."), now: instant))
        #expect(item.facts.count == 1)
        #expect(item.facts[0].kind == .upcomingReset)
        #expect(item.facts[0].effectiveAt == nil)
        #expect(item.facts[0].timingText == "tomorrow")
        #expect(item.facts[0].scope == "all")
        #expect(item.summaryZH.contains("根据公告发布时间推算"))
    }

    @Test func announcementAndCreditsRemainDistinctFacts() throws {
        let text = "We reset Codex limits and gave Pro users 3 extra reset credits."
        let item = try #require(ResetNewsRuleEngine().evaluate(post(text), now: instant))
        #expect(item.facts.map(\.kind) == [.resetAnnouncement, .extraResetCredits])
        #expect(item.facts[0].count == nil)
        #expect(item.facts[1].count == 3)
        #expect(item.facts[1].scope == "pro")
        #expect(item.summaryZH.contains("额外提供 3 次"))
    }

    @Test func unknownCreditsAndScopeStayUnknown() throws {
        let item = try #require(ResetNewsRuleEngine().evaluate(post("We are giving Codex users extra reset credits."), now: instant))
        #expect(item.facts.count == 1)
        #expect(item.facts[0].kind == .extraResetCredits)
        #expect(item.facts[0].count == nil)
        #expect(item.facts[0].scope == nil)
        #expect(item.summaryZH.contains("次数未说明"))
        #expect(item.summaryZH.contains("适用范围未说明"))
    }

    @Test func futureCreditClauseDoesNotTurnCompletedQuotaResetIntoUpcoming() throws {
        let item = try #require(ResetNewsRuleEngine().evaluate(post("We reset Codex limits and will give Pro users 2 extra reset credits tomorrow."), now: instant))
        #expect(item.facts.map(\.kind) == [.resetAnnouncement, .extraResetCredits])
        #expect(item.facts[1].count == 2)
    }

    @Test(arguments: [
        "Codex limits will not reset tomorrow.",
        "We did not reset Codex limits.",
        "Codex users may get extra reset credits.",
        "Reset your password to continue using Codex.",
        "Codex limits are unchanged after we reset the cache.",
        "Codex now has improved performance.",
        "How do Codex reset credits work?",
        "You can reset your Codex quota using a credit."
    ]) func rejectsNegationAndUnrelatedReset(_ text: String) {
        #expect(ResetNewsRuleEngine().evaluate(post(text), now: instant) == nil)
    }

    @Test func negatedFragmentDoesNotEraseIndependentCreditGrant() throws {
        let text = "Codex limits will not reset tomorrow, but Pro users get 2 extra reset credits."
        let item = try #require(ResetNewsRuleEngine().evaluate(post(text), now: instant))
        #expect(item.facts.map(\.kind) == [.extraResetCredits])
        #expect(item.facts[0].count == 2)
    }

    @Test func rangeDoesNotBecomeExactCount() throws {
        let item = try #require(ResetNewsRuleEngine().evaluate(post("Codex users get 2–3 extra reset credits."), now: instant))
        #expect(item.facts[0].count == nil)
    }

    @Test func exactTimestampAndExpiryAreParsedWithoutGuessingTimezone() throws {
        let announcement = try #require(ResetNewsRuleEngine().evaluate(post("Codex limits will reset at 2026-09-23T12:00:00Z."), now: instant))
        #expect(announcement.facts[0].effectiveAt == ResetNewsDate.parse("2026-09-23T12:00:00Z"))
        let credits = try #require(ResetNewsRuleEngine().evaluate(post("Codex Pro users get two additional reset credits until 2026-09-24T12:00:00Z."), now: instant))
        #expect(credits.facts[0].count == 2)
        #expect(credits.facts[0].expiresAt == ResetNewsDate.parse("2026-09-24T12:00:00Z"))
    }

    @Test func structuredCompoundBankedResetAddsCreditFact() throws {
        let facts = [ResetNewsFact(kind: .upcomingReset, effectiveAt: instant.addingTimeInterval(3600))]
        let item = try #require(ResetNewsRuleEngine().evaluate(post("Full reset within the hour plus one additional banked reset, after usage was being consumed faster than expected.", facts: facts), now: instant))
        #expect(item.facts.map(\.kind) == [.upcomingReset, .extraResetCredits])
        #expect(item.facts[1].count == 1)
    }
}

struct ResetNewsDecoderTests {
    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func event(id: String = "100", preview: Bool = false) -> [String: Any] {
        ["id": id, "url": "https://x.com/thsottiaux/status/\(id)", "summary": "Reset all propagated.",
         "announced_at": "2026-09-22T03:00:00Z", "group": "reset", "type": "reset", "preview": preview,
         "scope": "global", "confidence": "high", "reset_kind": "hard", "audience": ["codex", "chatgpt_work"],
         "announcement_state": "announced", "source": "archive"]
    }

    @Test func liveFeedSchemaKeepsTweetsEventsDatesAndUnknownFields() throws {
        let tweet: [String: Any] = ["id": "101", "url": "https://x.com/thsottiaux/status/101",
                                    "text": "Codex limits will reset tomorrow.", "at": "2026-09-22T02:00:00.000Z",
                                    "explicit_reset_claim": false, "tease_classification": ["anything": [1, 2, 3]]]
        let payload: [String: Any] = ["profile": ["handle": "thsottiaux"], "source_scope": "timeline", "stale": false,
                                      "fetched_at": "2026-09-22T03:30:00Z", "tweets": [tweet], "events": [event()],
                                      "rhythm": ["large": "ignored"], "chart": [1, 2, 3]]
        let batch = try ResetNewsSourceDecoder().decodeBatch(data(payload), source: .feed)
        #expect(batch.identityValidated && !batch.stale)
        #expect(batch.items.count == 2)
        #expect(batch.items.allSatisfy { $0.publishedAt != nil })
        #expect(batch.fetchedAt == ResetNewsDate.parse("2026-09-22T03:30:00Z"))
        let structured = try #require(batch.items.first { $0.sourceID == "100" })
        #expect(structured.hints?.audience == ["codex", "chatgpt_work"])
        #expect(structured.hints?.scope == "global")
        let classified = try #require(ResetNewsRuleEngine().evaluate(structured, now: instant))
        #expect(classified.facts[0].kind == .resetAnnouncement)
        #expect(classified.facts[0].scope == "all")
        #expect(classified.facts[0].confidence == .explicit)
    }

    @Test func previewWindowIsUpcomingAndPreservesDeadline() throws {
        var value = event(preview: true)
        value["official_window"] = ["label": "within an hour", "start_at": "2026-09-22T03:00:00Z",
                                    "end_at": "2026-09-22T04:00:00Z", "target_at": "2026-09-22T04:00:00Z"]
        let batch = try ResetNewsSourceDecoder().decodeBatch(data(["events": [value], "updated_at": "2026-09-22T03:30:00Z"]), source: .timeline)
        let item = try #require(batch.items.first.flatMap { ResetNewsRuleEngine().evaluate($0, now: instant) })
        #expect(item.facts[0].kind == .upcomingReset)
        #expect(item.facts[0].effectiveAt == ResetNewsDate.parse("2026-09-22T04:00:00Z"))
        #expect(item.facts[0].timingText == "within an hour")
    }

    @Test func structuredCreditsDoNotClaimQuotaReset() throws {
        var value = event()
        value["group"] = "credits"; value["type"] = "credits"; value["banked_state"] = "announced"
        value["summary"] = "One banked reset for every day without Astra on a paid ChatGPT plan."
        let records = try ResetNewsSourceDecoder().decode(data([value]), source: .timeline)
        let item = try #require(records.first.flatMap { ResetNewsRuleEngine().evaluate($0, now: instant) })
        #expect(item.facts.map(\.kind) == [.extraResetCredits])
        #expect(item.facts[0].count == nil)
    }

    @Test(arguments: ["announced", "arriving", "available"])
    func structuredCreditDeliveryStatesAreExplicitWithoutActionKeyword(_ bankedState: String) throws {
        var value = event()
        value["group"] = "credits"; value["type"] = "credits"; value["reset_kind"] = "banked"
        value["confidence"] = "medium"; value["announcement_state"] = NSNull(); value["banked_state"] = bankedState
        value["summary"] = "A milestone banked-reset update for paid Codex and ChatGPT Work users."
        let records = try ResetNewsSourceDecoder().decode(data(["events": [value]]), source: .timeline)
        let item = try #require(records.first.flatMap { ResetNewsRuleEngine().evaluate($0, now: instant) })
        #expect(item.facts.map(\.kind) == [.extraResetCredits])
        #expect(item.facts[0].confidence == .explicit)
        #expect(item.facts[0].count == nil)
        #expect(records.first?.hints?.bankedState == bankedState)
        #expect(!item.summaryZH.contains("已到账") && !item.summaryZH.contains("你的账户"))
    }

    @Test(arguments: ["unknown", "null"])
    func uncertainStructuredCreditsAreExcludedFromForecasts(_ bankedState: String) throws {
        var value = event()
        value["group"] = "credits"; value["type"] = "credits"; value["reset_kind"] = "banked"
        value["confidence"] = "medium"; value["announcement_state"] = NSNull()
        value["banked_state"] = bankedState == "null" ? NSNull() : bankedState as Any
        value["summary"] = "Banked reset delivery details are under review."
        let records = try ResetNewsSourceDecoder().decode(data(["events": [value]]), source: .timeline)
        let now = try #require(records.first?.publishedAt)
        let result = ResetNewsReducer().reduce(previous: .init(hasBaseline: true), incoming: records, now: now)
        #expect(result.state.items.isEmpty)
        #expect(result.notificationCandidates.isEmpty && result.recoveryCandidates.isEmpty)
    }

    @Test func landedCreditAnnouncementAndExplicitCompensationAreNotDropped() throws {
        var value = event()
        value["group"] = "credits"; value["type"] = "credits"; value["reset_kind"] = "banked"
        value["confidence"] = "medium"; value["announcement_state"] = "none"; value["banked_state"] = "unknown"
        for text in ["The milestone banked reset landed in accounts for paid Codex and ChatGPT Work users, redeemable on demand.",
                     "Some banked resets were not fully applying in Codex. Everyone affected is getting another one."] {
            value["text"] = text
            let records = try ResetNewsSourceDecoder().decode(data(["events": [value]]), source: .timeline)
            let item = try #require(records.first.flatMap { ResetNewsRuleEngine().evaluate($0, now: instant) })
            #expect(item.facts[0].confidence == .explicit)
            #expect(item.facts[0].count == nil)
        }
    }

    @Test func bankedKindWithoutGroupStillCreatesFactAndOperatorObservationIsRejected() throws {
        var value = event()
        value.removeValue(forKey: "group"); value.removeValue(forKey: "type")
        value["reset_kind"] = "banked"; value["banked_state"] = NSNull(); value["announcement_state"] = NSNull()
        value["summary"] = "Banked reset delivery details."
        let records = try ResetNewsSourceDecoder().decode(data(["events": [value]]), source: .timeline)
        let item = try #require(records.first.flatMap { ResetNewsRuleEngine().evaluate($0, now: instant) })
        #expect(item.facts.map(\.kind) == [.extraResetCredits])
        #expect(item.facts[0].confidence == .explicit)
        value["source"] = "operator-observed"
        let observed = try ResetNewsSourceDecoder().decode(data(["events": [value]]), source: .timeline)
        #expect(observed.first.flatMap { ResetNewsRuleEngine().evaluate($0, now: instant) } == nil)
    }

    @Test func negatedAvailabilityDoesNotCreateCreditGrant() throws {
        var value = event()
        value["group"] = "credits"; value["type"] = "credits"; value["banked_state"] = "unknown"
        value["confidence"] = "medium"; value["announcement_state"] = "none"
        value["summary"] = "The Codex banked reset is not available."
        let records = try ResetNewsSourceDecoder().decode(data(["events": [value]]), source: .timeline)
        #expect(records.first?.structuredFacts?.isEmpty == true)
        #expect(records.first.flatMap { ResetNewsRuleEngine().evaluate($0, now: instant) } == nil)
    }

    @Test(arguments: ["No extra reset credits are available for Codex users.",
                      "No extra reset credits are available for Codex users. A new model is available."])
    func highConfidenceCannotTurnExplicitCreditDenialIntoGrant(_ text: String) throws {
        var value = event()
        value["group"] = "credits"; value["type"] = "credits"
        value["summary"] = text
        let records = try ResetNewsSourceDecoder().decode(data(["events": [value]]), source: .timeline)
        #expect(records.first?.structuredFacts?.isEmpty == true)
        let result = ResetNewsReducer().reduce(previous: .init(hasBaseline: true), incoming: records, now: instant)
        #expect(result.state.items.isEmpty && result.notificationCandidates.isEmpty)
    }

    @Test(arguments: ["https://x.com/other/status/100", "https://example.com/thsottiaux/status/100",
                      "http://x.com/thsottiaux/status/100", "https://x.com/thsottiaux/status/999",
                      "https://x.com/thsottiaux/status/100?tracking=1"])
    func rejectsInvalidCanonicalIdentity(_ url: String) throws {
        var value = event(); value["url"] = url
        let batch = try ResetNewsSourceDecoder().decodeBatch(data(["events": [value]]), source: .timeline)
        #expect(batch.identityValidated && batch.items.isEmpty && batch.rejectedIdentityCount == 1)
    }

    @Test func emptySuccessDiffersFromStaleAndIdentityFailure() throws {
        let valid: [String: Any] = ["profile": ["handle": "thsottiaux"], "source_scope": "timeline", "tweets": [], "events": []]
        let clean = try ResetNewsSourceDecoder().decodeBatch(data(valid), source: .feed)
        #expect(clean.identityValidated && clean.items.isEmpty && !clean.stale)
        var stale = valid; stale["stale"] = true
        #expect(try ResetNewsSourceDecoder().decodeBatch(data(stale), source: .feed).stale)
        var wrong = valid; wrong["profile"] = ["handle": "someone_else"]
        #expect(try !ResetNewsSourceDecoder().decodeBatch(data(wrong), source: .feed).identityValidated)
        #expect(throws: ResetNewsDecodingError.unsupportedEnvelope) {
            try ResetNewsSourceDecoder().decode(data(["unrelated": 123]), source: .timeline)
        }
    }

    @Test func operatorObservationDoesNotBecomeOfficialReset() throws {
        var value = event(); value["source"] = "operator-observed"
        let records = try ResetNewsSourceDecoder().decode(data(["events": [value]]), source: .timeline)
        #expect(records.first.flatMap { ResetNewsRuleEngine().evaluate($0, now: instant) } == nil)
    }

    @Test func nonemptyMalformedContainersNeverBecomeSuccessfulEmptyFeed() throws {
        for invalid: Any in [[123], [["id": "100"]], [["text": 123]], [["text": ["unexpected": "shape"]]], "invalid array"] {
            let payload: [String: Any] = ["profile": ["handle": "thsottiaux"], "source_scope": "timeline", "tweets": invalid, "events": []]
            #expect(throws: ResetNewsDecodingError.unsupportedEnvelope) {
                try ResetNewsSourceDecoder().decodeBatch(data(payload), source: .feed)
            }
        }
        #expect(throws: ResetNewsDecodingError.unsupportedEnvelope) {
            try ResetNewsSourceDecoder().decodeBatch(data(["events": [123]]), source: .timeline)
        }
    }

    @Test func confidenceAndAudienceAreMappedWithoutLosingRawHints() throws {
        var value = event()
        value["scope"] = "unknown"; value["confidence"] = "medium"; value["announcement_state"] = "none"
        let records = try ResetNewsSourceDecoder().decode(data(["events": [value]]), source: .timeline)
        let item = try #require(records.first.flatMap { ResetNewsRuleEngine().evaluate($0, now: instant) })
        #expect(item.facts[0].scope == "chatgpt_work,codex")
        #expect(item.facts[0].confidence == .tentative)
        #expect(records.first?.hints?.confidence == "medium")
        #expect(item.summaryZH.contains("待确认"))
    }
}

struct ResetNewsReducerTests {
    private func forecast(_ id: String = "100", source: ResetNewsSource = .feed, delay: TimeInterval = 3600,
                          publishedAt: Date? = instant, scope: String? = nil) -> ResetNewsSourceItem {
        post("Scheduled", id: id, source: source, publishedAt: publishedAt,
             facts: [.init(kind: .upcomingReset, scope: scope, effectiveAt: instant.addingTimeInterval(delay))])
    }

    @Test func firstSuccessfulBatchIsSilentAndBothSourcesAreOneItem() throws {
        let reducer = ResetNewsReducer()
        let first = reducer.reduce(previous: .init(), incoming: [forecast(), forecast(source: .timeline)], now: instant)
        #expect(first.state.hasBaseline && first.state.items.count == 1)
        #expect(first.state.items.first?.sources == [.feed, .timeline])
        #expect(first.notificationCandidates.isEmpty && first.state.notificationRecords.count == 1)
        let again = reducer.reduce(previous: first.state, incoming: [forecast()], now: instant.addingTimeInterval(120))
        #expect(again.state.items.first?.materialRevision == 1 && again.notificationCandidates.isEmpty)
    }

    @Test func partialSourceFailureKeepsAcceptedPlanAndDoesNotReplay() throws {
        let reducer = ResetNewsReducer()
        let feed = forecast()
        let timeline = forecast(source: .timeline)
        let first = reducer.reduce(previous: .init(), incoming: [feed, timeline], now: instant)
        let partial = reducer.reduce(previous: first.state, incoming: [feed], now: instant.addingTimeInterval(120))
        #expect(partial.state.items.first?.facts == first.state.items.first?.facts)
        #expect(partial.state.items.first?.sourceSnapshots?.count == 2)
        #expect(partial.state.items.first?.materialRevision == 1 && partial.notificationCandidates.isEmpty)
        var changed = forecast(source: .timeline, delay: 7200)
        changed.updatedAt = instant.addingTimeInterval(180)
        let updated = reducer.reduce(previous: partial.state, incoming: [feed, changed], now: instant.addingTimeInterval(180))
        #expect(updated.state.items.first?.facts.first?.effectiveAt == instant.addingTimeInterval(7200))
        #expect(updated.state.items.first?.materialRevision == 2 && updated.notificationCandidates.count == 1)
    }

    @Test func mixedFactsAndSnapshotsRetainOnlyForecastsWithoutCountingCreditQuantity() throws {
        var source = forecast()
        source.structuredFacts?.append(contentsOf: [.init(kind: .extraResetCredits, count: 99), .init(kind: .resetAnnouncement)])
        let first = ResetNewsReducer().reduce(previous: .init(hasBaseline: true), incoming: [source], now: instant)
        let item = try #require(first.state.items.first)
        #expect(first.state.items.count == 1 && item.facts.count == 1)
        #expect(item.sourceSnapshots?.allSatisfy { $0.facts.allSatisfy { $0.kind == .upcomingReset } } == true)
        let again = ResetNewsReducer().reduce(previous: first.state, incoming: [source], now: instant.addingTimeInterval(60))
        #expect(again.state.items.first?.materialRevision == item.materialRevision && again.notificationCandidates.isEmpty)
    }

    @Test(arguments: [ResetNewsStatus.cancelled, .superseded, .expired])
    func terminalStateRemovesCardAndPreventsOlderReplicaFromReturning(_ status: ResetNewsStatus) throws {
        let reducer = ResetNewsReducer()
        let first = reducer.reduce(previous: .init(), incoming: [forecast()], now: instant)
        var cancelled = forecast(source: .timeline); cancelled.status = status
        cancelled.updatedAt = instant.addingTimeInterval(60)
        let next = reducer.reduce(previous: first.state, incoming: [cancelled], now: instant.addingTimeInterval(60))
        #expect(next.state.items.isEmpty && next.notificationCandidates.isEmpty)
        #expect(next.state.retiredForecasts?.count == 1)
        let replay = reducer.reduce(previous: next.state, incoming: [forecast()], now: instant.addingTimeInterval(120))
        #expect(replay.state.items.isEmpty && replay.notificationCandidates.isEmpty)
        let json = String(decoding: try JSONEncoder().encode(next.state.retiredForecasts), as: UTF8.self)
        #expect(!json.contains("originalText") && !json.contains("facts"))
    }

    @Test func completedAnnouncementOverridesOlderPlanButUnknownClassificationIsNotTerminal() {
        let reducer = ResetNewsReducer()
        let first = reducer.reduce(previous: .init(), incoming: [forecast()], now: instant)
        var completed = post("We have reset Codex limits.", source: .timeline)
        completed.updatedAt = instant.addingTimeInterval(60)
        let result = reducer.reduce(previous: first.state, incoming: [completed], now: instant.addingTimeInterval(60))
        #expect(result.state.items.isEmpty && result.state.retiredForecasts?.count == 1)
        let unknown = post("Not scheduled yet", id: "other", facts: [.init(kind: .resetAnnouncement, confidence: .tentative)])
        let uncertain = reducer.reduce(previous: .init(), incoming: [unknown], now: instant)
        #expect(uncertain.state.items.isEmpty && uncertain.state.retiredForecasts?.isEmpty == true)
    }

    @Test func exactTimeTodayDoesNotExpireOrCreateUnreadRevisionAtTheClockTime() {
        let reducer = ResetNewsReducer()
        let first = reducer.reduce(previous: .init(), incoming: [forecast(delay: 5)], now: instant)
        let next = reducer.reduce(previous: first.state, incoming: [forecast(delay: 5)], now: instant.addingTimeInterval(10))
        #expect(next.state.items.first?.status == .active && next.state.items.first?.materialRevision == 1)
        #expect(next.notificationCandidates.isEmpty)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: instant))!
        let expired = reducer.reduce(previous: next.state, incoming: [forecast(delay: 5)], now: tomorrow)
        #expect(expired.state.items.isEmpty && expired.notificationCandidates.isEmpty)
    }

    @Test func futurePublicationOlderThanThirtyDaysSurvivesAndOrderingUsesSchedule() {
        let reducer = ResetNewsReducer()
        let later = forecast("later", delay: 7200, publishedAt: instant.addingTimeInterval(-90 * 86400))
        let sooner = forecast("sooner", delay: 3600)
        let result = reducer.reduce(previous: .init(hasBaseline: true), incoming: [later, sooner], now: instant)
        #expect(result.state.items.map(\.id) == [sooner.stableID, later.stableID])
        #expect(result.recoveryCandidates.map(\.id) == [later.stableID])
    }

    @Test func defaultDoesNotTruncateValidForecastsToFiftyAndLedgerStillBounded() {
        let incoming = (0..<60).map { forecast(String($0), delay: Double($0 + 1) * 60) }
        let result = ResetNewsReducer().reduce(previous: .init(), incoming: incoming, now: instant)
        #expect(result.state.items.count == 60)
        let ledger = (0..<510).map { ResetNewsNotificationRecord(key: "old:\($0)", recordedAt: instant) }
        let bounded = ResetNewsReducer().reduce(previous: .init(notificationRecords: ledger), incoming: [], now: instant)
        #expect(bounded.state.notificationRecords.count == 500)
    }

    @Test func scopeAndScheduleChangesAreMaterialButHistoricalFactEditsAreNot() {
        let reducer = ResetNewsReducer()
        let first = reducer.reduce(previous: .init(), incoming: [forecast(scope: "pro")], now: instant)
        let updated = reducer.reduce(previous: first.state, incoming: [forecast(scope: "all")], now: instant)
        #expect(updated.state.items.first?.materialRevision == 2)
        var same = forecast(scope: "all"); same.structuredFacts?.append(.init(kind: .extraResetCredits, count: 9))
        let unchanged = reducer.reduce(previous: updated.state, incoming: [same], now: instant)
        #expect(unchanged.state.items.first?.materialRevision == 2 && unchanged.notificationCandidates.isEmpty)
    }

    @Test func uncertainOrUnknownPublicationNeverCreatesStrongReminder() {
        let reducer = ResetNewsReducer()
        var source = forecast(publishedAt: nil)
        let unknown = reducer.reduce(previous: .init(hasBaseline: true), incoming: [source], now: instant)
        #expect(unknown.state.items.count == 1 && unknown.notificationCandidates.isEmpty)
        source.structuredFacts?[0].confidence = .tentative
        let tentative = reducer.reduce(previous: .init(hasBaseline: true), incoming: [source], now: instant)
        #expect(tentative.notificationCandidates.isEmpty && tentative.recoveryCandidates.isEmpty)
    }

    @Test func legacyCacheWithoutSnapshotsAndNewStateRoundTripStayCompatible() throws {
        let reducer = ResetNewsReducer()
        let first = reducer.reduce(previous: .init(), incoming: [forecast(), forecast(source: .timeline)], now: instant)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(first.state)) as? [String: Any])
        var items = try #require(json["items"] as? [[String: Any]])
        items[0].removeValue(forKey: "sourceSnapshots"); json["items"] = items; json.removeValue(forKey: "retiredForecasts")
        let legacy = try JSONDecoder().decode(ResetNewsState.self, from: JSONSerialization.data(withJSONObject: json))
        let next = reducer.reduce(previous: legacy, incoming: [forecast()], now: instant.addingTimeInterval(120))
        #expect(next.state.items.count == 1 && next.notificationCandidates.isEmpty)
        #expect(try JSONDecoder().decode(ResetNewsState.self, from: JSONEncoder().encode(next.state)) == next.state)
    }
}
