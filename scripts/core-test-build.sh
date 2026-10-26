#!/usr/bin/env bash
# Source once from test-core.sh. Production sources are compiled once for this
# invocation; each existing fixture is still linked and run as its own process.
# This is a disposable test library, never a production or cross-run cache.
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh

CORE_TEST_DIR="$PWD/.build/core-check"
CORE_TEST_MODULE_DIR="$CORE_TEST_DIR/module"
CORE_TEST_LIBRARY="$CORE_TEST_MODULE_DIR/libHUDCoreTestSupport.a"
mkdir -p "$CORE_TEST_MODULE_DIR" "$CORE_TEST_DIR/bin"
CORE_TEST_FLAGS=("${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}"
    -module-cache-path "$SWIFT_MODULE_CACHE")
core_test_sources=()
for core_test_source in Sources/*.swift; do
    [[ "$core_test_source" == Sources/main.swift ]] || core_test_sources+=("$core_test_source")
done
# Always rebuild on entry. Local invocations cannot accidentally consume a stale
# library after changing SDK, compiler flags, or a file with a preserved mtime.
rm -f "$CORE_TEST_LIBRARY" "$CORE_TEST_MODULE_DIR/HUDCoreTestSupport.swiftmodule"
swiftc "${CORE_TEST_FLAGS[@]}" -parse-as-library -enable-testing \
    -emit-library -static -emit-module -module-name HUDCoreTestSupport \
    "${core_test_sources[@]}" \
    -emit-module-path "$CORE_TEST_MODULE_DIR/HUDCoreTestSupport.swiftmodule" \
    -o "$CORE_TEST_LIBRARY"

core_test_compile() {
    local executable="$1"
    shift
    # Force-load preserves Objective-C discovery from the old direct-source
    # builds. No fixture is merged with another fixture's main/global state.
    swiftc "${CORE_TEST_FLAGS[@]}" -parse-as-library -D HUD_SHARED_CORE_TESTS \
        -I "$CORE_TEST_MODULE_DIR" -Xlinker -force_load -Xlinker "$CORE_TEST_LIBRARY" \
        "$@" -o "$executable"
}
