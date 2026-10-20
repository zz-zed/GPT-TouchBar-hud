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
    private var header: some View {
        HStack(spacing: 8) {
            if layout.expandedSize.width >= 500 {
                Text(AppIdentity.productName).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
            }
            HStack(spacing: model.usesGroupedControls ? 2 : 8) {
                ForEach(model.visiblePages, id: \.rawValue) { page in
                    Button { model.selectPage(page) } label: {
                        Text(page.title(language: model.presentationContext.language) + (page == .messages && model.resetNews.forecastCount > 0 ? " \(ResetForecastIndicator.countText(model.resetNews.forecastCount))" : "")).font(.system(size: 12, weight: .medium))
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .foregroundColor(model.page == page || model.increaseContrast ? .white : NotchStyle.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(model.page == page ? Color.white.opacity(0.12) : .clear).cornerRadius(model.usesGroupedControls ? 12 : 5)
                    }.buttonStyle(PlainButtonStyle()).accessibilityIdentifier("notch.page.\(page.rawValue)")
                }
            }
            .padding(model.usesGroupedControls ? 3 : 0)
            .modifier(NotchControlSurface(surface: model.controlSurface))
        }.frame(height: model.usesGroupedControls ? 32 : 26)
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if layout.expandedSize.width < 500 { updateLabel }
            footerActions
        }.frame(height: layout.expandedSize.width < 500 ? 45 : 28)
    }
    private var updateLabel: some View {
        Text(model.content.updated).font(.system(size: 10)).foregroundColor(NotchStyle.secondary).lineLimit(1)
    }
    private var footerActions: some View {
        HStack(spacing: 6) {
            if layout.expandedSize.width >= 500 { updateLabel }
            Spacer(minLength: 4)
            HStack(spacing: model.usesGroupedControls ? 2 : 6) {
                NotchAction(title: model.presentationContext.text("刷新额度", "Refresh quota"), identifier: "notch.refresh", reduceMotion: model.reduceMotion, grouped: model.usesGroupedControls, increaseContrast: model.increaseContrast) { model.onRefresh?() }
                    .disabled(model.content.isRefreshing)
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
        VStack(alignment: .leading, spacing: 8) {
            if quotaMetrics.isEmpty {
                Text(model.presentationContext.text("暂无额度数据", "No quota data")).font(.system(size: 18, weight: .semibold))
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Array(quotaMetrics.enumerated()), id: \.offset) { _, metric in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metric.title).font(.system(size: 10, weight: .medium)).foregroundColor(NotchStyle.secondary)
                            Text(metric.value).font(.system(size: 34, weight: .semibold, design: .monospaced))
                                .foregroundColor(NotchStyle.accent).lineLimit(1).minimumScaleFactor(0.45)
                            if let percent = metric.percent {
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.12))
                                        Capsule().fill(NotchStyle.accent).frame(width: proxy.size.width * CGFloat(max(0, min(100, percent))) / 100)
                                    }
                                }.frame(height: 4).accessibilityHidden(true)
                            }
                            Text(metric.date).font(.system(size: 10)).foregroundColor(NotchStyle.secondary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            resetAndForecast
        }
    }
    private var quotaMetrics: [HUDMetric] { model.content.metrics.filter { $0.percent != nil } }
    private var forecastHeadline: ResetForecastHeadline? {
        model.showsForecastShoulder ? model.forecast.headline : nil
    }
    @ViewBuilder private var resetAndForecast: some View {
        if model.content.state.resetCredits != nil || forecastHeadline != nil {
            HStack(alignment: .top, spacing: 16) {
                if let credits = model.content.state.resetCredits {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.presentationContext.text(credits.availableCount > 0 ? "可用完整重置" : "可用重置", "Available resets"))
                            .font(.system(size: 10, weight: .medium)).foregroundColor(NotchStyle.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(model.presentationContext.text("\(credits.availableCount) 次", "\(credits.availableCount) left"))
                                .font(.system(size: credits.availableCount > 0 ? 16 : 11,
                                              weight: credits.availableCount > 0 ? .semibold : .regular, design: .monospaced))
                                .foregroundColor(credits.availableCount > 0 ? .white : NotchStyle.secondary)
                            if let date = credits.earliestExpirationDate {
                                Text(earliestExpiry(date)).font(.system(size: 10)).foregroundColor(NotchStyle.secondary)
                                    .lineLimit(1).minimumScaleFactor(0.65)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let headline = forecastHeadline {
                    Button(action: model.openResetForecasts) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(forecastLabel(headline)).font(.system(size: 11, weight: .medium))
                                .foregroundColor(NotchStyle.secondary).lineLimit(1).minimumScaleFactor(0.65)
                            Text(headline.headline).font(.system(size: 16, weight: .semibold).monospacedDigit())
                                .foregroundColor(model.resetNews.forecastAvailability == .cached ? NotchStyle.secondary : .white)
                                .lineLimit(1).minimumScaleFactor(0.65)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityIdentifier("notch.forecastSummary")
                    .accessibilityLabel((model.resetNews.forecastAvailability == .cached
                        ? model.presentationContext.text("上次重置预告 · ", "Last reset forecast · ")
                        : model.presentationContext.text("公开重置预告 · ", "Public reset forecast · ")) + headline.summary)
                }
            }
        }
    }
    private func forecastLabel(_ headline: ResetForecastHeadline) -> String {
        let prefix = model.resetNews.forecastAvailability == .cached
            ? model.presentationContext.text("上次重置预告", "Last reset forecast")
            : model.presentationContext.text("公开重置预告", "Public reset forecast")
        return prefix + (headline.shoulderQualifier.map { " · " + $0 } ?? "")
    }

    private func earliestExpiry(_ date: Date) -> String {
        model.presentationContext.text("最早到期 ", "Expires ") + model.presentationContext.date(date)
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
        VStack(alignment: .leading, spacing: 12) {
            if let usage = model.content.state.tokenUsage {
                Text(usage.yesterdayText(language: model.presentationContext.language) + "  ·  " + usage.cumulativeText(language: model.presentationContext.language))
                    .font(.system(size: 18, weight: .semibold, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                if usage.isStale { Text(model.presentationContext.text("* 为上次统计，当前数据尚未更新。", "* Last known totals; current data is not available.")).foregroundColor(.orange) }
                if let status = usage.status { Text(status).foregroundColor(NotchStyle.secondary) }
            } else { Text(model.presentationContext.text("Token 用量暂无数据", "Token usage unavailable")) }
            Text(model.content.state.creditBalance.map {
                model.presentationContext.language == .chinese ? $0.displayText : $0.displayText.replacingOccurrences(of: "还剩点数：", with: "Credits: ")
            } ?? model.presentationContext.text("点数余额暂无数据", "Credit balance unavailable"))
            Text(model.presentationContext.text("当前数据未提供历史用量曲线。", "Historical usage charts are not available from this snapshot."))
                .foregroundColor(NotchStyle.secondary)
        }.font(.system(size: 11, weight: .medium))
    }
}
