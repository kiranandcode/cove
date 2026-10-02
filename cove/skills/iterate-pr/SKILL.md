---
name: iterate-pr
description: Drive a pull request to approval inside the Cove, with each agent as a visible termling on the board. A fresh reviewer termling reviews the PR; if it finds issues it fixes them and pushes; then it's closed and a new reviewer takes a fresh look, until one approves. Also fans out over several PRs, one child orchestrator per PR in its own frame. Use when asked to iterate on, review-until-approved, or babysit a PR (or a list of PRs) in the Cove, or when a parent termling hands you "iterate-pr".
---

# iterate-pr: review → fix → fresh review, as termlings

You're running in a Cove termling (`COVE=1`). You orchestrate; you don't review
or edit code yourself. Everything you spawn shows up on the user's board so they
can watch the loop and step into any termling. The tools are the `cove` MCP
server's; the `cove` skill describes them.

## Inputs

- One PR (`123`, `#123` or a URL) or several. The repo is your cwd unless told
  otherwise.
- Optional: `frame` (a frame id your parent made for you), `max_rounds` (default
  5), any review focus the user asked for.

Several PRs? Go to **Fan out** below. One PR: carry on.

## 1. Lay out your frame

1. `whoami`: your `rect` is one termling's size (about 330×185 world units; its
   crew and shadow need about as much again underneath).
2. No frame from your parent? `add_frame(title="PR #123 · <PR title>", w=1300,
   h=480, near="me")`. It holds three termlings side by side.
   Then `join_frame` it yourself, so you and your reviewers sit together.
3. `add_link(url)` with the PR URL, so its live state card sits next to you.
4. `add_note(type="todo", text="PR #123 rounds", items=[])`: one line per round
   (`r1: 3 issues → fixed`). Update it as you go.
5. `screenshot(target=<frame id>)` and look. Nothing overlapping, all inside?
   If not, move your own shapes with `update_note(id, x, y, w, h)` and look again.

## 2. A worktree for the PR

Reviewers push fixes, so they need the PR's branch checked out somewhere that
isn't the user's working copy:

```
git fetch origin
git worktree add --detach ../<repo>-pr-123 && (cd ../<repo>-pr-123 && gh pr checkout 123)
```

Reuse it if it already exists (`git -C ../<repo>-pr-123 pull`).

## 3. The loop (round k = 1..max_rounds)

Keep the prompts short, as the user would type them.
Each round deliberately uses fresh context, an exception to normal child reuse.
Never overlap successive reviewers: preserve and close one before starting the
next.
Every `kill` below must return `ok: true`. On a partial failure, reconcile its
`killed`, `failed` and `retained` entries with `children`, set `status(blocked,
...)`, and stop; never start the next round with the prior subtree still live.
If it returns `cleanup_error`, owned board artifacts for sessions in `killed`
still need cleanup before the round is complete; `failed` and `retained` did not
close.

1. Spawn a fresh reviewer (no memory of earlier rounds):
   `spawn(name="review #123 r<k>", frame=<your frame>, cwd=<worktree>,
   command="claude", prompt="Please review <PR url>", link_text="r<k>")`.
2. `wait(ids=[reviewer])` until its turn ends, then `read(reviewer, lines=200)`
   to see the review. Process any `finished` entry even when the result also says
   `timed_out: true`. If it's stuck on a question or a permission prompt, answer
   it with `send` if you can. Otherwise `status(needs_you, ...)` and wait again.
   (If `spawn` returned `trust_prompt: true`, the user has to accept the folder
   first: `status(needs_you, ...)`.)
3. Judge the review yourself:
   - **No issues** (it says approve / LGTM): record the result, audit its
     descendant subtree, `kill` the live reviewer by id or finalize an exited
     reviewer by session, and go to **Finish**.
   - **Issues**: `send(to=reviewer, text="Please fix these issues and update the PR")`,
     then `wait` and `read` to confirm it pushed.
     - Were any issues **major** (bugs, broken behaviour, missing tests for
       real logic, design problems)? Another round is needed: record the round,
       audit its subtree, `kill` it, then go to round k+1.
     - All **minor**, and the reviewer said it should be approved once they're
       fixed? Record the result, audit its subtree, `kill` it, and go to
       **Finish**. No further round.
4. Tick the round on your todo each time (`r1: 2 major → fixed`).
5. After `max_rounds` still with major issues: `status(needs_you, "#123 still
   has major issues after N rounds")` and stop.

If a reviewer can't fix something, leave it up only for user action or
inspection, name it and the next action, and set `status(blocked, ...)`. Do not
claim approval while a reviewer is blocked or intentionally retained.

## 4. Finish

- Run a final `children` audit. An approved PR has no live reviewer or pending
  exited lineage; finalize `alive: false` records with `kill(session)`. Preserve
  and name any blocked reviewer intentionally retained for the user.
- If you have a parent (`whoami.parent`), call `report(state="done", ...)` as
  your last state-changing action: `APPROVED: #123 after <k> rounds`. Otherwise
  finish with `status(done, "#123 approved after <k> rounds")`.
- Leave your frame, todo and link on the board; the user clears them. Leave the
  worktree too, unless the user asked you to clean up.

## Fan out: several PRs

You're the top orchestrator. Each PR gets its own child orchestrator, which runs
this skill for that PR in a frame you give it.

1. `gh pr view <n> --json title,url` for each, to get titles.
2. One group frame for the lot: `add_frame(title="PR sweep · <date>",
   w=1450, h=40 + 540·N, near="me")`, then one frame per PR **inside** it:
   `add_frame(title="PR #n · <title>", w=1300, h=480, inside=<group id>)`.
   `find_space` keeps them from overlapping. `screenshot(target=<group id>)` to
   check, and fix with `update_note`.
3. For each PR: `spawn(name="iterate #n", frame=<its frame>, command="claude",
   prompt="/iterate-pr <PR url> (frame <frame id>)")`. The arrows
   follow who spawned whom: yours go to each orchestrator, and each
   orchestrator's go to its reviewers.
4. `add_note(type="todo", text="PR sweep", items=["#n …", ...])` next to you.
5. Loop `wait(mode="any")`, processing every `finished` entry even on a partial
   timeout. On each final report, preserve the result, tick its item, audit the
   orchestrator's subtree, and kill a successful completed orchestrator,
   requiring `ok: true`. Keep a blocked or explicitly retained subtree alive
   and name the reason and next action. Once all PRs are resolved, run a final
   `children` audit and then finish with the parent-aware status/report ordering
   above and a one-line summary per PR.

## Rules

- Only drive your own children. The user's other termlings are off limits.
- Every termling you spawn goes in a frame. No strays: if one ends up outside
  (check `children` / `screenshot`), `place` it back.
- Kill live reviewers by id and finalize exited reviewers by session once their
  round is over and their subtree is clear. A blocked review or explicit user
  request is the exception: leave it for inspection and say so in `status`.
