import SwiftUI
import ResetNewsCore

/// Shared by the notch page and the native popover. A row is read only after it
/// intersects the visible scroll viewport; LazyVStack prefetch alone is not enough.
struct ResetNewsListView: View {
    let state: ResetNewsViewState
    let isVisible: Bool
    var focusedItemID: String? = nil
    let onCheck: () -> Void
    let onMarkAllRead: () -> Void
    let onSettings: () -> Void
    let onPageVisibility: (Bool) -> Void
    let onVisibleItem: (String) -> Void
    private let coordinateSpace = "resetNewsListViewport"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.statusText).font(.system(size: 11)).foregroundColor(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(state.statusText)
            HStack(spacing: 12) {
                Button(DisplayLanguage.text("检查预告", "Check forecasts"), action: onCheck)
                    .disabled(!state.enabled || state.status == .checking || state.status == .codexNotRunning || state.status == .idle)
                    .accessibilityIdentifier("resetNews.check")
                Button(DisplayLanguage.text("预告设置", "Forecast settings"), action: onSettings).accessibilityIdentifier("resetNews.settings")
            }.font(.system(size: 11))
            Text(DisplayLanguage.text("仅显示今天及未来的预告；当前账号数据以额度区域为准", "Today and upcoming forecasts only; see quota for your account data"))
                .font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { viewport in
                ScrollViewReader { reader in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if state.items.isEmpty {
                                Text(state.enabled
                                    ? DisplayLanguage.text("暂无重置预告", "No reset forecasts")
                                    : DisplayLanguage.text("开启后可查看今天及未来的 Codex 重置预告", "Enable reset forecasts to see today's and upcoming Codex resets"))
                                    .font(.system(size: 12)).foregroundColor(.secondary).padding(.vertical, 16)
                            }
                            ForEach(state.items) { item in
                                ResetNewsCard(item: item, unread: !state.readIDs.contains(item.id))
                                    .id(item.id)
                                    .background(GeometryReader { row in
                                        Color.clear.preference(key: ResetNewsCardFrames.self,
                                            value: [item.id: ResetNewsCardFrame(frame: row.frame(in: .named(coordinateSpace)),
                                                pageVisible: isVisible, unread: !state.readIDs.contains(item.id),
                                                materialRevision: item.materialRevision)])
                                    })
                            }
                        }.padding(.vertical, 4).id(isVisible)
                    }
                    .coordinateSpace(name: coordinateSpace)
                    .onPreferenceChange(ResetNewsCardFrames.self) { measurements in
                        onPageVisibility(isVisible)
                        let frames = measurements.filter { $0.value.pageVisible }.mapValues(\.frame)
                        let ids = ResetNewsCardVisibility.visibleIDs(frames: frames, viewport: viewport.size,
                            pageVisible: isVisible, state: state)
                        for id in ids { onVisibleItem(id) }
                    }
                    .onAppear { if let focusedItemID { reader.scrollTo(focusedItemID, anchor: .top) } }
                    .onChange(of: isVisible) { visible in
                        if visible, let focusedItemID { reader.scrollTo(focusedItemID, anchor: .top) }
                    }
                    .onChange(of: focusedItemID) { id in if let id { reader.scrollTo(id, anchor: .top) } }
                }
            }
        }
        .onAppear { onPageVisibility(isVisible) }
        .onChange(of: isVisible) { onPageVisibility($0) }
        .onDisappear { onPageVisibility(false) }
        .accessibilityIdentifier("resetNews.list")
    }
}

enum ResetNewsCardVisibility {
    static func visibleIDs(frames: [String: CGRect], viewport: CGSize, pageVisible: Bool,
                           state: ResetNewsViewState) -> [String] {
        guard pageVisible, viewport.width > 0, viewport.height > 0 else { return [] }
        let bounds = CGRect(origin: .zero, size: viewport)
        let unreadIDs = Set(state.items.map(\.id)).subtracting(state.readIDs)
        return frames.filter { unreadIDs.contains($0.key) && $0.value.width > 0 && $0.value.height > 0 && bounds.intersects($0.value) }
            .map(\.key).sorted()
    }
}

