import AppKit

/// Screen-space hardware bounds and visual height are deliberately independent.
struct NotchLayout: Equatable {
    let screenFrame: CGRect
    let hardwareExclusionRect: CGRect
    let notchCenterX: CGFloat
    let notchWidth: CGFloat
    let physicalTopInset: CGFloat
    let visualBarHeight: CGFloat
    let backingScaleFactor: CGFloat
    let windowFrame: CGRect
    let expandedSize: CGSize
    let pillSlotWidth: CGFloat

    init(geometry: NotchHUDGeometry, visibleTopDelta: CGFloat? = nil, heightCalibration: CGFloat = 1) {
        screenFrame = geometry.screen
        hardwareExclusionRect = geometry.cameraEnclosure
        notchCenterX = geometry.anchor.x
        notchWidth = geometry.notchWidth
        physicalTopInset = geometry.topInset
        backingScaleFactor = geometry.backingScale
        visualBarHeight = Self.visualHeight(physical: geometry.topInset, visibleDelta: visibleTopDelta,
                                           calibration: heightCalibration, scale: geometry.backingScale)
        let available = floor(2 * min(notchCenterX - screenFrame.minX, screenFrame.maxX - notchCenterX))
        let width = min(900, available)
        let height = min(360, screenFrame.height)
        windowFrame = CGRect(x: notchCenterX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
        // Keep shadow inside the carrier; narrow displays shrink slots before overflowing.
        let surfaceWidth = min(width, max(notchWidth + 76, min(520, width - 48)))
        let footerAllowance: CGFloat = surfaceWidth < 500 ? 17 : 0
        let detailHeight = max(physicalTopInset, visualBarHeight) + 218 + footerAllowance
        expandedSize = CGSize(width: surfaceWidth, height: min(height - 36, detailHeight))
        pillSlotWidth = max(0, min(96, (expandedSize.width - notchWidth - 76) / 2))
    }

    static func visualHeight(physical: CGFloat, visibleDelta: CGFloat?, calibration: CGFloat, scale: CGFloat) -> CGFloat {
        let measured = (visibleDelta ?? 0) - calibration
        let height = measured.isFinite && measured > 0 ? min(physical, measured) : physical
        return max(20, floor(height * scale) / scale)
    }

    func size(for state: NotchPresentationState) -> CGSize {
        switch state {
        case .compact: return CGSize(width: min(windowFrame.width, notchWidth + 76), height: visualBarHeight)
        case .peek: return CGSize(width: min(windowFrame.width, notchWidth + 76 + pillSlotWidth * 2), height: visualBarHeight)
        case .expanded: return expandedSize
        }
    }
    var isUsable: Bool {
        windowFrame.width >= notchWidth + 76 && expandedSize.height >= max(physicalTopInset, visualBarHeight) + 164
    }
    var localExclusion: CGRect {
        CGRect(x: hardwareExclusionRect.minX - windowFrame.minX, y: 0, width: notchWidth, height: physicalTopInset)
    }
    func markX(left: Bool) -> CGFloat { windowFrame.width / 2 + (left ? -1 : 1) * (notchWidth / 2 + 19) }
}
