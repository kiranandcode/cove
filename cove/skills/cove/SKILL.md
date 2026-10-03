---
name: cove
description: Work inside the Cove, the user's board of live terminals ("termlings"). Use when you're running in a Cove termling (COVE=1) and want to tell the user your status, name your own termling, put yourself in a frame, keep your own notes or todo lists on the board, or look up other termlings, or orchestrate child termlings (spawn agents into frames, type into them, wait for them, screenshot the board). Agents never move the user's termlings or change focus; the user arranges the board.
---
# The Cove

The Cove is the user's board of live terminals. Each terminal is a **termling**
that sits on a tldraw-style board next to the user's frames, boxes, text and
arrows. **The user owns the layout and their attention.** You never move
their termlings, change focus, or drive the camera. The exception is termlings
*you* spawned (see Orchestrating). You describe yourself, and the
Cove decides how to show it.

The `cove` MCP server is already registered. Everything acts on your own
termling, identified by `$COVE_SESSION` (its abduco session, which survives
kitty restarts).

## Am I in the Cove?

A shell inside the Cove has `COVE=1` and `COVE_SESSION=cove-<n>`. Call
**`whoami`** to get your termling record (id, session, name, frame, cwd), or an
error if you aren't in one.

## Looking around (read-only)

- **`list_terminals`**: every termling (id, session, name, agent, busy, the frame
  it's in as `container`, cwd, project, title) plus the board's frames
  (`zones`: id, name, rect).
- **`board(mine?)`**: the shapes on the board. `mine=true` returns only yours.
- **`find(query)`**: rank termlings by a natural-language description ("the one
  running the tests"). It returns matches and never changes focus.

## Telling the user how you're doing

- **`status(state, summary?)`**: `needs_you`, `blocked` or `done` puts a "!"
  badge on your termling and queues you for the user's attention. If the user
  isn't focused on anything, focus jumps to you; otherwise you wait in a queue,
  and focus comes to you when they leave their current termling. Call it once;
  don't repeat it. `working` clears it.
- The Stop/Notification hooks already ping when you finish or wait for input.
  Use `status` for something more specific ("blocked: need the API key").

## Describing yourself

- **`rename(name)`**: name your own termling, e.g. `auth-refactor`. Only do it
  when a name helps the user; nothing requires it.
- **`join_frame(frame)`** / **`leave_frame()`**: put your own termling into an
  existing frame (by name or shape id from `list_terminals` `zones`), or take it
  out. Frames often share names like "rectangle", so prefer the id. Only
  yourself: you can't place other termlings.

## Your notes on the board

You can keep your own shapes on the board, placed next to your termling. By
default only you (and the user) can change them; todo owners may grant other
termlings incremental checklist access.

- **`add_note(type, text?, items?, color?)`**: `type` is `note`, `todo` or `text`.
  A `todo` with `items` makes a checklist, which is good for showing your plan.
  Returns the shape id.
- **`update_note(id, ...)`**: change one of your shapes. A shared todo editor may
  only `add_items`, `check`, `uncheck` or `remove`; the owner retains title,
  full-list, style, layout and deletion control.
- **`share_todo(id, editors)`**: owner-only; replace a todo's editors with live
  termlings resolved to stable sessions. An empty list revokes shared access.
  Shared editors should address items by exact text, since concurrent changes
  can shift numeric indices.
- **`link(to, from?, text?)`**: an arrow from one of your shapes (or `me`, your
  termling) to a termling id or shape id.
- **`add_link(url)`**: a bookmark card for a link (title, preview image,
  favicon), next to your termling. For a GitHub PR or issue the card shows its
  live state (open / draft / merged / closed) and +/- lines, so when you open a
  PR, put its link on the board. `board` shows the card's `title` and `github`
  state.
- **`delete_notes(ids)`**: remove shapes you own.

Keep it tidy: update one todo list as you go rather than adding new notes, and
delete your notes when the work is done if they're no longer useful.

## Orchestrating child termlings

You can spawn agents as termlings instead of hidden subagents, so the user can
watch every one on the board and step in. You own what you spawn (and what they
spawn); only those can you drive. `cove-team` is the general workflow (tasks →
frames → termlings → steer); `iterate-pr` is the PR version.

- **`spawn(name, frame?, cwd?, command?, prompt?, link?, link_text?)`**:
  a new termling in `frame` (with no frame, it gets a small frame of its own in
  free space beside you), with a dashed grey arrow from your termling to it. `command` runs in
  its shell, e.g. `claude` (a claude child is shift+tabbed into auto mode unless
  `auto_mode=false`), and its folder-trust dialog is accepted when `cwd` is your
  own repo or a worktree of it (otherwise `trust_prompt: true`: ask the user).
  `prompt` becomes that agent's first message. Returns
  `{id, session, rect, zone}`.
- **`send(to, text?, enter?, keys?)`**: type into a child. Multi-line text is
  pasted, then Enter. `keys=["ctrl+c"]` / `["escape"]` for single keys.
- **`read(id, lines?, all?)`**: any termling's screen text.
- **`wait(ids?, mode?, timeout?)`**: block until a child ends a turn (its Stop
  hook), needs input (Notification), `report`s, or exits, counting only what
  happened since your last `send`. Returns the event, reports and screen tail.
  `timed_out` means call it again.
- **`report(text, state?)`**: a child tells its parent how it went. Lead with
  the verdict (`APPROVED: …`).
- **`children`**: your descendants (alive, frame, last event) and reports.
- **`place(id, frame? | pos?, teleport?)`** / **`kill(id)`**: move a child into
  a frame; close it (and its descendants and your arrow to it).

Laying out: **`add_frame(title, w, h, x?, y?, near?, inside?)`** draws a titled
frame you own, in free space when you omit x/y (`inside` nests it in another
frame). **`find_space(w, h, near?, inside?)`** finds room without placing
anything. **`screenshot(target?)`** returns a PNG of a termling, a shape or
frame, an `[x,y,w,h]` world rect, or the user's `view`, without moving their
camera. Look after you lay things out, and fix overlaps with
`update_note(id, x, y, w, h)`. A termling's screen is about 330×185 world units,
and its crew stand below it, so a frame for three side by side is about 1300×480.

No strays: every child goes in a frame, and you kill children whose job is done.

## Notes

- Commands carry a request id. If the Cove confirms, you get `confirmed: true`,
  and errors (unknown shape, not yours) come back as tool errors. An older Cove
  answers `confirmed: false`; re-read `board` / `list_terminals` to check.
- No-op if the Cove isn't running: reads return an empty world and self
  actions error with "not inside a Cove termling".
