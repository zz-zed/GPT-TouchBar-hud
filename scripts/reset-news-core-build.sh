#!/usr/bin/env bash
# Source from repository root: reusable static module for standalone swiftc regression scripts.
# SPM consumers use the ResetNewsCore target directly.

reset_news_core_build() {
    local output_dir="$1"
    local sdk_path="$2"
    local target="$3"
    local library="$output_dir/libResetNewsCore.a"
    local module="$output_dir/ResetNewsCore.swiftmodule"
    local configuration="$output_dir/ResetNewsCore.build-configuration"
    local expected_configuration="$sdk_path|$target"
    local rebuild=0

    mkdir -p "$output_dir/module-cache"
    [[ -f "$library" && -f "$module" && -f "$configuration" ]] || rebuild=1
    if [[ "$rebuild" == 0 && "$(<"$configuration")" != "$expected_configuration" ]]; then
        rebuild=1
    fi
    for source in ResetNewsCore/*.swift scripts/reset-news-core-build.sh; do
        [[ "$source" -nt "$library" ]] && rebuild=1
    done

    if [[ "$rebuild" == 1 ]]; then
        swiftc -swift-version 5 -sdk "$sdk_path" -target "$target" -O -parse-as-library \
            -emit-module -emit-library -static -module-name ResetNewsCore \
            -module-cache-path "$output_dir/module-cache" ResetNewsCore/*.swift \
            -emit-module-path "$module" -o "$library"
        printf '%s\n' "$expected_configuration" > "$configuration"
    fi
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
