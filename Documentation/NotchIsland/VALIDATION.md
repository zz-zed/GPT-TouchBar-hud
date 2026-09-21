# Validation record — 2026-09-21

This is local implementation acceptance on an arm64 Mac running macOS 27.0 (26A428) with Apple Swift 6.4 / SDK 27. No installed App was replaced. No push, PR, tag, release, or DMG overwrite was performed. The 51-case attachment mentioned by the source conversation was unavailable; the following matrix is derived from its accessible body.

## Stage 1 evidence

`evidence/stage1-results.json` records 21 initial native checks and 89 actual SwiftUI presentation-geometry samples. The accompanying three stable-state carrier screenshots and opening keyframe were captured from `NSHostingView`. Carrier frame changes were exactly one, at initial configuration. Foreground PID and key-window checks passed. These initial corner/camera/decoration tests were path/routing assertions, not end-to-end click delivery.

Subsequent native receiver tests close that specific gap: real WindowServer mouse events are posted to isolated test windows, and a separate receiver process counts delivered clicks. This does not simulate physical camera hardware.

## Acceptance matrix

| Area | Executed verification | Result / limit |
|---|---|---|
| Compact / Peek / Expanded | Shared production hosting snapshots and model states | Pass |
| Always-show preference | Both resting states; setting change while Expanded; preference defaults | Pass; existing mode/visibility keys unchanged |
| Fixed carrier | Native animated sequence and `frameChanges` counter | Pass; window frame changes only with environment configuration |
| Mark positions | Production layout checks and synthetic Compact/Peek screenshots | Pass; marker centers remain camera-relative |
| Current animation geometry | Native modifier/bridge reports intermediate sizes | Pass; no separate spring prediction or per-frame NSPanel resize |
| Camera / transparent corner / decoration exclusion | Path boundaries plus real WindowServer click delivery to separate receiver | Pass on this host |
| Outside click | Expanded before click; separate receiver count increments and island collapses | Pass on this host |
| Static pointer during shrink | No movement between animated shrink and click; separate receiver receives click | Pass on this host |
| First click / detail blank click | Real wing click expands; blank click stays Expanded | Pass on this host |
| Focus | Foreground PID and non-key status before/after show, hover, clicks, refresh, pages and lifecycle | Pass on this host; sustained typing in other editors still a manual hardware check |
| Drag capture | Model capture/release while leaving surface | Pass; native multi-device gestures remain manual |
| Menu / submenu hold | Nested lease model tests and native context-menu delegate exercise | Pass, including real NSMenu open/close callbacks; real submenu pointer traversal remains manual |
| Delayed sequencing | Injected clock: 60 / 220 / 250 ms entry, 20 ms shell exit, 100 ms retained content | Pass |
| Rapid reversal | Host presentation-size continuity and hostile cancelled-callback delivery | Pass |
| Refresh during transition | Generation and Expanded intent stay unchanged | Pass |
| Hide / destruction / screen changes | Cancelled work deliberately delivered; native reopen and environment reset | Pass; physical unplug/lock/Space changes not performed |
| Task data | Off / unknown / explicit zero / running / completed / authoritative Hook counts | Pass; existing mapping retained |
| Quota data | Missing values, reset fallback, connection error and old data markings | Pass |
| Usage data | Missing and stale totals, large numbers, diagnostic text | Pass; no invented history or costs |
| Chinese / English / narrow screen | Native 400 pt screenshots for three pages, missing/off/long-stale fixtures | Pass after fixing complete English footer actions and duplicate reset-card text |
| Paging | Stable shell and fixed header/footer; only middle HStack moves | Pass; no history charts added |
| Reduce Motion | No delayed staging, spring displacement, press scale or sweep | Model and native reduced-mode screenshots pass |
| Reduce Transparency | Material layer disabled | Native reduced-mode screenshots pass |
| Low Power / invisibility | Sweep predicate at rest, on hover and hidden | Pass, including a background power notification delivered to main-queue UI state; no physical battery/power toggle or energy profiling performed |
| Accessibility | Labels/identifiers, hidden inactive/exit pages and native controls | Labels/identifiers inspected in source; direct AppKit traversal returned no SwiftUI AX children in this standalone harness, so native accessibility action and VoiceOver navigation acceptance remain manual |
| No-notch / external fallback | Nil geometry declines island; original AppDelegate floating fallback retained | Pass for injected geometry; real hotplug pending |
| Full-screen policy / Dock | Existing window level, collection behavior and accessory activation policy | Code/native property checks pass; actual full-screen Spaces pending |
| Legacy rollback | Launch switch creates no island object/window | Pass; legacy layout/settings regressions pass |
| macOS 11 | Explicit-target native harness and App build; Mach-O `minos 11.0` | Pass at compile/link level; no macOS 11 machine tested |
| arm64 | Native tests, distribution build, strict codesign and architecture inspection | Pass |
| Intel | CI entry exists for dedicated tests/build | Not executed locally; no Intel runtime claim |
| Upstream licensing | MIT notice copied to App Resources and byte-compared | Pass |
| Original release candidate | Read-only hash and clean-worktree verification | Unchanged: SHA-256 `aa352d4b6a1470f3be4157500707d9bc6b9cdd1e9db19da895f53672f5b19b7b` |

