import Foundation
import Testing
@testable import ResetNewsCore

struct ResetForecastTimingTests {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func display(_ fact: ResetNewsFact, publication: Date? = nil, zone: String = "Asia/Shanghai") -> ResetForecastDatePresentation {
        ResetForecastDatePresentation(fact: fact, publishedAt: publication, now: date("2026-10-03T01:00:00Z"),
                                      calendar: calendar(zone))
    }

    @Test func completeRelativeClockIsKeptAndAnchoredToPublicationInItsOwnTimezone() throws {
        let text = "Global reset landing tomorrow 10am PST for all paid ChatGPT accounts."
        let timing = try #require(ResetForecastTiming.timingText(in: text))
        #expect(timing == "tomorrow 10am PST")
        let fact = ResetNewsFact(kind: .upcomingReset, timingText: timing)
        let publication = date("2026-10-02T02:14:51Z") // Still October 1 in PST.
        let resolved = try #require(ResetForecastTiming.resolve(fact, publishedAt: publication, calendar: calendar()))
        #expect(resolved.date == date("2026-10-02T18:00:00Z") && resolved.precision == .exact)
        let rendered = display(fact, publication: publication)
        #expect(rendered.dateText == "10月3日（周六）" && rendered.timeText == "02:00（本地 UTC+08:00）")
        #expect(rendered.isExactTime && rendered.basisText?.contains("PST") == true)
        #expect(fact.effectiveAt == nil) // Resolution is a projection and never invents source fields.
    }

    @Test func pacificCivilTimezoneTracksDSTWhileExplicitAbbreviationsKeepTheirOffsets() {
        let policy = ResetForecastPolicy(calendar: calendar())
        let summer = date("2026-07-01T03:00:00Z")
        let winter = date("2026-12-01T03:00:00Z")
        let pt = ResetNewsFact(kind: .upcomingReset, timingText: "tomorrow 10am PT")
        let pst = ResetNewsFact(kind: .upcomingReset, timingText: "tomorrow 10am PST")
        let pdt = ResetNewsFact(kind: .upcomingReset, timingText: "tomorrow 10am PDT")
        #expect(policy.scheduledDate(for: pt, publishedAt: summer) == date("2026-07-01T17:00:00Z"))
        #expect(policy.scheduledDate(for: pst, publishedAt: summer) == date("2026-07-01T18:00:00Z"))
        #expect(policy.scheduledDate(for: pt, publishedAt: winter) == date("2026-12-01T18:00:00Z"))
        #expect(policy.scheduledDate(for: pdt, publishedAt: winter) == date("2026-12-01T17:00:00Z"))
    }

    @Test func explicitClockWithoutTrustworthyTimezoneNeverBecomesExact() {
        for label in ["tomorrow 10am", "tomorrow 10am ET", "tomorrow 10am CST", "tomorrow 10am XYZ"] {
            let rendered = display(.init(kind: .upcomingReset, timingText: label), publication: date("2026-10-02T02:14:51Z"))
            #expect(!rendered.isExactTime && rendered.timeText == "具体时刻未公布")
            #expect(rendered.basisText?.contains("未换算具体时刻") == true)
            #expect(!rendered.timeText.contains("00:00"))
        }
        #expect(ResetForecastTiming.timeZone("CST") == nil && ResetForecastTiming.timeZone("ET") == nil)
    }

    @Test func DSTGapAndRepeatedClockDoNotIdentifyAnExactResetInstant() {
        for label in ["2026-03-08 2:30am PT", "2026-11-01 1:30am PT"] {
            let rendered = display(.init(kind: .upcomingReset, timingText: label))
            #expect(!rendered.isExactTime && rendered.timeText == "具体时刻未公布")
        }
        let unambiguous = display(.init(kind: .upcomingReset, timingText: "2026-11-01 1:30am PST"))
        #expect(unambiguous.isExactTime && unambiguous.timeText == "17:30（本地 UTC+08:00）")
    }

    @Test func sourceTimezoneCanQualifyAClockWithoutDuplicatingText() {
        let fact = ResetNewsFact(kind: .upcomingReset, timingText: "tomorrow 10am", sourceTimeZone: "America/Los_Angeles")
        let rendered = display(fact, publication: date("2026-10-02T02:14:51Z"))
        #expect(rendered.dateText == "10月3日（周六）" && rendered.timeText == "01:00（本地 UTC+08:00）")
        #expect(rendered.isExactTime)
    }

