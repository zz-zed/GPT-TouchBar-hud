import SwiftUI

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
            Text("GPT HUD").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            ForEach(NotchDetailPage.allCases, id: \.rawValue) { page in
                Button { model.selectPage(page) } label: {
                    Text(page.title).font(.system(size: 12, weight: .medium))
                        .foregroundColor(model.page == page ? .white : NotchStyle.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(model.page == page ? Color.white.opacity(0.12) : .clear).cornerRadius(5)
                }.buttonStyle(PlainButtonStyle()).accessibilityIdentifier("notch.page.\(page.rawValue)")
            }
        }.frame(height: 26)
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
            NotchAction(title: DisplayLanguage.text("刷新", "Refresh"), identifier: "notch.refresh", reduceMotion: model.reduceMotion) { model.onRefresh?() }
                .disabled(model.content.isRefreshing)
            NotchAction(title: DisplayLanguage.text("设置", "Settings"), identifier: "notch.settings", reduceMotion: model.reduceMotion) { model.onSettings?() }
            NotchAction(title: DisplayLanguage.text("隐藏", "Hide"), identifier: "notch.hide", reduceMotion: model.reduceMotion) { model.onHide?() }
            NotchAction(title: DisplayLanguage.text("收起", "Collapse"), identifier: "notch.collapse", reduceMotion: model.reduceMotion) { model.collapse() }
        }.frame(height: 28)
    }
    private func page(_ page: NotchDetailPage) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.content.errorSummary {
                    Text(error).font(.system(size: 11, weight: .medium)).foregroundColor(.orange)
                        .help(model.content.state.errorMessage ?? error)
                }
                switch page {
                case .quota: quota
                case .activity: activity
                case .usage: usage
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        }
        .accessibilityHidden(model.page != page)
        .allowsHitTesting(model.page == page)
        .accessibilityIdentifier("notch.content.\(page.rawValue)")
    }
    private var quota: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.content.metrics.isEmpty {
                Text(DisplayLanguage.text("暂无额度数据", "No quota data")).font(.system(size: 18, weight: .semibold))
            } else {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(Array(model.content.metrics.enumerated()), id: \.offset) { _, metric in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(metric.title).font(.system(size: 11, weight: .medium)).foregroundColor(NotchStyle.secondary)
                            Text(metric.value).font(.system(size: 38, weight: .semibold, design: .monospaced))
                                .foregroundColor(NotchStyle.accent).lineLimit(1).minimumScaleFactor(0.45)
                            if let percent = metric.percent {
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.12))
                                        Capsule().fill(NotchStyle.accent).frame(width: proxy.size.width * CGFloat(max(0, min(100, percent))) / 100)
                                    }
                                }.frame(height: 4).accessibilityHidden(true)
                            }
                            Text(metric.date).font(.system(size: 10)).foregroundColor(NotchStyle.secondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let credits = model.content.state.resetCredits,
               model.content.state.fiveHour != nil || credits.availableCount == 0 {
                Text(DisplayLanguage.text("重置卡 · ", "Reset credits · ") + credits.availableText + " · " + credits.expirationText)
                    .font(.system(size: 11)).foregroundColor(NotchStyle.secondary)
            }
        }
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
                Text(usage.yesterdayText + "  ·  " + usage.cumulativeText)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                if usage.isStale { Text(DisplayLanguage.text("* 为上次统计，当前数据尚未更新。", "* Last known totals; current data is not available.")).foregroundColor(.orange) }
                if let status = usage.status { Text(status).foregroundColor(NotchStyle.secondary) }
            } else { Text(DisplayLanguage.text("Token 用量暂无数据", "Token usage unavailable")) }
            Text(model.content.state.creditBalance.map {
                DisplayLanguage.current == .chinese ? $0.displayText : $0.displayText.replacingOccurrences(of: "还剩点数：", with: "Credits: ")
            } ?? DisplayLanguage.text("点数余额暂无数据", "Credit balance unavailable"))
            Text(DisplayLanguage.text("当前数据未提供历史用量曲线。", "Historical usage charts are not available from this snapshot."))
                .foregroundColor(NotchStyle.secondary)
        }.font(.system(size: 11, weight: .medium))
    }
}
