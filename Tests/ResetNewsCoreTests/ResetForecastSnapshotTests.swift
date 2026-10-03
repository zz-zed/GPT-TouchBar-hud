import Foundation
import Testing
@testable import ResetNewsCore

private func forecastDate(_ text: String) -> Date { ResetNewsDate.parse(text)! }
private var forecastCalendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
}
private func forecastPayload(signal: Any = NSNull(), lastReset: Any = NSNull(),
                             updatedAt: Any = "2026-10-03T12:00:00Z") -> [String: Any] {
    ["updated_at": updatedAt, "last_reset_at": lastReset, "official_signal": signal]
}
private func forecastRecord(text: String = "Codex limits will reset tomorrow for all paid users.",
                            window: Any? = nil) -> [String: Any] {
    var value: [String: Any] = [
        "tweet_id": "2105843926221660585",
        "url": "https://x.com/thsottiaux/status/2105843926221660585",
        "summary": text, "at": "2026-10-03T10:00:00Z"
    ]
    value["window"] = window
    return value
}
private func decodeForecast(_ payload: [String: Any]) throws -> ResetForecastSnapshot {
    try ResetForecastSnapshotDecoder().decode(JSONSerialization.data(withJSONObject: payload))
}

struct ResetForecastSnapshotTests {
    @Test func explicitNullIsSuccessfulNoCurrentSignal() throws {
        let snapshot = try decodeForecast(forecastPayload())
        #expect(snapshot.updatedAt == forecastDate("2026-10-03T12:00:00Z"))
        #expect(snapshot.lastResetAt == nil)
        #expect(snapshot.officialSignal == nil)
        #expect(snapshot.item(now: forecastDate("2026-10-03T14:00:00Z")) == nil)
        #expect(snapshot.notificationKey == nil)
    }

    @Test(arguments: ["updated_at", "last_reset_at", "official_signal"])
    func absentRequiredKeyIsNotNoSignal(_ field: String) throws {
        var payload = forecastPayload()
        payload.removeValue(forKey: field)
        #expect(throws: ResetForecastDecodingError.missingField(field)) { try decodeForecast(payload) }
    }

    @Test(arguments: ["false", "[]", "\"none\"", "{}", "123"])
    func malformedSignalCannotClearCurrentPreview(_ value: String) throws {
        let body = "{\"updated_at\":\"2026-10-03T12:00:00Z\",\"last_reset_at\":null,\"official_signal\":\(value)}"
        #expect(throws: (any Error).self) { try ResetForecastSnapshotDecoder().decode(Data(body.utf8)) }
    }

    @Test(arguments: ["updated_at", "last_reset_at"])
    func invalidSnapshotDatesAreErrors(_ field: String) throws {
        var payload = forecastPayload()
        payload[field] = "not a date"
        #expect(throws: ResetForecastDecodingError.invalidField(field)) { try decodeForecast(payload) }
        payload[field] = false
        #expect(throws: ResetForecastDecodingError.invalidField(field)) { try decodeForecast(payload) }
    }

    @Test(arguments: [
        "https://x.com/other/status/2105843926221660585",
        "https://x.com/thsottiaux/status/123",
        "https://example.com/thsottiaux/status/2105843926221660585",
        "http://x.com/thsottiaux/status/2105843926221660585",
        "https://x.com/thsottiaux/status/2105843926221660585?source=feed",
        "https://user@x.com/thsottiaux/status/2105843926221660585"
    ]) func rejectsNoncanonicalOfficialPostIdentity(_ url: String) throws {
        var record = forecastRecord()
        record["url"] = url
        #expect(throws: ResetForecastDecodingError.invalidIdentity) { try decodeForecast(forecastPayload(signal: record)) }
    }

    @Test func officialDeadlineExitsAtDeadlineAndRetainsReadableEvidence() throws {
        let window: [String: Any] = ["label": "within an hour", "start_at": "2026-10-03T10:00:00Z",
            "end_at": "2026-10-03T11:00:00Z", "target_at": "2026-10-03T11:00:00Z", "target_kind": "deadline"]
        let snapshot = try decodeForecast(forecastPayload(signal: forecastRecord(window: window)))
        let signal = try #require(snapshot.officialSignal)
        let item = try #require(snapshot.item(now: forecastDate("2026-10-03T10:59:59Z"), calendar: forecastCalendar))
        #expect(item.sources == [.forecast])
        #expect(item.facts[0].effectiveAtPrecision == .deadline)
        #expect(item.facts[0].scope == "paid")
        #expect(signal.expiresAt(calendar: forecastCalendar) == forecastDate("2026-10-03T11:00:00Z"))
        #expect(snapshot.item(now: forecastDate("2026-10-03T11:00:00Z"), calendar: forecastCalendar) == nil)
        #expect(signal.evidenceItem(calendar: forecastCalendar).originalText == signal.originalText)
        #expect(signal.evidenceItem(calendar: forecastCalendar).facts[0].kind == .upcomingReset)
    }

