import Foundation
import Testing
@testable import ResetNewsCore

struct ResetForecastDatePresentationTests {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private var publication: Date { date("2026-09-22T04:31:32Z") }
    private func render(_ fact: ResetNewsFact, published: Date? = nil, now: Date? = nil,
                        zone: String = "Asia/Shanghai", locale: String = "zh_CN") -> ResetForecastDatePresentation {
        ResetForecastDatePresentation(fact: fact, publishedAt: published, now: now ?? publication,
                                      calendar: calendar(zone), locale: Locale(identifier: locale))
    }

    @Test func tuesdayBecomesAChineseDateWithAnHonestDerivationNote() {
        let value = render(.init(kind: .upcomingReset, timingText: "Tuesday"), published: publication)
        #expect(value.dateText == "9月22日（周二）")
        #expect(value.timeText == "具体时刻未公布" && value.basisText == "根据公告发布时间及周二推算")
        #expect(!value.isExactTime && !value.timeText.contains("00:00") && !value.dateText.contains("Tuesday"))
        let later = render(.init(kind: .upcomingReset, timingText: "Tuesday"), published: publication, now: publication.addingTimeInterval(7 * 86400))
        #expect(later.dateText == value.dateText)
    }

    @Test func exactTimeConvertsToLocalTimeAndExplicitOffset() {
        let value = render(.init(kind: .upcomingReset, effectiveAt: date("2026-09-22T07:00:00Z"), effectiveAtPrecision: .exact))
        #expect(value.dateText == "9月22日（周二）")
        #expect(value.timeText == "15:00（本地 UTC+08:00）" && value.isExactTime && value.basisText == nil)
    }

    @Test func exactMidnightDiffersFromInferredMidnight() {
        let instant = date("2026-09-21T16:00:00Z")
        let exact = render(.init(kind: .upcomingReset, effectiveAt: instant, effectiveAtPrecision: .exact))
        let day = render(.init(kind: .upcomingReset, timingText: "2026-09-22"))
        #expect(exact.dateText == day.dateText)
        #expect(exact.timeText == "00:00（本地 UTC+08:00）" && exact.isExactTime)
        #expect(day.timeText == "具体时刻未公布" && !day.isExactTime && day.basisText == nil)
    }

    @Test func crossYearRelativeDateIncludesYearWithoutGuessingAnHour() {
        let published = date("2026-12-31T04:00:00Z")
        let value = render(.init(kind: .upcomingReset, timingText: "tomorrow"), published: published, now: published)
        #expect(value.dateText == "2027年1月1日（周五）")
        #expect(!value.isExactTime && value.timeText == "具体时刻未公布")
    }

    @Test func exactOffsetUsesTheEventDateIncludingDSTAndDateRollover() {
        let summer = render(.init(kind: .upcomingReset, effectiveAt: date("2026-07-01T00:30:00Z"), effectiveAtPrecision: .exact), zone: "America/Los_Angeles")
        let winter = render(.init(kind: .upcomingReset, effectiveAt: date("2026-12-01T00:30:00Z"), effectiveAtPrecision: .exact), zone: "America/Los_Angeles")
        #expect(summer.dateText == "6月30日（周二）" && summer.timeText == "17:30（本地 UTC-07:00）")
        #expect(winter.dateText == "11月30日（周一）" && winter.timeText == "16:30（本地 UTC-08:00）")
        let nepal = render(.init(kind: .upcomingReset, effectiveAt: date("2026-09-22T00:00:00Z"), effectiveAtPrecision: .exact), zone: "Asia/Kathmandu")
        #expect(nepal.timeText == "05:45（本地 UTC+05:45）")
    }

