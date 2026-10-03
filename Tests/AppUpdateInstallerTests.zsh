#!/bin/zsh
# Only the sourced state machine operates on these owned fixtures. The real entry
# retains its installation-path / session checks and is tested separately below.
set -eu
source Resources/install-update.sh
hud_test_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/hud-installer-test.XXXXXX")"
trap '/bin/rm -rf "$hud_test_root"' EXIT
hud_checks=0
hud_case=''

hud_check() {
    if ! eval "$1"; then print -u2 "FAIL: $2"; exit 1; fi
    hud_checks=$((hud_checks + 1))
}
hud_install_pause() { :; }
hud_install_alive() { [[ "$hud_case" == owner-alive ]]; }
hud_install_open() {
    if [[ "$hud_case" == launch-failure && ! -d "$hud_stage/failed.app" ]]; then return 1; fi
    return 0
}
hud_install_confirmed() {
    [[ "$hud_case" != launch-timeout && "$hud_case" != restore-unconfirmed ]]
}
hud_install_move() {
    if [[ "$hud_case" == backup-failure && "$2" == "$hud_backup" ]]; then return 1; fi
    if [[ "$hud_case" == replace-failure || "$hud_case" == restore-failure || "$hud_case" == restore-unconfirmed ]]; then
        [[ "$1" != "$hud_stage/new.app" ]] || return 1
    fi
    if [[ "$hud_case" == restore-failure && "$1" == "$hud_backup" ]]; then return 1; fi
    /bin/mv "$1" "$2"
}

for hud_case in success owner-alive backup-failure replace-failure launch-failure launch-timeout restore-failure restore-unconfirmed; do
    hud_dir="$hud_test_root/$hud_case"
    hud_target="$hud_dir/GPT TouchBar HUD.app"
    hud_session="$(/usr/bin/uuidgen)"
    hud_stage="$hud_dir/.GPTTouchBarHUD-update-$hud_session"
    /bin/mkdir -p "$hud_target" "$hud_stage/new.app"
    print -n old > "$hud_target/marker"
    print -n new > "$hud_stage/new.app/marker"
    printf '{"sourceVersion":"0.1.37","targetVersion":"0.1.38"}\n' > "$hud_stage/context.json"
    if hud_install_execute 999999 "$hud_target" "$hud_stage" "$hud_session"; then hud_result=0; else hud_result=$?; fi
    hud_phase="$(/usr/bin/plutil -extract phase raw -o - "$hud_stage/install.json")"
    hud_recovery="$(/usr/bin/plutil -extract recovery raw -o - "$hud_stage/install.json")"
    hud_check '[[ "$(/usr/bin/stat -f %Lp "$hud_stage/install.json")" == 600 ]]' "$hud_case: private atomic status"
    hud_check '[[ "$(/usr/bin/plutil -extract sessionID raw -o - "$hud_stage/install.json")" == "$hud_session" ]]' "$hud_case: same update session"
    case "$hud_case" in
        success)
            hud_check '[[ "$hud_result" == 0 && "$hud_phase" == succeeded ]]' 'Success requires launch acknowledgement'
            hud_check '[[ "$(<"$hud_target/marker")" == new && "$(<"$hud_stage/previous.app/marker")" == old ]]' 'New app and old backup retained'
            # A second runner must not perform another replacement in this session.
            if hud_install_execute 999999 "$hud_target" "$hud_stage" "$hud_session" 2>/dev/null; then hud_duplicate=0; else hud_duplicate=$?; fi
            hud_check '[[ "$hud_duplicate" == 7 && "$(<"$hud_target/marker")" == new ]]' 'Duplicate installer rejected'
            ;;
        owner-alive|backup-failure)
            hud_check '[[ "$hud_result" != 0 && "$hud_phase" == failed && "$hud_recovery" == untouched ]]' "$hud_case: untouched failure reported"
            hud_check '[[ "$(<"$hud_target/marker")" == old && ! -e "$hud_stage/previous.app" ]]' "$hud_case: original application retained"
            ;;
        replace-failure|launch-failure)
            hud_check '[[ "$hud_result" == 4 && "$hud_phase" == failed && "$hud_recovery" == restored ]]' "$hud_case: recovery needs old-version acknowledgement"
            hud_check '[[ "$(<"$hud_target/marker")" == old ]]' "$hud_case: restored old application"
            if [[ "$hud_case" == launch-failure ]]; then
                hud_check '[[ "$(<"$hud_stage/failed.app/marker")" == new ]]' 'Failed new app retained for inspection'
            fi
            ;;
        launch-timeout)
            hud_check '[[ "$hud_result" == 9 && "$hud_phase" == launchUnconfirmed && "$hud_recovery" == backupRetained ]]' 'Timeout is not successful installation'
            hud_check '[[ "$(<"$hud_target/marker")" == new && "$(<"$hud_stage/previous.app/marker")" == old ]]' 'Timeout does not replace a potentially running new app'
            ;;
        restore-failure)
            hud_check '[[ "$hud_result" == 6 && "$hud_phase" == failed && "$hud_recovery" == needsRecovery ]]' 'Failed restore is not reported as restored'
            hud_check '[[ ! -e "$hud_target" && "$(<"$hud_stage/previous.app/marker")" == old ]]' 'Unmoved backup retained when restore fails'
            ;;
        restore-unconfirmed)
            hud_check '[[ "$hud_result" == 4 && "$hud_phase" == failed && "$hud_recovery" == needsRecovery ]]' 'Replaced-back old app without receipt is not healthy recovery'
            hud_check '[[ "$(<"$hud_target/marker")" == old ]]' 'Unconfirmed old app remains at target'
            ;;
    esac
    # Production script refuses these same non-installation paths before mutation.
    if /bin/zsh Resources/install-update.sh 999999 "$hud_target" "$hud_stage" "$hud_session"; then hud_guard=0; else hud_guard=$?; fi
    hud_check '[[ "$hud_guard" == 2 ]]' "$hud_case: production target boundary preserved"
done
print "PASS: $hud_checks isolated installer checks"