## Commands and outputs

The final raw summaries, native results and local build manifest are preserved in `evidence/`. Native assertions include a small matrix of screen origin, width and scale combinations; they are not a count of distinct end-user acceptance cases. The mirrored containment grid was removed during review.

- `bash scripts/test-notch-presentation.sh`: 356 dedicated state/geometry/data/native-render/event assertions; 239 presented geometry samples in the recorded run. Real WindowServer receiver and NSMenu tests passed.
- `bash scripts/test-notch-hud.sh`: legacy geometry/layout, menu/settings and Hook presentation integration; 202,762 checks, including legacy geometric sampling.
- `bash scripts/test-design-layout.sh`: 158 design integration checks.
- `bash scripts/test-app-update.sh`: 73 update policy checks; installer shell syntax and invalid-target rejection.
- `swift test`: 41 HookCore tests in 7 suites.
- `swift build`: passed. This toolchain's SwiftPM build still emits its existing missing developer-framework search-path warnings; it is not used as the distribution deployment-target proof.
- `bash scripts/build-app.sh`: arm64 distribution App, strict ad-hoc signature, bundled helper and third-party notice.
- `xcrun vtool -show-build`: App and helper minimum macOS 11.0.

## Startup auto-detection follow-up

The unconfigured display mode now defaults to Automatic. Startup detects valid notch geometry and initializes an absent visibility preference to shown when that mode can use the notch. Saved display modes and explicit hidden/visible preferences take precedence. Previously saved floating values are retained because older versions did not distinguish a manual mode choice from a mode written alongside visibility.

- `bash scripts/test-notch-hud.sh`: passed 202,778 checks, including 16 additional assertions covering first launch with/without a notch, saved manual modes, hidden-state restoration, screen availability changes and opting back into Automatic. These preference cases use an isolated defaults suite and injected geometry availability.
- `bash scripts/test-notch-presentation.sh`: the first run stopped at the existing foreground-focus preservation assertion. No cause was established. Re-running the same compiled `.build/notch-presentation/NotchHarness` without source changes passed all 356 checks with 220 presented geometry samples, including real WindowServer click delivery. The initial failure is not counted as a pass.
- `bash scripts/build-app.sh`: rebuilt the local arm64 App and passed the script's strict signature and architecture checks. The installed App was not launched or replaced for startup testing.

The earlier files in `evidence/` describe the original island implementation run; this follow-up rebuilt `build/GPT TouchBar HUD.app`, so its current binary is no longer the artifact hashed in that earlier build manifest. Physical notch startup and display hotplug remain untested on actual notch hardware.

## Expanded-panel refinement

The standard expanded shell is reduced from 800 × 280 to 520 × 250 pt at a 32 pt physical inset. Its top corners now round continuously as the actual presentation height grows, and bottom corners increase from 14 to 28 pt. The material halo follows the same curves. Drawing, content clipping and input routing still share one path.

`bash scripts/test-notch-presentation.sh` passed 359 assertions and 283 presented geometry samples for this refinement, including real click-through at all four expanded corners. The normal Chinese quota screen and all three narrow English long-content pages were visually inspected; the footer controls remain complete and long content scrolls. New previews use the `refined-` filename prefix; earlier images remain historical evidence. This does not establish physical-notch acceptance.

## Remaining physical acceptance

Same-machine upstream comparison; physical black levels and camera seams; crowded real menu bars; display scaling and auto-hide; physical monitor unplug/replug; lock/sleep/wake and full-screen Space transitions; actual VoiceOver/trackpad interactions; sustained editor typing; macOS 11 and Intel runtime. Synthetic screenshots and CI wiring do not establish release readiness for those items.
