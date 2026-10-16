import SwiftUI
import ResetNewsCore

// Resolve the macOS 11 property wrapper explicitly; newer SDKs also export a State macro.
private typealias ForecastLocalState<Value> = SwiftUI.State<Value>

/// Shared by the notch page and the native popover. A row is read only after it
/// intersects the visible scroll viewport; LazyVStack prefetch alone is not enough.
struct ResetNewsListView: View {
    enum Density { case regular, notch }
    let state: ResetNewsViewState
    let isVisible: Bool
    var focusedItemID: String? = nil
    let onCheck: () -> Void
    let onMarkAllRead: () -> Void
    let onSettings: () -> Void
    let onPageVisibility: (Bool) -> Void
    let onVisibleItem: (String) -> Void
    var onPreferredHeightChange: ((CGFloat) -> Void)? = nil
    var density: Density = .regular
    @ForecastLocalState<Date?> private var shownDeadline = nil
    @ForecastLocalState<Bool> private var expiredWhileOpen = false
    private let coordinateSpace = "resetNewsListViewport"

    var body: some View {
        VStack(alignment: .leading, spacing: density == .notch ? 6 : 12) {
            GeometryReader { viewport in
                ScrollViewReader { reader in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: density == .notch ? 10 : 18) {
                            if state.items.isEmpty {
                                if density == .notch {
                                    Text(expiredWhileOpen ? DisplayLanguage.text("已到预计截止时间，预告已收起", "The announced window has ended")
                                        : ResetNewsListPresentation.emptyText(state))
                                        .font(.system(size: 12)).foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    VStack(alignment: .leading, spacing: 18) {
                                        Label(ResetNewsListPresentation.heading(state), systemImage: "calendar.badge.clock")
                                            .font(.system(size: 13, weight: .medium))
                                        Text(expiredWhileOpen ? DisplayLanguage.text("已到预计截止时间，预告已收起", "The announced window has ended")
                                            : ResetNewsListPresentation.emptyText(state))
                                            .font(.system(size: 18, weight: .semibold))
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(DisplayLanguage.text("实际额度以账号数据为准", "See quota for your account's actual status"))
                                            .font(.system(size: 12)).foregroundColor(.secondary)
                                    }.padding(.vertical, 8)
                                }
                            }
                            ForEach(state.items) { item in
                                ResetNewsCard(item: item, unread: !state.readIDs.contains(item.id),
                                    compactForNotch: density == .notch,
                                    cached: state.forecastAvailability == .cached)
                                    .id(item.id)
                                    .background(GeometryReader { row in
                                        Color.clear.preference(key: ResetNewsCardFrames.self,
                                            value: [item.id: ResetNewsCardFrame(frame: row.frame(in: .named(coordinateSpace)),
                                                pageVisible: isVisible, unread: !state.readIDs.contains(item.id),
                                                materialRevision: item.materialRevision)])
                                    })
                            }
                            if density == .notch, let notice = ResetNewsListPresentation.notice(state), !state.items.isEmpty {
                                Text(notice).font(.system(size: 10)).foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("resetNews.cached")
                            }
                        }.padding(.vertical, density == .notch ? 0 : 4).id(isVisible)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: ResetNewsNaturalHeight.self,
                                    value: .init(content: geometry.size.height))
                            })
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
            VStack(alignment: .leading, spacing: 9) {
                if density == .regular, let notice = ResetNewsListPresentation.notice(state), !state.items.isEmpty {
                    Text(notice).font(.system(size: 12)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("resetNews.cached")
                }
                Divider()
                HStack(spacing: 12) {
                    Text(ResetNewsListPresentation.checkedText(state))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    Button(DisplayLanguage.text("刷新预告", "Refresh forecast"), action: onCheck)
                        .disabled(!state.enabled || [.checking, .codexNotRunning, .idle].contains(state.status))
                        .accessibilityIdentifier("resetNews.check")
                    Button(DisplayLanguage.text("设置", "Settings"), action: onSettings)
                        .accessibilityIdentifier("resetNews.settings")
                }.font(.system(size: 11)).buttonStyle(PlainButtonStyle()).foregroundColor(.accentColor)
            }.help(state.statusText)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ResetNewsNaturalHeight.self, value: .init(footer: geometry.size.height))
                })
        }
        .onPreferenceChange(ResetNewsNaturalHeight.self) { size in
            guard size.content > 0, size.footer > 0 else { return }
            onPreferredHeightChange?(size.content + size.footer + 12)
        }
        .onAppear { onPageVisibility(isVisible); rememberDeadline(state.items) }
        .onChange(of: state.items) { items in
            expiredWhileOpen = isVisible && items.isEmpty && shownDeadline.map { $0 <= Date() } == true
            rememberDeadline(items)
        }
        .onChange(of: isVisible) { visible in
            onPageVisibility(visible)
            if !visible { expiredWhileOpen = false }
        }
        .onDisappear { onPageVisibility(false) }
        .accessibilityIdentifier("resetNews.list")
    }

    private func rememberDeadline(_ items: [ResetNewsItem]) {
        guard let item = items.first, let fact = item.facts.first(where: { $0.kind == .upcomingReset }),
              ResetForecastHeadline(fact: fact, publishedAt: item.publishedAt).hasClock else {
            shownDeadline = nil; return
        }
        shownDeadline = ResetForecastPolicy().scheduledDate(for: fact, publishedAt: item.publishedAt)
    }
}

private struct ResetNewsNaturalSize: Equatable {
    var content: CGFloat = 0
    var footer: CGFloat = 0
}
private enum ResetNewsNaturalHeight: PreferenceKey {
    static var defaultValue = ResetNewsNaturalSize()
    static func reduce(value: inout ResetNewsNaturalSize, nextValue: () -> ResetNewsNaturalSize) {
        let next = nextValue()
        value.content = max(value.content, next.content)
        value.footer = max(value.footer, next.footer)
    }
}

