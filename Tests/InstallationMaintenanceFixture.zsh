#!/bin/zsh
# An installer-shaped process tree. No command reads stdin or starts an actual app.
set -eu
fixture_mode="$1"
fixture_directory="$2"
fixture_probe="$3"
print -n ready > "$fixture_directory/shell-started"
case "$fixture_mode" in
    success|rollback)
        # Exercise the current production replacement/rollback state machine on
        # owned fixtures; the executable path validator remains separately tested.
        source "${0:A:h:h}/Resources/install-update.sh"
        fixture_session="$(/usr/bin/uuidgen)"
        fixture_target="$fixture_directory/GPT HUD.app"
        fixture_stage="$fixture_directory/.GPTTouchBarHUD-update-$fixture_session"
        /bin/mkdir -p "$fixture_target" "$fixture_stage/new.app"
        print -n old > "$fixture_target/marker"
        print -n new > "$fixture_stage/new.app/marker"
        print -r -- '{"sourceVersion":"0.1.37","targetVersion":"0.1.38"}' > "$fixture_stage/context.json"
        hud_install_alive() { return 1; }
        hud_install_pause() { :; }
        hud_install_open() { :; }
        hud_install_confirmed() { return 0; }
        hud_install_move() {
            if [[ ! -f "$fixture_directory/move-checked" ]]; then
                print -n checked > "$fixture_directory/move-checked"
                "$fixture_probe" --descendant "$fixture_directory"
            fi
            if [[ "$fixture_mode" == rollback && "$1" == "$fixture_stage/new.app" ]]; then return 1; fi
            /bin/mv "$1" "$2"
        }
        while [[ ! -f "$fixture_directory/shell-proceed" ]]; do /bin/sleep 0.02; done
        if hud_install_execute 999999 "$fixture_target" "$fixture_stage" "$fixture_session"; then
            fixture_result=0
        else
            fixture_result=$?
        fi
        print -n "$fixture_result" > "$fixture_directory/shell-result"
        exit "$fixture_result"
        ;;
    orphan-descendant)
        while [[ ! -f "$fixture_directory/shell-proceed" ]]; do /bin/sleep 0.02; done
        "$fixture_probe" --descendant "$fixture_directory"
        print -n 0 > "$fixture_directory/shell-result"
        ;;
    launch-inherited|launch-detached)
        if [[ "$fixture_mode" == launch-detached ]]; then
            "$fixture_probe" --launched "$fixture_directory" </dev/null &
        else
            "$fixture_probe" --launched "$fixture_directory" &
        fi
        while [[ ! -f "$fixture_directory/launched-started" ]]; do /bin/sleep 0.02; done
        print -n 0 > "$fixture_directory/shell-result"
        # Explicit disown avoids zsh job teardown affecting the launched fixture.
        disown
        ;;
    *) exit 64 ;;
esac
