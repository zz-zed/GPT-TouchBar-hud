import AppKit

enum ResetForecastIndicator {
    static func image(size: CGFloat = 18) -> NSImage {
        let side = max(1, size)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            context.saveGState()
            defer { context.restoreGState() }

            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / 18, y: rect.height / 18)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            // A long return arc keeps the reset meaning distinct from a plain clock.
            let center = CGPoint(x: 9, y: 9)
            context.setLineWidth(1.55)
            context.addArc(
                center: center,
                radius: 6.25,
                startAngle: .pi / 4,
                endAngle: .pi * 5 / 6,
                clockwise: true
            )
            context.strokePath()

            // Arrow head at the end of the return arc.
            context.move(to: CGPoint(x: 3.59, y: 12.13))
            context.addLine(to: CGPoint(x: 1.63, y: 10.88))
            context.move(to: CGPoint(x: 3.59, y: 12.13))
            context.addLine(to: CGPoint(x: 3.39, y: 9.99))
            context.strokePath()

            // Four clock ticks remain legible at the default 18-point size.
            context.setLineWidth(0.9)
            for angle in stride(from: CGFloat(0), to: .pi * 2, by: .pi / 2) {
                let inner = CGPoint(
                    x: center.x + cos(angle) * 3.15,
                    y: center.y + sin(angle) * 3.15
                )
                let outer = CGPoint(
                    x: center.x + cos(angle) * 3.75,
                    y: center.y + sin(angle) * 3.75
                )
                context.move(to: inner)
                context.addLine(to: outer)
            }
            context.strokePath()

            // Clock hands point to an upcoming time, not to a refresh action.
            context.setLineWidth(1.25)
            context.move(to: center)
            context.addLine(to: CGPoint(x: 9, y: 11.75))
            context.move(to: center)
            context.addLine(to: CGPoint(x: 11.05, y: 10.15))
            context.strokePath()

            context.fillEllipse(in: CGRect(x: 8.35, y: 8.35, width: 1.3, height: 1.3))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = DisplayLanguage.text("重置预告", "Reset forecasts")
        return image
    }

    static func countText(_ forecastCount: Int) -> String {
        let count = max(0, forecastCount)
        return count > 99 ? "99+" : String(count)
    }

    static func accessibilityLabel(_ forecastCount: Int) -> String {
        let count = max(0, forecastCount)
        return DisplayLanguage.text(
            "重置预告（\(count) 条）",
            "Reset forecasts (\(count) upcoming)"
        )
    }
}
