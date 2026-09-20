# Notch V2 / accessory app delivery

Worktree: `/Users/didi/.codex/worktrees/6c27/TouchBarCodexToken`.
Baseline: `dd274b28f1f7487d447fad6bb62fd7ce3f9aad46`, v0.1.27 / build 28, initially clean. Version remains unchanged. This is an isolated local implementation for review, not an installed or published update.

## Implemented behavior

- The normal summary is 24 pt. Its attributed title is also its measurement source: complete task numbers and all present quotas are displayed together, with no maximum-number, error, separator or missing-column reservations. Hardware gap width is the minimum. Extreme narrow layouts first abbreviate the reset label and then wrap without dropping digits.
- Expanded width starts at 340 pt. Native fonts determine height; the regular Chinese dual-quota fixture measures **340 × 227 pt**. Long status/date/metadata text wraps. If natural height exceeds the screen, the detail region scrolls and its actions remain reachable. Normal content has no scroll bar.
- The black surface has a hardware-width neck, curved shoulders and bottom corners. Drawing, view hit testing and window mouse routing use the same current path, including during animation. No decorative overlap is currently added above the safe-area edge: this conservatively avoids menu hit regions until a real camera seam can be calibrated. Neither the prototype's 180 px camera width nor its 8 px overlap is a device constant.
- Expansion/collapse resizes the small window downward from a stable top/center in 180 ms; detail text then fades in over 100 ms. Text is not scaled. Reduced Motion switches directly. Only an active transition owns a timer. Data updates are immediate and never open details or start completion animations.
- AppKit rounds window origins to whole points on the test system. The hardware center is aligned once, and even point widths prevent half-point horizontal drift during resize. The safe-area vertical anchor remains unchanged.
- The panel remains borderless/nonactivating, cannot become key/main, and does not activate the application. Mouse-only outside-click monitoring is retained; there is no keyboard monitor. Outside click, app/Space change and loss of visibility collapse details. Settings can deliberately acquire focus through the existing AppDelegate path.
- `DisplayTargetResolver` keeps the selected valid display ID across main-screen reordering; removal reselects another valid notch display, with existing Quiet fallback if none remains. Geometry uses screen frame and hardware safe-area APIs, not changing visibleFrame/menu-bar height.
- User visibility (`HUDPresentationPreferences`), presentation mode and actual notch visibility are separate. The controller's `isPresented` is an ordering request; `isVisible` additionally requires active-Space membership and visible occlusion state. Visibility changes update the existing automatic menu mode. It does not infer fullscreen from a preference or `NSWindow.isVisible` alone, or repeatedly order the panel front on Space changes. User hiding, lock/sleep suspension and mode changes preserve existing preference semantics.
- `LSUIElement=true` is in the source and packaged plist; `.accessory` remains in launch/host-start. Detail actions are Refresh, Settings, Hide and Collapse. Settings now has a Quit action. Existing Finder/Spotlight reopen-to-settings behavior remains. Nothing tries to recover an overcrowded menu item or modify a user-pinned Dock item.

## Full-screen mechanism and evidence boundary

Apple's **canJoinAllApplications**, Discussion, explicitly says:

> To opt out of joining other apps’ full screen spaces use fullScreenPrimary.

Source, read on 2026-09-20: [Apple documentation](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications), also available as [official Markdown](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications.md).

The panel therefore replaces `.fullScreenAuxiliary` with `.fullScreenPrimary` and `.fullScreenDisallowsTiling`, retaining `.canJoinAllSpaces`. It offers no action to enter its own fullscreen. `fullScreenNone` only prohibits the window's own fullscreen and was not treated as equivalent evidence. `canJoinAllApplications` itself is not called, so its macOS 13 introduction does not raise this app's deployment target.

Three separate evidence levels must not be conflated:

1. The current Apple documentation supports the selected public collection-behavior strategy.
2. macOS 11 deployment compatibility is checked by compilation/build metadata; it does not prove behavior on macOS 11.
3. Other-app fullscreen entry/exit, multiple displays with independent Spaces, automatic menu hiding, and restoration of an already-hidden preference still require real desktop/hardware acceptance. There is no private fullscreen query, screen capture, Accessibility permission or polling workaround. Occlusion is availability evidence, not a claim to identify why a window is unavailable. AppKit manages exclusion on the target display's active Space; the behavior when another display alone enters fullscreen is not empirically verified.

The test host has two screens (1680 × 1050 and 1920 × 1080); both report safe-area top inset 0 and nil auxiliary camera areas. All camera geometries in automated tests are synthetic.

## Task-state adapter / integration contract

This baseline contains `TaskStatusSummary`, not the future `TaskActivitySnapshot`. `NotchTaskPresentation` is display-only; it does no discovery, logging, hooks, counting, completion inference or health inference.

Current inputs: `TaskStatusSummary?` and explicit `taskDisplayEnabled`.

- Disabled: omit task icon/count; show quota overview.
- Enabled but nil: unavailable, `—`, never zero.
- Explicit legacy idle: `0` with “No recent local activity”, scoped to local observations rather than complete desktop coverage.
- Running: full `runningCount`; uncertainty adds `?`.
- Legacy `unknownCount > 0`: generic incomplete-monitoring explanation. This value can contain a discovery/read-failure sentinel, so it is **not** described as a known number of additional tasks.
- Legacy completion is a static reflection of the source's `recentlyCompletedCount`. With remaining activity the activity count remains; with uncertainty and no confirmed activity there is no overall-success badge. No UI completion timer starts on repeat snapshots, quota refresh or reopening. Stable completion identity/time and event-driven brief feedback remain for the reviewed Hooks adapter integration; this delivery does not claim that final event behavior is complete.

