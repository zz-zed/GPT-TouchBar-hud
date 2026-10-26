#!/usr/bin/env bash
# Source from repository root: reusable static module for standalone swiftc regression scripts.
# SPM consumers use the ResetNewsCore target directly.
source scripts/swift-module-cache.sh

reset_news_core_build() {
    local output_dir="$1"
    local sdk_path="$2"
    local target="$3"
    local library="$output_dir/libResetNewsCore.a"
    local module="$output_dir/ResetNewsCore.swiftmodule"
    local configuration="$output_dir/ResetNewsCore.build-configuration"
    local compiler module_cache expected_configuration
    compiler="$(type -P swiftc)"
    module_cache="$(swift_module_cache_path "$target" "$sdk_path")"
    local flags=(-swift-version 5 -sdk "$sdk_path" -target "$target" -O -parse-as-library
        -emit-module -emit-library -static -module-name ResetNewsCore -module-cache-path "$module_cache")
    expected_configuration="$(python3 scripts/core_library_build_key.py --compiler "$compiler" \
        --sdk "$sdk_path" --helper scripts/reset-news-core-build.sh --sources ResetNewsCore/*.swift \
        -- "${flags[@]}")"
    mkdir -p "$output_dir"
    if [[ -s "$library" && -s "$module" && -f "$configuration" ]] &&
       [[ "$(<"$configuration")" == "$expected_configuration" ]]; then
        ci_time dependency-reuse ResetNewsCore true
        echo "Reusing optimized ResetNewsCore ($target)" >&2
        return
    fi
    rm -f "$configuration"
    swiftc "${flags[@]}" ResetNewsCore/*.swift \
        -emit-module-path "$module" -o "$library" || return
    [[ -s "$library" && -s "$module" ]] || return 1
    printf '%s\n' "$expected_configuration" > "$configuration"
}

if [[ "${RESET_NEWS_CORE_BUILD_DEFERRED:-0}" != 1 ]]; then
    RESET_NEWS_CORE_DIR="${RESET_NEWS_CORE_DIR:-$PWD/.build/reset-news-core-standalone}"
    RESET_NEWS_CORE_SDK_PATH="${RESET_NEWS_CORE_SDK_PATH:-${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}}"
    RESET_NEWS_CORE_TARGET="${RESET_NEWS_CORE_TARGET:-$(uname -m)-apple-macosx11.0}"
    reset_news_core_build "$RESET_NEWS_CORE_DIR" "$RESET_NEWS_CORE_SDK_PATH" "$RESET_NEWS_CORE_TARGET"
    RESET_NEWS_CORE_SWIFT_FLAGS=(
        -swift-version 5
        -sdk "$RESET_NEWS_CORE_SDK_PATH"
        -target "$RESET_NEWS_CORE_TARGET"
        -I "$RESET_NEWS_CORE_DIR"
        -L "$RESET_NEWS_CORE_DIR"
        -lResetNewsCore
    )
fi
