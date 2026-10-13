import Foundation
import Testing
@testable import ResetNewsCore

struct ResetForecastEndOfDayTests {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var publication: Date { date("2026-10-13T01:03:59Z") } // October 12 in Pacific time.
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    @Test(arguments: ["EOD PST time", "eod pst", "end of day PST", "end of the day PST",
                      "today EOD PST", "EOD today PST"])
    func endOfDayIsADeadlineAnchoredToPublication(_ label: String) throws {
        let text = "Global reset landing by \(label). Enjoy"
        let timing = try #require(ResetNewsRuleEngine().timingDetails(text).text)
        #expect(timing == label)
        let fact = ResetNewsFact(kind: .upcomingReset, timingText: timing)
        let resolved = try #require(ResetForecastTiming.resolve(fact, publishedAt: publication, calendar: calendar()))
        #expect(resolved.date == date("2026-10-13T08:00:00Z"))
        #expect(resolved.precision == .deadline && resolved.isEndOfDay)
        let display = ResetForecastDatePresentation(fact: fact, publishedAt: publication, now: publication, calendar: calendar())
        #expect(display.dateText == "10月13日（周二）")
        #expect(display.timeText == "预计在 16:00 前（本地 UTC+08:00）")
        #expect(!display.isExactTime && display.basisText?.contains("非确定重置时刻") == true)
        #expect(fact.effectiveAt == nil && fact.officialWindow == nil)
    }

    @Test(arguments: ["tomorrow EOD PST", "EOD tomorrow PST", "2026-10-13 end of day PST",
                      "end of day 2026-10-13 PST"])
    func explicitDayIsNotLostDuringExtraction(_ label: String) throws {
        let timing = ResetForecastTiming.timingText(in: "Codex will reset by \(label).")
        #expect(timing == label)
        let resolved = try #require(ResetForecastTiming.resolve(.init(kind: .upcomingReset, timingText: timing),
                                                               publishedAt: publication, calendar: calendar()))
        #expect(resolved.date == date("2026-10-14T08:00:00Z") && resolved.precision == .deadline)
    }

    @Test(arguments: [
        ("2026-03-08 EOD PT", "2026-03-09T07:00:00Z"), // 23-hour civil day.
        ("2026-11-01 EOD PT", "2026-11-02T08:00:00Z"), // 25-hour civil day.
        ("2026-10-12 EOD PT", "2026-10-13T07:00:00Z"),
        ("2026-10-12 EOD PDT", "2026-10-13T07:00:00Z"),
        ("2026-10-12 EOD PST", "2026-10-13T08:00:00Z"),
        ("2026-12-31 end of day UTC", "2027-01-01T00:00:00Z")
    ])
    func dayEndUsesCalendarArithmeticAndTheDeclaredZone(_ label: String, _ expected: String) throws {
        let timing = ResetForecastTiming.timingText(in: "Reset by \(label).")
        #expect(timing == label)
        let resolved = try #require(ResetForecastTiming.resolve(.init(kind: .upcomingReset, timingText: timing),
                                                               publishedAt: nil, calendar: calendar()))
        #expect(resolved.date == date(expected) && resolved.precision == .deadline)
    }

    @Test(arguments: ["EOD", "EOD CST", "end of day ET", "EOD XYZ"])
    func missingOrAmbiguousTimezoneCannotProduceALocalDeadline(_ label: String) {
        let fact = ResetNewsFact(kind: .upcomingReset, timingText: ResetForecastTiming.timingText(in: "Reset by \(label)."))
        #expect(ResetForecastTiming.resolve(fact, publishedAt: publication, calendar: calendar()) == nil)
        let display = ResetForecastDatePresentation(fact: fact, publishedAt: publication, calendar: calendar())
        #expect(!display.isExactTime && display.timeText == "具体时刻未公布")
    }

    @Test func sourceZoneQualifiesOnlyAnUnzonedDeadline() throws {
        let fact = ResetNewsFact(kind: .upcomingReset, timingText: "EOD", sourceTimeZone: "PT")
        let resolved = try #require(ResetForecastTiming.resolve(fact, publishedAt: publication, calendar: calendar()))
        #expect(resolved.date == date("2026-10-13T07:00:00Z"))
        #expect(fact.materialKey != ResetNewsFact(kind: .upcomingReset, timingText: "EOD", sourceTimeZone: "UTC").materialKey)
        #expect(fact.materialKey == ResetNewsFact(kind: .upcomingReset, timingText: "EOD", sourceTimeZone: "America/Los_Angeles").materialKey)
        let explicit = ResetNewsFact(kind: .upcomingReset, timingText: "EOD PST", sourceTimeZone: "UTC")
        #expect(explicit.materialKey == ResetNewsFact(kind: .upcomingReset, timingText: "EOD PST").materialKey)
        #expect(ResetForecastTiming.resolve(explicit, publishedAt: publication, calendar: calendar())?.date == date("2026-10-13T08:00:00Z"))
        #expect(ResetForecastTiming.resolve(fact, publishedAt: nil, calendar: calendar()) == nil)
        #expect(ResetForecastTiming.resolve(.init(kind: .upcomingReset, timingText: "EOD CST", sourceTimeZone: "UTC"),
                                          publishedAt: publication, calendar: calendar()) == nil)
    }

    @Test func conversionFollowsTheViewersTimezoneAndRetainsDeadlineWordingInEnglish() {
        let fact = ResetNewsFact(kind: .upcomingReset, timingText: "EOD PST")
        let display = ResetForecastDatePresentation(fact: fact, publishedAt: publication, now: publication,
                                                   calendar: calendar("America/Los_Angeles"), locale: Locale(identifier: "en_US"))
        #expect(display.dateText == "Oct 13 (Tue)")
        #expect(display.timeText == "Expected by 01:00 (local UTC-07:00)")
        #expect(!display.isExactTime && display.basisText?.contains("not an exact reset time") == true)
    }

    @Test func liveSignalShapeSurvivesCacheAndExpiresWithoutClaimingCompletion() throws {
        let payload: [String: Any] = [
            "updated_at": "2026-10-13T01:52:42Z", "last_reset_at": NSNull(),
            "official_signal": ["tweet_id": "2109812360596865224",
                "url": "https://x.com/thsottiaux/status/2109812360596865224",
                "summary": "Global reset landing by EOD PST time. Enjoy",
                "at": "2026-10-13T01:03:59Z", "window": NSNull()]
        ]
        let decoded = try ResetForecastSnapshotDecoder().decode(JSONSerialization.data(withJSONObject: payload))
        let snapshot = try JSONDecoder().decode(ResetForecastSnapshot.self, from: JSONEncoder().encode(decoded))
        #expect(snapshot == decoded)
        let signal = try #require(snapshot.officialSignal)
        let item = try #require(snapshot.item(now: date("2026-10-13T07:59:59Z"), calendar: calendar()))
        let summary = ResetNewsSummary.chinese(item, now: publication, calendar: calendar())
        #expect(summary.contains("10月13日（周二）") && summary.contains("预计在 16:00 前"))
        #expect(!summary.contains("日期待公布") && !summary.contains("已完成"))
        #expect(signal.expiresAt(calendar: calendar()) == date("2026-10-13T08:00:00Z"))
        #expect(snapshot.item(now: date("2026-10-13T08:00:00Z"), calendar: calendar()) == nil)
        #expect(snapshot.lastResetAt == nil && signal.evidenceItem().facts[0].kind == .upcomingReset)
        var refreshed = snapshot
        refreshed.updatedAt = date("2026-10-13T03:00:00Z")
        #expect(refreshed.notificationKey == snapshot.notificationKey)
    }
}