    @Test func deadlineRetainsBoundariesButDoesNotAssertAnExactResetTime() {
        let start = date("2026-10-03T02:00:00Z"), end = date("2026-10-03T03:00:00Z")
        let window = ResetNewsOfficialWindow(label: "within an hour", startAt: start, endAt: end,
                                              targetAt: end, targetKind: "deadline", timeZone: "UTC")
        let fact = ResetNewsFact(kind: .upcomingReset, effectiveAt: end, effectiveAtPrecision: .deadline, officialWindow: window)
        let rendered = display(fact)
        #expect(rendered.dateText == "10月3日（周六）" && !rendered.isExactTime)
        #expect(rendered.timeText == "预计在 11:00 前（本地 UTC+08:00）")
        #expect(rendered.basisText == "公告给出完成截止时间")
        #expect(fact.officialWindow?.startAt == start && fact.officialWindow?.endAt == end)
    }

    @Test func unknownTargetKindStaysConservativeAndCompleteWindowShowsRange() {
        let start = date("2026-10-03T02:00:00Z"), end = date("2026-10-03T03:00:00Z")
        let fact = ResetNewsFact(kind: .upcomingReset, effectiveAt: end, effectiveAtPrecision: .windowBoundary,
                                officialWindow: .init(startAt: start, endAt: end, targetAt: end))
        let rendered = display(fact)
        #expect(!rendered.isExactTime && rendered.timeText == "预计在 10:00–11:00（本地 UTC+08:00）")
        #expect(rendered.basisText?.contains("时间范围") == true)
        let incomplete = display(.init(kind: .upcomingReset, effectiveAt: end, effectiveAtPrecision: .windowBoundary,
                                       officialWindow: .init(targetAt: end)))
        #expect(!incomplete.isExactTime && incomplete.timeText == "具体时刻未公布")
    }

    @Test func windowCrossingLocalMidnightShowsBothCalendarDays() {
        let start = date("2026-10-02T15:30:00Z"), end = date("2026-10-02T17:30:00Z")
        let fact = ResetNewsFact(kind: .upcomingReset, effectiveAt: end, effectiveAtPrecision: .windowBoundary,
                                officialWindow: .init(startAt: start, endAt: end))
        let rendered = display(fact)
        #expect(rendered.dateText == "10月2日（周五） – 10月3日（周六）")
        #expect(rendered.timeText == "预计在 23:30–01:30（本地 UTC+08:00）")
        #expect(!rendered.isExactTime)
    }

    @Test func windowAcrossNewYearDoesNotOmitThePriorYear() {
        let start = date("2026-12-31T15:30:00Z"), end = date("2026-12-31T17:30:00Z")
        let fact = ResetNewsFact(kind: .upcomingReset, effectiveAt: end, effectiveAtPrecision: .windowBoundary,
                                officialWindow: .init(startAt: start, endAt: end))
        let rendered = ResetForecastDatePresentation(fact: fact, publishedAt: nil, now: date("2027-01-01T01:00:00Z"),
                                                      calendar: calendar())
        #expect(rendered.dateText == "2026年12月31日（周四） – 2027年1月1日（周五）")
        #expect(!rendered.isExactTime)
    }

    @Test func dateOnlyInSourceTimezoneRemainsAnUnconvertedDayAndRetainsOverlappingLocalDay() throws {
        let publication = date("2026-10-02T02:14:51Z")
        let fact = ResetNewsFact(kind: .upcomingReset, timingText: "tomorrow", sourceTimeZone: "America/Los_Angeles")
        let rendered = display(fact, publication: publication)
        #expect(rendered.dateText == "10月2日（周五）" && rendered.timeText == "具体时刻未公布")
        #expect(rendered.basisText == "日期按公告时区 America/Los_Angeles 解释" && !rendered.isExactTime)
        let item = ResetNewsItem(id: "one", sources: [.feed], originalText: "Codex limits will reset tomorrow.",
                                 facts: [fact], publishedAt: publication, firstSeenAt: publication)
        let policy = ResetForecastPolicy(calendar: calendar())
        #expect(policy.retaining(item, now: date("2026-10-03T01:00:00Z")) != nil)
        #expect(policy.retaining(item, now: date("2026-10-03T17:00:00Z")) == nil)
        let resolved = try #require(ResetForecastTiming.resolve(fact, publishedAt: publication, calendar: calendar()))
        #expect(resolved.dayEnd == date("2026-10-03T07:00:00Z"))
    }