private struct ResetNewsCardFrame: Equatable {
    let frame: CGRect
    let pageVisible: Bool
    // Reading or revising a card may leave its geometry unchanged. Both changes
    // must invalidate the preference; the state read-ID filter prevents replay.
    let unread: Bool
    let materialRevision: Int
}

private struct ResetNewsCardFrames: PreferenceKey {
    static var defaultValue: [String: ResetNewsCardFrame] = [:]
    static func reduce(value: inout [String: ResetNewsCardFrame], nextValue: () -> [String: ResetNewsCardFrame]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct ResetNewsCard: View {
    let item: ResetNewsItem
    let unread: Bool
    private let forecastFacts: [ResetNewsFact]
    private let forecastDates: [ResetForecastDatePresentation]

    init(item: ResetNewsItem, unread: Bool) {
        self.item = item
        self.unread = unread
        let forecasts = item.facts.filter { $0.kind == .upcomingReset }
        forecastFacts = forecasts
        forecastDates = forecasts.map { ResetForecastDatePresentation(fact: $0, publishedAt: item.publishedAt) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if unread { Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityLabel(DisplayLanguage.text("待查看预告", "Forecast to review")) }
                Text(forecastFacts.isEmpty ? item.facts.map { Self.kind($0.kind) }.uniqued.joined(separator: " · ") : "预计重置日期")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                Spacer(minLength: 2)
                Text(Self.status(item.status)).font(.system(size: 10)).foregroundColor(.secondary)
            }
            ForEach(Array(forecastFacts.enumerated()), id: \.offset) { index, fact in
                forecast(fact, date: forecastDates[index])
            }
            if forecastFacts.isEmpty {
                Text(item.summaryZH).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(item.facts.filter { $0.kind != .upcomingReset }.enumerated()), id: \.offset) { _, fact in
                VStack(alignment: .leading, spacing: 3) {
                    Text("范围：\(fact.scope ?? "未说明")")
                    if fact.kind == .extraResetCredits {
                        Text("次数：\(fact.count.map { "\($0) 次" } ?? "未说明")")
                    }
                    if fact.kind == .upcomingReset || fact.effectiveAt != nil || fact.timingText != nil {
                        Text("生效时间：" + (fact.effectiveAt.map { Self.date($0) } ?? fact.timingText ?? "未说明"))
                    }
                    Text("有效期：" + (fact.expiresAt.map { Self.date($0) } ?? fact.validityText ?? "未说明"))
                    if fact.confidence == .tentative { Text("公告措辞尚未确定").foregroundColor(.orange) }
                }.font(.system(size: 10)).foregroundColor(.secondary)
            }
            if let publishedAt = item.publishedAt {
                Text("发布于 " + Self.date(publishedAt)).font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06)).cornerRadius(8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("resetNews.item.\(item.id)")
    }

    private func forecast(_ fact: ResetNewsFact, date: ResetForecastDatePresentation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(date.dateText).font(.system(size: 20, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("resetNews.forecastDate")
            Text(date.timeText).font(.system(size: 11, weight: date.isExactTime ? .medium : .regular))
                .foregroundColor(date.isExactTime ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let basis = date.basisText {
                Text(basis).font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if fact.confidence == .tentative {
                Text("公告措辞尚未确定").font(.system(size: 10)).foregroundColor(.orange)
            }
            if let scope = fact.scope, !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("适用范围：" + scope).font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let validity = fact.expiresAt.map({ Self.date($0) }) ?? fact.validityText, !validity.isEmpty {
                Text("有效期：" + validity).font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func kind(_ kind: ResetNewsFactKind) -> String {
        switch kind {
        case .upcomingReset: return "即将重置"
        case .resetAnnouncement: return "重置公告"
        case .extraResetCredits: return "额外重置次数"
        }
    }
    private static func status(_ status: ResetNewsStatus) -> String {
        switch status {
        case .active: return "有效"
        case .cancelled: return "已取消"
        case .expired: return "已过期"
        case .superseded: return "已被替代"
        }
    }
    private static func date(_ date: Date?) -> String {
        date.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "未提供"
    }
}

private extension Array where Element == String {
    var uniqued: [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