    @Test func UnknownTargetKindRetainsRangeUntilItsEnd() throws {
        let window: [String: Any] = ["start_at": "2026-10-03T14:00:00Z", "end_at": "2026-10-03T18:00:00Z",
            "target_at": "2026-10-03T16:00:00Z", "target_kind": "approximate"]
        let snapshot = try decodeForecast(forecastPayload(signal: forecastRecord(window: window)))
        let item = try #require(snapshot.item(now: forecastDate("2026-10-03T17:00:00Z"), calendar: forecastCalendar))
        #expect(item.facts[0].effectiveAtPrecision == .windowBoundary)
        #expect(snapshot.officialSignal?.expiresAt(calendar: forecastCalendar) == forecastDate("2026-10-03T18:00:00Z"))
        #expect(snapshot.item(now: forecastDate("2026-10-03T18:00:00Z"), calendar: forecastCalendar) == nil)
    }

    @Test func explicitSingleTimeExitsWithoutACompletionPost() throws {
        let record = forecastRecord(text: "Codex limits will reset at 2026-10-03T14:00:00Z.")
        let snapshot = try decodeForecast(forecastPayload(signal: record))
        #expect(snapshot.item(now: forecastDate("2026-10-03T13:59:59Z"), calendar: forecastCalendar)?.facts[0].effectiveAtPrecision == .exact)
        #expect(snapshot.item(now: forecastDate("2026-10-03T14:00:00Z"), calendar: forecastCalendar) == nil)
        #expect(snapshot.lastResetAt == nil)
    }

    @Test func explicitOriginalTimestampStaysExactWithALabelOnlyWindow() throws {
        let record = forecastRecord(text: "Codex limits will reset at 2026-10-03T14:00:00Z.", window: ["label": "this afternoon"])
        let snapshot = try decodeForecast(forecastPayload(signal: record))
        #expect(snapshot.officialSignal?.expiresAt(calendar: forecastCalendar) == forecastDate("2026-10-03T14:00:00Z"))
        #expect(snapshot.item(now: forecastDate("2026-10-03T13:59:59Z"), calendar: forecastCalendar)?.facts[0].effectiveAtPrecision == .exact)
        #expect(snapshot.item(now: forecastDate("2026-10-03T14:00:00Z"), calendar: forecastCalendar) == nil)
    }

    @Test func undatedCurrentSignalKeepsUnknownTime() throws {
        let snapshot = try decodeForecast(forecastPayload(signal: forecastRecord(text: "Global reset coming for all paid ChatGPT accounts.")))
        let item = try #require(snapshot.item(now: forecastDate("2026-10-03T14:00:00Z"), calendar: forecastCalendar))
        #expect(item.facts[0].effectiveAt == nil)
        #expect(item.facts[0].timingText == nil)
        #expect(item.facts[0].scope == "paid_chatgpt")
        #expect(snapshot.officialSignal?.expiresAt(calendar: forecastCalendar) == nil)
    }

    @Test func originalClockWithExplicitSourceZoneHasAnExactExit() throws {
        let snapshot = try decodeForecast(forecastPayload(signal: forecastRecord(text: "Global reset landing tomorrow 10am PST for all paid ChatGPT accounts.")))
        let signal = try #require(snapshot.officialSignal)
        #expect(signal.expiresAt(calendar: forecastCalendar) == forecastDate("2026-10-04T18:00:00Z"))
        #expect(snapshot.item(now: forecastDate("2026-10-04T17:59:59Z"), calendar: forecastCalendar) != nil)
        #expect(snapshot.item(now: forecastDate("2026-10-04T18:00:00Z"), calendar: forecastCalendar) == nil)
        // Parsing verbatim timing does not fabricate a date field in the source.
        #expect(signal.evidenceItem().facts[0].effectiveAt == nil)
        #expect(signal.officialWindow == nil)
    }

