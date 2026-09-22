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
        guard let date = ResetForecastPolicy(calendar: calendar).scheduledDate(for: fact, publishedAt: publishedAt) else {
            dateText = unknownDate; timeText = unknownTime; basisText = nil; isExactTime = false
            return
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = chinese ? (sameYear ? "M月d日（EEE）" : "yyyy年M月d日（EEE）")
            : (sameYear ? "MMM d (EEE)" : "MMM d, yyyy (EEE)")
        let renderedDate = formatter.string(from: date)
        guard !renderedDate.isEmpty else {
            dateText = unknownDate; timeText = unknownTime; basisText = nil; isExactTime = false
            return
        }
        dateText = renderedDate
        isExactTime = fact.effectiveAt != nil && fact.effectiveAtPrecision == .exact
        if isExactTime {
            formatter.dateFormat = "HH:mm"
            let seconds = calendar.timeZone.secondsFromGMT(for: date)
            let offset = String(format: "UTC%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
            timeText = formatter.string(from: date) + (chinese ? "（本地 \(offset)）" : " (local \(offset))")
            basisText = nil
        } else {
            timeText = unknownTime
            if fact.effectiveAtPrecision == .windowBoundary {
                basisText = chinese ? "日期依据公告时间窗口" : "Date based on the announced time window"
            } else if fact.effectiveAt == nil,
                      !ResetNewsText.matches(#"^\d{4}-\d{2}-\d{2}$"#, in: fact.timingText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
                let label = fact.timingText?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                if ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"].contains(label) {
                    formatter.dateFormat = chinese ? "EEE" : "EEEE"
                    let weekday = formatter.string(from: date)
                    basisText = chinese ? "根据公告发布时间及\(weekday)推算" : "Derived from the publication date and \(weekday)"
                } else {
                    basisText = chinese ? "根据公告发布时间推算" : "Derived from the announcement's publication date"
                }
            } else {
                basisText = nil
            }
        }
    }
}
