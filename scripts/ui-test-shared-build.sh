#!/usr/bin/env bash
# Test-only static module for the two unoptimized, identically configured UI
# fixtures. Other scripts keep their original compilation and optimization.

ui_test_compile() {
    local test_source="$1" executable="$2"
    local flags=("${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}"
        -module-cache-path "$SWIFT_MODULE_CACHE")
    if [[ "${HUD_SHARED_UI_TESTS:-1}" == 0 ]]; then
        swiftc "${flags[@]}" "${sources[@]}" "$test_source" -o "$executable"
        return
    fi

    local compiler key directory library module
    compiler="$(type -P swiftc)"
    key="$(python3 scripts/ui_test_build_key.py --compiler "$compiler" \
        --dependency "$HOOK_CORE_DIR/libHookCore.a" --dependency "$HOOK_CORE_DIR/HookCore.swiftmodule" \
        --dependency "$RESET_NEWS_CORE_DIR/libResetNewsCore.a" --dependency "$RESET_NEWS_CORE_DIR/ResetNewsCore.swiftmodule" \
        --sources "${sources[@]}" -- "${flags[@]}")"
    directory="$PWD/.build/ui-test-shared/$key"
    library="$directory/libHUDTestSupport.a"
    module="$directory/HUDTestSupport.swiftmodule"
    if [[ ! -f "$directory/complete" || ! -s "$library" || ! -s "$module" ]]; then
        mkdir -p "$directory"
        rm -f "$directory/complete"
        # Completion is published only after both the archive and module exist.
        # UI fixtures are deliberately serial; this is not a concurrent cache.
        swiftc "${flags[@]}" -parse-as-library -enable-testing \
            -emit-library -static -emit-module -module-name HUDTestSupport \
            "${sources[@]}" -emit-module-path "$module" -o "$library"
        test -s "$library" && test -s "$module"
        touch "$directory/complete"
    else
        ci_time dependency-reuse HUDTestSupport true
    fi
    # Force-load every object to preserve Objective-C runtime discovery, as with
    # the old direct-source link. Each fixture remains its own executable/process.
    swiftc "${flags[@]}" -parse-as-library -D HUD_SHARED_UI_TESTS \
        -I "$directory" -Xlinker -force_load -Xlinker "$library" \
        "$test_source" -o "$executable"
}
