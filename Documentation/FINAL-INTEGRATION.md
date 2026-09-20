# Reviewed A + B + C integration delivery

> Historical integration acceptance for 0.1.27 / build 28. The original frozen bundle and hashes remain in the worktree below. Subsequent 0.1.28 release preparation is recorded separately in [RELEASE-PREPARATION-0.1.28.md](RELEASE-PREPARATION-0.1.28.md); rebuilding in a different worktree does not refresh these historical hashes.

2026-09-20. Local worktree: `/Users/didi/.codex/worktrees/iteration-integration/TouchBarCodexToken`.

This report describes the integrated candidate. The earlier A+B, B and C reports remain stage-specific evidence; their pending-integration and SwiftPM-only packaging notes do not describe the final bundle below. No original delivery worktree, installed app, real Hook configuration or user preference was changed.

## Fixed code

- Reviewed A source: `1a68cc5142e88d003be1a7f91a1920951c65f107`; local `d0700726b80d1b2d25d2bfcb29e74fa31c4286c0`.
- Reviewed B source: `57e4c23bbd24b27ad616aff10558dd6234f992e4`; local `ec58913b2c0a8ad75de1a218c2e72911b304cf3d`.
- Reviewed C source: `99d2e5342cad367b40ed2e5abfcbd5afa7f6c322`; integration merge/cherry-pick **`41837c8ad1c53e9919b1295f8186bbc99a663e83`**.
- Final presentation/lifecycle wiring: **`0e267d258559f7577984a612d3fcd86637784ee8`**.

C's only merge conflict was the adjacent `quitClicked` and `openHookExperiment` methods in Preferences; both callbacks remain. A's native menu sizing/application helper and B's actual visibility, screen selection, geometry, scroll overflow, LSUIElement, Quit and reopen behavior remain. C's source coordinator, isolated configuration-review UI, helper and explicit deployment-target build remain.

## Final shared presentation

`NotchTaskPresentation` checks the explicit enabled flag first, then consumes `TaskStatusSummary.activityPresentation` whenever present. Legacy counters are ignored in that branch. Submitted remains confirming/ellipsis; unknown/partial retains the coverage reason and cannot become zero. Visible detail shows adapter-owned scope/health text, and tooltips retain full diagnostic facts. A missing English reset time now displays one `Resets —` label.

`TaskCompletionFeedbackController` is owned by AppDelegate, independently of any window. It retains C's `HookCompletionFeedbackTracker`, establishes the initial snapshot as a baseline, and grants new eligible identities a four-second display window. Repeated snapshots, quota refresh, hide/reopen and expand/collapse neither replay nor extend it. Disabling task display, changing source and restarting the host clear permission and reset the baseline. A single nonrepeating timer clears permission even while the HUD is hidden and requests one render; there is no standing animation or polling task.

The controller retains at most 32 active completion IDs. Each later authoritative snapshot intersects that set with its current completion identities. A same-turn continuation therefore immediately withdraws its superseded checkmark; another supported completion can keep the original deadline. Removing every supported identity cancels the timer. Neither the snapshot, reducer count nor terminal time is modified.

`TaskStatusSummary.completionFeedbackVisible` carries only this display permission. `HookTaskDisplayAdapter.showsCompletionFeedback` has a backwards-compatible default for source-only callers; the application always supplies the bounded decision. After expiry, badge, label, state and appearance jointly become running, unknown or scope-idle as appropriate, even though source recent-completion history remains for 30 seconds. Partial running work can show a secondary notch ✓ while preserving the running number and `?`; other surfaces keep the same primary meaning without needing that secondary decoration.

The Touch Bar's old fixed 20 pt badge clipped full Hook counts such as `512 ?`. Its badge now measures the actual string and shifts quota columns only as necessary; the icon and existing layout remain. When launching without the host, AppDelegate renders the coordinator's explicit unavailable/disabled state rather than overwriting the menu with `.initial`.

## Final validation

GUI and frontmost-PID scripts ran serially. These checks use isolated state, temporary configuration directories or source fixtures; no Hook was enabled or trusted in the real host.

