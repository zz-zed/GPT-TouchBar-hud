import AppKit
import ObjectiveC
import Darwin

protocol SystemTouchBarPresenting: AnyObject {
    var isAvailable: Bool { get }
    func present(_ touchBar: NSTouchBar)
    func dismiss(_ touchBar: NSTouchBar)
}

/// AppKit's public responder-chain API cannot display a bar across applications.
/// Keep the undocumented system-modal API isolated and resolve it at runtime so
/// unsupported systems can continue using the public, focused-window behavior.
final class SystemTouchBarPresenter: SystemTouchBarPresenting {
    // App-region placement preserves the native Control Strip and its expansion.
    static let applicationRegionPlacement: Int64 = 0
    private typealias Present = @convention(c) (AnyObject, Selector, NSTouchBar, Int64, NSString?) -> Void
    private typealias Dismiss = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void
    static let systemButtonIdentifier = NSTouchBarItem.Identifier("com.jackchen.TouchBarCodexToken.emptySystemButton")

    /// Current AppKit's system-modal overlay uses this item in place of its
    /// automatic background close button. The legacy DFR close-box function is
    /// a no-op on the tested OS. Configure only our bar, never a system overlay.
    static func configureSystemButton(for touchBar: NSTouchBar) {
        guard touchBar.escapeKeyReplacementItemIdentifier == nil ||
                touchBar.escapeKeyReplacementItemIdentifier == systemButtonIdentifier else { return }
        if !touchBar.templateItems.contains(where: { $0.identifier == systemButtonIdentifier }) {
            let item = NSCustomTouchBarItem(identifier: systemButtonIdentifier)
            let emptyView = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 30))
            emptyView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                emptyView.widthAnchor.constraint(equalToConstant: 0),
                emptyView.heightAnchor.constraint(equalToConstant: 30)
            ])
            item.view = emptyView
            item.visibilityPriority = .high
            touchBar.templateItems.insert(item)
        }
        touchBar.escapeKeyReplacementItemIdentifier = systemButtonIdentifier
    }

    private let presentSelector = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
    private let dismissSelector = NSSelectorFromString("dismissSystemModalTouchBar:")
    private let presentFunction: Present?
    private let dismissFunction: Dismiss?

    init() {
        if let method = Self.compatibleMethod(presentSelector, arguments: ["@", ":", "@", "q", "@"]) {
            presentFunction = unsafeBitCast(method_getImplementation(method), to: Present.self)
        } else {
            presentFunction = nil
        }
        if let method = Self.compatibleMethod(dismissSelector, arguments: ["@", ":", "@"]) {
            dismissFunction = unsafeBitCast(method_getImplementation(method), to: Dismiss.self)
        } else {
            dismissFunction = nil
        }
    }

    var isAvailable: Bool { presentFunction != nil && dismissFunction != nil }

    private static func compatibleMethod(_ selector: Selector, arguments: [String]) -> Method? {
        guard let method = class_getClassMethod(NSTouchBar.self, selector),
              method_getNumberOfArguments(method) == arguments.count else { return nil }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType) == "v" else { return nil }
        for (index, expected) in arguments.enumerated() {
            guard let type = method_copyArgumentType(method, UInt32(index)) else { return nil }
            defer { free(type) }
            guard String(cString: type) == expected else { return nil }
        }
        return method
    }

    func present(_ touchBar: NSTouchBar) {
        guard isAvailable else { return }
        Self.configureSystemButton(for: touchBar)
        // Let macOS own the right-hand controls and cover this bar when expanded.
        // Never request full-width placement or alter global Control Strip prefs.
        presentFunction?(NSTouchBar.self, presentSelector, touchBar, Self.applicationRegionPlacement, nil)
    }

    func dismiss(_ touchBar: NSTouchBar) {
        dismissFunction?(NSTouchBar.self, dismissSelector, touchBar)
    }
}