    @Test func newPresentationProvenanceRoundTripsWithoutChangingExistingMaterialKeys() throws {
        let target = date("2026-10-03T03:00:00Z")
        let old = ResetNewsFact(kind: .upcomingReset, effectiveAt: target, effectiveAtPrecision: .exact)
        let refined = ResetNewsFact(kind: .upcomingReset, effectiveAt: target, effectiveAtPrecision: .deadline,
                                   officialWindow: .init(startAt: target.addingTimeInterval(-3600), endAt: target,
                                                         targetAt: target, targetKind: "deadline", timeZone: "UTC"),
                                   sourceTimeZone: "UTC")
        #expect(old.materialKey == refined.materialKey)
        #expect(try JSONDecoder().decode(ResetNewsFact.self, from: JSONEncoder().encode(refined)) == refined)
        let legacyJSON = #"{"kind":"upcomingReset","effectiveAt":812430000,"confidence":"explicit","evidence":""}"#
        let legacy = try JSONDecoder().decode(ResetNewsFact.self, from: Data(legacyJSON.utf8))
        #expect(legacy.officialWindow == nil && legacy.sourceTimeZone == nil && legacy.effectiveAtPrecision == nil)
        #expect(!display(legacy).isExactTime)
        let oldWindowJSON = #"{"label":"within an hour","startAt":812426400,"endAt":812430000,"targetAt":812430000}"#
        let oldWindow = try JSONDecoder().decode(ResetNewsOfficialWindow.self, from: Data(oldWindowJSON.utf8))
        #expect(oldWindow.targetKind == nil && oldWindow.timeZone == nil)
    }

    @Test func exactExplicitEffectiveTimeCanDifferFromWindowDeadline() {
        let effective = date("2026-10-03T02:45:00Z"), deadline = date("2026-10-03T03:00:00Z")
        let rendered = display(.init(kind: .upcomingReset, effectiveAt: effective, effectiveAtPrecision: .exact,
                                      officialWindow: .init(targetAt: deadline, targetKind: "deadline")))
        #expect(rendered.isExactTime && rendered.timeText == "10:45（本地 UTC+08:00）")
    }

    @Test func onlySourceTimezoneActuallyUsedToResolveScheduleChangesItsMaterialKey() {
        let local = ResetNewsFact(kind: .upcomingReset, timingText: "tomorrow 10am")
        let pacific = ResetNewsFact(kind: .upcomingReset, timingText: "tomorrow 10am", sourceTimeZone: "PT")
        let sameZone = ResetNewsFact(kind: .upcomingReset, timingText: "tomorrow 10am", sourceTimeZone: "America/Los_Angeles")
        let utc = ResetNewsFact(kind: .upcomingReset, timingText: "tomorrow 10am", sourceTimeZone: "UTC")
        #expect(local.materialKey != pacific.materialKey && pacific.materialKey != utc.materialKey)
        #expect(pacific.materialKey == sameZone.materialKey)
        let explicit = ResetNewsFact(kind: .upcomingReset, timingText: "tomorrow 10am PST")
        let irrelevantZone = ResetNewsFact(kind: .upcomingReset, timingText: "tomorrow 10am PST", sourceTimeZone: "UTC")
        #expect(explicit.materialKey == irrelevantZone.materialKey)
        let unknownZone = ResetNewsFact(kind: .upcomingReset, timingText: "tomorrow 10am", sourceTimeZone: "CST")
        #expect(unknownZone.materialKey == local.materialKey)
        let absoluteDay = ResetNewsFact(kind: .upcomingReset, timingText: "2026-10-03")
        let absoluteDayZone = ResetNewsFact(kind: .upcomingReset, timingText: "2026-10-03", sourceTimeZone: "PT")
        #expect(absoluteDay.materialKey == absoluteDayZone.materialKey)
    }
}
