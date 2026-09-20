# Default-off native Hooks task monitoring experiment

This is a local implementation for review, based on v0.1.27 / dd274b28. It does not change the product version. The existing log mode remains the default. No user Hook configuration, trust record, installed app, or stable helper is changed by building or testing this repository.

## State and display contract

`TaskStatusSummary.activity` is authoritative when non-nil. Its `activityPresentation` is a `HookTaskDisplayAdapter`; label, badge, details, color and Touch Bar running animation all consume that interpretation. `RateLimitDisplayState.displayedTaskStatus` filters legacy idle only. Hook zero, unknown and submitted stay visible. The coordinator emits an explicit unready state before starting or switching sources and nil only when task display is disabled. A generation check rejects callbacks from the previous mode.

The snapshot counts unique source/session pairs. Submitted is a subset of pending verification; pending can overlap running while Stop is checked. Do not add those counts. An unsequenced callback cannot override newer log evidence. A known newer turn's explicit `task_started` timestamp later than an older unlogged hint's local receipt is the causal bound used to supersede that hint. If this relation is unavailable or reversed, it stays unresolved. Receipt order or opaque turn-ID sorting alone never establishes host order. A terminal-only event does not establish a new turn order over an already known different turn.

Completion requires a matching `task_complete` plus a subsequent stable EOF check. A later same-turn start/execution record can reactivate it. Interrupted/aborted, SessionEnd, silence, sleep, host loss, or restored active cache never manufacture completion. Recovery accepts historical terminal facts; historical start alone is unknown. An explicit host recovery rebuilds observation; callbacks and delayed appends from a lost host cannot revive running state.

`recentCompletions` carries stable source/session/turn/terminal-time identity and the actual log terminal time. It contains at most 32 recent feedback events; `recentlyCompletedCount` may be larger. The feedback tracker uses an occurrence-time watermark plus bounded IDs, takes its first delivery as baseline, and does not replay on refresh/reopen/recovery. It can provide secondary completion feedback while another task is confirmed running, even under partial coverage. Primary ✓ is allowed only without running work or uncertainty. The >128-ID test covers public tracker robustness, not a production snapshot size observed in this implementation.

Connection health and coverage are independent. The production adapter always retains `initialCoverageUnknown`; no supported global inventory of the desktop host is used. An isolated app-server is used only to verify Hook configuration discovery, never to claim desktop task state. Details show readable gap reasons and source health. Unknown counts are not fabricated from coverage flags.

## Runtime and budgets

`HookEmitter` is a signed Swift executable embedded in `Contents/Helpers`. It retains only the four event kinds, session/turn, protocol/source and the continuation Boolean. It neither forwards nor saves prompt/reply/tool arguments, cwd or transcript paths. Wire data and cache contain lifecycle metadata only; transient bounded log parsing is not persisted.

| Resource | Bound |
| --- | --- |
| Helper stdin / wire | 1 MiB / 4 KiB |
| Connection + ACK / total helper / configured host timeout | 200 ms / 500 ms / 1 s |
| Concurrent receiver connections | 16 |
| Turn records / diagnostic records | 512 / 128 |
| Scheduling metadata / tracked submission correlations | 512 / 512 |
| Observed files / per-file initial or incremental read | 32 / 256 KiB (header included) |
| One recovery pass | 32 files / 8 MiB |
| Metadata cache / configuration file | 512 KiB / 1 MiB |

The helper returns `{}` and exit 0 on every failure path. A 500 ms process watchdog covers slow stdin and parsing; OS launch/scheduling overhead is outside that internal budget. The ACK is sent before log I/O. A private directory (0700), 0600 socket/cache/lock, peer UID check, non-following directory traversal/file opens, file ownership/type/link checks, exclusive receiver lock and stale-socket liveness/inode checks protect the IPC path. Installed app/runtime executable inputs may be root-owned; the signed helper is verified before copying. IPC, logs, index, configuration and stable helper data require the current user. This is not authentication against malicious processes running as the same user.

A serial utility worker owns sockets, SQLite, logs, cursors and cache. UI receives values on main. Related file changes coalesce for about 100 ms and can preempt a later retry. Retry offsets are approximately 0, 0.1, 0.5, 2, 5 and 5.15 seconds; the last tick expires an unresolved Stop/submission window. A 30-second timer ages trust in old evidence; it does not scan candidate logs. Reconciliation is triggered by startup, Hook receipt, watched-file change and explicit wake/host recovery. Recovery performs one bounded candidate query plus exact cached-session lookups. SQLite uses bound parameters, read-only open, 50 ms busy timeout and a 100 ms VM budget. Resource truncation remains a coverage gap.

## Configuration and installation

Open **Settings → Experiments → Configure Hooks experiment**. Merely opening this controller does not enable monitoring or write files. Checking the box prepares a read-only plan; Apply is the explicit user action. The plan shows scope, helper command, four events, 1-second timeout and the full merged JSON. For installation it first checks discovery using an isolated temporary CODEX_HOME with this host runtime, no Hook execution and no trust bypass. Clearing definitions does not require a working host.

The default target is `$CODEX_HOME/hooks.json` (otherwise `~/.codex/hooks.json`). The JSON merger appends separate exact-owned definitions and preserves unrelated keys and hooks. An edited entry carrying this tool's owner marker blocks overwrite. Cleanup removes only byte-equivalent semantic definitions belonging to the reviewed command. A timestamped 0600 backup is byte-verified before changing an existing file; the current input is compared with the reviewed plan again, the write is atomic, and output is parsed and read back. Existing trust is never changed. New/changed definitions must be trusted in Codex normally; existing tasks may need to be reopened. Successful discovery is not proof of execution/trust or coverage.

