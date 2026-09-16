#!/bin/zsh
# Invoked only after archive, bundle identity, version and signature verification.
set -eu
old_pid="$1"
target_app="$2"
staging_dir="$3"
[[ "$old_pid" == <-> ]] || exit 2
[[ "$target_app" == /Applications/'GPT TouchBar HUD.app' || "$target_app" == "$HOME/Applications/GPT TouchBar HUD.app" ]] || exit 2
[[ "$staging_dir" == "${target_app:h}/.GPTTouchBarHUD-update-"* && -d "$staging_dir/new.app" && ! -L "$staging_dir" ]] || exit 2
for attempt in {1..60}; do
    /bin/kill -0 "$old_pid" 2>/dev/null || break
    /bin/sleep 1
done
if /bin/kill -0 "$old_pid" 2>/dev/null; then exit 3; fi
backup_app="$staging_dir/previous.app"
/bin/mv "$target_app" "$backup_app"
if ! /bin/mv "$staging_dir/new.app" "$target_app"; then
    /bin/mv "$backup_app" "$target_app"
    /usr/bin/open "$target_app"
    exit 4
fi
if ! /usr/bin/open "$target_app"; then
    /bin/mv "$target_app" "$staging_dir/failed.app"
    /bin/mv "$backup_app" "$target_app"
    /usr/bin/open "$target_app"
    exit 5
fi
# Retain previous.app and install.log for recovery; never delete user installations.
