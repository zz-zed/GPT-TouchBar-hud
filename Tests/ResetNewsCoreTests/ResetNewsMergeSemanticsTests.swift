import Foundation
import Testing
@testable import ResetNewsCore

struct ResetNewsMergeSemanticsTests {
    private let published = ISO8601DateFormatter().date(from: "2026-10-02T02:14:51Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func post(_ source: ResetNewsSource, text: String, fact: ResetNewsFact,
                      updated: Date? = nil, status: ResetNewsStatus? = nil) -> ResetNewsSourceItem {
        .init(source: source, sourceID: "2105843926221660585", body: text,
              publishedAt: published, updatedAt: updated, status: status, structuredFacts: [fact])
    }

    @Test func fullPostKeepsClockWhenBothEndpointsRepeatTheSameAnnouncement() throws {
        let text = "Global reset landing tomorrow 10am PST for all paid ChatGPT accounts. Apologies for the slow start."
        let feed = post(.feed, text: text,
                        fact: .init(kind: .upcomingReset, scope: "paid_chatgpt", timingText: "tomorrow 10am PST"))
        let timeline = post(.timeline, text: "Global reset landing tomorrow",
                            fact: .init(kind: .upcomingReset, timingText: "tomorrow"))
        let reducer = ResetNewsReducer(forecastPolicy: .init(calendar: calendar))
        for records in [[feed, timeline], [timeline, feed]] {
            let first = reducer.reduce(previous: .init(), incoming: records, now: published)
            let item = try #require(first.state.items.first)
            #expect(item.originalText == text && item.facts.count == 1)
            #expect(item.facts.first?.scope == "paid_chatgpt")
            #expect(reducer.forecastPolicy.firstDate(item) == ISO8601DateFormatter().date(from: "2026-10-02T18:00:00Z"))
            #expect(first.notificationCandidates.isEmpty)
            let partial = reducer.reduce(previous: first.state, incoming: [timeline], now: published.addingTimeInterval(120))
            #expect(partial.state.items.first?.facts == item.facts)
            #expect(partial.state.items.first?.materialRevision == 1 && partial.notificationCandidates.isEmpty)
        }
    }

    @Test func sameVersionStructuredTimeComplementsFullOriginalText() throws {
        let text = "We will reset Codex limits tomorrow. This is the full original announcement."
        let target = published.addingTimeInterval(86400)
        let feed = post(.feed, text: text, fact: .init(kind: .upcomingReset, scope: "paid_chatgpt", timingText: "tomorrow"))
        let timeline = post(.timeline, text: "Codex limits will reset tomorrow.",
                            fact: .init(kind: .upcomingReset, effectiveAt: target, effectiveAtPrecision: .deadline,
                                        officialWindow: .init(targetAt: target, targetKind: "deadline")))
        let result = ResetNewsReducer(forecastPolicy: .init(calendar: calendar))
            .reduce(previous: .init(), incoming: [feed, timeline], now: published)
        let item = try #require(result.state.items.first)
        #expect(item.originalText == text)
        #expect(item.facts.first?.effectiveAt == target && item.facts.first?.effectiveAtPrecision == .deadline)
        #expect(item.facts.first?.scope == "paid_chatgpt")
    }

    @Test func completeDeadlineWindowWinsOverEqualTimestampWithoutProvenance() throws {
        let target = published.addingTimeInterval(86400)
        let full = post(.feed, text: "We will reset Codex limits tomorrow for all paid ChatGPT accounts. Full original.",
                        fact: .init(kind: .upcomingReset, scope: "paid_chatgpt", effectiveAt: target, effectiveAtPrecision: .exact))
        let window = ResetNewsOfficialWindow(startAt: target.addingTimeInterval(-7200), endAt: target,
                                             targetAt: target, targetKind: "deadline", timeZone: "PST")
        let short = post(.timeline, text: "Codex reset tomorrow.",
                         fact: .init(kind: .upcomingReset, effectiveAt: target, effectiveAtPrecision: .deadline, officialWindow: window))
        let result = ResetNewsReducer(forecastPolicy: .init(calendar: calendar))
            .reduce(previous: .init(), incoming: [full, short], now: published)
        let fact = try #require(result.state.items.first?.facts.first)
        #expect(fact.officialWindow == window && fact.effectiveAtPrecision == .deadline)
        #expect(fact.scope == "paid_chatgpt")
    }

    @Test func newerShorterPlanOverridesAnOlderDetailedCopy() throws {
        let feed = post(.feed, text: "Global reset landing tomorrow 10am PST for all paid ChatGPT accounts.",
                        fact: .init(kind: .upcomingReset, timingText: "tomorrow 10am PST"))
        let updated = published.addingTimeInterval(120)
        let target = published.addingTimeInterval(2 * 86400)
        let timeline = post(.timeline, text: "Updated Codex reset schedule.",
                            fact: .init(kind: .upcomingReset, effectiveAt: target), updated: updated)
        let reducer = ResetNewsReducer(forecastPolicy: .init(calendar: calendar))
        let initial = reducer.reduce(previous: .init(), incoming: [feed], now: published)
        let result = reducer.reduce(previous: initial.state, incoming: [feed, timeline], now: updated)
        let item = try #require(result.state.items.first)
        #expect(item.originalText == timeline.body && item.facts.first?.effectiveAt == target)
        #expect(item.materialRevision == 2)
    }

    @Test func sameVersionCancellationWinsOverMoreDetailedOriginalText() {
        let feed = post(.feed, text: "Global reset landing tomorrow 10am PST for all paid ChatGPT accounts.",
                        fact: .init(kind: .upcomingReset, timingText: "tomorrow 10am PST"))
        let cancelled = post(.timeline, text: "The reset is cancelled.", fact: .init(kind: .upcomingReset, timingText: "tomorrow"), status: .cancelled)
        let result = ResetNewsReducer(forecastPolicy: .init(calendar: calendar))
            .reduce(previous: .init(), incoming: [feed, cancelled], now: published)
        #expect(result.state.items.isEmpty && result.state.retiredForecasts?.count == 1)
    }
}
