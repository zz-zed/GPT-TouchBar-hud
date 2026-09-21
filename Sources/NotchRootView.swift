import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchPresentationModel
    let bridge: NotchGeometryBridge
    var body: some View {
        Group {
            if let layout = model.layout {
                content(layout)
                    .frame(width: layout.windowFrame.width, height: layout.windowFrame.height, alignment: .top)
                    .modifier(NotchAnimatedSurface(width: model.size.width, height: model.size.height,
                                                   layout: layout, bridge: bridge, epoch: bridge.epoch,
                                                   expanded: model.state == .expanded,
                                                   haloMounted: model.detailsMounted,
                                                   haloVisible: model.detailsVisible,
                                                   reduceTransparency: model.reduceTransparency,
                                                   sweepActive: model.sweepActive))
            } else { Color.clear }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("GPT HUD")
    }

    private func content(_ layout: NotchLayout) -> some View {
        ZStack(alignment: .top) {
            if model.state != .expanded {
                Button(action: model.click) { Color.black.opacity(0.001).frame(width: model.size.width, height: layout.visualBarHeight) }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel(DisplayLanguage.text("展开详情", "Expand details"))
                    .accessibilityIdentifier("notch.expand")
            }
            marks(layout).allowsHitTesting(false)
            peek(layout).allowsHitTesting(false)
            if model.detailsMounted {
                NotchDetailPages(model: model, layout: layout)
                    .frame(width: layout.expandedSize.width, height: layout.expandedSize.height)
                    .opacity(model.detailsVisible ? 1 : 0)
                    .offset(y: model.detailsVisible || model.reduceMotion ? 0 : -8)
                    .allowsHitTesting(model.detailsVisible && model.state == .expanded)
                    .accessibilityHidden(!model.detailsVisible || model.state != .expanded)
            }
        }.frame(width: layout.windowFrame.width, height: layout.windowFrame.height, alignment: .top)
    }
    private func marks(_ layout: NotchLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 20)).foregroundColor(.white)
                .frame(width: 20, height: 20)
                .position(x: layout.markX(left: true), y: layout.visualBarHeight / 2)
            Image(systemName: model.content.tasksEnabled ? model.content.task.appearance.notchSymbol : "gauge")
                .font(.system(size: 20)).foregroundColor(Color(model.content.task.appearance.color ?? .white))
                .frame(width: 20, height: 20)
                .position(x: layout.markX(left: false), y: layout.visualBarHeight / 2)
                .accessibilityLabel(model.content.taskTitle)
        }
    }
    private func peek(_ layout: NotchLayout) -> some View {
        ZStack(alignment: .topLeading) {
            pill(left: true, layout: layout)
            pill(left: false, layout: layout)
        }.opacity(model.pillsVisible ? 1 : 0).accessibilityHidden(!model.pillsVisible)
    }
    private func pill(left: Bool, layout: NotchLayout) -> some View {
        let info = model.content.peek(left: left)
        let direction: CGFloat = left ? -1 : 1
        return VStack(spacing: 0) {
            Text(info.value).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(NotchStyle.accent)
            Text(info.detail).font(.system(size: 8)).foregroundColor(NotchStyle.secondary)
        }
        .lineLimit(1).minimumScaleFactor(0.65)
        .frame(width: max(0, layout.pillSlotWidth - 8), height: layout.visualBarHeight)
        .position(x: layout.windowFrame.width / 2 + direction * (layout.notchWidth / 2 + 38 + layout.pillSlotWidth / 2), y: layout.visualBarHeight / 2)
        .offset(x: model.pillsVisible || model.reduceMotion ? 0 : direction * 6)
        .help(info.value + " · " + info.detail)
    }
}

private extension TaskStatusAppearance {
    var notchSymbol: String {
        switch self {
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle"
        case .idle: return "circle.dotted"
        }
    }
}
