#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
project_dir="$PWD"
baseline_ref="${1:-947641c}"
idle_seconds="${HUD_CPU_IDLE_SECONDS:-30}"
run_dir="$project_dir/build/task-monitor-cpu/$(date +%Y%m%d-%H%M%S).noindex"
mkdir -p "$run_dir/baseline-source"
chmod 700 "$project_dir/build/task-monitor-cpu" "$run_dir"
# Raw local input stays private and ignored. Report only aggregate measurements.
python3 scripts/task-monitor-cpu-fixture.py "${HUD_CPU_SOURCE_HOME:-$HOME/.codex}" "$run_dir/frozen/codex" > "$run_dir/input.json"
git archive "$baseline_ref" HookCore ResetNewsCore Sources scripts | tar -x -C "$run_dir/baseline-source"
build_benchmark() (
    cd "$1"
    source scripts/hook-core-build.sh
    source scripts/reset-news-core-build.sh
    sources=()
    for source in Sources/*.swift; do
        [[ "$source" == Sources/main.swift ]] || sources+=("$source")
    done
    swiftc -O "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" \
        -module-cache-path "$SWIFT_MODULE_CACHE" "${sources[@]}" \
        "$project_dir/Tests/TaskMonitorCPUBenchmark.swift" -o "$2"
)
build_benchmark "$run_dir/baseline-source" "$run_dir/baseline"
build_benchmark "$project_dir" "$run_dir/candidate"
shasum -a 256 "$run_dir/baseline" "$run_dir/candidate" > "$run_dir/binary-sha256.txt"
variants=(baseline candidate candidate baseline)
for number in 0 1 2 3; do
    variant="${variants[$number]}"
    fixture="$run_dir/$variant-$number/codex"
    python3 scripts/task-monitor-cpu-fixture.py "$run_dir/frozen/codex" "$fixture" > "$run_dir/$variant-input-$number.json"
    "$run_dir/$variant" "$fixture" "$run_dir/$variant-result-$number.json" "$idle_seconds"
done
printf '%s\n' "$run_dir"
