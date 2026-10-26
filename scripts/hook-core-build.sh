#!/usr/bin/env bash
# Source from repository root: reusable static module for standalone swiftc regression scripts.
# SPM consumers use the HookCore target directly.
source scripts/swift-module-cache.sh

hook_core_build() {
    local output_dir="$1" sdk_path="$2" target="$3"
    local library="$output_dir/libHookCore.a" module="$output_dir/HookCore.swiftmodule"
    local configuration="$output_dir/HookCore.build-configuration"
    local compiler module_cache expected_configuration
    compiler="$(type -P swiftc)"
    module_cache="$(swift_module_cache_path "$target" "$sdk_path")"
    # These are the original production HookCore flags, also used by core tests.
    local flags=(-O -sdk "$sdk_path" -target "$target" -module-cache-path "$module_cache"
        -parse-as-library -emit-module -emit-library -static -module-name HookCore)
    expected_configuration="$(python3 scripts/core_library_build_key.py --compiler "$compiler" \
        --sdk "$sdk_path" --helper scripts/hook-core-build.sh --sources HookCore/*.swift \
        -- "${flags[@]}")"
    mkdir -p "$output_dir"
    if [[ -s "$library" && -s "$module" && -f "$configuration" ]] &&
       [[ "$(<"$configuration")" == "$expected_configuration" ]]; then
        ci_time dependency-reuse HookCore true
        echo "Reusing optimized HookCore ($target)" >&2
        return
    fi
    rm -f "$configuration"
    swiftc "${flags[@]}" HookCore/*.swift \
        -emit-module-path "$module" -o "$library" || return
    [[ -s "$library" && -s "$module" ]] || return 1
    printf '%s\n' "$expected_configuration" > "$configuration"
}

if [[ "${HOOK_CORE_BUILD_DEFERRED:-0}" != 1 ]]; then
    HOOK_CORE_DIR="${HOOK_CORE_DIR:-$PWD/.build/hook-core-standalone}"
    HOOK_CORE_SDK_PATH="${HOOK_CORE_SDK_PATH:-${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}}"
    HOOK_CORE_TARGET="${HOOK_CORE_TARGET:-$(uname -m)-apple-macosx11.0}"
    hook_core_build "$HOOK_CORE_DIR" "$HOOK_CORE_SDK_PATH" "$HOOK_CORE_TARGET"
    SWIFT_MODULE_CACHE="$(swift_module_cache_path "$HOOK_CORE_TARGET" "$HOOK_CORE_SDK_PATH")"
    HOOK_CORE_SWIFT_FLAGS=(-I "$HOOK_CORE_DIR" -L "$HOOK_CORE_DIR" -lHookCore)
fi
