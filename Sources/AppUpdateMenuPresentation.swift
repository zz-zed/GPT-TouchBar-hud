import AppKit

/// A native menu row keeps arrow-key navigation and VoiceOver actions intact.
enum AppUpdateMenuPresentation {
    static func apply(to item: NSMenuItem?, version: String, enabled: Bool) {
        guard let item else { return }
        let heading = "新版本 \(version) 可用"
        let title = NSMutableAttributedString(string: heading, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.systemBlue
        ])
        title.append(NSAttributedString(string: "   查看更新…", attributes: [
            .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor
        ]))
        item.title = heading + " · 查看更新…"
        item.attributedTitle = title
        item.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "有新版本")
        item.toolTip = "查看版本说明，选择安装、稍后或跳过此版本。"
        item.isEnabled = enabled
    }
}
