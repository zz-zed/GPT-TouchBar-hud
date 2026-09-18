import AppKit

enum TaskStatusAppearance: Equatable {
    case idle, running, completed, unknown

    init(_ summary: TaskStatusSummary?) {
        if let summary, summary.runningCount > 0 { self = .running }
        else if let summary, summary.recentlyCompletedCount > 0 { self = .completed }
        else if let summary, summary.unknownCount > 0 { self = .unknown }
        else { self = .idle }
    }

    var color: NSColor? {
        switch self {
        case .idle: return nil
        case .running: return .systemBlue
        case .completed: return .systemGreen
        case .unknown: return .systemGray
        }
    }

    func menuIcon() -> NSImage? {
        let symbol: String
        switch self {
        case .completed: symbol = "checkmark.circle.fill"
        case .unknown: symbol = "questionmark.circle.fill"
        case .idle, .running: symbol = "bolt.horizontal.circle.fill"
        }
        guard let source = NSImage(systemSymbolName: symbol,
                                   accessibilityDescription: "GPT TouchBar HUD") else { return nil }
        guard let color else {
            source.isTemplate = true
            return source
        }
        // Tint only the image, not NSStatusBarButton's quota text. A template
        // image would let AppKit replace the task color with monochrome.
        let image = NSImage(size: source.size, flipped: false) { rect in
            source.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
        image.isTemplate = false
        return image
    }
}