The coordinator has selected `TaskStatusSummary.activity: TaskActivitySnapshot?`, with C's `HookTaskDisplayAdapter` as the authoritative presentation source when activity is non-nil. Integration must first check `TaskStatusSummary.activityPresentation` in `NotchTaskPresentation`, after the explicit enabled guard. That property returns C’s `HookTaskDisplayAdapter` with `state`, `badge`, `label`, `detail`, `hasRunningTasks` and `snapshot.recentCompletions`. Use those values directly; never use legacy default counters in this branch. Preserve `.submitted` as confirming/ellipsis, not running. Keep the completion tracker on the retained controller, not a freshly rebuilt view. C owns coverage, pending/submitted overlap, completion identity/time and source health; production Hooks coverage remains partial, so it must not become precise zero. B intentionally does not import or copy unfinished C code.

Shared integration points:

- `AppDelegate.renderDisplayState()` now calls `notchHUD.update(state, taskDisplayEnabled: taskStatusEnabled)`.
- `AppDelegate` changes here concern window/visibility/screen coordination plus Quit wiring. C's monitoring/experimental settings changes must be retained separately.
- `PreferencesWindowController` adds `onQuit`, the Quit control and corrected display-availability copy. C's experiment controls must be retained.
- `HUDPresentation.swift`: B changes notch geometry/selection and adds the task/visibility adapters. A's `MenuBarPresentation.apply(to:)` and true-content menu-width semantics must be retained; B leaves the original menu code untouched.
- `Tests/NotchHUDTests.swift`: A's native status-item tests must survive alongside B's geometry/layout/visibility tests. The baseline maximum-width menu assertion still exists here because A was not cherry-picked; the integrator must use A's replacement.

## Validation

Fixed-source verification on 2026-09-20 (GUI test scripts run serially):

| Check | Result |
| --- | --- |
| `scripts/test-notch-hud.sh` | PASS, 742 checks; native layout, complete count/percentage matrix, unknown/partial mapping, disabled task group, narrow summary wrapping, screen-height overflow scrolling, target selection, shape routing, intermediate/terminal animation, actual synthetic-panel visibility, refresh/show/expand frontmost-PID preservation, preferences Quit/accessory behavior |
| `scripts/test-design-layout.sh` | PASS, 155 existing design integration checks |
| `scripts/test-touchbar-layout.sh` | PASS, 291 existing layout checks |
| `scripts/test-touchbar.sh` | PASS, 34 lifecycle/preference/data/focus checks, fake presenter; no real system-modal smoke invocation |
| `scripts/test-task-status.sh` | PASS, 34 existing source-state checks |
| `scripts/test-app-migration.sh` | PASS, 4 migration checks |
| `swiftc -target x86_64-apple-macosx11.0 -typecheck Sources/*.swift` | PASS; compilation compatibility only, not an x86_64 runtime build |
| `scripts/build-app.sh` | PASS; Swift 6.4 arm64 release bundle, ad-hoc signing |
| Source/packaged plist | Both parse; `LSUIElement=true`, version remains 0.1.27 / 28 |
| `codesign --verify --deep --strict --verbose=2` | PASS; valid on disk and satisfies designated requirement |
| `scripts/test-first-open.sh` | PASS; isolated temporary copy, launch suppressed, installed app untouched |
| `git diff --check` | PASS |

**Packaging limitation:** `otool` reports `LC_BUILD_VERSION minos 12.0` in this host’s SwiftPM-built arm64 executable, while `Package.swift` and `LSMinimumSystemVersion` still declare 11.0. The x86_64 macOS 11 typecheck does not resolve that mismatch or establish macOS 11 runtime support. The verbose log (`build/notch-v2-build-verbose.log`) confirms SwiftPM invokes `-target arm64-apple-macos12.0`. No build-script change was made here; coordinate the deployment target/toolchain check with C’s packaging integration. The release build also emits missing CommandLineTools library/framework search-path warnings, without failing the link or signature checks.

Final local app: `build/GPT TouchBar HUD.app`.
Executable SHA-256: `f49a3918867f89c8862a6961f6faff522b7cd59e162b8e90cc3e739db67387a4`.

Native evidence: [compact](../build/notch-v2-compact.png), [Chinese expanded](../build/notch-ledger-zh-0.png), [English reset-credit layout](../build/notch-ledger-en-1.png), [extreme count wrapping](../build/notch-v2-extreme.png), [settings general tab](../build/notch-settings-general.png). PNG alpha inspection confirms transparent expanded shoulder/bottom corners and an opaque central neck; this is raster evidence, not real window click-through acceptance. Native screenshots are written under `build/` by `scripts/test-notch-hud.sh`; they are NSView bitmap captures on synthetic geometry, not physical-notch screenshots. The full settings-window bitmap is incomplete on this AppKit renderer; the separate general-tab bitmap and control bounds/action assertions are usable evidence.

Known intermediate failures and fixes:

- A wrapping-height test initially included AppKit's private NSButton text subviews. It now checks the labels owned by the HUD; this was a test-scope correction, with no assertion removed for app-managed labels.
- One design-test compilation was invalidated because the source was edited during compilation. It is rerun after freezing source.
- A live intermediate resize initially moved the center from 756 to 755.5 pt. Even-width alignment fixes the cause; the strict center assertion now observes 756 pt while top remains 950 pt.

Not performed: physical camera seam/transparent-corner click-through; actual other-app fullscreen/multi-display/Space transitions; hardware menu auto-hide; lock/sleep/wake; Finder/Spotlight launch or relaunch, automatic launch, update restart and Dock UI acceptance. Programmatic nonactivating panel actions are a narrower focus check, not a substitute for those cases. No installed app or host process was stopped, no app was copied into `/Applications`, no user Hook configuration or preferences were changed, and nothing was pushed, tagged or released.
