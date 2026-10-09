#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
# Optional existing checkout for before/after comparison; all outputs stay in this worktree.
replay_source="${HUD_REPLAY_SOURCE_ROOT:-$PROJECT_DIR}"
replay_build="$PROJECT_DIR/.build/task-lifecycle-replay"
mkdir -p "$replay_build"
source scripts/swift-module-cache.sh
replay_cache="$(swift_module_cache_path "$(uname -m)-apple-macosx11.0")"
swiftc -target "$(uname -m)-apple-macosx11.0" -O -parse-as-library -emit-module -emit-library -static \
    -module-name HookCore -module-cache-path "$replay_cache" "$replay_source"/HookCore/*.swift \
    -emit-module-path "$replay_build/HookCore.swiftmodule" -o "$replay_build/libHookCore.a"
swiftc -I "$replay_build" -L "$replay_build" -lHookCore -module-cache-path "$replay_cache" \
    "$replay_source/Sources/DiagnosticEvent.swift" "$replay_source/Sources/DiagnosticTaskTrace.swift" "$replay_source/Sources/DiagnosticTaskPresentation.swift" "$replay_source/Sources/LimitModels.swift" "$replay_source/Sources/TaskStatusMonitor.swift" \
    Tests/TaskLifecycleReplay.swift -o "$replay_build/TaskLifecycleReplay"
"$replay_build/TaskLifecycleReplay" "$@"
