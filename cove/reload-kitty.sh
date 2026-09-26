#!/usr/bin/env bash
# Warm-reload the Cove: rebuild + RESTART kitty (to pick up cove.c / boss.py
# changes) WITHOUT losing termlings. Each terminal's shell runs inside an abduco
# session (see cove-shell.sh), so killing kitty only *detaches* the shells; we
# restart kitty, reattach every session as its own window, and relaunch Godot,
# which restores each termling's position/name by session from state.json.
#
# Use this when you changed kitty-side code (cove.c / boss.py). For Godot-only
# changes (Cove.gd, the gdext dylib), plain reload.sh is enough -- it leaves
# kitty running and only relaunches Godot.
set -euo pipefail

DIR="/tmp/cove"
[ -f "$DIR/dev-env" ] || { echo "Not in dev mode (no $DIR/dev-env). Start with cove/dev.sh." >&2; exit 1; }
# shellcheck disable=SC1090
source "$DIR/dev-env"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KITTY="$REPO/kitty/launcher/kitty"
KITTEN="${COVE_KITTEN:-$REPO/kitty/launcher/kitty.app/Contents/MacOS/kitten}"
WRAPPER="$REPO/cove/cove-shell.sh"
REATTACH="$REPO/cove/cove-reattach.sh"   # prints the saved screen, then abduco -a
SOCK="${COVE_KITTY_SOCKET:-unix:/tmp/cove-kitty}"
ABDUCO="$REPO/cove/bin/abduco"   # patched: no alt screen (build-abduco.sh)
[ -x "$ABDUCO" ] || ABDUCO="$(command -v abduco 2>/dev/null || echo /opt/homebrew/bin/abduco)"

LOCK_FILE="/tmp/cove-launch.lock"
COVE_KITTY_PID=""
STARTUP_COMPLETE=false

# dev-env, with the running kitty's pid when there is one. Without a pid rather
# than deleted: reload.sh and a retry of this script still need the rest, but a
# dead (maybe reused) pid must not vouch for window ids (cove_mcp.py).
write_dev_env() {
    {
        echo "COVE_KITTEN=$KITTEN"
        echo "COVE_KITTY_SOCKET=$SOCK"
        echo "APP=$APP"
        echo "GODOT=$GODOT"
        [ -z "${1:-}" ] || echo "COVE_KITTY_PID=$1"
    } > "$DIR/dev-env.new"
    mv "$DIR/dev-env.new" "$DIR/dev-env"
}

# If the new kitty never comes up, don't leave it half-started holding the
# socket; the sessions stay in abduco for the next attempt.
cleanup_startup() {
    if [ "$STARTUP_COMPLETE" != true ] && [ -n "$COVE_KITTY_PID" ]; then
        kill "$COVE_KITTY_PID" 2>/dev/null || true
        for _ in $(seq 1 30); do
            kill -0 "$COVE_KITTY_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$COVE_KITTY_PID" 2>/dev/null || true
        wait "$COVE_KITTY_PID" 2>/dev/null || true
        rm -f /tmp/cove-kitty "$DIR/kitty.pid"
        write_dev_env
    fi
}

[ -e "$KITTY" ] || { echo "kitty not built ($KITTY). Run cove/dev.sh first." >&2; exit 1; }
[ -x "$KITTEN" ] || { echo "kitten not built ($KITTEN)" >&2; exit 1; }
[ -x "$ABDUCO" ] || { echo "abduco not found at $ABDUCO" >&2; exit 1; }
# One launch at a time (run.sh and dev.sh take the same lock; dev.sh passes it
# down when it hands off to us).
if [ "${COVE_LAUNCH_LOCK_HELD:-}" != 1 ]; then
    exec 9>"$LOCK_FILE"
    if ! /usr/bin/lockf -s -t 0 9; then
        echo "another Cove launch is already in progress" >&2
        exit 1
    fi
fi
unset COVE_LAUNCH_LOCK_HELD
trap cleanup_startup EXIT

