#!/usr/bin/env bash
# Hot-reload the Cove: relaunch ONLY Godot against the still-running kitty.
# Terminals, shells and agents keep running; Godot restores positions/names/
# camera from state.json. Run after editing scripts. Requires dev.sh first.
set -euo pipefail

_COVE_IOSURFACE_OVERRIDE_SET=${COVE_IOSURFACE+x}
_COVE_IOSURFACE_OVERRIDE=${COVE_IOSURFACE-}

DIR="/tmp/cove"
[ -f "$DIR/dev-env" ] || { echo "Not in dev mode (no $DIR/dev-env). Start with cove/dev.sh." >&2; exit 1; }
# shellcheck disable=SC1090
source "$DIR/dev-env"
if [ "$_COVE_IOSURFACE_OVERRIDE_SET" = x ]; then
    COVE_IOSURFACE=$_COVE_IOSURFACE_OVERRIDE
fi

# Is the cove-kitty still alive? Prefer the pid file dev.sh wrote; fall back to
# scanning ps (macOS `pgrep -f` can't read kitty's args, so it never matches).
kpid="$(cat "$DIR/kitty.pid" 2>/dev/null || true)"
if [ -z "$kpid" ] || ! kill -0 "$kpid" 2>/dev/null; then
    kpid="$(ps -Ao pid=,command= | awk '/[l]auncher\/kitty --title cove/ {print $1; exit}')"
fi
if [ -z "$kpid" ]; then
    # Gone (a failed reload-kitty.sh, a crash): its termlings live on in abduco,
    # so restart kitty and reattach them rather than send you back to dev.sh.
    echo "kitty (cove) isn't running; restarting it with reload-kitty.sh." >&2
    exec "$APP/reload-kitty.sh"
fi

pkill -if "godot --path $APP" 2>/dev/null || pkill -if 'godot --path' 2>/dev/null || true
sleep 0.4
COVE_KITTEN="$COVE_KITTEN" COVE_KITTY_SOCKET="$COVE_KITTY_SOCKET" \
    nohup "$GODOT" --path "$APP" >/tmp/cove-godot.log 2>&1 &
echo "reloaded Godot ($!) — terminals + positions preserved."