    @Test func oldJSONKeepsTheDateWithoutAssertingExactnessAndNewPrecisionRoundTrips() throws {
        let exact = ResetNewsFact(kind: .upcomingReset, effectiveAt: publication, effectiveAtPrecision: .exact)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(exact)) as? [String: Any])
        json.removeValue(forKey: "effectiveAtPrecision")
        let legacy = try JSONDecoder().decode(ResetNewsFact.self, from: JSONSerialization.data(withJSONObject: json))
        let value = render(legacy)
        #expect(legacy.effectiveAt == exact.effectiveAt && legacy.effectiveAtPrecision == nil)
        #expect(value.dateText == "9月22日（周二）" && !value.isExactTime && value.timeText == "具体时刻未公布")
        #expect(try JSONDecoder().decode(ResetNewsFact.self, from: JSONEncoder().encode(exact)) == exact)
        #expect(legacy.materialKey == exact.materialKey)
        #expect(ResetForecastPolicy(calendar: calendar()).scheduledDate(for: legacy, publishedAt: nil) == exact.effectiveAt)
    }

    @Test func decoderDistinguishesExactTargetFromWindowBoundaries() throws {
        let base: [String: Any] = ["id": "100", "url": "https://x.com/thsottiaux/status/100", "summary": "Codex limits will reset.",
            "group": "reset", "preview": true, "announced_at": publication.timeIntervalSince1970]
        for key in ["start_at", "end_at", "target_at", "effective_at"] {
            var record = base
            if key == "effective_at" { record[key] = "2026-09-22T07:00:00Z" }
            else { record["official_window"] = [key: "2026-09-22T07:00:00Z"] }
            let records = try ResetNewsSourceDecoder().decode(JSONSerialization.data(withJSONObject: ["events": [record]]), source: .timeline)
            let fact = try #require(records.first?.structuredFacts?.first)
            let value = render(fact)
            let isTarget = key == "target_at" || key == "effective_at"
            #expect(value.isExactTime == isTarget)
            #expect(fact.effectiveAtPrecision == (isTarget ? .exact : .windowBoundary))
            #expect(value.timeText == (isTarget ? "15:00（本地 UTC+08:00）" : "具体时刻未公布"))
            #expect(value.basisText == (isTarget ? nil : "日期依据公告时间窗口"))
        }
    }

    @Test func ruleEngineMarksOnlyParsedExactTimestampAsExact() throws {
        let source = ResetNewsSourceItem(source: .feed, body: "Codex limits will reset at 2026-09-22T07:00:00Z.", publishedAt: publication)
        let item = try #require(ResetNewsRuleEngine().evaluate(source, now: publication))
        #expect(item.facts.first?.effectiveAtPrecision == .exact)
        let relative = ResetNewsSourceItem(source: .feed, body: "Codex limits will reset tomorrow.", publishedAt: publication,
                                            structuredFacts: [.init(kind: .upcomingReset)])
        let tomorrow = try #require(ResetNewsRuleEngine().evaluate(relative, now: publication))
        #expect(tomorrow.facts.first?.effectiveAtPrecision == nil && tomorrow.facts.first?.effectiveAt == nil)
    }

    @Test func unknownInvalidAndUnanchoredLabelsHaveNoEnglishLeakOrInventedDate() {
        let facts: [ResetNewsFact] = [.init(kind: .upcomingReset), .init(kind: .upcomingReset, timingText: "Tuesday"),
            .init(kind: .upcomingReset, timingText: "2026-02-30"),
            .init(kind: .upcomingReset, effectiveAt: Date(timeIntervalSince1970: .nan), effectiveAtPrecision: .exact)]
        for fact in facts {
            let value = render(fact)
            #expect(value.dateText == "日期待公布" && value.timeText == "具体时刻未公布" && !value.isExactTime && value.basisText == nil)
        }
    }

    @Test func injectedEnglishLocaleKeepsSamePrecisionAndCalendar() {
        let value = render(.init(kind: .upcomingReset, timingText: "Tuesday"), published: publication, locale: "en_US_POSIX")
        #expect(value.dateText == "Sep 22 (Tue)" && value.timeText == "Exact time not announced" && !value.isExactTime)
        #expect(value.basisText == "Derived from the publication date and Tuesday")
    }

    @Test func summaryUsesTheSameDateProjectionWhileLegacyCreditBranchRemainsCompatible() {
        let facts: [ResetNewsFact] = [.init(kind: .upcomingReset, timingText: "Tuesday"),
            .init(kind: .upcomingReset, effectiveAt: date("2026-09-22T07:00:00Z"), effectiveAtPrecision: .exact)]
        let item = ResetNewsItem(id: "forecast", sources: [.feed], originalText: "", facts: facts, publishedAt: publication, firstSeenAt: publication)
        let summary = ResetNewsSummary.chinese(item, now: publication, calendar: calendar())
        #expect(summary.contains("预计重置日期：9月22日（周二）") && summary.contains("15:00（本地 UTC+08:00）"))
        #expect(summary.contains("根据公告发布时间及周二推算") && !summary.contains("Tuesday") && !summary.contains("T07:00"))
        let old = ResetNewsItem(id: "credit", sources: [.feed], originalText: "", facts: [.init(kind: .extraResetCredits, count: 3)], firstSeenAt: publication)
        #expect(old.summaryZH.contains("额外提供 3 次 Codex 重置机会") && !old.summaryZH.contains("预计重置日期"))
    }
}
