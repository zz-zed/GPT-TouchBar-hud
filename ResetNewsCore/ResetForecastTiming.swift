import Foundation

/// Resolves only announced dates and clocks. A source calendar day remains a day, never a reset at midnight.
enum ResetForecastTiming {
    struct Resolved {
        var date: Date
        var precision: ResetNewsTimePrecision?
        var dayCalendar: Calendar?
        var dayEnd: Date?
        var sourceZone: String?
        var inferredFromPublication: Bool = false
        var assumedTimeZone: Bool = false
        var unresolvedClock: Bool = false
        var isEndOfDay: Bool = false
    }

    private static let dayPattern = #"(?:later\s+today|tomorrow|tonight|today|next\s+(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|\d{4}-\d{2}-\d{2}|明天|今晚|今天)"#
    private static let clockPattern = #"(?:\d{1,2}:\d{2}\s*(?:am|pm)?|\d{1,2}\s*(?:am|pm))"#
    private static let zonePattern = #"(?:UTC(?:[+-]\d{1,2}(?::?\d{2})?)?|GMT(?:[+-]\d{1,2}(?::?\d{2})?)?|PST|PDT|PT|ET|EST|EDT|CST|CDT|CET|CEST|(?:[A-Za-z_]+(?:/[A-Za-z0-9_+-]+)+)|(?-i:[A-Z]{2,5}))"#
    private static let relativeAmountPattern = #"\d+(?:\.\d+)?|an?|one|two|three|four|five|six|seven|eight|nine|ten"#
    private static let relativeDeadlinePattern = "within\\s+(?:the\\s+next\\s+)?(?:(\(relativeAmountPattern))\\s+)?(hours?|hrs?|minutes?|mins?)(?:(?:\\s+and\\s*|,\\s*(?:and\\s*)?|\\s+)(\(relativeAmountPattern))\\s*(minutes?|mins?))?"
    // Reject an unsupported adjacent duration instead of assigning an expiry to its prefix.
    // Sentence punctuation ends this check; unrelated later prose does not invalidate a duration.
    private static let continuationAmountPattern = #"(?:(?:another|about)\s+)*(?:[+-]?\d+(?:\.\d+)?(?:\s*[–-]\s*\d+(?:\.\d+)?)?|an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)(?:[-\s]+(?:one|two|three|four|five|six|seven|eight|nine))?|(?:a\s+)?few|several)"#
    // A fractional continuation can inherit the preceding unit ("an hour and a half").
    private static let continuationHalfPattern = #"(?:(?:another|about)\s+)*(?:a\s+)?half(?![a-z0-9])"#
    private static let durationContinuationPattern = "^\\s*(?:,?\\s*(?:and|plus)\\s*|,\\s*|\\+\\s*|\\s+)(?:\(continuationHalfPattern)|(?:\(continuationAmountPattern))\\s*(?:hours?|hrs?|minutes?|mins?|seconds?|secs?|days?|weeks?)(?![a-z0-9]))"
    // Keep a day qualifier with EOD; otherwise "EOD tomorrow" would silently become today.
    private static let endOfDayPattern = "(?:(\(dayPattern))\\s+)?(?:EOD|end\\s+of\\s+(?:the\\s+)?day)(?:\\s+(\(dayPattern)))?(?:\\s+(\(zonePattern)))?(?:\\s+time)?"