# Don't stop anything we can't reattach afterwards.
if ! "$ABDUCO" >/dev/null 2>&1; then
    echo "failed to list abduco sessions" >&2
    exit 1
fi

# Save each termling's screen + scrollback (with colours) while this kitty still
# has it: abduco keeps the processes, not the screen, so without this every
# reattached window starts blank. cove-reattach.sh prints it back. Best-effort.
mkdir -p "$DIR/scroll"
"$KITTEN" @ --to "$SOCK" ls 2>/dev/null | /usr/bin/python3 -c '
import json, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
kitten, sock, out = sys.argv[1:4]
try:
    wins = [w for o in json.load(sys.stdin) for t in o["tabs"] for w in t["windows"]]
except Exception:
    sys.exit(0)
def save(w):
    for p in w.get("foreground_processes", []):
        m = re.search(r"abduco\S*\s+-[aA]\s+(cove-\d+)", " ".join(p.get("cmdline", [])))
        if m:
            try:
                txt = subprocess.run([kitten, "@", "--to", sock, "get-text", "--match", "id:%d" % w["id"],
                                      "--ansi", "--extent", "all"], capture_output=True, timeout=20).stdout
            except Exception:
                return
            if txt.strip():
                with open("%s/%s.ansi" % (out, m.group(1)), "wb") as f:
                    f.write(txt)
            return
with ThreadPoolExecutor(8) as ex:
    list(ex.map(save, wins))
' "$KITTEN" "$SOCK" "$DIR/scroll" || true
echo "saved $(ls "$DIR/scroll" 2>/dev/null | wc -l | tr -d ' ') termling screen(s)"

# Stop Godot + kitty. The abduco masters (and the shells/agents they hold) keep
# running, detached, so nothing inside the termlings is lost. Match --path as
# an argument pair: Godot may have flags such as --max-fps before it.
GODOT_PIDS="$(ps -Ao pid=,command= | APP_PATH="$APP" awk '
    {
        is_godot = 0; has_app_path = 0
        for (i = 2; i <= NF; i++) {
            if (tolower($i) ~ /(^|\/)godot$/) is_godot = 1
            if ($i == "--path" && i < NF && $(i + 1) == ENVIRON["APP_PATH"]) has_app_path = 1
        }
        if (is_godot && has_app_path) print $1
    }
')"
for _p in $GODOT_PIDS; do kill "$_p" 2>/dev/null || true; done
# Wait for Godot to be gone before touching kitty: a Godot still running while
# the frame files vanish and reappear under new ids re-places those termlings
# and saves the wrong spots to state.json (seen 2026-09-25 under heavy load).
for _ in $(seq 1 50); do
    _alive=0
    for _p in $GODOT_PIDS; do kill -0 "$_p" 2>/dev/null && _alive=1; done
    [ "$_alive" = 0 ] && break
    sleep 0.1
done
for _p in $GODOT_PIDS; do kill -9 "$_p" 2>/dev/null || true; done
# kitty.pid can outlive its kitty (a crash), and the pid be reused: only kill
# it if it's still a Cove kitty.
KPIDS="$(ps -Ao pid=,command= | awk '/[l]auncher\/kitty --title cove/ {print $1}')"
_pidfile="$(cat "$DIR/kitty.pid" 2>/dev/null || true)"
case "$_pidfile" in
*[!0-9]*|"") ;;
*) ps -p "$_pidfile" -o command= 2>/dev/null | grep -q 'launcher/kitty --title cove' \
       && KPIDS="$_pidfile $KPIDS" ;;
esac
for _p in $KPIDS; do kill "$_p" 2>/dev/null || true; done
# A long-lived kitty can ignore SIGTERM, then unlink the NEW kitty's socket when
# it finally exits. Give it a moment, then make sure.
for _ in $(seq 1 30); do
    _alive=0; for _p in $KPIDS; do kill -0 "$_p" 2>/dev/null && _alive=1; done
    [ "$_alive" = 0 ] && break; sleep 0.1