Stable helper: `~/Library/Application Support/GPTTouchBarHUD/Hooks/HookEmitter`. Stable IPC/cache directory: `~/.gpt-touchbar-hud-hooks` (short enough for Unix socket paths). No helper is installed there until Apply. The bundled helper's signature identifier and all-architecture signature are verified; exact bytes are copied atomically, then verified/read back. Changed executable upgrades preserve `HookEmitter.previous` and a hash receipt. `HookHelperInstaller.rollback` restores only receipt-matching bytes; `uninstall` removes only the unchanged installed executable. Configuration cleanup is separate; directories, other hooks, backup files and user-edited entries are not recursively deleted. A failed multi-step Apply can leave a copied helper and reviewable backups while the monitoring preference stays unchanged; the error says so. The bundle retains the project's existing ad-hoc signing policy; this work does not add notarization.

Disabling immediately stops this tool's receiver/watches and restores log mode. It does not silently edit configuration; a separate cleanup plan is available. Residual configured commands fail open while the receiver is absent. Replacing/deleting the app does not automatically remove the stable copy; explicitly disable, review config cleanup, then remove the receipt-matching helper. Keep the prior binary for rollback until the upgraded helper is verified. A changed helper command definition can trigger renewed host trust.

## Build and verification commands

- `bash scripts/test-hooks.sh`: Swift Testing behavior and resource/security tests. On this CLT, explicitly loads the already bundled TestingMacros plugin that swiftbuild omits.
- `bash scripts/test-hook-integration.sh`: isolated default-off settings and source-selection/generation checks.
- `bash scripts/test-task-status.sh` and existing regression scripts: compile against the shared static module via `scripts/hook-core-build.sh`.
- `bash scripts/build-app.sh`: optimized signed app + helper for the current architecture, explicit Info.plist deployment target passed to compilation and linking.
- `HUD_BUILD_ARCHS='arm64 x86_64' bash scripts/build-app.sh`: universal artifact when the toolchain has both architectures and required compatibility libraries. Failure is surfaced, never converted to a falsely universal bundle.
- `python3 scripts/test-hook-helper.py`: isolated subprocess fail-open, privacy and wall-time checks against the packaged helper.
- `python3 scripts/probe-hooks-runtime.py`: development-only isolated host discovery; no model task or Hook execution.
- `bash scripts/benchmark-hooks.sh`: short synthetic startup/static-log comparison with the unchanged legacy monitor; not an energy/accuracy certification.

The shipped products require no Node.js or Python. Python scripts are development checks only. Existing Intel/arm64 CI runners remain separate and include the new source paths and helper signature/architecture checks.

## Deliberate experimental limits

- A first log read containing `task_started` just before Hook receipt remains unknown until new matching execution evidence arrives. This avoids inventing a tolerance before real host timing/blocked-submission behavior is verified. A real-format fixture covers a start 10 ms before receipt. Do not claim common startup latency ≤2 seconds from the later-start synthetic fixture.
- This implementation supports the observed local legacy JSONL format and local `cli`, `exec`, `vscode` sources. New formats, paginated-only history, remote hosts, unidentified sources, events without attributable turn IDs, missing files and incomplete startup scope remain gaps. Subagent sessions from index/header metadata are excluded.
- Silent activity may age to unknown after 30 minutes. It never becomes success or precise zero. If a missing path appears only after all finite retries and no watch could be established, another Hook or explicit recovery is needed.
- Snapshot coverage gaps are conservative for the controller lifetime. There is no promise of desktop-wide exact zero. A restored cache does not prove current execution.
- Current-machine arm64 Mach-O minimum target 11.0 is a build fact only. Actual macOS 11 execution, Intel runtime behavior, notarization and real-host end-to-end trust/execution remain release acceptance work.
- No baseline-versus-Hooks claim about energy savings, false-positive/negative rate, real unknown proportion or production latency is established by these isolated tests.

## Shared-file integration scope

C changes AppDelegate's monitor type, initial unready state, monitor update callback, sleep/wake hooks, host start/stop, display-enable handling and one independent experiment settings controller entry. It does not change window/screen geometry, menu title sizing, visibility preference semantics or Dock behavior. Preferences adds only an Experiments tab/entry. Other shared edits are TaskStatusSummary's optional snapshot and derived display semantics, TaskStatusAppearance's adapter priority, and TouchBarRateLimitsView's hasRunningTasks access.

Integrate A → B → C in the coordinator's isolated integration checkout. Conflicts likely: AppDelegate, PreferencesWindowController, LimitModels and test/build scripts. B's NotchTaskPresentation should consume `summary.activityPresentation` and keep its own geometry untouched. No automatic merge, push, PR, version bump, tag or release is part of this delivery.

## Sources

Implementation constraints follow the confirmed local Design/iteration-next/HOOKS-IMPLEMENTATION.md and IMPLEMENTATION-BRIEF-V2.md. Current hook discovery/event fields were checked in installed runtime 0.155.0-alpha.9.2's generated schema and isolated discovery. [Official Hooks documentation](https://learn.chatgpt.com/docs/hooks) was checked for config shape, trust, output and Stop continuation semantics; the transcript format remains an unstable evidence interface.