enum ResetNewsListPresentation {
    static func emptyText(_ state: ResetNewsViewState) -> String {
        guard state.enabled else { return DisplayLanguage.text("开启后可查看公开重置预告", "Enable public reset forecasts") }
        if state.forecastAvailability == .current { return DisplayLanguage.text("当前暂无公开重置预告", "No current public reset forecast") }
        if state.forecastAvailability == .cached || [.failure, .partial, .stale].contains(state.status) {
            return DisplayLanguage.text("暂时无法获取预告，请稍后重试", "Forecast unavailable. Try again later.")
        }
        switch state.status {
        case .checking: return DisplayLanguage.text("正在获取预告", "Fetching forecast")
        case .codexNotRunning: return DisplayLanguage.text("检查已暂停，Codex 启动后继续", "Checks resume when Codex starts")
        case .idle: return DisplayLanguage.text("检查已暂停", "Forecast checks paused")
        default: return DisplayLanguage.text("尚未获取预告", "Forecast not fetched yet")
        }
    }
    static func heading(_ state: ResetNewsViewState) -> String {
        DisplayLanguage.text("公开重置预告", "Public reset forecast")
    }
    static func checkedText(_ state: ResetNewsViewState) -> String {
        if state.status == .checking { return DisplayLanguage.text("正在更新…", "Updating…") }
        guard let date = state.forecastCheckedAt else { return DisplayLanguage.text("尚未检查", "Not checked yet") }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"; formatter.timeZone = .current
        return DisplayLanguage.text("最近检查 ", "Checked ") + formatter.string(from: date)
    }
    static func notice(_ state: ResetNewsViewState) -> String? {
        if state.forecastAvailability == .cached {
            return DisplayLanguage.text("暂时无法更新，正在显示上次获取的预告", "Unable to update; showing the last fetched forecast")
        }
        if [.failure, .partial, .stale].contains(state.status) { return state.statusText }
        return nil
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
    let compactForNotch: Bool
    let cached: Bool
    private let forecasts: [ResetForecastHeadline]

    init(item: ResetNewsItem, unread: Bool, compactForNotch: Bool = false, cached: Bool = false,
         now: Date = Date(), calendar: Calendar = .current) {
        self.item = item; self.unread = unread; self.compactForNotch = compactForNotch; self.cached = cached
        forecasts = item.facts.filter { $0.kind == .upcomingReset }.map {
            ResetForecastHeadline(fact: $0, publishedAt: item.publishedAt, now: now, calendar: calendar,
                locale: Locale(identifier: DisplayLanguage.current == .chinese ? "zh_CN" : "en_US"))
        }
    }

    var body: some View {
        Group {
            if compactForNotch { notchBody }
            else { fullBody }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("resetNews.item.\(item.id)")
    }

    private var notchBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(forecasts.enumerated()), id: \.offset) { _, date in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text((cached ? DisplayLanguage.text("上次预告 · ", "Last forecast · ") : "")
                            + (date.lead ?? DisplayLanguage.text("公开重置预告", "Public reset forecast")))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(NotchStyle.secondary)
                        if unread {
                            Circle().fill(NotchStyle.accent).frame(width: 5, height: 5)
                                .accessibilityLabel(DisplayLanguage.text("新预告", "New forecast"))
                        }
                        Spacer(minLength: 4)
                    }
                    Text(date.headline).font(.system(size: date.hasClock ? 27 : 21, weight: .semibold).monospacedDigit())
                        .foregroundColor(cached ? NotchStyle.secondary : .white)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("resetNews.forecastTime")
                    if let day = date.dateText {
                        Text(day + (date.zoneText.map { " · " + $0 } ?? ""))
                            .font(.system(size: 10)).foregroundColor(NotchStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("resetNews.forecastDate")
                    }
                }
            }
            if forecasts.isEmpty {
                Text(ResetNewsDisplayText.hidingAddresses(in: item.summaryZH))
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            Text(DisplayLanguage.text("实际额度以账号数据为准", "See quota for your account's actual status"))
                .font(.system(size: 10)).foregroundColor(NotchStyle.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 7) {
                Image(systemName: "calendar.badge.clock").foregroundColor(.secondary)
                Text(DisplayLanguage.text("公开重置预告", "Public reset forecast"))
                    .font(.system(size: 13, weight: .medium))
                if unread {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                        .accessibilityLabel(DisplayLanguage.text("新预告", "New forecast"))
                }
                Spacer(minLength: 4)
                Text(item.facts.contains { $0.confidence == .tentative }
                    ? DisplayLanguage.text("措辞待确认", "Tentative") : DisplayLanguage.text("已有预告", "Announced"))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            ForEach(Array(forecasts.enumerated()), id: \.offset) { _, date in
                VStack(alignment: .leading, spacing: 7) {
                    if let lead = date.lead { Text(lead).font(.system(size: 14, weight: .medium)) }
                    Text(date.headline).font(.system(size: date.hasClock ? 30 : 22, weight: .semibold).monospacedDigit())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("resetNews.forecastTime")
                    if date.hasClock, let day = date.dateText {
                        Text(day + (date.zoneText.map { " · " + $0 } ?? ""))
                            .font(.system(size: 12)).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("resetNews.forecastDate")
                    } else if let zone = date.zoneText {
                        Text(zone).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }
            }
            if forecasts.isEmpty {
                Text(ResetNewsDisplayText.hidingAddresses(in: item.summaryZH)).font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text(DisplayLanguage.text("实际额度以账号数据为准", "See quota for your account's actual status"))
                .font(.system(size: 12)).foregroundColor(.secondary)

        }
        .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
    }
}
