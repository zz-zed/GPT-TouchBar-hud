import Foundation

/// Time-first display fields share the resolver used for expiry. They never alter source facts.
public struct ResetForecastHeadline: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case unknown, exact, deadline, window, dateOnly }
    public enum Day: Equatable, Sendable { case today, tomorrow, date }
    public let kind: Kind
    public let day: Day?
    public let compactValue: String
    public let compactDetail: String
    public let shoulderQualifier: String?
    public let spansMultipleDays: Bool

    public let lead: String?
    public let headline: String
    public let dateText: String?
    public let zoneText: String?
    public let basisText: String?
    public let summary: String
    public let hasClock: Bool

    public init(fact: ResetNewsFact, publishedAt: Date?, now: Date = Date(),
                calendar: Calendar = .current, locale: Locale = Locale(identifier: "zh_CN")) {
        let chinese = locale.identifier.lowercased().hasPrefix("zh")
        let detail = ResetForecastDatePresentation(fact: fact, publishedAt: publishedAt,
            now: now, calendar: calendar, locale: locale)
        guard let timing = ResetForecastTiming.resolve(fact, publishedAt: publishedAt, calendar: calendar) else {
            kind = .unknown; day = nil; spansMultipleDays = false
            compactValue = chinese ? "时间待定" : "Time TBD"
            compactDetail = chinese ? "已有公开预告" : "Public forecast available"
            shoulderQualifier = nil
            lead = nil; headline = chinese ? "时间待定" : "Time not announced"
            dateText = nil; zoneText = nil; basisText = nil; summary = headline; hasClock = false
            return
        }
        if let start = fact.officialWindow?.startAt, let end = fact.officialWindow?.endAt {
            spansMultipleDays = !calendar.isDate(start, inSameDayAs: end)
        } else { spansMultipleDays = false }
        let displayCalendar = timing.dayCalendar ?? calendar
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.calendar = displayCalendar; formatter.timeZone = displayCalendar.timeZone
        formatter.dateFormat = "HH:mm"
        let resolvedDay: Day
        let relativeDay: String?
        if displayCalendar.isDate(timing.date, inSameDayAs: now) { resolvedDay = .today; relativeDay = chinese ? "今天" : "today" }
        else if let tomorrow = displayCalendar.date(byAdding: .day, value: 1, to: now),
                displayCalendar.isDate(timing.date, inSameDayAs: tomorrow) { resolvedDay = .tomorrow; relativeDay = chinese ? "明天" : "tomorrow" }
        else { resolvedDay = .date; relativeDay = nil }
        day = resolvedDay

        var basis = detail.basisText
        if timing.precision == .deadline, timing.inferredFromPublication, !timing.isEndOfDay, let publishedAt {
            let seconds = timing.date.timeIntervalSince(publishedAt)
            let amount: Double
            let unit: String
            if seconds.truncatingRemainder(dividingBy: 3600) == 0 {
                amount = seconds / 3600; unit = chinese ? "小时" : "hours"
            } else if seconds.truncatingRemainder(dividingBy: 60) == 0 {
                amount = seconds / 60; unit = chinese ? "分钟" : "minutes"
            } else { amount = seconds; unit = chinese ? "秒" : "seconds" }
            let duration = String(format: "%g", amount) + " " + unit
            let publishedClock = formatter.string(from: publishedAt)
            basis = chinese ? "按 \(publishedClock) 公告的「未来 \(duration)内」换算"
                : "Based on the \(publishedClock) announcement: within \(duration)"
        }
        basisText = basis
        dateText = detail.dateText
        if timing.precision == .exact || timing.precision == .deadline {
            kind = timing.precision == .exact ? .exact : .deadline
            hasClock = true
            let expected = timing.precision == .exact ? (chinese ? "计划" : "Planned") : (chinese ? "预计" : "Expected")
            lead = relativeDay.map { chinese ? expected + $0 : expected + " " + $0 } ?? expected
            let clock = formatter.string(from: timing.date)
            headline = timing.precision == .deadline ? (chinese ? clock + " 前" : "By " + clock) : clock
            zoneText = Self.zone(timing.date, calendar: calendar, chinese: chinese)
            summary = chinese ? expected + (relativeDay ?? detail.dateText) + " " + headline
                : expected + " " + (relativeDay ?? detail.dateText) + " · " + headline
        } else if let window = fact.officialWindow, let start = window.startAt, let end = window.endAt,
                  start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, start <= end {
            kind = .window
            hasClock = true
            formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
            let sameDay = calendar.isDate(start, inSameDayAs: end)
            lead = sameDay ? (chinese ? "预计" : "Expected") : (chinese ? "预计时段" : "Expected window")
            let sameOffset = calendar.timeZone.secondsFromGMT(for: start) == calendar.timeZone.secondsFromGMT(for: end)
            let first = formatter.string(from: start), last = formatter.string(from: end)
            headline = sameOffset ? "\(first)–\(last)"
                : "\(first) \(Self.offset(start, calendar: calendar)) – \(last) \(Self.offset(end, calendar: calendar))"
            zoneText = sameOffset ? Self.zone(start, calendar: calendar, chinese: chinese) : nil
            summary = (chinese ? "预计" : "Expected ") + detail.dateText + " " + headline
        } else {
            kind = .dateOnly
            hasClock = false
            lead = chinese ? "预计日期" : "Announced date"
            headline = detail.dateText
            zoneText = chinese ? "具体时刻未公布" : "Exact time not announced"
            summary = (chinese ? "预计" : "Expected ") + (relativeDay ?? detail.dateText)
                + (chinese ? " · 时刻待公布" : " · Time not announced")
        }
        // Compact and shoulder fields are derived from typed timing, never from localized labels.
        let dayFormatter = DateFormatter()
        dayFormatter.locale = locale; dayFormatter.calendar = calendar; dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = calendar.component(.year, from: timing.date) == calendar.component(.year, from: now) ? "MM/dd" : "yyyy/MM/dd"
        if kind == .window, let start = fact.officialWindow?.startAt, let end = fact.officialWindow?.endAt,
           !calendar.isDate(start, inSameDayAs: end) {
            func compactDay(_ date: Date) -> String {
                if calendar.isDate(date, inSameDayAs: now) { return chinese ? "今天" : "Today" }
                if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
                    return chinese ? "明天" : "Tomorrow"
                }
                return dayFormatter.string(from: date)
            }
            formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
            let differentOffset = calendar.timeZone.secondsFromGMT(for: start) != calendar.timeZone.secondsFromGMT(for: end)
            let firstClock = formatter.string(from: start) + (differentOffset ? " " + Self.offset(start, calendar: calendar) : "")
            let lastClock = formatter.string(from: end) + (differentOffset ? " " + Self.offset(end, calendar: calendar) : "")
            compactValue = "\(compactDay(start)) \(firstClock) – \(compactDay(end)) \(lastClock)"
            let days = dayFormatter.string(from: start) + "–" + dayFormatter.string(from: end)
            compactDetail = (chinese ? "预计时段 · " : "Expected window · ") + days
            shoulderQualifier = days
        } else if kind == .dateOnly {
            switch resolvedDay {
            case .today: compactValue = chinese ? "今天" : "Today"
            case .tomorrow: compactValue = chinese ? "明天" : "Tomorrow"
            case .date: compactValue = detail.dateText
            }
            compactDetail = detail.dateText + (chinese ? " · 时刻未公布" : " · Time not announced")
            shoulderQualifier = lead
        } else {
            compactValue = headline
            compactDetail = (lead ?? (chinese ? "预计" : "Expected")) + " · " + dayFormatter.string(from: timing.date)
            // A relative lead already names its day. Other clocks need the announced date.
            shoulderQualifier = kind == .window || resolvedDay == .date ? detail.dateText : lead
        }
    }

    private static func offset(_ date: Date, calendar: Calendar) -> String {
        let seconds = calendar.timeZone.secondsFromGMT(for: date)
        return String(format: "UTC%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
    }
    private static func zone(_ date: Date, calendar: Calendar, chinese: Bool) -> String {
        (chinese ? "本地 " : "Local ") + offset(date, calendar: calendar)
    }
}
