#!/usr/bin/env bash
# Walking Terminals -- Phase 0 launcher. Starts the hacked kitty in cove
# mode (publishing frames to a shared file, remote control on) and then launches
# the Godot host that displays it and forwards input. See cove/README.md.
set -euo pipefail

_COVE_IOSURFACE_OVERRIDE_SET=${COVE_IOSURFACE+x}

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/cove"
KITTY="$REPO/kitty/launcher/kitty"
KITTEN="$REPO/kitty/launcher/kitty.app/Contents/MacOS/kitten"
SOCK="unix:/tmp/cove-kitty"
DIR="/tmp/cove"
GODOT="${GODOT:-godot}"
ABDUCO="$REPO/cove/bin/abduco"
[ -x "$ABDUCO" ] || ABDUCO="$(command -v abduco 2>/dev/null || echo /opt/homebrew/bin/abduco)"
LOCK_FILE="/tmp/cove-launch.lock"

exec 9>"$LOCK_FILE"
if ! /usr/bin/lockf -s -t 0 9; then
    echo "another Cove launch is already in progress" >&2
    exit 1
fi

if [ ! -e "$KITTY" ]; then
    echo "kitty is not built at $KITTY -- see cove/README.md (Building kitty)" >&2
    exit 1
fi
if [ ! -x "$KITTEN" ]; then
    echo "kitten is not built at $KITTEN" >&2
    exit 1
fi
if ! command -v "$GODOT" >/dev/null 2>&1; then
    echo "godot not found on PATH. Set GODOT=/path/to/godot" >&2
    exit 1
fi
if [ ! -x "$ABDUCO" ]; then
    echo "abduco not found at $ABDUCO" >&2
    exit 1
fi
# Reject a malformed transport request before touching saved state. The class
# probe itself waits until we know this launch will actually restart kitty.
# shellcheck disable=SC1091
source "$APP/cove-iosurface.sh"
cove_normalize_iosurface
# Pids of processes whose command line starts with "$1 " (or is exactly $1),
# case-insensitively (Godot runs as .../Godot.app/Contents/MacOS/Godot). The
# pattern goes in through the environment so awk's own argv can't match it.
pids_running() {
    ps -Ao pid=,command= | WANT="$1" awk '{
        want = ENVIRON["WANT"]; pid = $1; cmd = $0; sub(/^ *[0-9]+ +/, "", cmd)
        i = index(tolower(cmd), tolower(want))
        if (i && (length(cmd) == i + length(want) - 1 || substr(cmd, i + length(want), 1) == " ")) print pid
    }'
}
list_sessions() { printf '%s\n' "$session_listing" | awk "NR>1 && $1 {print \$NF}" | grep -E '^cove-[0-9]+$' || true; }

export COVE_KITTEN="$KITTEN"
export COVE_KITTY_SOCKET="$SOCK"

# Kitty survived and only Godot died (e.g. a dev.sh kitty): the termlings are
# all still there, so just bring Godot back, as reload.sh does.
if "$KITTEN" @ --to "$SOCK" ls >/dev/null 2>&1; then
    if [ -n "$(pids_running "godot --path $REPO/cove")" ]; then
        echo "Cove is already running at $SOCK" >&2
        exit 1
    fi
    if [ "$_COVE_IOSURFACE_OVERRIDE_SET" = x ]; then
        echo "warning: kitty is already running; its IOSurface mode is unchanged. Restart kitty to apply COVE_IOSURFACE=${COVE_IOSURFACE} (cove/reload-kitty.sh in dev mode)." >&2
    fi
    echo "kitty is still running at $SOCK; relaunching Godot"
    exec 9>&-
    "$REPO/cove/cove-remote-start.sh" || true
    exec "$GODOT" --path "$REPO/cove"
fi

# A cove kitty that is alive but not answering (hung, or its socket was
# unlinked) still holds its termlings; starting a second one would fight it.
STUCK_KITTY=$(pids_running "$KITTY --title cove" | tr '\n' ' ')
if [ -n "$STUCK_KITTY" ]; then
    echo "a Cove kitty is still running but not answering at $SOCK (pid $STUCK_KITTY)." >&2
    echo "kill -9 it (its termlings survive in abduco) and run this again." >&2
    exit 1
fi

# The abduco masters outlive a crashed Cove. Reattach detached sessions instead
# of deleting their saved layout and starting one empty replacement terminal.
if ! session_listing=$("$ABDUCO" 2>/dev/null); then
    echo "failed to list abduco sessions" >&2
    exit 1
fi
SESSIONS=($(list_sessions '$1 != "*" && $1 != "+"'))
# Attached elsewhere (someone ran `abduco -a` by hand): leave those alone.
ATTACHED=($(list_sessions '$1 == "*"'))
if [ "${#ATTACHED[@]}" -ne 0 ]; then
    echo "warning: skipping ${#ATTACHED[@]} session(s) attached elsewhere: ${ATTACHED[*]}" >&2
