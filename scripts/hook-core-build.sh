#!/usr/bin/env bash
# Source from repository root: reusable static module for standalone swiftc regression scripts.
# SPM consumers use the HookCore target directly.
HOOK_CORE_DIR="$PWD/.build/hook-core-standalone"
mkdir -p "$HOOK_CORE_DIR"
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path "$(uname -m)-apple-macosx11.0")"
hook_core_rebuild=0
[[ -f "$HOOK_CORE_DIR/libHookCore.a" && -f "$HOOK_CORE_DIR/HookCore.swiftmodule" ]] || hook_core_rebuild=1
for hook_core_source in HookCore/*.swift scripts/hook-core-build.sh; do
    [[ "$hook_core_source" -nt "$HOOK_CORE_DIR/libHookCore.a" ]] && hook_core_rebuild=1
done
if [[ "$hook_core_rebuild" == 1 ]]; then
    swiftc -target "$(uname -m)-apple-macosx11.0" -O -parse-as-library -emit-module -emit-library -static -module-name HookCore \
        -module-cache-path "$SWIFT_MODULE_CACHE" HookCore/*.swift \
        -emit-module-path "$HOOK_CORE_DIR/HookCore.swiftmodule" -o "$HOOK_CORE_DIR/libHookCore.a"
fi
HOOK_CORE_SWIFT_FLAGS=(-I "$HOOK_CORE_DIR" -L "$HOOK_CORE_DIR" -lHookCore)
