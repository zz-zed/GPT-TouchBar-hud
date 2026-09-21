# Reference provenance and implementation choices

- Application base: `a2969a071cf4edba9b572ea46d33498bb0b685ba`.
- Reference: [ericjypark/codex-island at 810b8ac](https://github.com/ericjypark/codex-island/tree/810b8ac0c45e1fd191c3b37e6dc37f943b71cba1).
- Retrieved the pinned GitHub tarball on 2026-09-21. Read `LICENSE`, `Sources/Window/IslandWindowController.swift`, `Sources/Model/IslandModel.swift`, `Sources/Model/NotchInfo.swift`, `Sources/Views/IslandShape.swift`, `Sources/Theme/Animations.swift`, and the presentation/decoration sections of `Sources/Views/IslandRootView.swift`.
- MIT: Copyright (c) 2026 Eric Park. Full notice is in `Resources/ThirdPartyNotices.txt` and copied into the signed App's Resources directory by `scripts/build-app.sh`.

## Confirmed upstream mechanisms

The controller uses a 900 × 360 transparent host and positions its top edge at the screen top. The model uses 38 pt mark slots, 96 pt outer preview slots, 800 pt expanded width. `IslandShape` uses a continuous 14 pt lower corner and square top corners. Opening and closing springs use response/damping 0.42/0.82 and 0.30/0.88. Root choreography starts preview at 60 ms, details at 220 ms, preview exit at 250 ms, and closing geometry 20 ms after content starts fading. The decorative sweep alone owns a 30 Hz timeline at 100 degrees/second.

## Deliberate differences required by the brief

- Upstream activates the app, makes its window key, uses a popup-menu window level and intercepts keyboard navigation. This implementation retains a nonactivating, non-key status-level `NSPanel` and the existing full-screen policy; no keyboard monitor is added.
- Upstream routes with a target-size rectangle. Our `AnimatableModifier` supplies its actual interpolated dimensions to both the shared CGPath and an `NSViewRepresentable` bridge, which refreshes `ignoresMouseEvents` for stationary as well as moving pointers. Camera exclusion, hover tolerance and decorative effects are separate.
- All delayed work is cancellable and generation-checked. An exiting detail layer remains mounted through its 100 ms fade. Updating data never changes transition intent or recomputes the window frame.
- Upstream `UnevenRoundedRectangle` requires a newer OS. Our macOS 11 path uses a cubic continuous-corner approximation with zero curvature at straight-edge joins. This is not a claim of pixel-identical Apple squircle geometry. The same path is used for rendering, clipping and containment.
- Width and content height are bounded before animation. Small-screen preview slots shrink; details scroll inside a fixed shell. Physical camera height and visible bar height are independent; the minus-1-point policy is a calibratable default, not a universal hardware fact.
- Quota, activity and usage pages consume existing `HUDMetric` / `NotchTaskPresentation` semantics. No usage history, charges, completion inference, Hook redesign or fetch pipeline is invented.
- The internal `GPT_HUD_NOTCH_RENDERER=legacy` launch switch creates only the legacy renderer. The ordinary path creates only the island renderer. It does not rewrite preferences.

## Evidence boundary

The full provided implementation and reference text are preserved alongside this document. The separately mentioned 51-case attachment was not returned. Our executable checklist is derived from the available body. Neither this source inspection nor the synthetic native harness is same-machine upstream visual comparison, physical-notch acceptance, Intel runtime acceptance or macOS 11 runtime acceptance.