fi
if [ "${#SESSIONS[@]}" -eq 0 ] && [ "${#ATTACHED[@]}" -eq 0 ]; then
    rm -rf "$DIR"
else
    [ "${#SESSIONS[@]}" -eq 0 ] || echo "reattaching ${#SESSIONS[@]} termling session(s): ${SESSIONS[*]}"
    # Keep state.json (positions/names by session) and the app critters' frames
    # (panes >= 1000000); drop what belonged to the dead kitty. kitty.pid and
    # dev-env would point reload.sh/reload-kitty.sh at a dead (maybe reused) pid.
    mkdir -p "$DIR"
    for _f in "$DIR"/term-*.rgba; do
        _n=${_f##*/term-}; _n=${_n%.rgba}
        case "$_n" in *[!0-9]*|"") continue ;; esac
        [ "$_n" -lt 1000000 ] && rm -f "$_f"
    done
    rm -f "$DIR/kitty.pid" "$DIR/dev-env" "$DIR/events.jsonl"
fi
rm -f /tmp/cove-kitty

export KITTY_COVE=1
export KITTY_COVE_DIR="$DIR"
# Child shells (and agents inside them) inherit these: COVE=1 marks a shell
# as living in the cove; its terminal id is kitty's own $KITTY_WINDOW_ID.
export COVE=1

# COVE_IOSURFACE is an opt-in request. Kitty's internal presence-only flag is
# set only after Godot confirms that it can import the corresponding class.
cove_probe_iosurface

# The kitty window is created hidden (cove mode); only Godot is visible.
# sync_to_monitor=no lets the hidden window keep rendering without a display link.
# cove-shell.sh wraps each shell in an abduco session (survives a kitty restart;
# see reload-kitty.sh). -o shell= makes Cmd+N windows use it too.
WRAPPER="$REPO/cove/cove-shell.sh"
CHILD=("$WRAPPER")
if [ "${#SESSIONS[@]}" -ne 0 ]; then
    CHILD=("$ABDUCO" -a "${SESSIONS[0]}")
fi
"$KITTY" --title cove \
    --listen-on "$SOCK" \
    -o allow_remote_control=yes \
    -o macos_quit_when_last_window_closed=yes \
    -o sync_to_monitor=no \
    -o font_size=16 \
    -o remember_window_size=no -o initial_window_width=110c -o initial_window_height=32c \
    -o "map cmd+n cove_new_os_window" \
    -o shell="$WRAPPER" \
    "${CHILD[@]}" 9>&- &
KITTY_PID=$!
cleanup() { kill "$KITTY_PID" 2>/dev/null || true; }
trap cleanup EXIT

# Wait for remote control before asking kitty to create recovered windows.
kitty_ready=false
for _ in $(seq 1 80); do
    if "$KITTEN" @ --to "$SOCK" ls >/dev/null 2>&1; then
        kitty_ready=true
        break
    fi
    sleep 0.1
done
if [ "$kitty_ready" != true ]; then
    echo "kitty did not become ready at $SOCK" >&2
    exit 1
fi

for ((i=1; i<${#SESSIONS[@]}; i++)); do
    "$KITTEN" @ --to "$SOCK" launch --type=os-window \
        "$ABDUCO" -a "${SESSIONS[$i]}" >/dev/null
done

# abduco preserves processes, not kitty's screen buffer. Resize and restore the
# windows so full-screen clients repaint instead of reopening as black panes.
# Wait for every client to attach first, or a late one misses the pulse.
if [ "${#SESSIONS[@]}" -ne 0 ]; then
    for _ in $(seq 1 30); do
        session_listing=$("$ABDUCO" 2>/dev/null) || break
        _detached=" $(list_sessions '$1 != "*" && $1 != "+"' | tr '\n' ' ')"
        _waiting=false
        for _s in "${SESSIONS[@]}"; do
            case "$_detached" in *" $_s "*) _waiting=true ;; esac
        done
        [ "$_waiting" = true ] || break
        sleep 0.1
    done
    if "$KITTEN" @ --to "$SOCK" resize-os-window --match all \
        --unit cells --incremental --width 1 >/dev/null; then
        sleep 0.3
        "$KITTEN" @ --to "$SOCK" resize-os-window --match all \
            --unit cells --incremental --width=-1 >/dev/null || \
            echo "warning: failed to restore recovered window widths" >&2
    else
        echo "warning: failed to resize recovered windows for repaint" >&2
    fi
fi

exec 9>&-

# Auto-start remote termlings (relay + peer auto-viewer) before the Godot host.
"$REPO/cove/cove-remote-start.sh" || true

"$GODOT" --path "$REPO/cove"
