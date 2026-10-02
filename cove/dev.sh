#!/usr/bin/env bash
# Cove dev launcher. Runs kitty DETACHED (its own lifetime) + the Godot app, so
# you can edit scripts and `reload.sh` to relaunch just Godot — kitty keeps
# running, so all terminals/shells/agents stay, and Godot restores their
# positions/names/camera from state.json. `stop.sh` quits everything.
set -euo pipefail

_COVE_IOSURFACE_OVERRIDE_SET=${COVE_IOSURFACE+x}

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/cove"
KITTY="$REPO/kitty/launcher/kitty"
# kitty holds ~5 fds per termling (pty, frame file, disk cache, pipes); the
# 256 a login item inherits from launchd runs out near 50 termlings.
ulimit -n 10240 2>/dev/null || true
KITTEN="$REPO/kitty/launcher/kitty.app/Contents/MacOS/kitten"
SOCK="unix:/tmp/cove-kitty"
DIR="/tmp/cove"
GODOT="${GODOT:-godot}"
ABDUCO="$APP/bin/abduco"
[ -x "$ABDUCO" ] || ABDUCO="$(command -v abduco 2>/dev/null || echo /opt/homebrew/bin/abduco)"

[ -e "$KITTY" ] || { echo "kitty not built ($KITTY) — see cove/README.md" >&2; exit 1; }
[ -x "$KITTEN" ] || { echo "kitten not built ($KITTEN)" >&2; exit 1; }
command -v "$GODOT" >/dev/null 2>&1 || { echo "godot not found; set GODOT=/path/to/godot" >&2; exit 1; }
[ -x "$ABDUCO" ] || { echo "abduco not found at $ABDUCO" >&2; exit 1; }
exec 9>/tmp/cove-launch.lock
if ! /usr/bin/lockf -s -t 0 9; then
    echo "another Cove launch is already in progress" >&2
    exit 1
fi

# Check session discovery before stopping the running Cove.
if ! session_listing=$("$ABDUCO" 2>/dev/null); then
    echo "failed to list abduco sessions" >&2
    exit 1
fi
SESSIONS=($(printf '%s\n' "$session_listing" | awk 'NR>1 && $1 != "+"{print $NF}' | grep -E '^cove-[0-9]+$' || true))

# An explicit setting wins. Otherwise a warm restart keeps the request recorded
# by the previous dev launch instead of silently falling back to CPU readback.
if [ "$_COVE_IOSURFACE_OVERRIDE_SET" != x ] && [ "${#SESSIONS[@]}" -ne 0 ] \
        && [ -f "$DIR/dev-env" ]; then
    while IFS='=' read -r _key _value; do
        [ "$_key" = COVE_IOSURFACE ] && COVE_IOSURFACE=$_value
    done < "$DIR/dev-env"
fi
# shellcheck disable=SC1091
source "$APP/cove-iosurface.sh"

# The GDExtension (CoveInput/IOSurface) must be registered for fast input.
if [ ! -f "$APP/.godot/extension_list.cfg" ]; then
    "$GODOT" --path "$APP" --editor --headless --quit >/dev/null 2>&1 || true
fi
cove_resolve_iosurface

# Reuse the warm-restart path when a crashed or running Cove already owns
# sessions. It preserves layout and reattaches them instead of wiping /tmp/cove.
if [ "${#SESSIONS[@]}" -ne 0 ]; then
    mkdir -p "$DIR"
    {
        echo "COVE_KITTEN=$KITTEN"
        echo "COVE_KITTY_SOCKET=$SOCK"
        echo "APP=$APP"
        echo "GODOT=$GODOT"
        cove_write_iosurface_env
    } > "$DIR/dev-env.new"
    mv "$DIR/dev-env.new" "$DIR/dev-env"
    COVE_LAUNCH_LOCK_HELD=1 "$APP/reload-kitty.sh"
    "$APP/cove-remote-start.sh" 9>&- || true
    exec 9>&-
    exit 0
