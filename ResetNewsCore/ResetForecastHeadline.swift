import Foundation

/// Time-first display fields share the resolver used for expiry. They never alter source facts.
public struct ResetForecastHeadline: Equatable, Sendable {
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
            lead = nil; headline = chinese ? "时间待定" : "Time not announced"
            dateText = nil; zoneText = nil; basisText = nil; summary = headline; hasClock = false
            return
        }
        let displayCalendar = timing.dayCalendar ?? calendar
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.calendar = displayCalendar; formatter.timeZone = displayCalendar.timeZone
        formatter.dateFormat = "HH:mm"
        let relativeDay: String?
        if displayCalendar.isDate(timing.date, inSameDayAs: now) { relativeDay = chinese ? "今天" : "today" }
        else if let tomorrow = displayCalendar.date(byAdding: .day, value: 1, to: now),
                displayCalendar.isDate(timing.date, inSameDayAs: tomorrow) { relativeDay = chinese ? "明天" : "tomorrow" }
        else { relativeDay = nil }

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
            hasClock = false
            lead = chinese ? "预计日期" : "Announced date"
            headline = detail.dateText
            zoneText = chinese ? "具体时刻未公布" : "Exact time not announced"
            summary = (chinese ? "预计" : "Expected ") + (relativeDay ?? detail.dateText)
                + (chinese ? " · 时刻待公布" : " · Time not announced")
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
