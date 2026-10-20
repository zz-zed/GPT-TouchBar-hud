#!/bin/zsh
# All filesystem movement, validation, state writes, recovery and branching come
# from the byte-identical v0.1.38 installer. No real app is opened.
set -eu
[[ $# == 4 ]] || exit 2
source "$1"
local fixture_stage="$2" fixture_home="$3" fixture_mode="$4"
export HOME="$fixture_home"
local fixture_target="$HOME/Applications/GPT TouchBar HUD.app"
local fixture_session="$(/usr/bin/plutil -extract sessionID raw -o - "$fixture_stage/context.json")"
local fixture_pid="$(/usr/bin/plutil -extract ownerPID raw -o - "$fixture_stage/context.json")"
# Only OS launch, receipt and waiting are simulated; validation and file operations are original.
hud_install_pause() { :; }
hud_install_open() {
    print -r -- "$1" >> "$fixture_stage/launch-fixture.log"
    if [[ "$fixture_mode" == rollback && ! -e "$fixture_stage/failed.app" ]]; then return 1; fi
    return 0
}
hud_install_confirmed() { return 0; }
hud_install_validate "$fixture_pid" "$fixture_target" "$fixture_stage" "$fixture_session"
print 'Original historical path, owner, permissions and context validation passed.'
set +e
hud_install_execute "$fixture_pid" "$fixture_target" "$fixture_stage" "$fixture_session"
local fixture_result=$?
set -e
print -r -- "Original historical execute exit=$fixture_result"
if [[ "$fixture_mode" == success ]]; then [[ "$fixture_result" == 0 ]]; else [[ "$fixture_result" == 4 ]]; fi
