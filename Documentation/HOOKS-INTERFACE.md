# Hooks experiment: snapshot and file ownership

Baseline: dd274b28f1f7487d447fad6bb62fd7ce3f9aad46 (v0.1.27), clean isolated worktree on 2026-09-20.

## Reviewed consumer contract

`TaskActivitySnapshot: Equatable, Codable, Sendable` is a value. It contains `confirmedRunningCount`, `pendingVerificationCount`, `submittedCount`, `recentlyCompletedCount`, `coverage` (scope + explicit gap reasons), `sourceHealth` (source, connection state, last receipt), and `updatedAt`, plus stable `recentCompletions` identities/occurrence times (at most 32 feedback events; total recent count can be larger). Counts are unique source/session pairs, never hook invocations. `pendingVerificationCount` may overlap running while Stop is checked; submitted is a subset of pending. A pure presentation property provides `2`, `2 ?`, `—`, `…`, `0`, or `✓`; completion is shown only without uncertainty.

Coverage and transport health are independent. Production Codex initialization always retains `initialCoverageUnknown`: no supported desktop-wide inventory exists here. Receiving a hook never clears this gap. Thus precise zero is available to synthetic complete-scope tests, not claimed for the current desktop host.

`HookConnectionController.onUpdate: (TaskActivitySnapshot) -> Void` delivers on main. start/stop, suspend/resume, and hostUnavailable manage a serial background worker. No socket, log or SQLite work on main. A mode owner selects either this controller or existing TaskStatusMonitor and ignores stale callbacks; their counts are never added.

## Ownership

- `HookCore/TaskActivitySnapshot.swift`: public values, pure display decision.
- `HookCore/TaskStateReducer.swift`: pure state transitions, session/turn ordering from log evidence, bounded metadata.
- `HookCore/HookProtocol.swift`, `HookIPC.swift`, `HookPaths.swift`: allowlist, native bounded transport, private paths/cache.
- `HookCore/TaskEvidenceResolver.swift`: exact session index lookup, safe bounded/incremental log reads and recovery.
- `HookCore/HookConnectionController.swift`: retries, coalesced file observation, lifecycle and callback generations.
- `HookCore/HookConfiguration.swift`: reviewable JSON plan, backup/merge/readback and exact-owned cleanup.
- `HookHelper/main.swift`: native fail-open emitter, no Node dependency.
- New app-side settings controller/adapter: default-off UI, review before applying configuration.
- `Package.swift`, `scripts/build-app.sh`: helper/module packaging and nested signing; no version change.
- `Tests/HookCoreTests/`: behavior, security, resource and isolation tests.

The coordinating task approved TaskStatusSummary.activity and the minimum integration on 2026-09-20. LimitModels, TaskStatusAppearance and the Touch Bar running flag use activityPresentation; AppDelegate selects exactly one monitor and opens a separate settings controller. HUDPresentation, notch geometry and menu width remain unchanged here. Settings accepts explicit config URLs for isolation; no live hooks are enabled by this implementation task. Integration with the other tasks is still coordinated separately.

## Boundaries

Stable helper: `~/Library/Application Support/GPTTouchBarHUD/Hooks/HookEmitter`, atomically copied from the signed bundle after user action, with previous executable retained for rollback. IPC/cache use a shorter private `~/.gpt-touchbar-hud-hooks` directory (0700) to stay within Unix socket path limits; sockets/cache 0600. No symlink helper, no executable path inside a transient build/worktree in generated user configuration. Signing and architecture must be validated for the artifact actually installed. Hook trust remains entirely in the host UI; config changes may require review and a new host task.

The authoritative final consumer adapter is `HookCore/HookTaskDisplayAdapter.swift`: `state`, `badge`, `label`, `detail`, `hasRunningTasks` and `snapshot`. See HOOKS-EXPERIMENT.md for implementation and current limitations.
