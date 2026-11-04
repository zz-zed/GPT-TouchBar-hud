import SwiftUI
import ResetNewsCore

struct NotchDetailPages: View {
    @ObservedObject var model: NotchPresentationModel
    let layout: NotchLayout
    var body: some View {
        VStack(spacing: 8) {
            header
            GeometryReader { proxy in
                HStack(alignment: .top, spacing: 0) {
                    page(.quota).frame(width: proxy.size.width, height: proxy.size.height)
                    page(.activity).frame(width: proxy.size.width, height: proxy.size.height)
                    page(.usage).frame(width: proxy.size.width, height: proxy.size.height)
                    messages.frame(width: proxy.size.width, height: proxy.size.height)
                }.offset(x: -CGFloat(model.page.rawValue) * proxy.size.width)
            }.clipped()
            footer
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
        .padding(.top, max(layout.visualBarHeight, layout.physicalTopInset) + 10)
        .foregroundColor(.white)
    }
    private var usesTwoHeaderRows: Bool {
        layout.expandedSize.width < 500 || model.presentationContext.language == .english
    }
    private var navigationHeight: CGFloat { model.usesGroupedControls ? 32 : 26 }
    private var headerRowHeight: CGFloat { model.usesGroupedControls ? 32 : 28 }
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(AppIdentity.productName).font(.system(size: 13, weight: .semibold))
                    .fixedSize()
                if !usesTwoHeaderRows { navigation }
                Spacer(minLength: 4)
                refreshControls
            }.frame(height: headerRowHeight)
            if usesTwoHeaderRows {
                navigation.frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: navigationHeight)
            }
        }.frame(height: headerRowHeight + (usesTwoHeaderRows ? navigationHeight + 4 : 0))
    }
    private var navigation: some View {
        HStack(spacing: model.usesGroupedControls ? 2 : 4) {
            ForEach(model.visiblePages, id: \.rawValue) { page in
                Button { model.selectPage(page) } label: {
                    Text(pageTitle(page) + (page == .messages && model.resetNews.forecastCount > 0 ? " \(ResetForecastIndicator.countText(model.resetNews.forecastCount))" : "")).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundColor(model.page == page || model.increaseContrast ? .white : NotchStyle.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(model.page == page ? Color.white.opacity(0.12) : .clear).cornerRadius(model.usesGroupedControls ? 12 : 5)
                }.buttonStyle(PlainButtonStyle()).accessibilityIdentifier("notch.page.\(page.rawValue)")
            }
        }
        .padding(model.usesGroupedControls ? 3 : 0)
        .modifier(NotchControlSurface(surface: model.controlSurface))
    }
    private var refreshControls: some View {
        HStack(spacing: 6) {
            lastUpdated
            NotchAction(title: model.refreshingAll ? model.presentationContext.text("刷新中…", "Refreshing…") : model.presentationContext.text("刷新全部", "Refresh all"), identifier: "notch.refresh", reduceMotion: model.reduceMotion, grouped: model.usesGroupedControls, increaseContrast: model.increaseContrast) { model.onRefreshAll?() }
                .disabled(model.refreshingAll)
                .padding(model.usesGroupedControls ? 2 : 0)
                .modifier(NotchControlSurface(surface: model.controlSurface))
        }.fixedSize(horizontal: true, vertical: false)
    }
    private func pageTitle(_ page: NotchDetailPage) -> String {
        page == .messages ? model.presentationContext.text("预告", "Forecasts") : page.title(language: model.presentationContext.language)
    }
    private var footer: some View {
        footerActions
            .overlay(Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5), alignment: .top)
    }
    private var lastUpdated: some View {
        Text(model.lastSuccessfulUpdateText)
            .font(.system(size: 10)).foregroundColor(NotchStyle.secondary)
            .lineLimit(1).minimumScaleFactor(0.8)
            .accessibilityIdentifier("notch.lastUpdated")
    }
    private var footerActions: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 4)
            HStack(spacing: model.usesGroupedControls ? 2 : 6) {
                NotchAction(title: model.presentationContext.text("设置", "Settings"), identifier: "notch.settings", reduceMotion: model.reduceMotion, grouped: model.usesGroupedControls, increaseContrast: model.increaseContrast) { model.onSettings?() }
                NotchAction(title: model.presentationContext.text("隐藏", "Hide"), identifier: "notch.hide", reduceMotion: model.reduceMotion, grouped: model.usesGroupedControls, increaseContrast: model.increaseContrast) { model.onHide?() }
                NotchAction(title: model.presentationContext.text("收起", "Collapse"), identifier: "notch.collapse", reduceMotion: model.reduceMotion, grouped: model.usesGroupedControls, increaseContrast: model.increaseContrast) { model.collapse() }
            }
            .padding(model.usesGroupedControls ? 2 : 0)
            .modifier(NotchControlSurface(surface: model.controlSurface))
        }.frame(height: 28)
    }
    private func page(_ page: NotchDetailPage) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: page == .quota ? 6 : 12) {
                if let error = model.content.errorSummary {
                    Text(error).font(.system(size: 11, weight: .medium)).foregroundColor(.orange)
                        .help(model.content.state.errorMessage ?? error)
                }
                switch page {
                case .quota: quota
                case .activity: activity
                case .usage: usage
                case .messages: EmptyView()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, page == .quota ? 0 : 8)
        }
        .accessibilityHidden(model.page != page)
        .allowsHitTesting(model.page == page)
        .accessibilityIdentifier("notch.content.\(page.rawValue)")
    }
    private var messages: some View {
        ResetNewsListView(state: model.resetNews, isVisible: model.messagesVisible,
            onCheck: { model.onCheckMessages?() }, onMarkAllRead: { model.onMarkAllMessagesRead?() },
            onSettings: { model.onMessageSettings?() }, onPageVisibility: model.resetNewsPageVisibilityChanged,
            onVisibleItem: model.resetNewsCardVisible, density: .notch,
            presentation: model.forecast, context: model.presentationContext)
            .padding(.vertical, 4)
            .accessibilityHidden(!model.messagesVisible)
            .allowsHitTesting(model.messagesVisible)
            .accessibilityIdentifier("notch.content.3")
    }
    private var quota: some View {
        VStack(alignment: .leading, spacing: 9) {
            if quotaMeters.isEmpty {
                Text(model.presentationContext.text("暂无额度数据", "No quota data")).font(.system(size: 18, weight: .semibold))
            } else {
                HStack(alignment: .top, spacing: 22) {
                    ForEach(Array(quotaMeters.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title).font(.system(size: 11, weight: .medium))
                            Text(row.meter.remainingText).font(.system(size: 30, weight: .semibold, design: .monospaced))
                                .lineLimit(1).minimumScaleFactor(0.7)
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(NotchStyle.quota.opacity(0.18))
                                    Capsule().fill(NotchStyle.quota)
                                        .frame(width: proxy.size.width * CGFloat(max(0, min(100, row.meter.remainingPercent))) / 100)
                                }
                            }.frame(height: 3).accessibilityHidden(true)
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(model.presentationContext.text("重置", "Resets"))
                                    .font(.system(size: 10)).fixedSize()
                                Text(businessTime(row.meter.resetDate, expiration: false))
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            }
                        }.foregroundColor(NotchStyle.quota)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            resetAndForecast
        }
    }
    private var quotaMeters: [(title: String, meter: LimitMeter)] {
        var rows: [(title: String, meter: LimitMeter)] = []
        if let five = model.content.state.fiveHour {
            rows.append((model.presentationContext.text("5 小时额度剩余", "5-hour remaining"), five))
        }
        if let weekly = model.content.state.weekly {
            rows.append((model.presentationContext.text("周额度剩余", "Weekly remaining"), weekly))
        }
        return rows
    }
    private var forecastHeadline: ResetForecastHeadline? {
        model.showsForecastShoulder ? model.forecast.headline : nil
    }
    private var resetAndForecast: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 3) {
                if let credits = model.content.state.resetCredits {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(model.presentationContext.text(credits.availableCount > 0 ? "可用完整重置" : "可用重置", "Available resets"))
                            .font(.system(size: 11, weight: .medium))
                        Text(model.presentationContext.text("\(credits.availableCount) 次", "\(credits.availableCount) left"))
                            .font(.system(size: 19, weight: .semibold, design: .monospaced))
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                    if credits.availableCount > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(model.presentationContext.text("最早到期", "Earliest expiry"))
                                .font(.system(size: 10)).fixedSize()
                            Text(businessTime(credits.earliestExpirationDate, expiration: true))
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(model.presentationContext.text("当前无可用次数", "No resets available"))
                            .font(.system(size: 11))
                    }
                } else {
                    Text(model.presentationContext.text("可用重置", "Available resets"))
                        .font(.system(size: 11, weight: .medium))
                    Text(model.presentationContext.text("次数待获取", "Count pending"))
                        .font(.system(size: 13, weight: .medium))
                }
            }.foregroundColor(NotchStyle.reset)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.resetNews.enabled {
                Button { model.selectPage(.messages) } label: {
                    HStack(alignment: .center, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(forecastHeadline.map(forecastLabel) ?? model.presentationContext.text("公开重置预告", "Public reset forecast"))
                                .font(.system(size: 11, weight: .medium)).lineLimit(2)
                            Text(forecastHeadline?.headline ?? model.forecast.value)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(NotchStyle.forecast.opacity(model.resetNews.forecastAvailability == .cached ? 0.75 : 1))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityIdentifier("notch.forecastSummary")
                .accessibilityLabel(model.presentationContext.text("查看公开重置预告，", "View public reset forecasts, ") + (forecastHeadline?.summary ?? model.forecast.value))
            }
        }
        .padding(.top, 7)
        .overlay(Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5), alignment: .top)
    }
    private func forecastLabel(_ headline: ResetForecastHeadline) -> String {
        let prefix = model.resetNews.forecastAvailability == .cached
            ? model.presentationContext.text("上次重置预告", "Last reset forecast")
            : model.presentationContext.text("公开重置预告", "Public reset forecast")
        return prefix + (headline.shoulderQualifier.map { " · " + $0 } ?? "")
    }

    private func businessTime(_ date: Date?, expiration: Bool) -> String {
        let context = model.presentationContext
        guard let date, date.timeIntervalSince1970.isFinite else {
            return context.text("时间未提供", "Time not provided")
        }
        guard date > context.now else {
            return expiration
                ? context.text("已到到期时间 · 待确认", "Expiry reached · Pending confirmation")
                : context.text("已到计划时间 · 待确认", "Scheduled time reached · Pending confirmation")
        }
        if context.calendar.isDate(date, inSameDayAs: context.now) {
            return context.text("今天 ", "Today ") + context.date(date, format: "HH:mm")
        }
        let sameYear = context.calendar.component(.year, from: date) == context.calendar.component(.year, from: context.now)
        return context.date(date, format: sameYear ? "MM/dd HH:mm" : "yyyy/MM/dd HH:mm")
    }
    private var activity: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.content.taskTitle).font(.system(size: 18, weight: .semibold, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
            if let note = model.content.task.note, model.content.tasksEnabled {
                Text(note).font(.system(size: 11, weight: .medium)).foregroundColor(.orange)
            }
            Text(model.content.taskDetail).font(.system(size: 11)).foregroundColor(NotchStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var usage: some View {
        HStack(alignment: .top, spacing: 22) {
            tokenUsage.frame(maxWidth: .infinity, alignment: .leading)
            if model.apiCosts.visible {
                apiUsage.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.font(.system(size: 11, weight: .medium))
    }

    private var tokenUsage: some View {
        let context = model.presentationContext
        let usage = model.content.state.tokenUsage
        let yesterday = context.text("昨日 ", "Yday ")
        let cumulative = context.text("累计 ", "Total ")
        return VStack(alignment: .leading, spacing: 6) {
            Text(context.text("Token 用量", "Token usage"))
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(context.text("昨日", "Yesterday"))
                Text(tokenValue(usage?.yesterdayText(language: context.language) ?? yesterday + "—", prefix: yesterday))
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(context.text("累计", "Total"))
                Text(tokenValue(usage?.cumulativeText(language: context.language) ?? cumulative + "—", prefix: cumulative))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            if usage?.isStale == true {
                Text(context.text("* 为上次统计 · 尚未更新", "* Previous totals · Not updated"))
                    .font(.system(size: 10)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.content.state.creditBalance.map {
                context.language == .chinese ? $0.displayText : $0.displayText.replacingOccurrences(of: "还剩点数：", with: "Credits: ")
            } ?? context.text("账号点数余额未提供", "Account credit balance not provided"))
                .font(.system(size: 10)).foregroundColor(NotchStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.foregroundColor(NotchStyle.token)
    }

    private func tokenValue(_ text: String, prefix: String) -> String {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    private var apiUsage: some View {
        let context = model.presentationContext
        return VStack(alignment: .leading, spacing: 6) {
            Text(context.text("本月 API 消费", "API spend this month"))
            Text(model.apiCosts.amountText(language: context.language))
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .lineLimit(2).minimumScaleFactor(0.7)
                .accessibilityIdentifier("notch.apiCosts.amount")
            Text(model.apiCosts.period.title)
            if model.apiCosts.refreshing {
                Text(context.text("消费仍在刷新…", "Costs still refreshing…"))
                    .foregroundColor(NotchStyle.secondary)
            } else if let recovery = model.apiCosts.recoveryTitle(language: context.language) {
                Button {
                    if model.apiCosts.error?.requiresRepair == true { model.onAPICostSettings?() }
                    else { model.onRefreshAPICosts?() }
                } label: {
                    Text(recovery).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                }
                .buttonStyle(PlainButtonStyle()).foregroundColor(.orange)
                .disabled(model.apiCosts.error?.requiresRepair != true && !model.apiCosts.canRefresh)
                .accessibilityIdentifier(model.apiCosts.error?.requiresRepair == true ? "notch.apiCosts.settings" : "notch.apiCosts.refresh")
            } else if model.apiCosts.isStale {
                Button(context.text("统计待更新 · 刷新消费", "Totals out of date · Refresh costs")) { model.onRefreshAPICosts?() }
                    .buttonStyle(PlainButtonStyle()).foregroundColor(.orange)
                    .disabled(!model.apiCosts.canRefresh)
                    .accessibilityIdentifier("notch.apiCosts.refresh")
            }
        }.foregroundColor(NotchStyle.api)
    }

}
