import Foundation
import Testing
@testable import ResetNewsCore

struct ResetForecastPolicyTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private var noon: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))! }
    private func item(_ facts: [ResetNewsFact], published: Date? = nil, status: ResetNewsStatus = .active,
                      text: String = "Scheduled") -> ResetNewsItem {
        ResetNewsItem(id: "one", sources: [.feed], originalText: text, facts: facts, status: status,
                      publishedAt: published, firstSeenAt: noon)
    }

    @Test func localDayKeepsEarlierTodayButNotYesterday() {
        let policy = ResetForecastPolicy(calendar: calendar)
        let today = calendar.startOfDay(for: noon)
        let facts = [ResetNewsFact(kind: .upcomingReset, effectiveAt: today.addingTimeInterval(-1)),
                     .init(kind: .upcomingReset, effectiveAt: today),
                     .init(kind: .upcomingReset, effectiveAt: noon.addingTimeInterval(-1)),
                     .init(kind: .resetAnnouncement), .init(kind: .extraResetCredits, count: 50),
                     .init(kind: .upcomingReset), .init(kind: .upcomingReset, effectiveAt: Date(timeIntervalSince1970: .nan))]
        #expect(policy.retaining(item(facts), now: noon)?.facts.count == 2)
        #expect(policy.retaining(item(facts, status: .cancelled), now: noon) == nil)
    }

    @Test func relativeDaysUsePublicationNotDiscoveryOrRefreshAndDoNotInventTimes() throws {
        let policy = ResetForecastPolicy(calendar: calendar)
        let tomorrow = ResetNewsFact(kind: .upcomingReset, timingText: "tomorrow")
        let publishedYesterday = calendar.date(byAdding: .day, value: -1, to: noon)!
        let retained = try #require(policy.retaining(item([tomorrow], published: publishedYesterday), now: noon))
        #expect(policy.firstDate(retained) == calendar.startOfDay(for: noon))
        #expect(retained.facts[0].effectiveAt == nil)
        #expect(policy.retaining(item([tomorrow]), now: noon) == nil)
        #expect(policy.retaining(retained, now: calendar.date(byAdding: .day, value: 1, to: noon)!) == nil)
        #expect(policy.retaining(item([.init(kind: .upcomingReset, timingText: "soon")], published: noon), now: noon) == nil)
    }

    @Test func actualTuesdayPromiseIsDateLevelTentativeAndCannotRollForwardNextWeek() throws {
        let text = "Ladies and gentlemen... start... your... ENGINES. We are almost Tuesday and I promised a reset for Tuesday. Among some other things. See you soon."
        let policy = ResetForecastPolicy(calendar: calendar)
        let legacy = item([.init(kind: .resetAnnouncement, confidence: .tentative)], published: noon, text: text)
        let retained = try #require(policy.retaining(legacy, now: noon))
        #expect(retained.facts.first?.kind == .upcomingReset && retained.facts.first?.confidence == .tentative)
        #expect(retained.facts.first?.effectiveAt == nil && policy.firstDate(retained) == calendar.startOfDay(for: noon))
        #expect(!policy.isConfirmedTerminal(legacy))
        #expect(policy.retaining(legacy, now: noon.addingTimeInterval(7 * 86400)) == nil)
        let source = ResetNewsSourceItem(source: .timeline, body: text, publishedAt: noon, structuredFacts: legacy.facts)
        #expect(ResetNewsRuleEngine().evaluate(source, now: noon)?.facts.first?.kind == .upcomingReset)
    }

    @Test(arguments: [ResetNewsConfidence.explicit, .tentative])
    func explicitCompletionWinsOverHistoricalPromise(_ confidence: ResetNewsConfidence) {
        let policy = ResetForecastPolicy(calendar: calendar)
        let completed = item([.init(kind: .resetAnnouncement, confidence: confidence)], published: noon,
                             text: "I promised a reset for Tuesday. Reset all propagated; it has now completed.")
        #expect(policy.retaining(completed, now: noon) == nil && policy.isConfirmedTerminal(completed))
        for text in ["I promised a reset for Tuesday. The reset has been cancelled.", "The reset scheduled for Tuesday has been cancelled."] {
            let cancelled = item([.init(kind: .resetAnnouncement, confidence: confidence)], published: noon, text: text)
            #expect(policy.retaining(cancelled, now: noon) == nil && policy.isConfirmedTerminal(cancelled))
        }
    }

    @Test func timeZoneChangeAndDSTUseNaturalDayBoundaries() {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var losAngeles = utc; losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = ISO8601DateFormatter().date(from: "2026-11-01T06:30:00Z")!
        let planned = ISO8601DateFormatter().date(from: "2026-10-31T23:00:00Z")!
        let forecast = item([.init(kind: .upcomingReset, effectiveAt: planned)])
        #expect(ResetForecastPolicy(calendar: utc).retaining(forecast, now: now) == nil)
        #expect(ResetForecastPolicy(calendar: losAngeles).retaining(forecast, now: now) != nil)
    }

    @Test func completedAliasesFromSourceAreTerminalEvenWithFuturePreview() throws {
        for status in ["completed", "executed", "done"] {
            let record: [String: Any] = ["id": "100", "url": "https://x.com/thsottiaux/status/100", "summary": "Codex reset scheduled for Tuesday",
                "group": "reset", "preview": true, "status": status, "effective_at": noon.addingTimeInterval(86400).timeIntervalSince1970]
            let decoded = try ResetNewsSourceDecoder().decode(JSONSerialization.data(withJSONObject: ["events": [record]]), source: .timeline)
            #expect(decoded.first?.status == .expired)
            #expect(ResetNewsReducer().reduce(previous: .init(), incoming: decoded, now: noon).state.items.isEmpty)
        }
    }

    @Test func sameEndpointCompletedEventWinsOverLongerOldTweet() {
        let date = noon.addingTimeInterval(3600)
        let tweet = ResetNewsSourceItem(source: .feed, sourceID: "100", body: "Codex limits will reset today.", publishedAt: noon,
                                        structuredFacts: [.init(kind: .upcomingReset, effectiveAt: date)])
        let event = ResetNewsSourceItem(source: .feed, sourceID: "100", body: "Reset all propagated.", publishedAt: noon,
                                        structuredFacts: [.init(kind: .resetAnnouncement, effectiveAt: date)])
        let result = ResetNewsReducer().reduce(previous: .init(), incoming: [tweet, event], now: noon)
        #expect(result.state.items.isEmpty && result.state.retiredForecasts?.count == 1)
    }

    @Test func structuredForecastFillsOnlyMissingTimingFromExplicitText() throws {
        var record: [String: Any] = ["id": "100", "url": "https://x.com/thsottiaux/status/100",
            "summary": "Codex limits will reset tomorrow.", "group": "reset", "preview": true,
            "confidence": "high", "announced_at": noon.timeIntervalSince1970]
        let decoder = ResetNewsSourceDecoder()
        let reducer = ResetNewsReducer(forecastPolicy: .init(calendar: calendar))
        let decoded = try decoder.decode(JSONSerialization.data(withJSONObject: ["events": [record]]), source: .timeline)
        let result = reducer.reduce(previous: .init(), incoming: decoded, now: noon)
        #expect(result.state.items.first?.facts.first?.timingText == "tomorrow")
        #expect(result.state.items.first?.facts.first?.effectiveAt == nil)
        record["effective_at"] = noon.addingTimeInterval(3 * 86400).timeIntervalSince1970
        let explicit = try decoder.decode(JSONSerialization.data(withJSONObject: ["events": [record]]), source: .timeline)
        #expect(reducer.reduce(previous: .init(), incoming: explicit, now: noon).state.items.first?.facts.first?.effectiveAt == noon.addingTimeInterval(3 * 86400))
    }

    @Test func fullCalendarDateNeedsNoPublicationAndRejectsInvalidDay() {
        let policy = ResetForecastPolicy(calendar: calendar)
        #expect(policy.retaining(item([.init(kind: .upcomingReset, timingText: "2026-09-23")]), now: noon) != nil)
        #expect(policy.scheduledDate(for: .init(kind: .upcomingReset, timingText: "2026-02-30"), publishedAt: nil) == nil)
        #expect(policy.scheduledDate(for: .init(kind: .upcomingReset, timingText: "2026-09-23 14:00 PT"), publishedAt: noon)
            == ISO8601DateFormatter().date(from: "2026-09-23T21:00:00Z"))
    }

    @Test(arguments: ["Codex reset will be completed tomorrow.", "Codex reset has not yet completed.", "The reset is not cancelled."])
    func futureOrNegatedCompletionIsNotTerminal(_ text: String) {
        let policy = ResetForecastPolicy(calendar: calendar)
        let upcoming = item([.init(kind: .upcomingReset, timingText: "tomorrow")], published: noon, text: text)
        #expect(!policy.isConfirmedTerminal(upcoming))
        #expect(policy.retaining(upcoming, now: noon) != nil)
    }

    @Test func completedResetAndSeparatelyAnnouncedFutureResetRemainDistinct() throws {
        let policy = ResetForecastPolicy(calendar: calendar)
        let text = "Reset all propagated. We will reset Codex limits tomorrow."
        let mixed = item([.init(kind: .resetAnnouncement),
                          .init(kind: .upcomingReset, timingText: "tomorrow", evidence: "We will reset Codex limits tomorrow.")],
                         published: noon, text: text)
        let retained = try #require(policy.retaining(mixed, now: noon))
        #expect(retained.facts.count == 1 && retained.facts.first?.kind == .upcomingReset)
        #expect(!policy.isConfirmedTerminal(mixed))
        let cancelled = item([.init(kind: .upcomingReset, timingText: "tomorrow")], published: noon,
                             text: "We planned to reset Codex limits tomorrow. The reset has been cancelled.")
        #expect(policy.retaining(cancelled, now: noon) == nil && policy.isConfirmedTerminal(cancelled))
    }

    @Test func passedClocksRemainCardsWithoutCreatingFutureReminders() throws {
        let policy = ResetForecastPolicy(calendar: calendar)
        for precision in [ResetNewsTimePrecision.exact, .deadline] {
            let forecast = item([.init(kind: .upcomingReset, effectiveAt: noon.addingTimeInterval(-60), effectiveAtPrecision: precision)])
            #expect(policy.retaining(forecast, now: noon) != nil)
            #expect(policy.reminder(for: forecast, now: noon) == nil)
        }
        let facts: [ResetNewsFact] = [.init(kind: .upcomingReset, effectiveAt: noon.addingTimeInterval(-60), effectiveAtPrecision: .exact),
                                     .init(kind: .upcomingReset, effectiveAt: noon.addingTimeInterval(3600), effectiveAtPrecision: .exact)]
        #expect(policy.reminder(for: item(facts), now: noon)?.facts.count == 1)
        #expect(policy.reminder(for: item([.init(kind: .upcomingReset, timingText: "today")], published: noon), now: noon) != nil)
        let window = ResetNewsOfficialWindow(startAt: noon.addingTimeInterval(-120), endAt: noon.addingTimeInterval(-60))
        let forecast = item([.init(kind: .upcomingReset, effectiveAt: window.endAt, effectiveAtPrecision: .windowBoundary, officialWindow: window)])
        #expect(policy.retaining(forecast, now: noon) != nil && policy.reminder(for: forecast, now: noon) == nil)
        let later = ISO8601DateFormatter().date(from: "2026-10-03T10:00:00Z")!
        let sourceDay = item([.init(kind: .upcomingReset, timingText: "2026-10-02", sourceTimeZone: "PT")])
        #expect(policy.retaining(sourceDay, now: later) != nil)
        #expect(policy.reminder(for: sourceDay, now: later) == nil)
    }
}
