#!/usr/bin/env bash
# Reproduce pre-fix production failures from immutable Git source. Exit 1 is red evidence.
# This remains separate from the post-fix production regression suite.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
BASELINE_REV="2059fd678fc2eea86ee5ed1a517d1b5d383a59d3"
EVIDENCE_DIR="$PROJECT_DIR/build/task-reliability/baseline"
SOURCE_DIR="$EVIDENCE_DIR/source"
mkdir -p "$SOURCE_DIR"
git archive "$BASELINE_REV" HookCore Sources/LimitModels.swift Sources/HUDPresentation.swift \
  Sources/TaskStatusAppearance.swift Sources/TaskStatusMonitor.swift scripts/hook-core-build.sh \
  scripts/swift-module-cache.sh | tar -x -C "$SOURCE_DIR"
git rev-parse "$BASELINE_REV" > "$EVIDENCE_DIR/baseline-revision.txt"
shasum -a 256 "$SOURCE_DIR/Sources/TaskStatusMonitor.swift" \
  "$PROJECT_DIR/Tests/TaskReliabilityBaselineTests.swift" > "$EVIDENCE_DIR/source-sha256.txt"
swiftc --version > "$EVIDENCE_DIR/compiler.txt"
cd "$SOURCE_DIR"
source scripts/hook-core-build.sh
swiftc -target "$(uname -m)-apple-macosx11.0" "${HOOK_CORE_SWIFT_FLAGS[@]}" \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  Sources/LimitModels.swift Sources/HUDPresentation.swift Sources/TaskStatusAppearance.swift \
  Sources/TaskStatusMonitor.swift "$PROJECT_DIR/Tests/TaskReliabilityBaselineTests.swift" \
  -o "$EVIDENCE_DIR/TaskReliabilityBaselineTests"
set +e
"$EVIDENCE_DIR/TaskReliabilityBaselineTests" > "$EVIDENCE_DIR/output.txt" 2>&1
TEST_EXIT=$?
set -e
printf '%s\n' "$TEST_EXIT" > "$EVIDENCE_DIR/exit-code.txt"
cat "$EVIDENCE_DIR/output.txt"
exit "$TEST_EXIT"
