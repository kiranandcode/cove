#!/usr/bin/env bash
# Quit the Cove (both Godot and the detached kitty).
DIR="/tmp/cove"
pkill -if 'godot --path' 2>/dev/null || true
# Kill the cove-kitty via pid file + ps scan (macOS `pkill -f` can't see its args).
[ -f "$DIR/kitty.pid" ] && kill "$(cat "$DIR/kitty.pid" 2>/dev/null)" 2>/dev/null || true
for _p in $(ps -Ao pid=,command= | awk '/[l]auncher\/kitty --title cove/ {print $1}'); do
    kill "$_p" 2>/dev/null || true
done
# Full stop: also tear down the abduco sessions holding the termling shells
# (reload-kitty.sh keeps these; stop.sh is the "quit everything" path). Killing
# each master SIGHUPs its shell + agents, so nothing lingers detached.
for _p in $(ps -Ao pid=,command= | awk '/[a]bduco.*cove-/ {print $1}'); do
    kill "$_p" 2>/dev/null || true
done
# An intended full stop: nothing for cove-recover.py to bring back next start.
pkill -f 'cove-recover.py watch' 2>/dev/null || true
python3 "$(dirname "$0")/cove-recover.py" snapshot --clear 2>/dev/null || true
echo "Cove stopped."
