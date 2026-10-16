import Foundation
import Testing
@testable import ResetNewsCore

struct ResetForecastRelativeDeadlineTests {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    @Test func october15SignalWithNullWindowShowsItsPublicationRelativeDeadline() throws {
        // Captured announcement identity, wording and timestamps; unrelated API fields omitted.
        let payload = #"{"updated_at":"2026-10-15T04:59:16.415Z","last_reset_at":"2026-10-13T05:03:51.000Z","official_signal":{"tweet_id":"2110595554036400151","summary":"Landing within the next 2 hours","at":"2026-10-15T04:56:07.000Z","url":"https://x.com/thsottiaux/status/2110595554036400151","window":null}}"#
        let snapshot = try ResetForecastSnapshotDecoder().decode(Data(payload.utf8))
        let signal = try #require(snapshot.officialSignal)
        let now = date("2026-10-15T05:17:15Z")
        let item = try #require(snapshot.item(now: now, calendar: calendar()))
        let fact = try #require(item.facts.first)
        let rendered = ResetForecastDatePresentation(fact: fact, publishedAt: item.publishedAt,
                                                     now: now, calendar: calendar())
        #expect(fact.timingText == "within the next 2 hours")
        #expect(rendered.dateText == "10月15日（周四）")
        #expect(rendered.timeText == "预计在 14:56 前（本地 UTC+08:00）")
        #expect(!rendered.isExactTime && rendered.basisText?.contains("公告发布时间") == true)
        #expect(fact.effectiveAt == nil && signal.officialWindow == nil)
        let deadline = date("2026-10-15T06:56:07Z")
        #expect(signal.expiresAt(calendar: calendar()) == deadline)
        #expect(snapshot.item(now: deadline.addingTimeInterval(-1), calendar: calendar()) != nil)
        #expect(snapshot.item(now: deadline, calendar: calendar()) == nil)
        #expect(snapshot.lastResetAt == date("2026-10-13T05:03:51Z"))
        #expect(ResetNewsSummary.chinese(item, now: now, calendar: calendar()).contains("预计在 14:56 前"))
    }

    @Test(arguments: [
        ("within the next 2 hours", 7200.0), ("within 2 hours", 7200.0),
        ("within two hours", 7200.0), ("within an hour", 3600.0),
        ("within the next hour", 3600.0), ("within a minute", 60.0),
        ("within 30 minutes", 1800.0), ("within the next 15 mins", 900.0),
        ("within 1.5 hours", 5400.0)
    ]) func relativeDurationsResolveAsDeadlines(_ text: String, _ seconds: TimeInterval) throws {
        let publication = date("2026-10-15T04:56:07Z")
        #expect(ResetForecastTiming.timingText(in: "Landing \(text).") == text)
        let fact = ResetNewsFact(kind: .upcomingReset, timingText: text)
        let resolved = try #require(ResetForecastTiming.resolve(fact, publishedAt: publication, calendar: calendar()))
        #expect(resolved.date == publication.addingTimeInterval(seconds))
        #expect(resolved.precision == .deadline && resolved.inferredFromPublication)
        #expect(fact.effectiveAt == nil)
    }

    @Test(arguments: ["within 0 hours", "within -2 hours", "within 2–3 hours", "within a few hours", "within about 2 hours"])
    func ambiguousOrNonpositiveDurationsDoNotInventTimes(_ text: String) {
        let fact = ResetNewsFact(kind: .upcomingReset, timingText: text)
        #expect(ResetForecastTiming.resolve(fact, publishedAt: date("2026-10-15T04:56:07Z"), calendar: calendar()) == nil)
    }

    @Test(arguments: ["within 1 hour and 30 minutes", "within 1 hour 30 minutes",
        "within 1 hour, 30 minutes", "within 1 hour, and 30 minutes", "within 1 hour and30minutes"])
    func compoundDurationSurvivesTheFullSignalChain(_ text: String) throws {
        let publication = date("2026-10-15T04:00:00Z")
        let signal = ResetForecastSignal(sourceID: "123", sourceURL: URL(string: "https://x.com/thsottiaux/status/123")!,
            originalText: "Landing \(text).", publishedAt: publication)
        let fact = try #require(signal.evidenceItem(calendar: calendar()).facts.first)
        #expect(fact.timingText == text)
        let resolved = try #require(ResetForecastTiming.resolve(fact, publishedAt: publication, calendar: calendar()))
        #expect(resolved.precision == .deadline && resolved.date == publication.addingTimeInterval(5400))
        #expect(signal.expiresAt(calendar: calendar()) == publication.addingTimeInterval(5400))
        let snapshot = ResetForecastSnapshot(updatedAt: publication, lastResetAt: nil, officialSignal: signal)
        #expect(snapshot.item(now: publication.addingTimeInterval(75 * 60), calendar: calendar()) != nil)
        #expect(snapshot.item(now: publication.addingTimeInterval(90 * 60 - 1), calendar: calendar()) != nil)
        #expect(snapshot.item(now: publication.addingTimeInterval(90 * 60), calendar: calendar()) == nil)
    }