done
for _p in $KPIDS; do kill -9 "$_p" 2>/dev/null || true; done
# The old kitty is gone: from here on, a failure must not leave its pid behind.
rm -f "$DIR/kitty.pid"
write_dev_env

# List the sessions only now, so one created while kitty was stopping isn't
# lost, and once the old kitty's clients have let go of theirs. (A leading "+"
# marks a session whose shell already exited: nothing to reattach. "*" is
# still attached: a slow old client or someone's `abduco -a`; abduco takes
# several clients, so reattach those too rather than drop them off the board.)
for _ in $(seq 1 50); do
    if ! session_listing=$("$ABDUCO" 2>/dev/null); then
        echo "failed to list abduco sessions after stopping kitty" >&2
        exit 1
    fi
    ATTACHED=($(printf '%s\n' "$session_listing" | awk 'NR>1 && $1=="*"{print $NF}' | grep -E '^cove-[0-9]+$' || true))
    [ "${#ATTACHED[@]}" -eq 0 ] && break
    sleep 0.1
done
SESSIONS=($(printf '%s\n' "$session_listing" | awk 'NR>1 && $1!="+"{print $NF}' | grep -E '^cove-[0-9]+$' || true))
if [ "${#ATTACHED[@]}" -ne 0 ]; then
    echo "warning: ${#ATTACHED[@]} session(s) still attached elsewhere, reattaching anyway: ${ATTACHED[*]}" >&2
fi
echo "reattaching ${#SESSIONS[@]} termling session(s): ${SESSIONS[*]:-<none>}"
# Drop the stale frame files + socket, but KEEP state.json so Godot can restore
# positions/names by session.
# (kitty's only: panes below 1000000; Vibefox and Vibemacs critters
# belong to their apps, which keep publishing.)
for _f in "$DIR"/term-*.rgba; do
    _n=${_f##*/term-}; _n=${_n%.rgba}
    case "$_n" in *[!0-9]*|"") continue ;; esac
    [ "$_n" -lt 1000000 ] && rm -f "$_f"
done
rm -f /tmp/cove-kitty 2>/dev/null || true

export COVE=1 KITTY_COVE=1 KITTY_COVE_DIR="$DIR"
[ "${COVE_IOSURFACE:-}" = "1" ] && export KITTY_COVE_IOSURFACE=1

COMMON=(--title cove --listen-on "$SOCK"
    -o allow_remote_control=yes -o sync_to_monitor=no -o font_size=16
    -o remember_window_size=no -o initial_window_width=110c -o initial_window_height=32c
    -o "map cmd+n cove_new_os_window"
    -o shell="$WRAPPER")

# Restart kitty. First window reattaches session[0] (or a fresh shell via the
# wrapper if there are none); the rest are reattached below via remote control.
if [ "${#SESSIONS[@]}" -eq 0 ]; then
    nohup "$KITTY" "${COMMON[@]}" "$WRAPPER" 9>&- >/tmp/cove-kitty.log 2>&1 &
else
    nohup "$KITTY" "${COMMON[@]}" "$REATTACH" "${SESSIONS[0]}" 9>&- >/tmp/cove-kitty.log 2>&1 &
fi
COVE_KITTY_PID=$!