    @Test func sourceCalendarDateExitsAtSourceDayEnd() throws {
        let record = forecastRecord(text: "Codex limits will reset tomorrow.", window: ["label": "tomorrow", "time_zone": "America/Los_Angeles"])
        let snapshot = try decodeForecast(forecastPayload(signal: record))
        #expect(snapshot.officialSignal?.expiresAt(calendar: forecastCalendar) == forecastDate("2026-10-05T07:00:00Z"))
        #expect(snapshot.item(now: forecastDate("2026-10-05T06:59:59Z"), calendar: forecastCalendar) != nil)
        #expect(snapshot.item(now: forecastDate("2026-10-05T07:00:00Z"), calendar: forecastCalendar) == nil)
    }

    @Test func readableWindowLabelFallsBackToMorePreciseOriginalTiming() throws {
        let record = forecastRecord(text: "Codex limits will reset tomorrow at 10am UTC.", window: ["label": "tomorrow", "future_schema": ["localized_date": "明天"]])
        let snapshot = try decodeForecast(forecastPayload(signal: record))
        #expect(snapshot.officialSignal?.officialWindow?.label == "tomorrow")
        #expect(snapshot.officialSignal?.expiresAt(calendar: forecastCalendar) == forecastDate("2026-10-04T10:00:00Z"))
    }

    @Test func unknownWindowSchemaNeedsDatedOriginalText() throws {
        let record = forecastRecord(text: "Codex limits will reset tomorrow at 10am UTC.", window: ["future_schema": ["localized_date": "明天"]])
        let snapshot = try decodeForecast(forecastPayload(signal: record))
        #expect(snapshot.officialSignal?.officialWindow == nil)
        #expect(snapshot.officialSignal?.expiresAt(calendar: forecastCalendar) == forecastDate("2026-10-04T10:00:00Z"))
    }

    @Test func startOnlyWindowUsesDatedOriginalTextAndNeverInventsAnEnd() throws {
        let window = ["start_at": "2026-10-03T10:00:00Z"]
        let record = forecastRecord(text: "Codex limits will reset tomorrow at 10am UTC.", window: window)
        let snapshot = try decodeForecast(forecastPayload(signal: record))
        let signal = try #require(snapshot.officialSignal)
        #expect(signal.officialWindow?.startAt == forecastDate("2026-10-03T10:00:00Z"))
        #expect(signal.officialWindow?.endAt == nil)
        #expect(signal.evidenceItem().facts[0].officialWindow?.startAt == nil)
        #expect(signal.expiresAt(calendar: forecastCalendar) == forecastDate("2026-10-04T10:00:00Z"))
    }

    @Test func explicitlyUnspecifiedWindowKeepsUndatedSignal() throws {
        let window = ["label": "official hint — timing unspecified"]
        let record = forecastRecord(text: "Global reset coming for all paid ChatGPT accounts.", window: window)
        let snapshot = try decodeForecast(forecastPayload(signal: record))
        #expect(snapshot.item(now: forecastDate("2026-10-03T14:00:00Z"), calendar: forecastCalendar) != nil)
        #expect(snapshot.officialSignal?.expiresAt(calendar: forecastCalendar) == nil)
    }

    @Test func targetOnlyWindowExitsAtItsStatedBoundary() throws {
        let record = forecastRecord(window: ["target_at": "2026-10-03T14:00:00Z"])
        let snapshot = try decodeForecast(forecastPayload(signal: record))
        #expect(snapshot.item(now: forecastDate("2026-10-03T13:59:59Z"), calendar: forecastCalendar)?.facts[0].effectiveAtPrecision == .windowBoundary)
        #expect(snapshot.officialSignal?.expiresAt(calendar: forecastCalendar) == forecastDate("2026-10-03T14:00:00Z"))
        #expect(snapshot.item(now: forecastDate("2026-10-03T14:00:00Z"), calendar: forecastCalendar) == nil)
    }

    @Test(arguments: [
        #""bad window""#,
        #"{}"#,
        #"{"future_schema":{"localized_date":"明天"}}"#,
        #"{"label":"within an hour"}"#,
        #"{"label":"within an hour","end_at":null}"#,
        #"{"start_at":"2026-10-03T10:00:00Z"}"#,
        #"{"end_at":"not-a-date"}"#,
        #"{"end_at":123}"#,
        #"{"start_at":"2026-10-03T18:00:00Z","end_at":"2026-10-03T14:00:00Z"}"#,
        #"{"start_at":"2026-10-03T14:00:00Z","end_at":"2026-10-03T18:00:00Z","target_at":"2026-10-04T14:00:00Z"}"#,
        #"{"label":false}"#
    ]) func damagedKnownWindowFieldsCannotBecomeUndated(_ windowJSON: String) throws {
        let window = try JSONSerialization.jsonObject(with: Data(windowJSON.utf8), options: [.fragmentsAllowed])
        let record = forecastRecord(text: "Global reset coming for all paid ChatGPT accounts.", window: window)
        #expect(throws: (any Error).self) { try decodeForecast(forecastPayload(signal: record)) }
    }

