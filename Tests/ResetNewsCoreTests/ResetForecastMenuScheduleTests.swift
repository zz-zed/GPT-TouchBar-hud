import Foundation
import Testing
@testable import ResetNewsCore

@Suite("Compact menu schedule")
struct ResetForecastMenuScheduleTests {
    private func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(identifier: zone)!
        return result
    }
    @Test(arguments: ["zh_CN", "en_US"])
    func exactAndDeadlineKeepBothDateAndTime(_ locale: String) throws {
        let now = date("2026-10-23T04:00:00Z")
        let reset = date("2026-10-23T17:00:00Z")
        let exact = try #require(ResetForecastMenuSchedule(fact: .init(kind: .upcomingReset, effectiveAt: reset, effectiveAtPrecision: .exact),
            publishedAt: now, now: now, calendar: calendar(), locale: Locale(identifier: locale)))
        let deadline = try #require(ResetForecastMenuSchedule(fact: .init(kind: .upcomingReset, effectiveAt: reset, effectiveAtPrecision: .deadline),
            publishedAt: now, now: now, calendar: calendar(), locale: Locale(identifier: locale)))
        #expect(exact.value == "10/24 01:00")
        #expect(deadline.value == (locale == "zh_CN" ? "10/24 01:00 前" : "10/24 by 01:00"))
    }
    @Test func crossYearKeepsBothYearsOnTwoLines() throws {
        let now = date("2026-12-31T04:00:00Z")
        let start = date("2026-12-31T15:00:00Z"), end = date("2026-12-31T17:00:00Z")
        let schedule = try #require(ResetForecastMenuSchedule(fact: .init(kind: .upcomingReset, effectiveAt: end,
            effectiveAtPrecision: .windowBoundary, officialWindow: .init(startAt: start, endAt: end)),
            publishedAt: now, now: now, calendar: calendar(), locale: Locale(identifier: "en_US")))
        #expect(schedule.value == "2026/12/31 23:00\n2027/01/01 01:00")
    }
    @Test func daylightSavingWindowKeepsBothOffsets() throws {
        let now = date("2026-10-31T00:00:00Z")
        let start = date("2026-11-01T08:00:00Z"), end = date("2026-11-01T11:00:00Z")
        let schedule = try #require(ResetForecastMenuSchedule(fact: .init(kind: .upcomingReset, effectiveAt: end,
            effectiveAtPrecision: .windowBoundary, officialWindow: .init(startAt: start, endAt: end)),
            publishedAt: now, now: now, calendar: calendar("America/Los_Angeles"), locale: Locale(identifier: "en_US")))
        #expect(schedule.value == "11/01\n01:00–03:00")
        #expect(schedule.detail == "From UTC−07:00; to UTC−08:00")
    }
    @Test func dateOnlyDoesNotInventMidnight() throws {
        let now = date("2026-10-23T04:00:00Z")
        let schedule = try #require(ResetForecastMenuSchedule(fact: .init(kind: .upcomingReset, timingText: "tomorrow"),
            publishedAt: now, now: now, calendar: calendar(), locale: Locale(identifier: "zh_CN")))
        #expect(schedule.value == "10/24\n时刻待公布")
        #expect(!schedule.value.contains("00:00"))
        #expect(ResetForecastMenuSchedule(fact: .init(kind: .upcomingReset), publishedAt: now, now: now,
            calendar: calendar(), locale: Locale(identifier: "zh_CN")) == nil)
    }
}