fi

pkill -if 'godot --path' 2>/dev/null || true
# Kill any previous cove-kitty. macOS `pkill -f` can't read kitty's args, so
# match via a `ps` scan on the launcher + title (which also finds the pid in
# kitty.pid, when that's still a Cove kitty rather than a reused pid).
for _p in $(ps -Ao pid=,command= | awk '/[l]auncher\/kitty --title cove/ {print $1}'); do
    kill "$_p" 2>/dev/null || true
done
sleep 0.5
rm -rf "$DIR"; rm -f /tmp/cove-kitty

export COVE=1
# Each terminal runs cove-shell.sh, which wraps the shell in an abduco session so
# it survives a kitty restart (see reload-kitty.sh). -o shell= makes Cmd+N windows
# use it too. abduco is a transparent passthrough, so rendering is unchanged.
WRAPPER="$APP/cove-shell.sh"
KITTY_COVE=1 KITTY_COVE_DIR="$DIR" nohup "$KITTY" --title cove \
    --listen-on "$SOCK" -o allow_remote_control=yes -o sync_to_monitor=no \
    -o repaint_delay=16 \
    -o font_size=16 -o remember_window_size=no \
    -o initial_window_width=110c -o initial_window_height=32c \
    -o "map cmd+n cove_new_os_window" \
    -o shell="$WRAPPER" \
    "$WRAPPER" 9>&- >/tmp/cove-kitty.log 2>&1 &
COVE_KITTY_PID=$!

# If kitty never answers, stop it and drop what it left so a retry isn't fooled.
# Its first window may already have made an abduco session, which outlives kitty
# by design: the next dev.sh then finds it and takes the warm-restart path.
cleanup_cold_start() {
    kill "$COVE_KITTY_PID" 2>/dev/null || true
    for _ in $(seq 1 30); do
        kill -0 "$COVE_KITTY_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -9 "$COVE_KITTY_PID" 2>/dev/null || true
    wait "$COVE_KITTY_PID" 2>/dev/null || true
    rm -f /tmp/cove-kitty "$DIR/kitty.pid" "$DIR/dev-env"
}
trap cleanup_cold_start EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Failing here kills kitty, so allow a slow first start (a loaded machine, a
# fresh build): 30 s, where reload-kitty.sh's warm start allows 8 s.
kitty_ready=false
for _ in $(seq 1 300); do
    if kill -0 "$COVE_KITTY_PID" 2>/dev/null \
            && "$KITTEN" @ --to "$SOCK" ls >/dev/null 2>&1; then
        kitty_ready=true
        break
    fi
    sleep 0.1
done
if [ "$kitty_ready" != true ]; then
    echo "kitty did not become ready at $SOCK" >&2
    exit 1
fi
# Record the kitty pid so reload.sh/stop.sh find it without pgrep (which can't
# read kitty's args on macOS).
echo "$COVE_KITTY_PID" > "$DIR/kitty.pid"
{
    echo "COVE_KITTEN=$KITTEN"
    echo "COVE_KITTY_SOCKET=$SOCK"
    echo "APP=$APP"
    echo "GODOT=$GODOT"
    cove_write_iosurface_env
    echo "COVE_KITTY_PID=$COVE_KITTY_PID"
} > "$DIR/dev-env"

# Auto-start remote termlings (relay + peer auto-viewer) — survives Godot reloads.
"$APP/cove-remote-start.sh" 9>&- || true

COVE_KITTEN="$KITTEN" COVE_KITTY_SOCKET="$SOCK" \
	nohup "$GODOT" --path "$APP" --max-fps 60 9>&- >/tmp/cove-godot.log 2>&1 &
trap - EXIT HUP INT TERM
exec 9>&-
echo "Cove dev up (kitty + godot). Edit scripts, then: cove/reload.sh"
echo "Quit everything with: cove/stop.sh"
