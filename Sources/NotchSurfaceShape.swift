import AppKit
import SwiftUI

/// A macOS 11-compatible continuous-corner approximation. The corner cubic has
/// zero curvature at both straight-edge joins (unlike a circular quarter arc).
/// Drawing, clipping, and AppKit containment all use this exact CGPath.
struct NotchSurfaceShape: Shape {
    var topRadius: CGFloat = 0
    var bottomRadius: CGFloat = 14
    func path(in rect: CGRect) -> Path {
        Path(Self.path(rect, topRadius: topRadius, bottomRadius: bottomRadius))
    }

    static func path(_ rect: CGRect, topRadius: CGFloat = 0, bottomRadius: CGFloat = 14) -> CGPath {
        let p = CGMutablePath()
        let top = min(max(0, topRadius), max(0, rect.width / 2), max(0, rect.height / 2))
        let r = min(max(0, bottomRadius), max(0, rect.width / 2), max(0, rect.height - top))
        let l = rect.minX, t = rect.minY, x = rect.maxX, b = rect.maxY
        p.move(to: CGPoint(x: l + top, y: t))
        p.addLine(to: CGPoint(x: x - top, y: t))
        p.addCurve(to: CGPoint(x: x, y: t + top), control1: CGPoint(x: x, y: t), control2: CGPoint(x: x, y: t))
        p.addLine(to: CGPoint(x: x, y: b - r))
        p.addCurve(to: CGPoint(x: x - r, y: b), control1: CGPoint(x: x, y: b), control2: CGPoint(x: x, y: b))
        p.addLine(to: CGPoint(x: l + r, y: b))
        p.addCurve(to: CGPoint(x: l, y: b - r), control1: CGPoint(x: l, y: b), control2: CGPoint(x: l, y: b))
        p.addLine(to: CGPoint(x: l, y: t + top))
        p.addCurve(to: CGPoint(x: l + top, y: t), control1: CGPoint(x: l, y: t), control2: CGPoint(x: l, y: t))
        p.closeSubpath()
        return p
    }
}

struct NotchPresentationGeometry: Equatable {
    let size: CGSize
    let carrierWidth: CGFloat
    let exclusion: CGRect
    var rect: CGRect { CGRect(x: (carrierWidth - size.width) / 2, y: 0, width: size.width, height: size.height) }
    // Derive the corner transition from the actual presented height, so reversals
    // and reduced-motion updates use the same outline for drawing and hit testing.
    private var expansion: CGFloat { max(0, min(1, (size.height - max(20, exclusion.height)) / 64)) }
    var topCornerRadius: CGFloat { 26 * expansion }
    var bottomCornerRadius: CGFloat { 14 + 14 * expansion }
    var path: CGPath {
        NotchSurfaceShape.path(rect, topRadius: topCornerRadius, bottomRadius: bottomCornerRadius)
    }
    func acceptsClick(_ point: CGPoint) -> Bool { path.contains(point) && !exclusion.contains(point) }
    func maintainsHover(_ point: CGPoint) -> Bool {
        rect.insetBy(dx: -2, dy: -2).contains(point) || exclusion.contains(point)
    }
}

/// Non-observable bridge: publishing a presented frame never invalidates the root.
final class NotchGeometryBridge {
    var epoch = 0
    private(set) var snapshot: NotchPresentationGeometry?
    var onChange: ((NotchPresentationGeometry) -> Void)?
    func publish(_ snapshot: NotchPresentationGeometry, epoch: Int) {
        guard epoch == self.epoch, self.snapshot != snapshot else { return }
        self.snapshot = snapshot
        onChange?(snapshot)
    }
    func invalidate() { epoch += 1; snapshot = nil }
}

private struct NotchGeometryProbe: NSViewRepresentable {
    let snapshot: NotchPresentationGeometry
    let epoch: Int
    let bridge: NotchGeometryBridge
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) { bridge.publish(snapshot, epoch: epoch) }
}

/// SwiftUI evaluates this body with its actual interpolated presentation values.
/// There is no separate timer, target-rect router, or spring approximation.
struct NotchAnimatedSurface: AnimatableModifier {
    var width: CGFloat
    var height: CGFloat
    let layout: NotchLayout
    let bridge: NotchGeometryBridge
    let epoch: Int
    let expanded: Bool
    let haloMounted: Bool
    let haloVisible: Bool
    let reduceTransparency: Bool
    let sweepActive: Bool
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(width, height) }
        set { width = newValue.first; height = newValue.second }
    }
    func body(content: Content) -> some View {
        let geometry = NotchPresentationGeometry(size: CGSize(width: width, height: height),
                                                carrierWidth: layout.windowFrame.width, exclusion: layout.localExclusion)
        let shape = Path(geometry.path)
        return content
            .clipShape(shape)
            .background(
                ZStack(alignment: .top) {
                    if haloMounted && !reduceTransparency {
                        NotchMaterialHalo().frame(width: width + 18, height: height + 18)
                            .clipShape(NotchSurfaceShape()).blur(radius: 8).opacity(haloVisible ? 0.55 : 0)
                            .offset(y: -9)
                    }
                    shape.fill(Color.black)
                        .shadow(color: NotchStyle.cobalt.opacity(0.35), radius: 14)
                        .shadow(color: expanded ? Color.black.opacity(0.5) : .clear, radius: 20, y: 10)
                    shape.stroke(Color.white.opacity(expanded ? 0.12 : 0), lineWidth: 0.5)
                    NotchSweep(path: shape, carrier: layout.windowFrame.size, active: sweepActive)
                }.allowsHitTesting(false)
            )
            .background(NotchGeometryProbe(snapshot: geometry, epoch: epoch, bridge: bridge))
    }
}
