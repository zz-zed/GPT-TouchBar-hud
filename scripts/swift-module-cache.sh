#!/usr/bin/env bash
# Source this file, then call swift_module_cache_path [target] [SDK path].
# A single directory is reused by compilations with the same compiler, SDK and target.

swift_module_cache_path() {
    local target="${1:-native}"
    local sdk_path="${2:-${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}}"
    local compiler="${3:-$(xcrun --find swiftc)}"
    local compiler_version cache_key root cache_dir
    compiler_version="$("$compiler" --version 2>&1)"
    cache_key="$(printf '%s\0' "$compiler" "$compiler_version" "$sdk_path" "$target" | shasum -a 256 | cut -c 1-16)"
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    cache_dir="$root/.build/module-cache/$cache_key"
    mkdir -p "$cache_dir"
    printf '%s\n' "$cache_dir"
}
