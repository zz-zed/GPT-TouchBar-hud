import AppKit
import SwiftUI

// Alias disambiguates the original macOS 10.15 property wrapper from the new
// same-named macro in newer SDKs; standalone swiftc does not ship that plugin.
private typealias NotchLocalState<Value> = SwiftUI.State<Value>

enum NotchStyle {
    static let cobalt = Color(red: 0, green: 71 / 255, blue: 171 / 255)
    static let accent = Color(red: 90 / 255, green: 168 / 255, blue: 240 / 255)
    static let secondary = Color(white: 0.72)
}

struct NotchMaterialHalo: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Only this decorative leaf owns a frame clock. It disappears when inactive.
struct NotchSweep: View {
    let path: Path
    let carrier: CGSize
    let active: Bool
    var body: some View {
        if active {
            if #available(macOS 12.0, *) {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    stroke(angle: context.date.timeIntervalSinceReferenceDate * 100)
                }
            }
        }
    }
    private func stroke(angle: Double) -> some View {
        path.stroke(AngularGradient(gradient: Gradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .clear, location: 0.55),
            .init(color: NotchStyle.cobalt, location: 0.78),
            .init(color: .white.opacity(0.95), location: 0.92),
            .init(color: .clear, location: 1)
        ]), center: UnitPoint(x: path.boundingRect.midX / carrier.width, y: path.boundingRect.midY / carrier.height),
        angle: .degrees(angle.truncatingRemainder(dividingBy: 360))), lineWidth: 4).blur(radius: 3)
    }
}

struct NotchButtonStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0.07))
            .cornerRadius(6)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(.easeOut(duration: reduceMotion ? 0 : 0.11), value: configuration.isPressed)
    }
}

struct NotchAction: View {
    let title: String
    let identifier: String
    let reduceMotion: Bool
    let action: () -> Void
    @NotchLocalState private var hovering = false
    var body: some View {
        Button(action: action) { Text(title).foregroundColor(hovering ? .white : NotchStyle.secondary) }
            .buttonStyle(NotchButtonStyle(reduceMotion: reduceMotion))
            .onHover { value in withAnimation(.easeOut(duration: 0.12)) { hovering = value } }
            .accessibilityIdentifier(identifier)
    }
}
