---
name: cove-team
description: Run a team of agents as termlings on the Cove board. Split work into tasks, give each task a frame and a fresh termling with a short prompt, wait for whichever finishes, follow up or close it, and track progress on a todo. Use in a Cove termling (COVE=1) when asked to "spawn N termlings", fan work out over files/items/ideas, run agents in parallel where the user can watch them, or get fresh eyes on something. iterate-pr is the PR-specific version.
---

# cove-team: a team of termlings

You're the lead, running in a Cove termling. You split the work, lay out the
board, spawn one termling per task, and steer them with short messages. The
user watches every termling and can step into any of them. The tools are the
`cove` MCP server's (see the `cove` skill).

## 1. Tasks

Turn the request into a list of tasks, each one line:

- "one per X" (files, PRs, modules, bugs, papers): one task per item. Get the
  list with a shell command (`ls`, `rg -l`, `gh issue list`) so none are
  missed.
- "N termlings on Y" (brainstorm, attempts, reviews): N copies of the same
  task. For variety, give each a different angle or constraint in one clause.
- Fresh eyes on something: one task.

Keep it to at most 8 at once, and choose a lower number when that is all you can
actively supervise. Queue the rest and spawn them as others finish.

Tasks that edit the same repo in parallel each get their own git worktree:
`git worktree add --detach ../<repo>-<slug>`. Read-only tasks share your cwd.

## 2. Board

1. `whoami`. A termling is about 330×185 world units, with its crew below.
   One task frame is 620×460.
2. A group frame for the team: `add_frame(title="<team name>", w=40+660·cols,
   h=80+500·rows, near="me")`, with cols = min(4, tasks) and
   rows = ceil(tasks / cols).
3. One frame per task inside it: `add_frame(title="<task, a few words>", w=620,
   h=460, inside=<group id>)`.
4. `add_note(type="todo", text="<team name>", items=[<one per task>])` next to
   you.
5. `screenshot(target=<group id>)`. Fix any overlap with `update_note(id, x, y,
   w, h)` before spawning.

## 3. Spawn

For each task: `spawn(name="<unique short name>", frame=<its frame>, cwd=<its dir>,
command="claude", prompt=<prompt>)`.

Write the prompt the way the user types: one or two plain sentences with the
task and any link or path. Leave out any output format and anything about the
Cove. Examples: "Please review src/parser.rs", "Find why test_login flakes",
"Sketch three ways to cache the board renderer".

Each termling owns an ongoing task. Run ordinary setup and patch commands in
your own terminal; do not create a new shell termling for each command. If a
separate helper shell is truly needed, reuse one for that workstream and kill it
as soon as the command or observable job ends.

## 4. Steer

Loop on `wait(mode="any")`. Process every entry in `finished`, even when the
same result has `timed_out: true`; those events and reports are already consumed.

- **Turn ended**: `read(id, lines=200)` and judge it.
  - Done and good: replace its todo item with
    `<task> — <one-line outcome>`, check it, and preserve the result. Reconcile
    `children`; if its subtree has no active or retained work, `kill` the live
    child by id or finalize an exited child by session, requiring `ok: true`.
    Spawn the next queued task only after closure is confirmed.
  - Needs more: `send` one short follow-up ("Please also cover X", "Please fix
    that and commit").
  - Went wrong: preserve anything useful, audit its subtree, then `kill` it and
    require `ok: true` before respawning with a sharper prompt. Once only. After
    that, leave it up for user action or inspection and
    `status(blocked, "<task>: <why>")`.
- **Asking a question or a permission prompt**: answer it with `send` if the
  answer is in the task. Otherwise `status(needs_you, "<task> asks …")` and keep
  waiting on the others.
- **Timed out**: after processing any `finished` entries, wait again on
  `still_running`.
- **`trust_prompt: true` from spawn**: the user accepts the folder.
  `status(needs_you, ...)`.

After every state-changing wait or change of direction, call `children` and
reconcile the set with the todo. `alive: false` means the termling exited; call
`kill(session)` to finalize its owned board artifacts and lineage. Never kill a
child lead while its subtree contains active or retained work.
If `kill` returns `ok: false`, process its `killed`, `failed` and `retained`
entries and reconcile `children`. `cleanup_error` means owned board artifacts
for sessions in `killed` still need cleanup; it does not close `failed` or
`retained`. Do not reuse the frame or claim successful completion while either
live work or cleanup remains.

## 5. Finish

When the todo is all ticked:

- Call `children` once more. Preserve unique work, kill every completed live
  child, and finalize every exited child by session, except one the user
  explicitly asked to retain. Do not kill an ancestor of blocked or retained
  work. Name every retained child, reason and next action in the handoff. Verify
  every cleanup returned `ok: true`; otherwise the team is blocked, not
  complete. A worktree may remain after its termling is closed.
- Combine the results in your own reply (a table or a short list, one line per
  task). For N-copies tasks, merge them: say where they agree and pick the
  strongest.
- If you have a parent, call `report(state="done", ...)` as your last
  state-changing action. Otherwise finish with `status(done, "<one line>")`.
- Leave the completed team frames and todo for the user to clear; this
  team-specific handoff overrides the base skill's optional note cleanup.
  Remove worktrees only when their work is merged or not needed.

## Rules

- Every termling goes in a frame, and every unretained completed child is killed
  or finalized by session. No strays.
- A successful completion report leaves no completed team child alive unless
  the user explicitly asked to retain it. Unrelated and user-owned termlings
  remain untouched.
- No duplicate live task termlings and no idle prompt-only shells. A live child
  must have a named current purpose visible to the lead.
- Only drive your own children.
- A task that is itself a team can go to a child lead: spawn it with "Use
  cove-team: <task>" and it builds its own frames inside the one you gave it.
  Its arrows go to its own team.
