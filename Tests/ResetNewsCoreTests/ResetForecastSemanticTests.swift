import Foundation
import Testing
@testable import ResetNewsCore

@Suite("Forecast temporal semantics")
struct ResetForecastSemanticTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }
    @Test func exactAndDeadlineKeepDifferentTypedMeaning() {
        let now = date("2026-10-15T04:00:00Z")
        let exact = ResetForecastHeadline(fact: .init(kind: .upcomingReset, effectiveAt: now, effectiveAtPrecision: .exact),
            publishedAt: now, now: now, calendar: calendar("Asia/Shanghai"))
        let deadline = ResetForecastHeadline(fact: .init(kind: .upcomingReset, effectiveAt: now, effectiveAtPrecision: .deadline),
            publishedAt: now, now: now, calendar: calendar("Asia/Shanghai"))
        #expect(exact.kind == .exact && deadline.kind == .deadline)
        #expect(exact.compactValue == "12:00" && deadline.compactValue == "12:00 前")
        #expect(exact.day == .today && exact == exact)
    }
    @Test func relativeDayChangesWithContextWithoutChangingFact() {
        let now = date("2026-12-31T04:00:00Z")
        let fact = ResetNewsFact(kind: .upcomingReset, timingText: "tomorrow")
        let first = ResetForecastHeadline(fact: fact, publishedAt: now, now: now, calendar: calendar("Asia/Shanghai"))
        let next = ResetForecastHeadline(fact: fact, publishedAt: now, now: now.addingTimeInterval(86400), calendar: calendar("Asia/Shanghai"))
        #expect(first.kind == .dateOnly && first.day == .tomorrow && first.compactValue == "明天")
        #expect(next.kind == .dateOnly && next.day == .today && next.compactValue == "今天")
        #expect(first.dateText?.contains("2027") == true)
        #expect(!next.compactDetail.contains("00:00"))
    }
    @Test func crossDayDSTWindowRetainsBothDatesAndOffsets() {
        let start = date("2026-11-01T06:00:00Z"), end = date("2026-11-01T10:00:00Z")
        let fact = ResetNewsFact(kind: .upcomingReset, effectiveAt: end, effectiveAtPrecision: .windowBoundary,
            officialWindow: .init(startAt: start, endAt: end))
        let value = ResetForecastHeadline(fact: fact, publishedAt: start, now: start,
            calendar: calendar("America/Los_Angeles"), locale: Locale(identifier: "en_US"))
        #expect(value.kind == .window)
        #expect(value.compactValue.contains("Today") && value.compactValue.contains("Tomorrow"))
        #expect(value.compactValue.contains("UTC-07:00") && value.compactValue.contains("UTC-08:00"))
        #expect(value.shoulderQualifier == "10/31–11/01")
    }
    @Test func sameDayWindowKeepsAnnouncedDateOnShoulder() {
        let now = date("2026-10-15T04:00:00Z")
        for offset in [0.0, 86400.0] {
            let start = now.addingTimeInterval(offset), end = start.addingTimeInterval(7200)
            let fact = ResetNewsFact(kind: .upcomingReset, effectiveAt: end, effectiveAtPrecision: .windowBoundary,
                officialWindow: .init(startAt: start, endAt: end))
            let value = ResetForecastHeadline(fact: fact, publishedAt: now, now: now, calendar: calendar("Asia/Shanghai"))
            #expect(value.kind == .window && value.shoulderQualifier == value.dateText)
        }
    }
    @Test func unknownHasNoRelativeDayOrClock() {
        let value = ResetForecastHeadline(fact: .init(kind: .upcomingReset), publishedAt: nil,
            now: date("2026-10-15T04:00:00Z"), calendar: calendar("UTC"))
        #expect(value.kind == .unknown && value.day == nil && value.shoulderQualifier == nil)
        #expect(!value.hasClock && value.compactValue == "时间待定")
    }
}
