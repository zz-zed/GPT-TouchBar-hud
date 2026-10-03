#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hud-material
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path "$(uname -m)-apple-macosx11.0")"
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
swiftc -whole-module-optimization -target "$(uname -m)-apple-macosx11.0" "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" \
    -module-cache-path "$SWIFT_MODULE_CACHE" "${sources[@]}" Tests/HUDMaterialTests.swift -o .build/hud-material/HUDMaterialTests
if [[ "${1:-}" == --preview ]]; then
    .build/hud-material/HUDMaterialTests
    preview_app="$PWD/.build/hud-material/Liquid Glass Preview.app"
    mkdir -p "$preview_app/Contents/MacOS"
    cp .build/hud-material/HUDMaterialTests "$preview_app/Contents/MacOS/HUDMaterialTests"
    cat > "$preview_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.gpt-touchbar-hud.liquid-glass-preview</string>
<key>CFBundleExecutable</key><string>HUDMaterialTests</string>
<key>CFBundleName</key><string>Liquid Glass Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
    exec "$preview_app/Contents/MacOS/HUDMaterialTests" --preview
fi
exec .build/hud-material/HUDMaterialTests "$@"
