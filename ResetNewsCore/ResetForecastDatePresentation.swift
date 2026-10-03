import Foundation

/// A display-only projection of the existing schedule resolver. No dates are written back to facts.
public struct ResetForecastDatePresentation: Equatable, Sendable {
    public let dateText: String
    public let timeText: String
    public let basisText: String?
    public let isExactTime: Bool

    public init(fact: ResetNewsFact, publishedAt: Date?, now: Date = Date(),
                calendar: Calendar = .current, locale: Locale = Locale(identifier: "zh_CN")) {
        let chinese = locale.identifier.lowercased().hasPrefix("zh")
        let unknownDate = chinese ? "日期待公布" : "Date not announced"
        let unknownTime = chinese ? "具体时刻未公布" : "Exact time not announced"
        guard let timing = ResetForecastTiming.resolve(fact, publishedAt: publishedAt, calendar: calendar) else {
            dateText = unknownDate; timeText = unknownTime; basisText = nil; isExactTime = false
            return
        }

        let date = timing.date
        // A calendar day with no clock is rendered in its declared source calendar. Converting its
        // midnight would falsely imply an exact reset time and can shift the announced date.
        let displayCalendar = timing.dayCalendar ?? calendar
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = displayCalendar
        formatter.timeZone = displayCalendar.timeZone
        let sameYear = displayCalendar.component(.year, from: date) == displayCalendar.component(.year, from: now)
        formatter.dateFormat = chinese ? (sameYear ? "M月d日（EEE）" : "yyyy年M月d日（EEE）")
            : (sameYear ? "MMM d (EEE)" : "MMM d, yyyy (EEE)")
        let renderedDate = formatter.string(from: date)
        guard !renderedDate.isEmpty else {
            dateText = unknownDate; timeText = unknownTime; basisText = nil; isExactTime = false
            return
        }
        isExactTime = timing.precision == .exact
        if isExactTime {
            dateText = renderedDate
            timeText = Self.clockText(date, formatter: formatter, calendar: calendar, chinese: chinese)
            basisText = fact.effectiveAt == nil && timing.inferredFromPublication
                ? (chinese ? "按公告发布时间及 \(timing.sourceZone ?? "") 换算" : "Converted from the publication date and \(timing.sourceZone ?? "")") : nil
        } else if timing.precision == .deadline {
            dateText = renderedDate
            formatter.dateFormat = "HH:mm"
            let clock = formatter.string(from: date)
            let offset = Self.offsetText(date, calendar: calendar)
            timeText = chinese ? "预计在 \(clock) 前（本地 \(offset)）" : "Expected by \(clock) (local \(offset))"
            basisText = chinese ? "公告给出完成截止时间" : "The announcement gives a completion deadline"
        } else if let window = fact.officialWindow, let start = window.startAt, let end = window.endAt,
                  start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, start <= end {
            formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
            let localYear = calendar.component(.year, from: now)
            if calendar.component(.year, from: start) != localYear || calendar.component(.year, from: end) != localYear {
                formatter.dateFormat = chinese ? "yyyy年M月d日（EEE）" : "MMM d, yyyy (EEE)"
            }
            let firstDate = formatter.string(from: start), lastDate = formatter.string(from: end)
            dateText = calendar.isDate(start, inSameDayAs: end) ? firstDate : "\(firstDate) – \(lastDate)"
            formatter.dateFormat = "HH:mm"
            let startClock = formatter.string(from: start), endClock = formatter.string(from: end)
            let startOffset = Self.offsetText(start, calendar: calendar), endOffset = Self.offsetText(end, calendar: calendar)
            let range = startOffset == endOffset ? "\(startClock)–\(endClock)"
                : "\(startClock) \(startOffset) – \(endClock) \(endOffset)"
            let offset = startOffset == endOffset ? (chinese ? "（本地 \(startOffset)）" : " (local \(startOffset))") : ""
            timeText = (chinese ? "预计在 " : "Expected between ") + range + offset
            basisText = chinese ? "公告给出时间范围，具体时刻未公布" : "The announcement gives a window, not a single reset time"
        } else {
            dateText = renderedDate
            timeText = unknownTime
            if timing.unresolvedClock {
                basisText = chinese ? "公告时区或时刻无法明确，未换算具体时刻" : "The announced timezone or clock is ambiguous; no exact time was converted"
            } else if let zone = timing.sourceZone, timing.dayCalendar != nil {
                basisText = chinese ? "日期按公告时区 \(zone) 解释" : "Date interpreted in the announced timezone \(zone)"
            } else if timing.precision == .windowBoundary {
                basisText = chinese ? "日期依据公告时间窗口" : "Date based on the announced time window"
            } else if fact.effectiveAt == nil,
                      !ResetNewsText.matches(#"^\d{4}-\d{2}-\d{2}$"#, in: fact.timingText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
                let label = fact.timingText?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                if ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"].contains(label) {
                    formatter.dateFormat = chinese ? "EEE" : "EEEE"
                    let weekday = formatter.string(from: date)
                    basisText = chinese ? "根据公告发布时间及\(weekday)推算（未注明时区，按本地日期）"
                        : "Derived from the publication date and \(weekday) (timezone unspecified; local date assumed)"
                } else {
                    basisText = chinese ? "根据公告发布时间推算（未注明时区，按本地日期）"
                        : "Derived from the announcement's publication date (timezone unspecified; local date assumed)"
                }
            } else {
                basisText = nil
            }
        }
    }

    private static func offsetText(_ date: Date, calendar: Calendar) -> String {
        let seconds = calendar.timeZone.secondsFromGMT(for: date)
        return String(format: "UTC%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
    }

    private static func clockText(_ date: Date, formatter: DateFormatter, calendar: Calendar, chinese: Bool) -> String {
        formatter.dateFormat = "HH:mm"
        let offset = offsetText(date, calendar: calendar)
        return formatter.string(from: date) + (chinese ? "（本地 \(offset)）" : " (local \(offset))")
    }
}
