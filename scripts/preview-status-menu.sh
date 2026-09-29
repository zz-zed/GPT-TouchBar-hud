#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${STATUS_MENU_PREVIEW_APP:-build/StatusMenuPreview.app}"
bundle_id="${STATUS_MENU_PREVIEW_BUNDLE_ID:-local.touchbarcodextoken.status-menu-preview}"
if [[ -e "$app" ]]; then
    existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$existing_id" != "$bundle_id" ]]; then
        echo "Refusing to overwrite an unrelated artifact: $app" >&2
        exit 1
    fi
fi
mkdir -p .build/status-menu-preview
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path)"
swiftc -whole-module-optimization "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" \
    -module-cache-path "$SWIFT_MODULE_CACHE" \
    "${sources[@]}" Tests/StatusMenuPreviewMain.swift -o .build/status-menu-preview/StatusMenuPreview
mkdir -p "$app/Contents/MacOS"
cp .build/status-menu-preview/StatusMenuPreview "$app/Contents/MacOS/StatusMenuPreview"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleName</key><string>StatusMenuPreview</string>
<key>CFBundleDisplayName</key><string>菜单交互测试（模拟数据）</string>
<key>CFBundleExecutable</key><string>StatusMenuPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.33</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>11.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
if [[ "$app" = /* ]]; then
    echo "Built simulated menu preview (not launched): $app"
else
    echo "Built simulated menu preview (not launched): $(pwd)/$app"
fi
