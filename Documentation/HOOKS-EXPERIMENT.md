# Native Hooks task monitoring

Hooks monitoring is an optional, default-off experiment. Ordinary log monitoring remains available. Hook configuration is changed only through the reviewed Apply action in Settings; building or testing the repository does not install or enable it.

## Task state and coverage

Ordinary logs and Hooks use the same `TaskEngineController` and `TaskActivityEngine`. Hooks provide discovery hints; paginated index discovery and the continuous journal reader provide lifecycle evidence. Read budgets limit work per pass without skipping unseen records. The two modes share metadata checkpoints and serial I/O coordination.

An explicit start establishes an active turn. Tool and token records can support a matching active turn but cannot create activity, reopen a completed turn or restore an old active cache as current execution. Terminal events must match the turn; silence, host loss, interruption and sleep do not manufacture successful completion. Restored state remains pending until current evidence confirms it.

Coverage and connection health are independent. Logs and callbacks do not provide a complete authoritative inventory of the desktop host. Unknown coverage is not presented as a verified zero. Ordinary mode retains its neutral display when there is no confirmed active task; Hooks can expose incomplete coverage through its status presentation. All display surfaces consume the shared snapshot.

## Helper and storage

The signed `HookEmitter` is embedded in the app. It forwards only allowlisted lifecycle metadata, never prompt/reply text, tool arguments, working directories or transcript paths. The receiver uses private local IPC and bounded input, queues and metadata storage. Failures return a neutral result so the helper does not block the host task.

Private directory and file modes, peer ownership checks, safe file handling and an exclusive receiver lock protect the IPC path. This is not an authentication boundary against malicious processes already running as the same user. Checkpoints store recovery metadata rather than conversation content.

## Configuration and installation

Open **Settings → Experiments → Configure Hooks experiment**. Merely opening this controller does not enable monitoring or write files. Checking the box prepares a read-only plan; Apply is the explicit user action. The plan shows scope, helper command, four events, 1-second timeout and the full merged JSON. For installation it first checks discovery using an isolated temporary CODEX_HOME with this host runtime, no Hook execution and no trust bypass. Clearing definitions does not require a working host.

The default target is `$CODEX_HOME/hooks.json` (otherwise `~/.codex/hooks.json`). The JSON merger appends separate exact-owned definitions and preserves unrelated keys and hooks. An edited entry carrying this tool's owner marker blocks overwrite. Cleanup removes only byte-equivalent semantic definitions belonging to the reviewed command. A timestamped 0600 backup is byte-verified before changing an existing file; the current input is compared with the reviewed plan again, the write is atomic, and output is parsed and read back. Existing trust is never changed. New/changed definitions must be trusted in Codex normally; existing tasks may need to be reopened. Successful discovery is not proof of execution/trust or coverage.

Stable helper: `~/Library/Application Support/GPTTouchBarHUD/Hooks/HookEmitter`. Stable IPC/cache directory: `~/.gpt-touchbar-hud-hooks` (short enough for Unix socket paths). No helper is installed there until Apply. The bundled helper's signature identifier and all-architecture signature are verified; exact bytes are copied atomically, then verified/read back. Changed executable upgrades preserve `HookEmitter.previous` and a hash receipt. `HookHelperInstaller.rollback` restores only receipt-matching bytes; `uninstall` removes only the unchanged installed executable. Configuration cleanup is separate; directories, other hooks, backup files and user-edited entries are not recursively deleted. A failed multi-step Apply can leave a copied helper and reviewable backups while the monitoring preference stays unchanged; the error says so. The bundle retains the project's existing ad-hoc signing policy; the app is not notarized.

Disabling immediately stops this tool's receiver/watches and restores log mode. It does not silently edit configuration; a separate cleanup plan is available. Residual configured commands fail open while the receiver is absent. Replacing/deleting the app does not automatically remove the stable copy; explicitly disable, review config cleanup, then remove the receipt-matching helper. Keep the prior binary for rollback until the upgraded helper is verified. A changed helper command definition can trigger renewed host trust.

## Build and verification commands

- `bash scripts/test-hooks.sh`: Swift Testing behavior and resource/security tests.
- `bash scripts/test-hook-integration.sh`: isolated default-off settings and source-selection/generation checks.
- `bash scripts/test-task-status.sh` and existing regression scripts: compile against the shared static module via `scripts/hook-core-build.sh`.
- `bash scripts/replay-task-lifecycle.sh <UTC-time> <rollout-path>...`: read-only inspection through the production continuous reader; outputs allowlisted lifecycle metadata, and explicitly leaves current execution unconfirmed. `HUD_REPLAY_SOURCE_ROOT` selects an existing checkout for source comparison; build outputs remain in the calling worktree.
- `bash scripts/build-app.sh`: optimized signed app + helper for the current architecture, explicit Info.plist deployment target passed to compilation and linking.
- `HUD_BUILD_ARCHS='arm64 x86_64' bash scripts/build-app.sh`: universal artifact when the toolchain has both architectures and required compatibility libraries. Failure is surfaced, never converted to a falsely universal bundle.
- `python3 scripts/test-hook-helper.py`: isolated subprocess fail-open, privacy and wall-time checks against the packaged helper.
- `python3 scripts/probe-hooks-runtime.py`: development-only isolated host discovery; no model task or Hook execution.
- `bash scripts/benchmark-hooks.sh`: short synthetic startup/static-log comparison between two adapters to the same engine; not an energy/accuracy certification.

The shipped products require no Node.js or Python. Python scripts are development checks only. Existing Intel/arm64 CI runners remain separate and cover the source paths and helper signature/architecture checks.


## Compatibility limits

Host configuration and event formats may change. Discovery does not prove trust, execution or global task coverage. Remote tasks, unknown sources, missing logs, late attachment and silent activity can leave unresolved state. Independent runtime instances do not expose another desktop instance's in-memory task state.

Synthetic checks establish the tested state and transport contracts; they do not certify physical-device display, long-term energy use or end-to-end behavior across every host version. See [task diagnostics](TASK-STATUS-DIAGNOSTICS.md) and [data and privacy](DATA-AND-PRIVACY.md).
