#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
CACHE_SOURCE="$1"
MIGRATION_COPY="$(mktemp -d /tmp/reset-forecast-migration.XXXXXX)"
cp "$CACHE_SOURCE" "$MIGRATION_COPY/state-v1.json"
TEST_BUILD="$PROJECT_DIR/.build/reset-news-migration-tests"
mkdir -p "$TEST_BUILD"
export RESET_NEWS_CORE_DIR="${RESET_NEWS_CORE_DIR:-$PROJECT_DIR/.build/reset-news-core-migration-review}"
source scripts/reset-news-core-build.sh
swiftc "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" Sources/ResetNewsRepository.swift \
  Tests/ResetNewsCacheMigrationCheck.swift -o "$TEST_BUILD/ResetNewsCacheMigrationCheck"
"$TEST_BUILD/ResetNewsCacheMigrationCheck" "$MIGRATION_COPY" "${2:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
