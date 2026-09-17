import AppKit

/// Non-interactive status section above native menu actions.
final class StatusSummaryView: NSView {
    init(state: RateLimitDisplayState) {
        super.init(frame: .zero)
        var lines: [(String, NSFont, NSColor)] = [
            (AppIdentity.productName, .systemFont(ofSize: 13, weight: .semibold), .labelColor)
        ]
        var metrics: [String] = []
        if let five = state.fiveHour { metrics.append("5h \(five.remainingText)") }
        else if let credits = state.resetCredits { metrics.append(credits.compactText) }
        if let weekly = state.weekly { metrics.append("7d \(weekly.remainingText)") }
        lines.append((metrics.isEmpty ? "额度 --" : metrics.joined(separator: "    "), .monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .labelColor))
        if let task = state.displayedTaskStatus { lines.append((task.label, .systemFont(ofSize: 11), TaskStatusAppearance(task).color ?? .secondaryLabelColor)) }
        if let five = state.fiveHour { lines.append(("5h · \(five.resetText)", .systemFont(ofSize: 11), .secondaryLabelColor)) }
        else if let credits = state.resetCredits { lines.append((credits.expirationText, .systemFont(ofSize: 11), .secondaryLabelColor)) }
        if let weekly = state.weekly { lines.append(("7d · \(weekly.resetText)", .systemFont(ofSize: 11), .secondaryLabelColor)) }
        if let usage = state.tokenUsage {
            lines.append(("\(usage.yesterdayText) · \(usage.cumulativeText)", .systemFont(ofSize: 11), .secondaryLabelColor))
        }
        if let balance = state.creditBalance { lines.append((balance.displayText, .systemFont(ofSize: 11), .secondaryLabelColor)) }
        lines.append((state.statusText, .systemFont(ofSize: 10), state.errorMessage == nil ? .secondaryLabelColor : .systemOrange))
        let labels = lines.map { text, font, color -> NSTextField in
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = color
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = text
            return label
        }
        let width = min(480, max(300, labels.map { $0.fittingSize.width + 28 }.max() ?? 300))
        let height = CGFloat(labels.count) * 20 + 18
        frame = NSRect(x: 0, y: 0, width: width, height: height)
        for (index, label) in labels.enumerated() {
            label.frame = NSRect(x: 14, y: height - 27 - CGFloat(index) * 20, width: width - 28, height: 18)
            addSubview(label)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