    @Test func sourceEventsCannotOccurAfterSnapshotCalculation() throws {
        #expect(throws: ResetForecastDecodingError.invalidField("last_reset_at")) {
            try decodeForecast(forecastPayload(lastReset: "2026-10-03T12:00:01Z"))
        }
        var record = forecastRecord()
        record["at"] = "2026-10-03T12:00:01Z"
        #expect(throws: ResetForecastDecodingError.invalidField("at")) { try decodeForecast(forecastPayload(signal: record)) }
    }

    @Test func currentItemDoesNotChangeJustBecauseLocalClockAdvanced() throws {
        let snapshot = try decodeForecast(forecastPayload(signal: forecastRecord()))
        #expect(snapshot.item(now: forecastDate("2026-10-03T12:00:00Z"), calendar: forecastCalendar)
            == snapshot.item(now: forecastDate("2026-10-03T12:30:00Z"), calendar: forecastCalendar))
    }

    @Test func recentConfirmedResetDoesNotRemoveAnotherFutureArrangement() throws {
        let record = forecastRecord(text: "Codex limits will reset at 2026-10-04T14:00:00Z.")
        let snapshot = try decodeForecast(forecastPayload(signal: record, lastReset: "2026-10-03T12:00:00Z"))
        #expect(snapshot.lastResetAt == forecastDate("2026-10-03T12:00:00Z"))
        #expect(snapshot.item(now: forecastDate("2026-10-03T14:00:00Z"), calendar: forecastCalendar) != nil)
    }

    @Test func snapshotRefreshAndTranslatedCopyKeepSameNotificationKey() throws {
        var record = forecastRecord(text: "Codex limits will reset at 2026-10-04T14:00:00Z for all paid users.")
        let first = try decodeForecast(forecastPayload(signal: record))
        record["localized_summary"] = ["zh": "新的中文展示"]
        record["summary"] = "Codex limits will reset at 2026-10-04T14:00:00Z for all paid users. Performance has improved."
        let second = try decodeForecast(forecastPayload(signal: record, lastReset: "2026-10-03T12:30:00Z", updatedAt: "2026-10-03T13:00:00Z"))
        #expect(first.notificationKey == second.notificationKey)
        record["summary"] = "Codex limits will reset at 2026-10-04T15:00:00Z for all paid users. Performance has improved."
        #expect(first.notificationKey != (try decodeForecast(forecastPayload(signal: record))).notificationKey)
    }

    @Test(arguments: [
        #""2026-10-03T11:00:00Z""#,
        #""not a date""#,
        #"123"#,
        #"{"unexpected":"value"}"#
    ]) func undocumentedEffectiveAtDoesNotAffectCurrentEligibility(_ unknownJSON: String) throws {
        var record = forecastRecord(text: "Codex limits will reset at 2026-10-03T14:00:00Z.")
        let first = try decodeForecast(forecastPayload(signal: record))
        record["effective_at"] = try JSONSerialization.jsonObject(with: Data(unknownJSON.utf8), options: [.fragmentsAllowed])
        let second = try decodeForecast(forecastPayload(signal: record))
        #expect(second == first)
        #expect(second.officialSignal?.effectiveAt == nil)
        #expect(second.notificationKey == first.notificationKey)
        #expect(second.officialSignal?.expiresAt(calendar: forecastCalendar) == forecastDate("2026-10-03T14:00:00Z"))
        #expect(second.item(now: forecastDate("2026-10-03T13:59:59Z"), calendar: forecastCalendar) != nil)
        #expect(second.item(now: forecastDate("2026-10-03T14:00:00Z"), calendar: forecastCalendar) == nil)
        record["summary"] = "Global reset coming for all paid ChatGPT accounts."
        record["window"] = ["label": "within an hour"]
        #expect(throws: ResetForecastDecodingError.invalidField("window")) {
            try decodeForecast(forecastPayload(signal: record))
        }
    }

    @Test func CodableCacheRoundTripPreservesSignalAndExplicitNull() throws {
        let signal = try decodeForecast(forecastPayload(signal: forecastRecord()))
        #expect(try JSONDecoder().decode(ResetForecastSnapshot.self, from: JSONEncoder().encode(signal)) == signal)
        let none = try decodeForecast(forecastPayload())
        #expect(try JSONDecoder().decode(ResetForecastSnapshot.self, from: JSONEncoder().encode(none)) == none)
    }
}
