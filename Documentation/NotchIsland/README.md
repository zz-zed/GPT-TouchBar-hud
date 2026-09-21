# Native notch island

The island renderer replaces the notch presentation layer while continuing to consume `AppDelegate.renderDisplayState()`. The existing floating HUD, Touch Bar, task authority, completion feedback and automatic updater are unchanged. The default resting presentation is Compact; the new setting **刘海始终显示额度** selects Peek at rest and does not reset existing display or visibility preferences.

Without a saved display mode, startup uses **自动**: valid notch geometry selects the island, otherwise presentation falls back to the floating HUD. A saved **桌面浮窗** or **刘海融合** choice takes precedence and survives restarts and display changes; selecting **自动** resumes detection. Startup shows the island if a notch is available and no visibility choice has been saved. An explicit hide stays hidden, and startup without a notch keeps the unconfigured floating HUD hidden. Previously saved modes are preserved because older versions did not record whether a saved value came from a manual selection or a visibility change.

## Native preview

From the repository root:

```sh
bash scripts/test-notch-presentation.sh --preview --debug-regions
```

The preview is a standalone native harness, not the installed app. It uses fixed sample data and synthetic screen/camera geometry and does not start Hook services, network requests, lifecycle launch agents, updater downloads or installation. It appears 100 pt below the real screen top over a labelled synthetic desktop. Hover a wing to Peek, click to expand, use the page buttons or the right-click menu, and leave the surface to collapse. Hide exits the preview; Control-C also exits. Refresh and Settings do not invoke application services in the harness.

Options may be combined:

```sh
bash scripts/test-notch-presentation.sh --preview --width 640 --height 600 --notch-width 180 --physical-inset 38 --visual-height 24 --always-peek --english
bash scripts/test-notch-presentation.sh --preview --reduced-motion --reduced-transparency --low-power
```

`--debug-regions`: green = actual rendered path; orange = hover rectangle/tolerance; red = camera exclusion. The camera may hold hover but never receives clicks. Decorative glow and shadows remain outside the click path. Width/height are bounded to the actual desktop for the interactive preview. Automated geometry tests additionally cover negative origins, secondary-display coordinates and 1×/2× scales. No synthetic configuration is named after a calibrated Mac model.

## Automated checks

```sh
bash scripts/test-notch-presentation.sh
bash scripts/test-notch-hud.sh
bash scripts/test-design-layout.sh
bash scripts/test-app-update.sh
swift test
bash scripts/build-app.sh
```

The first command compiles all production files (excluding app `main.swift`) for macOS 11, then runs deterministic state/clock, geometry, data adapter, native hosting, animation and routing checks. It writes PNGs and `results.json` into `build/notch-island/`. The dedicated test is connected to `.github/workflows/build-dmg.yml` alongside the legacy regression suite. `swift test` covers HookCore, not the island UI.

On hosts that already allow event posting, the harness launches a **separate native receiver process** and sends real WindowServer mouse events to its own isolated test windows. It verifies routing by the receiver's click count. It restores the original pointer position and terminates the receiver. No permission prompt is requested. Without that capability, the report explicitly marks native click delivery `NOT RUN`; model/path checks still execute. Other AppKit UI test suites should not run concurrently with this event-delivery segment.

Native images with `synthetic-` in their name include a simulated desktop and camera. `stage1-` images are transparent carrier snapshots from the shared production view. Full-screen Spaces, true hardware seams, actual menu congestion and Intel/older macOS runtime behavior require separate physical acceptance.

## Implementation map

- `NotchHUDController.swift`: stable external API, renderer selection, fixed panel, visibility/lifecycle, context menu ownership.
- `NotchPresentationModel.swift` / `NotchMotion.swift`: explicit Compact/Peek/Expanded state, page selection, cancellable generation-bound timers, content mounting and accessibility/power gates.
- `NotchLayout.swift`: screen bounds, physical exclusion, independent visual height and bounded carrier/content sizes.
- `NotchSurfaceShape.swift`: one CGPath for shell, clip and click containment; real SwiftUI presentation geometry passed through `NSViewRepresentable`.
- `NotchInteractionController.swift` / `NotchHostingView.swift`: mouse-only monitors, click-through routing, first click, capture, context-menu hold and local paging.
- `NotchContentAdapter.swift` / `NotchDetailPages.swift` / `NotchRootView.swift` / `NotchStyleTokens.swift`: existing data semantics, fixed header/footer, scrollable middle pages and isolated sweep animation.
- `NotchLegacyHUDController.swift`: preserved legacy renderer. Set `GPT_HUD_NOTCH_RENDERER=legacy` in the launch environment to use it; restarting is required. Renderer selection constructs only one window and does not mutate user preferences.

See [implementation brief](IMPLEMENTATION.md), [provided reference text](REFERENCE.md), [upstream facts and compatibility differences](UPSTREAM.md), and [validation record](VALIDATION.md). The separately referenced 51-case attachment was not obtained; the validation matrix was derived from the available text.
