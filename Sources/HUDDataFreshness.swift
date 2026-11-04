import Foundation

enum HUDDataFreshness {
    static func latestDate(account: RateLimitDisplayState, news: ResetNewsViewState,
                           costs: APICostViewState) -> Date? {
        let costDate = costs.visible && costs.snapshot?.period == costs.period ? costs.snapshot?.fetchedAt : nil
        return [account.lastUpdated, account.tokenUsage?.updatedAt,
                news.enabled ? news.forecastCheckedAt : nil, costDate].compactMap { $0 }.max()
    }

    static func text(account: RateLimitDisplayState, news: ResetNewsViewState,
                     costs: APICostViewState, context: PresentationContext) -> String {
        guard let date = latestDate(account: account, news: news, costs: costs) else {
            return context.text("尚未更新", "Not updated")
        }
        let format = context.calendar.isDate(date, inSameDayAs: context.now) ? "HH:mm" : "MM/dd HH:mm"
        return context.text("更新于 ", "Updated ") + context.date(date, format: format)
    }
}