    /// Keeps the clock and its timezone with a relative date rather than truncating it to "tomorrow".
    static func timingText(in text: String) -> String? {
        if let deadline = ResetNewsText.capture("(?<![A-Za-z0-9])(\(endOfDayPattern))(?![A-Za-z0-9])", in: text) {
            return deadline
        }
        if let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])\(relativeDeadlinePattern)(?![A-Za-z0-9])", options: [.caseInsensitive]),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            let deadline = String(text[range])
            let continuation = String(text[range.upperBound...])
            guard !ResetNewsText.matches(durationContinuationPattern, in: continuation) else { return nil }
            if relativeDuration(deadline) != nil { return deadline }
        }
        return ResetNewsText.capture("(?<![A-Za-z0-9])(\(dayPattern)(?:\\s+(?:at\\s+)?\(clockPattern)(?:\\s*\(zonePattern))?)?)(?![A-Za-z0-9])", in: text)
    }

    /// A declared source zone is material only when it actually supplies the zone used to resolve
    /// a relative day or clock. Absolute timestamps and clocks already carrying their own zone ignore it.
    static func materialSourceTimeZone(for fact: ResetNewsFact) -> String? {
        guard fact.kind == .upcomingReset, fact.effectiveAt == nil,
              fact.officialWindow?.targetAt == nil, fact.officialWindow?.startAt == nil, fact.officialWindow?.endAt == nil,
              let text = fact.timingText?.trimmingCharacters(in: .whitespacesAndNewlines),
              let label = fact.sourceTimeZone ?? fact.officialWindow?.timeZone,
              let zone = timeZone(label) else { return nil }
        if let endOfDay = endOfDayDetails(text) {
            return endOfDay.zone == nil ? zone.identifier : nil
        }
        let pattern = "^(\(dayPattern))(?:\\s+(?:at\\s+)?(\(clockPattern))(?:\\s*(\(zonePattern)))?)?$"
        guard ResetNewsText.matches(pattern, in: text),
              ResetNewsText.capture(pattern, in: text, group: 3) == nil else { return nil }
        let day = ResetNewsText.capture(pattern, in: text) ?? ""
        let hasClock = ResetNewsText.capture(pattern, in: text, group: 2) != nil
        guard hasClock || !ResetNewsText.matches(#"^\d{4}-\d{2}-\d{2}$"#, in: day) else { return nil }
        return zone.identifier
    }

    static func resolve(_ fact: ResetNewsFact, publishedAt: Date?, calendar: Calendar) -> Resolved? {
        guard fact.kind == .upcomingReset else { return nil }
        let window = fact.officialWindow
        let dates = [fact.effectiveAt, window?.targetAt, window?.endAt, window?.startAt]
        if let date = dates.compactMap({ $0 }).first {
            guard date.timeIntervalSince1970.isFinite else { return nil }
            let deadline = fact.effectiveAtPrecision == .deadline
                || (window?.targetKind?.lowercased() == "deadline"
                    && (fact.effectiveAtPrecision != .exact || fact.effectiveAt == window?.targetAt))
            let precision: ResetNewsTimePrecision? = deadline ? .deadline : fact.effectiveAtPrecision
            return Resolved(date: date, precision: precision, sourceZone: fact.sourceTimeZone ?? window?.timeZone)
        }
        guard let text = fact.timingText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let duration = relativeDuration(text) {
            // Elapsed hours/minutes start at the original announcement, never at a fetch or refresh.
            guard let publishedAt, publishedAt.timeIntervalSince1970.isFinite else { return nil }
            let deadline = publishedAt.addingTimeInterval(duration)
            guard deadline.timeIntervalSince1970.isFinite else { return nil }
            return Resolved(date: deadline, precision: .deadline, inferredFromPublication: true)
        }
        if let endOfDay = endOfDayDetails(text) {
            // Never anchor an unspecified/ambiguous source zone to the viewer's local day.
            guard let label = endOfDay.zone ?? fact.sourceTimeZone ?? window?.timeZone,
                  let zone = timeZone(label) else { return nil }
            var sourceCalendar = Calendar(identifier: .gregorian)
            sourceCalendar.timeZone = zone
            guard let day = calendarDay(endOfDay.day, publishedAt: publishedAt, calendar: sourceCalendar),
                  let end = sourceCalendar.dateInterval(of: .day, for: day)?.end else { return nil }
            return Resolved(date: end, precision: .deadline, sourceZone: label,
                            inferredFromPublication: !ResetNewsText.matches(#"^\d{4}-\d{2}-\d{2}$"#, in: endOfDay.day),
                            isEndOfDay: true)
        }
        let pattern = "^(\(dayPattern))(?:\\s+(?:at\\s+)?(\(clockPattern))(?:\\s*(\(zonePattern)))?)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let dayRange = Range(match.range(at: 1), in: text) else { return nil }
        func field(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        let dayText = String(text[dayRange]).lowercased()
        let clockText = field(2)
        let declaredZone = field(3) ?? fact.sourceTimeZone ?? window?.timeZone
        let zone = declaredZone.flatMap(timeZone)
        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.timeZone = zone ?? calendar.timeZone
        guard let sourceDay = calendarDay(dayText, publishedAt: publishedAt, calendar: sourceCalendar) else { return nil }
        let inferred = !ResetNewsText.matches(#"^\d{4}-\d{2}-\d{2}$"#, in: dayText)
        // With no trustworthy timezone, an announced clock cannot be converted into an exact instant.
        if let clockText, zone != nil, let clock = clock(clockText),
           let instant = exactDate(on: sourceDay, hour: clock.hour, minute: clock.minute, calendar: sourceCalendar) {
            return Resolved(date: instant, precision: .exact, sourceZone: declaredZone,
                            inferredFromPublication: inferred)
        }
        let dayEnd = sourceCalendar.date(byAdding: .day, value: 1, to: sourceDay)
        return Resolved(date: sourceDay, precision: nil, dayCalendar: zone == nil ? nil : sourceCalendar,
                        dayEnd: dayEnd, sourceZone: declaredZone, inferredFromPublication: inferred,
                        assumedTimeZone: zone == nil && inferred, unresolvedClock: clockText != nil)
    }

    private static func relativeDuration(_ text: String) -> TimeInterval? {
        let pattern = "^\(relativeDeadlinePattern)$"
        guard ResetNewsText.matches(pattern, in: text),
              let unit = ResetNewsText.capture(pattern, in: text, group: 2)?.lowercased() else { return nil }
        let words: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4,
                                     "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
        let amount: Double
        if let number = ResetNewsText.capture(pattern, in: text)?.lowercased() {
            guard let value = Double(number) ?? words[number] else { return nil }
            amount = value
        } else {
            guard ResetNewsText.matches(#"^within\s+the\s+next\s+"#, in: text),
                  ["hour", "hr", "minute", "min"].contains(unit) else { return nil }
            amount = 1
        }
        var duration = amount * (unit.hasPrefix("h") ? 3600 : 60)
        if let minutes = ResetNewsText.capture(pattern, in: text, group: 3)?.lowercased() {
            // Only hours followed by minutes are supported, never a partial multi-unit estimate.
            guard unit.hasPrefix("h"), let value = Double(minutes) ?? words[minutes] else { return nil }
            duration += value * 60
        }
        return duration.isFinite && duration > 0 ? duration : nil
    }

    private static func endOfDayDetails(_ text: String) -> (day: String, zone: String?)? {
        let pattern = "^\(endOfDayPattern)$"
        guard ResetNewsText.matches(pattern, in: text) else { return nil }
        let precedingDay = ResetNewsText.capture(pattern, in: text, group: 1)
        let followingDay = ResetNewsText.capture(pattern, in: text, group: 2)
        guard precedingDay == nil || followingDay == nil else { return nil }
        return ((precedingDay ?? followingDay ?? "today").lowercased(),
                ResetNewsText.capture(pattern, in: text, group: 3))
    }

    static func timeZone(_ label: String) -> TimeZone? {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        switch label.uppercased() {
        case "PT": return TimeZone(identifier: "America/Los_Angeles")
        case "PST": return TimeZone(secondsFromGMT: -8 * 3600)
        case "PDT": return TimeZone(secondsFromGMT: -7 * 3600)
        case "UTC", "GMT": return TimeZone(secondsFromGMT: 0)
        default:
            // IANA identities are explicit. Ambiguous abbreviations such as CST and ET are not guessed.
            if label.contains("/") { return TimeZone(identifier: label) }
            guard let sign = ResetNewsText.capture(#"^(?:UTC|GMT)([+-])\d{1,2}(?::?\d{2})?$"#, in: label),
                  let hours = ResetNewsText.capture(#"^(?:UTC|GMT)[+-](\d{1,2})(?::?\d{2})?$"#, in: label).flatMap(Int.init) else { return nil }
            let minutes = ResetNewsText.capture(#"^(?:UTC|GMT)[+-]\d{1,2}:?(\d{2})$"#, in: label).flatMap(Int.init) ?? 0
            guard hours <= 14, minutes < 60, hours < 14 || minutes == 0 else { return nil }
            return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
        }
    }

    private static func calendarDay(_ text: String, publishedAt: Date?, calendar: Calendar) -> Date? {
        if ResetNewsText.matches(#"^\d{4}-\d{2}-\d{2}$"#, in: text) {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
            guard let date = calendar.date(from: components),
                  calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
            return date
        }
        guard let publishedAt, publishedAt.timeIntervalSince1970.isFinite else { return nil }
        let start = calendar.startOfDay(for: publishedAt)
        let offset: Int
        switch text {
        case "today", "tonight", "later today", "今天", "今晚": offset = 0
        case "tomorrow", "明天": offset = 1
        default:
            let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            let next = text.hasPrefix("next ")
            let name = next ? String(text.dropFirst(5)) : text
            guard let index = weekdays.firstIndex(of: name) else { return nil }
            let delta = (index + 1 - calendar.component(.weekday, from: publishedAt) + 7) % 7
            offset = next && delta == 0 ? 7 : delta
        }
        return calendar.date(byAdding: .day, value: offset, to: start)
    }

    private static func clock(_ text: String) -> (hour: Int, minute: Int)? {
        guard let hourText = ResetNewsText.capture(#"^(\d{1,2})(?::\d{2})?\s*(?:am|pm)?$"#, in: text),
              var hour = Int(hourText) else { return nil }
        let minute = ResetNewsText.capture(#"^\d{1,2}:(\d{2})"#, in: text).flatMap(Int.init) ?? 0
        guard minute < 60 else { return nil }
        if let meridiem = ResetNewsText.capture(#"(am|pm)$"#, in: text)?.lowercased() {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
        } else if !(0...23).contains(hour) { return nil }
        return (hour, minute)
    }

    private static func exactDate(on day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour; components.minute = minute; components.second = 0
        let anchor = day.addingTimeInterval(-1)
        let first = calendar.nextDate(after: anchor, matching: components, matchingPolicy: .strict,
                                      repeatedTimePolicy: .first, direction: .forward)
        let last = calendar.nextDate(after: anchor, matching: components, matchingPolicy: .strict,
                                     repeatedTimePolicy: .last, direction: .forward)
        // DST gaps and repeated clocks do not identify a single exact instant.
        guard let first, let last, first == last,
              calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: first) == components else { return nil }
        return first
    }
}