# The sessions kitty has a window for, one per line, read from each window's own
# cmdline (ls is indented JSON, one element per line: kitty prints it with
# json.dumps(indent=2, sort_keys=True) in kitty/rc/ls.py, and kitten passes it
# through; if that changes, every window here looks missing). kitty reports the live
# argv, so that's `cove-reattach.sh cove-N` only until the script execs, then
# `abduco -a cove-N` (or `-A`, for a cove-shell.sh window). Titles, user vars
# and foreground_processes don't count: a shell where someone ran abduco by hand
# isn't that session's window. Prints nothing, and never fails, when ls fails or
# has none yet: under load ls can time out, and under `set -e` that mustn't
# abort the reload. (awk, not python: this is polled.)
kitty_sessions() {
    { "$KITTEN" @ --to "$SOCK" ls 2>/dev/null || true; } | awk '
        function indent(s) { match(s, /^[[:space:]]*/); return RLENGTH }
        BEGIN { skip = -1 }
        skip >= 0 { if (indent($0) == skip && $0 ~ /^[[:space:]]*\]/) skip = -1; next }
        /"foreground_processes": \[[[:space:]]*$/ { skip = indent($0); next }
        /^[[:space:]]*"cmdline": \[[[:space:]]*$/ { incmd = 1; n = 0; next }
        incmd && /^[[:space:]]*\]/ {
            incmd = 0
            for (i = 1; i < n; i++) {
                if (a[i] ~ /\/cove-reattach\.sh$/ && a[i+1] ~ /^cove-[0-9]+$/) print a[i+1]
                if (a[i] ~ /(^|\/)abduco$/ && a[i+1] ~ /^-[aA]$/ && a[i+2] ~ /^cove-[0-9]+$/) print a[i+2]
            }
            next
        }
        incmd { s = $0; sub(/^[[:space:]]*"/, "", s); sub(/",?[[:space:]]*$/, "", s); a[++n] = s }
    ' | sort -u
}

# Wait for remote control. Not for the first session's window: if that session
# died since the listing, its window closes at once, and that mustn't sink the
# reload of every other session. The loop below reattaches it like the rest.
kitty_ready=false
for _ in $(seq 1 80); do
    if kill -0 "$COVE_KITTY_PID" 2>/dev/null && "$KITTEN" @ --to "$SOCK" ls >/dev/null 2>&1; then
        kitty_ready=true
        break
    fi
    sleep 0.1
done
if [ "$kitty_ready" != true ]; then
    echo "kitty did not become ready at $SOCK" >&2
    exit 1
fi
echo "$COVE_KITTY_PID" > "$DIR/kitty.pid"

# Reattach every session, each as its own OS window. Under load a
# launch can time out, and a session that misses its window silently vanishes
# from the board (26 of 70 did on 2026-09-25). A timed-out launch may still
# land, so relaunch only what kitty's ls doesn't show after a grace period:
# 2 s, or 10 s when a launch this round timed out, since giving up on a launch
# that lands late opens a second window for the same session.
# The first session's window is kitty's own, already on its way, so the first
# round launches only the rest.
_missing=("${SESSIONS[@]+"${SESSIONS[@]}"}")
_launch=("${SESSIONS[@]:1}")
for _try in 1 2 3; do
    [ "${#_missing[@]}" -eq 0 ] && break
    _polls=20
    for _s in "${_launch[@]+"${_launch[@]}"}"; do
        _err=$("$KITTEN" @ --to "$SOCK" launch --type=os-window \
            "$REATTACH" "$_s" 2>&1 >/dev/null) ||
            case "$_err" in *"Timed out"*) _polls=100 ;; esac   # tools/cmd/at/main.go
    done
    for _ in $(seq 1 "$_polls"); do
        _have=" $(kitty_sessions | tr '\n' ' ')"
        _still=()
        for _s in "${_missing[@]}"; do
            case "$_have" in *" $_s "*) ;; *) _still+=("$_s") ;; esac
        done
        _missing=("${_still[@]+"${_still[@]}"}")
        [ "${#_missing[@]}" -eq 0 ] && break
        sleep 0.1
    done
    _launch=("${_missing[@]+"${_missing[@]}"}")
done
for _s in "${_missing[@]+"${_missing[@]}"}"; do
    echo "WARNING: couldn't reattach $_s (if it's still in abduco, run cove/reload-kitty.sh again)" >&2
done

# Refresh dev-env (new pid) and relaunch Godot.
write_dev_env "$COVE_KITTY_PID"
COVE_KITTEN="$KITTEN" COVE_KITTY_SOCKET="$SOCK" \
    nohup "$GODOT" --path "$APP" 9>&- >/tmp/cove-godot.log 2>&1 &
STARTUP_COMPLETE=true
exec 9>&-
echo "warm reload done: kitty restarted (new code), ${#SESSIONS[@]} termling(s) reattached."
