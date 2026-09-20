# A + B local integration candidate

Date: 2026-09-20. Worktree: `/Users/didi/.codex/worktrees/iteration-integration/TouchBarCodexToken`.

This isolated worktree starts from `dd274b28f1f7487d447fad6bb62fd7ce3f9aad46`. The delivered B worktree `/Users/didi/.codex/worktrees/6c27/TouchBarCodexToken` remains unchanged. No main-branch merge, push, release, version change, real configuration change or installation is included.

## Applied reviewed commits

| Order | Reviewed source | Local cherry-pick |
| --- | --- | --- |
| A: native menu sizing | `1a68cc5142e88d003be1a7f91a1920951c65f107` | `d0700726b80d1b2d25d2bfcb29e74fa31c4286c0` |
| B: notch V2 / accessory lifecycle | `57e4c23bbd24b27ad616aff10558dd6234f992e4` | `ec58913b2c0a8ad75de1a218c2e72911b304cf3d` |

The only textual conflict was adjacent test additions in `Tests/NotchHUDTests.swift`. Both blocks are retained: A's real NSStatusItem checks run before B's task-count/percentage matrix and overflow/transition checks. The obsolete reserved-width menu assertion was removed by A and was not restored.

A source-region comparison confirms that `AppDelegate.updateStatusTitle` and `MenuBarPresentation` exactly match reviewed A. `NotchHUDController.swift`, `PreferencesWindowController.swift` and `Resources/Info.plist` exactly match reviewed B. The combination retains variable/square status-item length, `presentation.apply(to:)`, actual visibility input, safe-area geometry, rounded-path routing, scrolling, LSUIElement and settings Quit.

`NOTCH-V2-DELIVERY.md` is B's original stage report, whose worktree/build/test references describe that delivered B checkpoint. This integration report supersedes its pending-A integration notes; it does not retroactively turn B's evidence into integrated-candidate evidence.

## Targeted verification

Both scripts passed in sequence against the integrated source:

- `scripts/test-notch-hud.sh`: **798 checks passed**, including A's actual NSStatusItem width transitions and B's notch layout/path/overflow/transition scenarios. Native regular size remained 340 × 227 pt; intermediate anchor remained center 756 / top 950. Log: `build/integration-evidence/notch-menu.log`.
- `scripts/test-design-layout.sh`: **155 checks passed**. Log: `build/integration-evidence/design.log`.
- `git diff --check`: passed. Source-preservation comparisons above passed.

This run's synthetic panel reported requested=true, activeSpace=true, occlusion=8192, actualVisible=false. That is recorded as an occluded synthetic-window observation, not evidence of fullscreen behavior or visible physical-notch focus acceptance. The programmatic transition/action assertions still passed. The separate B checkpoint's live-visible focus evidence remains in its original report.

Unchanged Touch Bar, task monitor and migration suites were not mechanically repeated. No integrated release package was built in this stage; release/target packaging awaits C's reviewed changes.

## C integration map — not yet applied

C's final reviewed SHA is still required. No C files or unresolvable HookCore symbols have been copied into this compiling candidate.

1. `Sources/HUDPresentation.swift`, `NotchTaskPresentation.init`: keep disabled first. Then consume `summary.activityPresentation` if non-nil. Use `HookTaskDisplayAdapter.state/badge/label/detail/hasRunningTasks/snapshot` directly; do not use legacy default counters or add pending and running. Preserve submitted as ellipsis/confirming, and partial coverage as unknown rather than zero. The existing legacy branch remains the fallback only when no activity presentation exists.
2. `Sources/NotchHUDController.swift`: retain `HookCompletionFeedbackTracker` with the controller, not a recreated view. Consume stable completion IDs/times once; establish first-delivery baseline; do not replay completion on window reopening, quota refresh or repeat snapshots. Any feedback must leave remaining confirmed activity and quota visible, never open details, and respect the adapter's coverage/health decisions. C's reviewed tracker contract will determine eligibility; B currently has only static legacy completion display.
3. `Sources/AppDelegate.swift`: reconcile C's mode owner/onUpdate, host start/stop, task-display enable/disable, sleep/session suspend/resume and termination with B's window coordination. There must be one authoritative monitoring source, stale callbacks ignored, and no addition of legacy and Hooks counts. Preserve `notchHUD.update(state, taskDisplayEnabled: taskStatusEnabled)`, visibility callback, stable display resolver and existing explicit settings activation.
4. `Sources/PreferencesWindowController.swift` / `AppDelegate.openPreferences`: add C's default-off experiment entry and configuration-review flow while retaining B's Quit callback, geometry availability copy, visibility controls and accessible settings recovery. Adding an experiment control must not crowd out or overlap the Quit/control layout.
5. Preserve C's reviewed `LimitModels`, `TaskStatusAppearance`, Touch Bar activity adaptation and packaging/helper changes when its commit arrives. Retain A's menu application helper and both sets of integration tests. Add submitted/partial/health/completion-event cases after those symbols actually exist.

The SwiftPM arm64 minos12 versus declared macOS11 packaging discrepancy is assigned to C; this worktree does not alter build strategy. Real camera seams, click-through, fullscreen/multiple display/Space behavior, sleep/lock/wake and Dock/Finder launch acceptance remain unverified. A+B integration tests do not replace those hardware checks.
