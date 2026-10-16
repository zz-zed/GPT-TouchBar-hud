import Foundation
import Testing
@testable import ResetNewsCore

@Suite("Time-first forecast presentation")
struct ResetForecastHeadlineTests {
    private let publication = ISO8601DateFormatter().date(from: "2026-10-15T04:56:07Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    @Test func relativeDeadlineUsesTheSameClockInMenuAndCard() {
        let value = ResetForecastHeadline(fact: .init(kind: .upcomingReset, timingText: "within the next 2 hours"),
            publishedAt: publication, now: publication, calendar: calendar)
        #expect(value.lead == "预计今天")
        #expect(value.headline == "14:56 前")
        #expect(value.summary == "预计今天 14:56 前")
        #expect(value.zoneText == "本地 UTC+08:00")
        #expect(value.basisText == "按 12:56 公告的「未来 2 小时内」换算")
    }
    @Test func unknownAndDateOnlyDoNotInventClocks() {
        let unknown = ResetForecastHeadline(fact: .init(kind: .upcomingReset), publishedAt: publication,
            now: publication, calendar: calendar)
        #expect(unknown.headline == "时间待定" && !unknown.hasClock && unknown.dateText == nil)
        let day = ResetForecastHeadline(fact: .init(kind: .upcomingReset, timingText: "tomorrow"),
            publishedAt: publication, now: publication, calendar: calendar)
        #expect(day.summary == "预计明天 · 时刻待公布")
        #expect(!day.hasClock && !day.headline.contains("00:00"))
    }
    @Test func exactTimeDoesNotGainADeadlineQualifier() {
        let value = ResetForecastHeadline(fact: .init(kind: .upcomingReset, effectiveAt: publication,
            effectiveAtPrecision: .exact), publishedAt: publication, now: publication, calendar: calendar)
        #expect(value.lead == "计划今天" && value.headline == "12:56")
        #expect(!value.summary.contains("前"))
    }
    @Test func crossDayWindowAndEndOfDayStayQualified() {
        let start = ISO8601DateFormatter().date(from: "2026-10-15T15:00:00Z")!
        let end = start.addingTimeInterval(7200)
        let window = ResetForecastHeadline(fact: .init(kind: .upcomingReset, effectiveAt: end,
            effectiveAtPrecision: .windowBoundary, officialWindow: .init(startAt: start, endAt: end)),
            publishedAt: publication, now: publication, calendar: calendar)
        #expect(window.lead == "预计时段" && window.headline == "23:00–01:00")
        #expect(window.dateText?.contains("10月16日") == true)
        let eod = ResetForecastHeadline(fact: .init(kind: .upcomingReset, timingText: "EOD PST"),
            publishedAt: publication, now: publication, calendar: calendar)
        #expect(eod.lead == "预计今天" && eod.headline == "16:00 前")
        #expect(eod.basisText?.contains("EOD") == true)
    }
    @Test func subminuteDurationRetainsItsAnnouncedDuration() {
        let value = ResetForecastHeadline(fact: .init(kind: .upcomingReset, timingText: "within 0.5 minutes"),
            publishedAt: publication, now: publication, calendar: calendar)
        #expect(value.basisText?.contains("30 秒") == true)
    }
}
