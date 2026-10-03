#!/bin/zsh
# Invoked only after archive, bundle identity, version and signature verification.
set -eu

hud_install_validate() {
    [[ $# == 4 ]] || return 2
    local hud_pid="$1" hud_target="$2" hud_stage="$3" hud_session="$4"
    [[ "$hud_pid" == <-> && "$hud_pid" -gt 0 ]] || return 2
    [[ "$hud_target" == /Applications/'GPT TouchBar HUD.app' || "$hud_target" == "$HOME/Applications/GPT TouchBar HUD.app" ]] || return 2
    [[ "$hud_session" =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ]] || return 2
    [[ "$hud_stage" == "${hud_target:h}/.GPTTouchBarHUD-update-$hud_session" && -d "$hud_stage/new.app" ]] || return 2
    [[ ! -L "$hud_stage" && ! -L "$hud_stage/new.app" && ! -L "$hud_target" && ! -e "$hud_stage/previous.app" ]] || return 2
    [[ "$(cd "$hud_stage" && /bin/pwd -P)" == "$hud_stage" ]] || return 2
    [[ "$(/usr/bin/stat -f '%u %Lp' "$hud_stage")" == "$(/usr/bin/id -u) 700" ]] || return 2
    [[ -f "$hud_stage/context.json" && ! -L "$hud_stage/context.json" && -x "$hud_stage/progress-helper" && ! -L "$hud_stage/progress-helper" ]] || return 2
    [[ "$(/usr/bin/plutil -extract sessionID raw -o - "$hud_stage/context.json")" == "$hud_session" ]] || return 2
    [[ "$(/usr/bin/plutil -extract targetPath raw -o - "$hud_stage/context.json")" == "$hud_target" ]] || return 2
    [[ "$(/usr/bin/plutil -extract ownerPID raw -o - "$hud_stage/context.json")" == "$hud_pid" ]] || return 2
}

# Isolated tests source these primitives; the executable entry always validates.
hud_install_alive() { /bin/kill -0 "$1" 2>/dev/null; }
hud_install_pause() { /bin/sleep 1; }
hud_install_move() { /bin/mv "$1" "$2"; }
hud_install_open() { /usr/bin/open -n "$1" --args --hud-update-session "$2" "$3"; }
hud_install_confirmed() { "$1/progress-helper" --check-update-launch "$1" "$2" "$3"; }

hud_install_write() {
    local hud_file
    hud_file="$(/usr/bin/mktemp "$hud_stage/.install-state.XXXXXX")" || return 1
    # Identifiers and messages here come from validation and fixed script strings.
    if ! printf '{"sessionID":"%s","phase":"%s","step":"%s","bytesReceived":0,"totalBytes":null,"bytesPerSecond":null,"message":"%s","recovery":"%s"}\n' \
        "$hud_session" "$1" "$2" "$3" "$4" > "$hud_file"; then return 1; fi
    /bin/chmod 600 "$hud_file" || return 1
    /bin/mv -f "$hud_file" "$hud_stage/install.json"
}

hud_install_wait_launch() {
    local hud_version="$1" hud_attempt
    for hud_attempt in {1..30}; do
        hud_install_confirmed "$hud_stage" "$hud_session" "$hud_version" && return 0
        hud_install_pause
    done
    return 1
}

hud_install_restore() {
    hud_install_write installing restoring '正在恢复旧版应用。' backupRetained || return 8
    if ! hud_install_move "$hud_backup" "$hud_target"; then
        hud_install_write failed restoring '旧版恢复失败，请使用保留的备份恢复应用。' needsRecovery || true
        return 6
    fi
    if hud_install_open "$hud_target" "$hud_stage" "$hud_session" && hud_install_wait_launch "$hud_source_version"; then
        hud_install_write failed restoring '更新未完成，旧版已恢复并完成启动。' restored || true
    else
        hud_install_write failed restoring '旧版已放回安装位置，但尚未确认启动，请打开应用或查看恢复说明。' needsRecovery || true
    fi
    return 4
}

hud_install_execute() {
    local hud_pid="$1" hud_target="$2" hud_stage="$3" hud_session="$4"
    local hud_backup="$hud_stage/previous.app" hud_attempt
    local hud_source_version hud_target_version
    hud_source_version="$(/usr/bin/plutil -extract sourceVersion raw -o - "$hud_stage/context.json")" || return 2
    hud_target_version="$(/usr/bin/plutil -extract targetVersion raw -o - "$hud_stage/context.json")" || return 2
    /bin/mkdir "$hud_stage/installer-lock" || return 7
    hud_install_write installing waitingForExit '等待本工具退出，随后安装新版。' untouched || return 8
    for hud_attempt in {1..60}; do
        hud_install_alive "$hud_pid" || break
        hud_install_pause
    done
    if hud_install_alive "$hud_pid"; then
        hud_install_write failed waitingForExit '本工具未能退出，原应用尚未替换。' untouched || true
        return 3
    fi
    hud_install_write installing backingUp '正在保留旧版应用。' untouched || return 8
    if ! hud_install_move "$hud_target" "$hud_backup"; then
        hud_install_write failed backingUp '无法保留旧版，原应用尚未替换。' untouched || true
        return 4
    fi
    if ! hud_install_write installing replacing '旧版已保留，正在替换应用。' backupRetained; then
        hud_install_restore || true
        return 8
    fi
    if ! hud_install_move "$hud_stage/new.app" "$hud_target"; then
        hud_install_restore
        return $?
    fi
    if ! hud_install_write restarting launching '应用已替换，正在等待新版启动确认。' backupRetained; then return 8; fi
    if ! hud_install_open "$hud_target" "$hud_stage" "$hud_session"; then
        if ! hud_install_move "$hud_target" "$hud_stage/failed.app"; then
            hud_install_write failed launching '新版无法打开，请查看保留的旧版与恢复说明。' needsRecovery || true
            return 5
        fi
        hud_install_restore
        return $?
    fi
    if hud_install_wait_launch "$hud_target_version"; then
        hud_install_write succeeded finished '新版已完成启动。' backupRetained || return 8
        return 0
    fi
    # A late receipt must not cause replacement of a potentially running new app.
    hud_install_write launchUnconfirmed launching '应用已替换，但尚未确认新版启动。旧版备份已保留。' backupRetained || return 8
    return 9
}

if [[ "$ZSH_EVAL_CONTEXT" == toplevel ]]; then
    hud_install_validate "$@" || exit 2
    hud_install_execute "$@"
fi
# Retain previous.app, status and logs for recovery; never delete user installations.
