#!/bin/bash
# SessionStart hook: tells an agent that starts inside a Cove termling what it
# may do there. Informational only -- it asks for nothing at startup. The user
# owns the Cove's layout and focus; agents describe themselves and keep their
# own notes. Only fires inside the cove ($COVE, set by cove/dev.sh / run.sh).

[ -n "$COVE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
SESS="${COVE_SESSION:-unknown}"

# Remember which Claude session runs in this termling, so cove-recover.py can
# `claude --resume` it after a reboot. Fires on startup, resume, /clear and
# compact, so the newest id always wins.
INPUT=$(cat)
case "$SESS" in
cove-[0-9]*)
	AGENTS="$HOME/.local/state/cove/agents"
	mkdir -p "$AGENTS"
	printf '%s' "$INPUT" | jq -c --arg now "$(date +%s)" \
		'{agent: "claude", id: .session_id, cwd: .cwd, source: .source, time: ($now | tonumber)}' \
		> "$AGENTS/$SESS.json.tmp" 2>/dev/null && mv "$AGENTS/$SESS.json.tmp" "$AGENTS/$SESS.json"
	;;
esac

MSG="You're running inside a Cove termling (session ${SESS}): your terminal is one of
several on the user's board. The user arranges the board and decides focus; you
never move the user's termlings or change focus. The 'cove' MCP tools, for when they help:
- status(state, summary): needs_you / blocked / done badges your termling and
  queues you for the user's attention; working clears it. (The Stop/Notification
  hooks already ping when you finish or wait for input.)
- rename(name): name your own termling. join_frame(frame) / leave_frame(): put
  yourself in (or out of) a frame on the board.
- add_note / update_note / link / delete_notes: your own notes, todo lists and
  arrows on the board, placed next to you.
- whoami, list_terminals, board, find: look around (read-only). look(where):
  a screenshot + full shapes for one region, a summary of the rest, and lint.
- run(code): code mode, a Python script against the board API for anything
  more than a shape or two (diagrams, layouts); lands as one undo step.
- spawn / send / read / wait / kill / place, add_frame, screenshot: orchestrate
  child agents as termlings you own (see the cove and iterate-pr skills).
  If you were spawned by another agent (whoami 'parent'), report() to it.
Nothing is required at startup."

jq -cn --arg m "$MSG" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
