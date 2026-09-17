#!/bin/bash
set -euo pipefail

# Packaging pins this helper to the app in the same DMG. Never accept a target argument.
APP='/Applications/GPT TouchBar HUD.app'
EXPECTED_CDHASH='__PACKAGED_CDHASH__'
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

finish() {
    printf '\n%s\n' "$1"
    if [[ -t 0 ]]; then read -r -p '按回车关闭此窗口…' _ || true; fi
    exit "$2"
}
fail() {
    printf '\n%s\n' "$1"
    finish '请查看安装包中的「首次打开说明.txt」。可信来源的应用可尝试：系统设置 → 隐私与安全性 → 仍要打开。若提示恶意软件或应用损坏，请停止操作并重新下载或联系维护者。' 1
}
validate() {
    [[ -d "$APP" && ! -L "$APP" && ! -L /Applications ]] || fail '请先将应用拖入 Applications；不处理符号链接。'
    local links identifier actual
    links="$(/usr/bin/find "$APP" -type l -print)" || fail '无法检查应用目录。'
    [[ -z "$links" ]] || fail '应用包含非预期符号链接，已停止。'
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" || fail '无法读取应用信息。'
    [[ "$identifier" == io.github.zz-zed.GPTTouchBarHUD ]] || fail '应用标识不匹配。'
    /usr/bin/codesign --verify --deep --strict "$APP" || fail '应用签名完整性校验失败。'
    actual="$(/usr/bin/codesign -dvvv "$APP" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')" || fail '无法读取代码签名。'
    [[ "$EXPECTED_CDHASH" =~ ^[0-9a-f]{40}$ && "$actual" == "$EXPECTED_CDHASH" ]] || fail '已安装应用与本安装包不一致，请先拖入本安装包中的应用。'
}

[[ $# -eq 0 ]] || fail '本助手不接受参数。'
printf '%s\n' 'GPT TouchBar HUD · 首次打开助手' "仅处理：$APP"
validate
printf '\n%s\n' \
    '确认后仅解除本应用的下载隔离并打开，不开启「任何来源」。' \
    '应用未经 Apple 公证，仅在信任安装包时继续；若提示恶意软件或损坏，请取消。'
answer=''
read -r -p '输入 OPEN 并回车继续；其他输入取消：' answer || finish '已取消，未修改应用。' 0
[[ "$answer" == OPEN ]] || finish '已取消，未修改应用。' 0
# Recheck after the user prompt; never elevate privileges or clear unrelated attributes.
validate
paths=()
while IFS= read -r -d '' entry; do paths+=("$entry"); done < <(/usr/bin/find "$APP" -print0)
for entry in "${paths[@]}"; do
    if /usr/bin/xattr -p com.apple.quarantine "$entry" >/dev/null 2>&1; then
        /usr/bin/xattr -d com.apple.quarantine "$entry" || fail '未能移除部分隔离标记（可能权限不足）；已停止，不请求管理员权限。'
    fi
done
/usr/bin/open "$APP" || fail '系统未接受打开请求。'
finish '已发送打开请求，请查看菜单栏。若仍被系统拦截，请按「首次打开说明.txt」手动处理。' 0
