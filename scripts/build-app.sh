#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/GPT TouchBar HUD.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
HELPERS_DIR="$APP_DIR/Contents/Helpers"
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
DEPLOYMENT_TARGET="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT_DIR/Resources/Info.plist")"
# Native by default (matches architecture-specific CI). Opt in to a universal local artifact.
read -r -a BUILD_ARCHS <<< "${HUD_BUILD_ARCHS:-$(uname -m)}"
cd "$ROOT_DIR"
app_slices=()
helper_slices=()
for build_arch in "${BUILD_ARCHS[@]}"; do
    [[ "$build_arch" == arm64 || "$build_arch" == x86_64 ]] || { echo 'Unsupported architecture' >&2; exit 1; }
    output_dir="$ROOT_DIR/.build/distribution/$build_arch"
    mkdir -p "$output_dir/module-cache"
    # Explicit SDK and target apply to compilation AND linking. Swift 6.4 swiftbuild currently
    # emits macOS 12 for this macOS 11 package; do not patch Mach-O version metadata afterwards.
    common=(-O -sdk "$SDK_PATH" -target "${build_arch}-apple-macosx${DEPLOYMENT_TARGET}" -module-cache-path "$output_dir/module-cache")
    swiftc "${common[@]}" -parse-as-library -emit-module -emit-library -static -module-name HookCore \
        HookCore/*.swift -emit-module-path "$output_dir/HookCore.swiftmodule" -o "$output_dir/libHookCore.a"
    swiftc "${common[@]}" -I "$output_dir" -L "$output_dir" -lHookCore Sources/*.swift -o "$output_dir/GPTTouchBarHUD"
    swiftc "${common[@]}" -I "$output_dir" -L "$output_dir" -lHookCore HookHelper/main.swift -o "$output_dir/HookEmitter"
    app_slices+=("$output_dir/GPTTouchBarHUD")
    helper_slices+=("$output_dir/HookEmitter")
done

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPERS_DIR"
if [[ "${#BUILD_ARCHS[@]}" -gt 1 ]]; then
    lipo -create "${app_slices[@]}" -output "$MACOS_DIR/GPTTouchBarHUD"
    lipo -create "${helper_slices[@]}" -output "$HELPERS_DIR/HookEmitter"
else
    cp "${app_slices[0]}" "$MACOS_DIR/GPTTouchBarHUD"
    cp "${helper_slices[0]}" "$HELPERS_DIR/HookEmitter"
fi
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"
cp Resources/gpt-touchbar-hud-launcher.sh "$RESOURCES_DIR/gpt-touchbar-hud-launcher.sh"
cp Resources/install-update.sh "$RESOURCES_DIR/install-update.sh"
chmod +x "$RESOURCES_DIR/gpt-touchbar-hud-launcher.sh" "$HELPERS_DIR/HookEmitter"
# Sign inner executable first, then the enclosing app. Match the existing ad-hoc distribution policy.
codesign --force --sign - --identifier com.gpt-touchbar-hud.hook-emitter "$HELPERS_DIR/HookEmitter" >/dev/null 2>&1
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1
codesign --verify --all-architectures --strict "$HELPERS_DIR/HookEmitter"
codesign --verify --deep --strict "$APP_DIR"
for build_arch in "${BUILD_ARCHS[@]}"; do
    lipo "$MACOS_DIR/GPTTouchBarHUD" -verify_arch "$build_arch"
    lipo "$HELPERS_DIR/HookEmitter" -verify_arch "$build_arch"
done
printf '%s\n' "$APP_DIR"
