import Foundation

/// Two-line menu schedule using the existing resolver; never changes source or shared headline semantics.
public struct ResetForecastMenuSchedule {
    public let value: String
    public let detail: String
    public init?(fact: ResetNewsFact, publishedAt: Date?, now: Date, calendar suppliedCalendar: Calendar, locale: Locale) {
        guard let timing = ResetForecastTiming.resolve(fact, publishedAt: publishedAt, calendar: suppliedCalendar) else { return nil }
        let headline = ResetForecastHeadline(fact: fact, publishedAt: publishedAt, now: now, calendar: suppliedCalendar, locale: locale)
        func text(_ chinese: String, _ english: String) -> String { locale.identifier.lowercased().hasPrefix("zh") ? chinese : english }
        let calendar = timing.dayCalendar ?? suppliedCalendar
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        let year = calendar.component(.year, from: now)
        func date(_ value: Date, yearRequired: Bool = false) -> String {
            formatter.dateFormat = yearRequired || calendar.component(.year, from: value) != year ? "yyyy/MM/dd" : "MM/dd"
            return formatter.string(from: value)
        }
        func clock(_ value: Date) -> String { formatter.dateFormat = "HH:mm"; return formatter.string(from: value) }
        func offset(_ value: Date) -> String {
            let seconds = calendar.timeZone.secondsFromGMT(for: value)
            return String(format: "UTC%@%02d:%02d", seconds < 0 ? "−" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
        }
        var value: String
        var detail: String
        if headline.kind == .window, let start = fact.officialWindow?.startAt, let end = fact.officialWindow?.endAt {
            let years = calendar.component(.year, from: start) != calendar.component(.year, from: end)
                || calendar.component(.year, from: start) != year || calendar.component(.year, from: end) != year
            if calendar.isDate(start, inSameDayAs: end) {
                value = date(start, yearRequired: years) + "\n" + clock(start) + "–" + clock(end)
            } else {
                value = date(start, yearRequired: years) + " " + clock(start) + "\n" + date(end, yearRequired: years) + " " + clock(end)
            }
            detail = text("预计时段 · 起 → 止", "Window: start → end")
            if calendar.timeZone.secondsFromGMT(for: start) != calendar.timeZone.secondsFromGMT(for: end) {
                detail = text("起 ", "From ") + offset(start) + text("；止 ", "; to ") + offset(end)
            }
        } else if timing.precision == .exact || timing.precision == .deadline {
            value = date(timing.date) + " " + (timing.precision == .deadline ? text(clock(timing.date) + " 前", "by " + clock(timing.date)) : clock(timing.date))
            detail = timing.precision == .deadline ? text("预计完成重置", "Expected deadline") : text("计划重置时间", "Planned reset")
            if date(timing.date).count > 5 { value = date(timing.date) + "\n" + (timing.precision == .deadline ? text(clock(timing.date) + " 前", "by " + clock(timing.date)) : clock(timing.date)) }
        } else {
            value = date(timing.date) + "\n" + text("时刻待公布", "Time pending")
            detail = timing.unresolvedClock ? text("时区或时刻未明确", "Timezone/clock unclear") : text("已公布日期", "Date announced")
        }
        self.value = value; self.detail = detail
    }
}