    @Test(arguments: ["within 1 hour and thirty minutes", "within 1 hour thirty minutes",
        "within 1 hour, thirty minutes", "within 1 hour and 30 seconds",
        "within 1 hour and 30–40 minutes", "within 1 hour and about 30 minutes"])
    func unsupportedDurationContinuationCannotExpireAPrefix(_ text: String) throws {
        let publication = date("2026-10-15T04:00:00Z")
        let signal = ResetForecastSignal(sourceID: "123", sourceURL: URL(string: "https://x.com/thsottiaux/status/123")!,
            originalText: "Landing \(text).", publishedAt: publication)
        let fact = try #require(signal.evidenceItem(calendar: calendar()).facts.first)
        #expect(ResetForecastTiming.resolve(fact, publishedAt: publication, calendar: calendar()) == nil)
        #expect(signal.expiresAt(calendar: calendar()) == nil)
        let snapshot = ResetForecastSnapshot(updatedAt: publication, lastResetAt: nil, officialSignal: signal)
        #expect(snapshot.item(now: publication.addingTimeInterval(75 * 60), calendar: calendar()) != nil)
        #expect(snapshot.item(now: publication.addingTimeInterval(90 * 60), calendar: calendar()) != nil)
    }

    @Test(arguments: ["Landing within an hour. Thirty minutes later we will post details.",
        "Landing within an hour, compared with several days last time."])
    func unrelatedFollowingProseDoesNotInvalidateSingleDuration(_ originalText: String) throws {
        let publication = date("2026-10-15T04:00:00Z")
        let signal = ResetForecastSignal(sourceID: "123", sourceURL: URL(string: "https://x.com/thsottiaux/status/123")!,
            originalText: originalText, publishedAt: publication)
        let fact = try #require(signal.evidenceItem(calendar: calendar()).facts.first)
        #expect(fact.timingText == "within an hour")
        #expect(signal.expiresAt(calendar: calendar()) == publication.addingTimeInterval(3600))
    }

    @Test func missingPublicationCannotBorrowTheCurrentClock() {
        let fact = ResetNewsFact(kind: .upcomingReset, timingText: "within the next 2 hours")
        #expect(ResetForecastTiming.resolve(fact, publishedAt: nil, calendar: calendar()) == nil)
        let rendered = ResetForecastDatePresentation(fact: fact, publishedAt: nil,
                                                     now: date("2026-10-15T05:17:15Z"), calendar: calendar())
        #expect(rendered.timeText == "具体时刻未公布" && !rendered.isExactTime)
    }

    @Test func refreshAndCacheRoundTripCannotMoveDeadlineOrReplayNotification() throws {
        let publication = date("2026-10-15T04:56:07Z")
        let signal = ResetForecastSignal(sourceID: "2110595554036400151",
            sourceURL: URL(string: "https://x.com/thsottiaux/status/2110595554036400151")!,
            originalText: "Landing within the next 2 hours", publishedAt: publication)
        let first = ResetForecastSnapshot(updatedAt: publication, lastResetAt: nil, officialSignal: signal)
        var refreshed = first
        refreshed.updatedAt = publication.addingTimeInterval(600)
        let reloaded = try JSONDecoder().decode(ResetForecastSnapshot.self, from: JSONEncoder().encode(refreshed))
        #expect(first.notificationKey == reloaded.notificationKey)
        #expect(reloaded.officialSignal?.expiresAt(calendar: calendar()) == publication.addingTimeInterval(7200))
        var corrected = signal
        corrected.publishedAt = publication.addingTimeInterval(60)
        #expect(corrected.notificationKey != signal.notificationKey)
    }

    @Test func elapsedDurationCrossesLocalMidnightAndDaylightSavingWithoutGuessingAZone() throws {
        let fact = ResetNewsFact(kind: .upcomingReset, timingText: "within the next 2 hours", sourceTimeZone: "CST")
        let publication = date("2026-10-15T15:30:00Z")
        let rendered = ResetForecastDatePresentation(fact: fact, publishedAt: publication,
                                                     now: publication, calendar: calendar())
        #expect(rendered.dateText == "10月16日（周五）")
        #expect(rendered.timeText == "预计在 01:30 前（本地 UTC+08:00）")
        let beforeFallback = date("2026-11-01T07:30:00Z")
        let pacific = calendar("America/Los_Angeles")
        let resolved = try #require(ResetForecastTiming.resolve(fact, publishedAt: beforeFallback, calendar: pacific))
        #expect(resolved.date == date("2026-11-01T09:30:00Z"))
        let english = ResetForecastDatePresentation(fact: fact, publishedAt: beforeFallback,
            now: beforeFallback, calendar: pacific, locale: Locale(identifier: "en_US"))
        #expect(english.timeText == "Expected by 01:30 (local UTC-08:00)" && !english.isExactTime)
        #expect(english.basisText?.contains("publication") == true)
    }

    @Test func explicitSourceDeadlineTakesPrecedenceOverRelativeWording() throws {
        let publication = date("2026-10-15T04:56:07Z")
        let deadline = date("2026-10-15T07:00:00Z")
        let fact = ResetNewsFact(kind: .upcomingReset, timingText: "within the next 2 hours",
            officialWindow: .init(targetAt: deadline, targetKind: "deadline"))
        let resolved = try #require(ResetForecastTiming.resolve(fact, publishedAt: publication, calendar: calendar()))
        #expect(resolved.date == deadline && resolved.precision == .deadline)
        #expect(!resolved.inferredFromPublication)
    }
}
