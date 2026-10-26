import Foundation
import ResetNewsCore

/// Public forecasts remain independent of the account's quota and refresh state.
struct ForecastPresentation: Equatable {
    enum Kind: Equatable { case hidden, currentEmpty, checking, paused, unavailable, announced, cached }
    let kind: Kind
    let checkStatus: ResetNewsCheckStatus
    let headline: ResetForecastHeadline?
    let cards: [String: [ResetForecastHeadline]]
    let value: String
    let detail: String
    let help: String
    let compactValue: String
    let compactDetail: String
    let canShowList: Bool
    let hasForecastDetails: Bool
    let canRetry: Bool
    let indicator: ForecastIndicatorPresentation
    var isEmpty: Bool { kind == .currentEmpty }
    var hasPendingTime: Bool { headline?.kind == .unknown }

    init(_ state: ResetNewsViewState, context: PresentationContext = PresentationContext()) {
        let cards = Dictionary(uniqueKeysWithValues: state.items.map { item in
            (item.id, item.facts.filter { $0.kind == .upcomingReset }.map {
                ResetForecastHeadline(fact: $0, publishedAt: item.publishedAt,
                    now: context.now, calendar: context.calendar, locale: context.locale)
            })
        })
        self.cards = cards
        checkStatus = state.status
        canShowList = state.enabled || !state.items.isEmpty
        hasForecastDetails = state.canOpenDetails
        indicator = ForecastIndicatorPresentation(count: state.indicatorCount, available: canShowList,
            cached: state.forecastAvailability == .cached, language: context.language)
        help = Self.statusLabel(state.status, context: context)
            + (state.detail.map { " · " + ResetNewsDisplayText.hidingAddresses(in: $0) } ?? "")
            + (state.forecastCheckedAt.map { "\n" + context.text("上次成功获取 ", "Last successful fetch ") + context.date($0) } ?? "")
        guard state.enabled else {
            kind = .hidden; headline = nil; value = context.text("预告已关闭", "Forecasts off")
            detail = context.text("可在设置中开启", "Enable in settings")
            compactValue = ""; compactDetail = ""; canRetry = false
            return
        }
        if let schedule = state.items.lazy.compactMap({ cards[$0.id]?.first }).first {
            headline = schedule
            kind = state.forecastAvailability == .cached ? .cached : .announced
            value = schedule.summary
            detail = kind == .cached
                ? context.text("尚未获取最新预告，当前显示已保存的安排", "Latest forecast unavailable; showing the saved schedule")
                : schedule.confirmationNote ?? context.text("查看当前安排", "View forecast")
            compactValue = schedule.compactValue
            compactDetail = schedule.compactDetail
            canRetry = kind == .cached && [.failure, .partial, .stale].contains(state.status)
            return
        }
        headline = nil
        switch state.forecastAvailability {
        case .current:
            kind = .currentEmpty; value = context.text("当前暂无公开重置预告", "No current public reset forecast"); detail = ""
            compactValue = context.text("预告 · 暂无", "No forecast"); compactDetail = ""; canRetry = false
        case .cached:
            kind = .unavailable; value = context.text("预告暂不可用", "Forecast unavailable")
            detail = context.text("上次结果已过期", "Last result expired")
            compactValue = value; compactDetail = ""; canRetry = state.status != .checking
        case .unknown:
            detail = ""; canRetry = [.failure, .partial, .stale].contains(state.status)
            switch state.status {
            case .checking: kind = .checking; value = context.text("正在获取预告", "Loading forecast")
            case .failure, .partial, .stale: kind = .unavailable; value = context.text("预告暂不可用", "Forecast unavailable")
            case .codexNotRunning: kind = .paused; value = context.text("等待 Codex 启动", "Waiting for Codex")
            case .idle: kind = .paused; value = context.text("预告检查已暂停", "Forecast checks paused")
            case .disabled: kind = .hidden; value = context.text("预告已关闭", "Forecasts off")
            case .success: kind = .checking; value = context.text("尚未获取预告", "Forecast not fetched")
            }
            compactValue = value; compactDetail = ""
        }
    }

    private static func statusLabel(_ status: ResetNewsCheckStatus, context: PresentationContext) -> String {
        guard context.language == .english else { return status.label }
        switch status {
        case .idle: return "Forecast checks paused"
        case .checking: return "Checking reset forecasts"
        case .success: return "Forecast check complete"
        case .partial: return "Some forecast sources failed"
        case .stale: return "Forecast source expired"
        case .failure: return "Forecast check failed"
        case .codexNotRunning: return "Waiting for Codex"
        case .disabled: return "Reset forecasts off"
        }
    }
}

/// Latest source values are retained even when a renderer suppresses equal visual content.
struct AppDisplaySnapshot {
    let state: RateLimitDisplayState
    let news: ResetNewsViewState
    let context: PresentationContext
    let forecast: ForecastPresentation
    let metrics: [HUDMetric]

    init(state: RateLimitDisplayState, news: ResetNewsViewState, context: PresentationContext = PresentationContext()) {
        self.state = state; self.news = news; self.context = context
        forecast = ForecastPresentation(news, context: context)
        metrics = HUDMetric.rows(for: state, context: context)
    }
}