| Check | Result |
| --- | --- |
| `scripts/test-notch-hud.sh` | **962 passed**: A's real NSStatusItem widths; B's native geometry, overflow, paths, animation and visibility; both languages; Hooks submitted/unknown/zero/full counts/partial; contradictory legacy counters ignored; state/label/appearance agreement across surfaces; disabled display; stable completion identities, exactly four-second fixed-clock permission, actual run-loop single expiration, no replay/extension, source reset, continuation withdrawal and partial withdrawal; settings Quit + experiment entry |
| `scripts/test-hooks.sh --filter DisplayTests` | **7 tests / 2 suites passed**, covering the changed adapter, existing event tracker and associated schedule tests; unchanged reducer/IPC/resolver suites were not mechanically repeated |
| `scripts/test-design-layout.sh` | **155 passed** |
| `scripts/test-touchbar-layout.sh` | **291 passed** |
| `scripts/test-touchbar.sh` | **34 passed**; lifecycle, preference, data and frontmost-PID checks; no real system-modal smoke invocation |
| `scripts/test-task-status.sh` | **41 passed** |
| `scripts/test-hook-integration.sh` | Passed: default off, opening isolated settings writes/installs nothing, unready/disabled states explicit, stale source callbacks rejected |
| `scripts/build-app.sh` | Optimized explicit macOS 11 distribution build passed for both main executable and helper |
| Packaged metadata | `LSUIElement=true`, version 0.1.27 / build 28 unchanged; both binaries arm64, **minos 11.0 / SDK 27.0** |
| Strict nested signing | Main bundle `--deep --strict` and helper `--all-architectures --strict` passed; both ad-hoc |
| `scripts/test-first-open.sh` | Passed on a temporary copy with launch suppressed: cancel, scoped removal, preserved unrelated attribute, repeat, symlink, hash mismatch, unexpected arguments, tampered signature |
| Packaged helper process checks | **25 neutral-exit checks passed**, bounded stdin read verified; 93-byte wire contained no prompt/reply text |
| `git diff --check` | Passed |

The final live synthetic-panel test reported requested=true, activeSpace=true, visible=true (occlusion 8194). Programmatic show/expand/refresh preserved the frontmost PID; the intermediate anchor stayed center 756 / top 950. Ordinary dual-quota native detail remained 340 × 227 pt. This is synthetic geometry on a non-notch host, not physical camera/fullscreen acceptance.

Logs are under `build/integration-evidence/`: `notch-menu-hooks.log`, `display-core.log`, `final-design.log`, `final-touchbar-layout.log`, `final-touchbar-lifecycle.log`, `final-task-status.log`, `final-hook-integration.log`, `final-release.log`, `final-package-verification.log`, `final-first-open.log`, `final-helper-process.json`. The last two small changes (startup unavailable state and missing English reset text), plus continuation withdrawal, were included in the final 962-check rerun and rebuilt bundle. Earlier unrelated passing suites were not repeated for those changes.

## Artifact and native images

Final app: `build/GPT TouchBar HUD.app`.
Full binary/bundle file SHA-256 inventory, sizes, architecture, build target and source commit: [integrated artifact manifest](validation/integrated-artifact-manifest.json).

| Binary | SHA-256 |
| --- | --- |
| Main | `a86147d1dfeab32cfd29026d7c5284a36e87a002f654ed19b2d017aaa6a68b37` |
| Helper | `32dd74e8236cf92ade4f325c4f3a2eaa31c445e049052bdef137069f6ca16d99` |

Native NSView raster captures, with fixture data: [compact](../build/notch-v2-compact.png), [ordinary expanded](../build/notch-ledger-zh-0.png), [Chinese partial scope](../build/integrated-hooks-zh-partial.png), [English submitted](../build/integrated-hooks-en-submitted.png), [secondary completion with remaining/unknown work](../build/integrated-feedback-partial.png), [Touch Bar full partial count](../build/integrated-touchbar-en-partial.png), [settings experiment entry](../build/integrated-settings-experiment.png), [extreme wrapping](../build/notch-v2-extreme.png).

## Acceptance boundaries retained

- Hooks remains a **default-off experiment**. The real desktop host has not trusted or executed this integration. Configuration discovery, source fixtures and isolated tests do not prove real-host accuracy, latency or event ordering.
- A first `task_started` timestamp earlier than Hook receipt conservatively remains unknown until new attributable evidence arrives. No timing tolerance was invented during integration.
- Production `initialCoverageUnknown` persists. Receiving events or healthy transport does not prove complete desktop coverage; exact zero is exercised only with explicitly complete synthetic scope.
- C's existing 12-second static-log sample does **not** support an energy-saving claim. No energy benchmark or real-host discovery was rerun here. The final helper process timing sample is a subprocess budget check, not a battery or production latency result.
- Physical camera seam, real transparent-corner click-through, other-app fullscreen and multiple displays/Spaces, menu auto-hide, sleep/lock/wake, Finder/Spotlight/Dock launch/relaunch and update-restart behavior remain unverified. B's public collection-behavior rationale still applies; no new permission or private fullscreen API was introduced.
- Real macOS 11 execution and Intel behavior/CI remain unverified. This machine's missing x86_64 compatibility-library slices were already established by C; no futile cross-link retry or false universal artifact was produced. Actual minos 11.0 is build/link evidence, not an execution result.
- No main-branch merge, push, PR, version bump, tag, release, `/Applications` replacement, running-host termination, real Hook/trust change or user preference change was performed. The frozen candidate is for coordinator review before any separate acceptance/release decision.
