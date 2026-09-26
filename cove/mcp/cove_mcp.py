#!/usr/bin/env python3
"""Cove MCP server (zero-dependency, stdio JSON-RPC).

What an agent may do in the Cove. The user owns space and attention: agents
never move the user's termlings, change focus or drive the camera. An agent can
read the world, describe itself (name, status), put ITSELF into a frame on the
board, and keep its OWN notes, todos, frames and arrows on the board.

Orchestration: an agent may also spawn CHILD termlings (spawn), and those it
owns (its descendants) it may drive: type into them (send), read their screen
(read), wait for their turn to end (wait), move them between its frames
(place) and close them (kill). A child reports back with report(). Lineage is
keyed on abduco sessions in ~/.local/state/cove/lineage.json, so it survives
kitty and Godot restarts. Everything is keyed on
the termling's abduco session ($COVE_SESSION, exported by cove-shell.sh), which
survives kitty restarts, unlike kitty window ids.

Reads $KITTY_COVE_DIR/state.json and board.json (written by Godot). Writes
commands.jsonl (board / assign / rename) and notify.jsonl (status), each line
tagged with a "req" id; Godot answers in replies.jsonl.

Register in ~/.claude.json under mcpServers, e.g.:
  "cove": {"command": "python3",
           "args": ["/Users/.../kitty/cove/mcp/cove_mcp.py"]}
"""
import sys, json, os, re, time, uuid, random, signal, base64, subprocess, shlex
import cove_find  # sibling module: semantic terminal resolver

DIR = os.environ.get("KITTY_COVE_DIR", "/tmp/cove")
STATE = os.path.join(DIR, "state.json")
BOARD = os.path.join(DIR, "board.json")
CMDS = os.path.join(DIR, "commands.jsonl")
NOTIFY = os.path.join(DIR, "notify.jsonl")
REPLIES = os.path.join(DIR, "replies.jsonl")
REPLY_WAIT = 1.5   # seconds to wait for Godot to confirm a command

EVENTS = os.path.join(DIR, "events")   # <session>.jsonl: that agent's Stop/Notification hooks
MAIL = os.path.join(DIR, "mail")       # <session>.jsonl: report()s from its children
SHOTS = os.path.join(DIR, "shots")
LINEAGE = os.path.expanduser("~/.local/state/cove/lineage.json")
HERE = os.path.dirname(os.path.abspath(__file__))
GAP = 40.0   # clearance find_space keeps around everything already on the board

STATUSES = ["working", "needs_you", "blocked", "done"]
NOTE_TYPES = ["note", "todo", "text"]


def _load(path, default):
    # Retry briefly: an older Cove rewrites its files in place, so a read can
    # land mid-write and fail to parse.
    for attempt in range(5):
        try:
            with open(path) as f:
                return json.load(f)
        except FileNotFoundError:
            return default
        except Exception:
            time.sleep(0.05)
    return default


def read_state():
    return _load(STATE, {"terminals": [], "camera": [0, 0, 1], "focused": -1})


def read_board():
    return _load(BOARD, {"shapes": []})


def my_session():
    return os.environ.get("COVE_SESSION", "")


def me():
    """This agent's own termling record: by session, else by kitty pane id."""
    terms = read_state().get("terminals", [])
    sess = my_session()
    if sess:
        for t in terms:
            if t.get("session") == sess:
                return t
    # Our kitty window id, but only if it's from the kitty running now (kitty
    # sets KITTY_PID in each window's env): after a restart the id we were born
    # with belongs to another termling, and acting as it misroutes everything.
    pane = os.environ.get("KITTY_WINDOW_ID", "")
    if pane.isdigit() and os.environ.get("KITTY_PID", "") == _kitty_pid() != "":
        for t in terms:
            if t.get("pane_id") == int(pane):
                return t
    return None


def require_me():
    t = me()
    if t is None:
        raise ValueError("not inside a Cove termling (no match for COVE_SESSION / "
                         "KITTY_WINDOW_ID in state.json; is the Cove running?)")
    return t


def _append(path, obj):
    os.makedirs(DIR, exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(obj) + "\n")


def _await_reply(req):
    deadline = time.time() + REPLY_WAIT
    while time.time() < deadline:
        try:
            with open(REPLIES) as f:
                for line in f:
                    try:
                        r = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(r, dict) and r.get("req") == req:
                        return r
        except OSError:
            pass
        time.sleep(0.1)
    return None


def send(path, obj):
    """Queue a line for Godot and return its answer. A Cove build that doesn't
    write replies yet gets {"ok": true, "confirmed": false}."""
    req = uuid.uuid4().hex[:12]
    _append(path, dict(obj, req=req, session=my_session()))
    r = _await_reply(req)
    if r is None:
        return {"ok": True, "confirmed": False}
    if not r.get("ok", False):
        raise ValueError(r.get("error") or "the Cove rejected the command")
    return dict(r, confirmed=True)


def _shape(shape_id):
    for s in read_board().get("shapes", []):
        if s.get("id") == shape_id:
            return s
    return None


def require_own(shape_id):
    """Agents may only change shapes they created (owner == their session)."""
    sess = my_session()
    if not sess:
        raise ValueError("no COVE_SESSION: can't prove ownership of board shapes")
    s = _shape(shape_id)
    if s is None:
        # Just created and not mirrored to board.json yet: our ids carry our session.
        if str(shape_id).startswith(sess + "."):
            return
        raise ValueError("no shape %r on the board" % shape_id)
    if s.get("owner") != sess:
        raise ValueError("shape %r isn't yours; you can only change shapes you created" % shape_id)


def _frames():
    """Containers the user has on the board: [{id, name, type, rect}]."""
    return read_state().get("zones", [])


def _endpoint(v, me_rec):
    """An arrow end: "me" -> my termling id, digits -> termling id, else a shape id."""
    if v in (None, "", "me"):
        return int(me_rec["id"])
    if isinstance(v, int) or str(v).isdigit():
        return int(v)
    return str(v)


# --- orchestration: child termlings --------------------------------------------

def _dev_env():
    env = {}
    try:
        with open(os.path.join(DIR, "dev-env")) as f:
            for line in f:
                k, _, v = line.strip().partition("=")
                if k:
                    env[k] = v
    except OSError:
        pass
    return env


def _kitty_pid():
    """The running Cove kitty's pid. Kitty window ids are only meaningful within
    one kitty: a restart renumbers every window, so an id recorded under an
    earlier kitty now names some other termling."""
    pid = _dev_env().get("COVE_KITTY_PID", "")
    if not pid:
        try:
            with open(os.path.join(DIR, "kitty.pid")) as f:
                pid = f.read().strip()
        except OSError:
            pass
    return pid


def _kitten(*args, timeout=15):
    env = _dev_env()
    kitten = env.get("COVE_KITTEN") or os.path.join(
        HERE, "..", "..", "kitty", "launcher", "kitty.app", "Contents", "MacOS", "kitten")
    sock = env.get("COVE_KITTY_SOCKET") or "unix:/tmp/cove-kitty"
    r = subprocess.run([kitten, "@", "--to", sock] + list(args),
                       capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise ValueError("kitten @ %s failed: %s" % (args[0], (r.stderr or r.stdout).strip()[:300]))
    return r.stdout


def read_lineage():
    return _load(LINEAGE, {})


def write_lineage(d):
    os.makedirs(os.path.dirname(LINEAGE), exist_ok=True)
    tmp = LINEAGE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=1)
    os.replace(tmp, LINEAGE)


def _is_descendant(sess, ancestor, lin=None):
    lin = lin if lin is not None else read_lineage()
    seen = set()
    while sess and sess not in seen:
        seen.add(sess)
        parent = (lin.get(sess) or {}).get("parent")
        if parent == ancestor:
            return True
        sess = parent
    return False


def _terms(lin=None):
    """state.json's terminals, with spawned children's sessions filled in from
    lineage. Godot learns a pane's session from a background poll, which can
    lag (a minute, when the Cove is busy); spawn already knows the pane, so a
    child never goes blank and orphaned in the meantime."""
    terms = read_state().get("terminals", [])
    if any(not t.get("session") for t in terms):
        lin = lin if lin is not None else read_lineage()
        # Only panes recorded under the running kitty: a restart renumbers them.
        kp = _kitty_pid()
        by_pane = {r.get("pane"): s for s, r in lin.items()
                   if r.get("pane") and not r.get("dead") and kp and str(r.get("kitty", "")) == kp}
        for t in terms:
            if not t.get("session") and t.get("pane_id") in by_pane:
                t["session"] = by_pane[t["pane_id"]]
    return terms


def _term(ref):
    """A termling by id, kitty pane id, session or name."""
    terms = _terms()
    r = str(ref)
    for key in ("id", "session", "name", "pane_id"):
        for t in terms:
            if str(t.get(key, "")) == r and r != "":
                return t
    return None


def require_child(ref):
    """A termling this agent spawned (or one of their descendants)."""
    t = _term(ref)
    if t is None:
        raise ValueError("no termling %r (by id, session or name)" % ref)
    sess = my_session()
    if not sess or not _is_descendant(t.get("session", ""), sess):
        raise ValueError("termling %r isn't one you spawned; you can only drive your own children" % ref)
    return t


def _events(sess):
    try:
        with open(os.path.join(EVENTS, sess + ".jsonl")) as f:
            return [json.loads(l) for l in f if l.strip()]
    except (OSError, ValueError):
        return []


def _mail(sess):
    try:
        with open(os.path.join(MAIL, sess + ".jsonl")) as f:
            return [json.loads(l) for l in f if l.strip()]
    except (OSError, ValueError):
        return []


def _screen(t, lines=60, everything=False):
    out = _kitten("get-text", "--match", "id:%d" % int(t["pane_id"]),
                  "--extent", "all" if everything else "screen")
    rows = [r.rstrip() for r in out.rstrip().split("\n")]
    rows = [r for i, r in enumerate(rows) if r or (i and rows[i - 1])]   # squeeze blank runs
    return "\n".join(rows[-max(1, int(lines)):])


def _type(t, text, enter):
    m = ["--match", "id:%d" % int(t["pane_id"])]
    if text:
        # auto: bracketed paste when the program asked for it (Claude Code, zsh),
        # so newlines inside the text don't submit early.
        _kitten("send-text", *m, "--bracketed-paste=auto", "--", text)
    if enter:
        if text:
            time.sleep(0.6)   # let a TUI finish taking the paste before Enter
        _kitten("send-text", *m, "--", "\r")


def _git_common(path):
    r = subprocess.run(["git", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def _same_project(child_cwd, parent_cwd):
    """The child works in the spawner's own folder, beneath it, or in a git
    worktree of the same repo: somewhere the spawner already runs trusted."""
    if not parent_cwd:
        return False
    c, p = os.path.realpath(child_cwd), os.path.realpath(parent_cwd)
    if c == p or c.startswith(p + os.sep):
        return True
    gc, gp = _git_common(c), _git_common(p)
    return gc is not None and gc == gp


def _settle_claude(t, trust_ok, auto, timeout=25.0):
    """Get a fresh Claude Code child to its prompt: answer the folder-trust
    dialog when trust_ok, then shift+tab into auto mode (as the user does) until
    its footer says so. Returns {auto_mode, trust_prompt}."""
    m = ["--match", "id:%d" % int(t["pane_id"])]
    deadline = time.time() + timeout
    presses = 0
    out = {"auto_mode": False, "trust_prompt": False}
    while time.time() < deadline:
        try:
            scr = _screen(t, 30).lower()
        except ValueError:
            scr = ""
        foot = "\n".join(scr.split("\n")[-6:])
        if "trust this folder" in scr or "trust the files" in scr:
            if not trust_ok:
                out["trust_prompt"] = True   # the spawner's own repo only; the user decides the rest
                return out
            # The cursor starts on "No, exit": move it to "Yes, I trust this
            # folder" and only press Enter once it's there.
            sel = next((l for l in scr.split("\n") if "\u276f" in l), "")
            if "yes" in sel:
                _kitten("send-text", *m, "--", "\r")
                time.sleep(1.5)
            else:
                _kitten("send-key", *m, "down")
                time.sleep(0.4)
            continue
        if not auto:
            return out
        if "auto mode on" in foot:
            out["auto_mode"] = True
            return out
        # the footer shows the mode line once the TUI is up ("shift+tab to cycle")
        if "shift+tab" in foot or "? for shortcuts" in foot or "mode on" in foot:
            if presses >= 6:
                return out
            _kitten("send-key", *m, "shift+tab")
            presses += 1
            time.sleep(0.5)
        else:
            time.sleep(0.5)
    return out


def _mark_sent(sess):
    """Waits look for hook events after this point."""
    lin = read_lineage()
    if sess in lin:
        lin[sess]["seen"] = len(_events(sess))
        write_lineage(lin)


def _wait_for_pane(pane, session, zone, timeout=15.0):
    """The new termling once it's on the board, placed, and its session known."""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        for t in read_state().get("terminals", []):
            if int(t.get("pane_id", -1)) == pane and t.get("rect"):
                last = t
                if t.get("session") == session and (not zone or t.get("container") == zone):
                    return t
        time.sleep(0.2)
    return last


def _pids_of_session(sess):
    """(abduco master pid, [descendant pids]) for an abduco session."""
    out = subprocess.run(["/bin/ps", "-Ao", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    procs, kids = {}, {}
    for line in out.splitlines():
        sp = line.split(None, 2)
        if len(sp) < 3:
            continue
        pid, ppid = int(sp[0]), int(sp[1])
        procs[pid] = sp[2]
        kids.setdefault(ppid, []).append(pid)
    for pid, cmd in procs.items():
        if "abduco" in cmd and re.search(r"(^|\s)%s(\s|$)" % re.escape(sess), cmd) and kids.get(pid):
            desc, q = [], list(kids[pid])
            while q:
                c = q.pop()
                desc.append(c)
                q.extend(kids.get(c, []))
            return pid, desc
    return None, []


def _kill_session(sess):
    master, desc = _pids_of_session(sess)
    if master is None:
        return False
    for sig in (signal.SIGHUP, signal.SIGTERM):
        for p in desc:
            try:
                os.kill(p, sig)
            except OSError:
                pass
        time.sleep(0.8)
        if _pids_of_session(sess)[0] is None:
            return True
    for p in desc + [master]:
        try:
            os.kill(p, signal.SIGKILL)
        except OSError:
            pass
    return True


# --- board geometry: where things are, and where there's room --------------------

def _shape_rect(s):
    if s.get("type") == "arrow":
        return None
    try:
        return [float(s["x"]), float(s["y"]), float(s.get("w", 0)), float(s.get("h", 0))]
    except (KeyError, TypeError, ValueError):
        return None


def _overlaps(a, b, gap=0.0):
    return not (a[0] + a[2] + gap <= b[0] or b[0] + b[2] + gap <= a[0] or
                a[1] + a[3] + gap <= b[1] or b[1] + b[3] + gap <= a[1])


def _contains(outer, inner):
    return (outer[0] <= inner[0] and outer[1] <= inner[1] and
            inner[0] + inner[2] <= outer[0] + outer[2] and inner[1] + inner[3] <= outer[1] + outer[3])


def _container_rect(ref):
    for z in _frames():
        if z.get("id") == ref or z.get("name") == ref:
            return z["id"], [float(v) for v in z["rect"]]
    raise ValueError("no frame %r on the board" % ref)


def _anchor_rect(near):
    """What find_space should stay close to: a termling, a shape, or [x,y]."""
    if near in (None, "", "me"):
        t = me()
        return t.get("rect") if t else None
    if isinstance(near, list) and len(near) >= 2:
        return [float(near[0]), float(near[1]), 0.0, 0.0]
    t = _term(near)
    if t is not None:
        return t.get("rect")
    for s in read_board().get("shapes", []):
        if s.get("id") == near:
            return _shape_rect(s)
    for z in _frames():
        if z.get("name") == near:
            return z["rect"]
    return None


def find_space(w, h, near=None, inside=None, exclude=()):
    """Top-left of a w x h rect that overlaps nothing on the board (termlings,
    shapes; frames that would contain it don't count), as close to `near` as
    possible. inside: keep it within that frame."""
    w, h = float(w), float(h)
    bound = None
    skip = set(exclude)
    if inside:
        fid, bound = _container_rect(inside)
        skip.add(fid)
    obstacles = []
    for s in read_board().get("shapes", []):
        r = _shape_rect(s)
        if r and s.get("id") not in skip and r[2] > 0 and r[3] > 0:
            obstacles.append((r, s.get("type") == "frame" or s.get("geo") is not None))
    for t in read_state().get("terminals", []):
        if t.get("rect") and t.get("id") not in skip and t.get("session") not in skip:
            r = [float(v) for v in t["rect"]]
            r[3] *= 1.6   # its crew and shadow stand below the screen
            obstacles.append((r, False))
    a = _anchor_rect(near) if near is not None or not bound else None
    if a is None and bound:
        a = [bound[0], bound[1], 0, 0]
    if a is None:
        v = read_state().get("view", [0, 0, 0, 0])
        a = [v[0] + v[2] / 2, v[1] + v[3] / 2, 0, 0]
    ax, ay = a[0] + a[2] / 2.0, a[1] + a[3] / 2.0

    def free(x, y):
        c = [x, y, w, h]
        if bound and not _contains([bound[0] + GAP / 2, bound[1] + GAP, bound[2] - GAP, bound[3] - GAP * 1.5], c):
            return False
        for r, is_box in obstacles:
            if is_box and _contains(r, c):
                continue   # sitting inside a bigger frame is fine
            if _overlaps(c, r, GAP):
                return False
        return True

    step = 40.0
    best = None
    for ring in range(0, 120):
        rad = ring * step
        cands = []
        if ring == 0:
            cands = [(0.0, 0.0)]
        else:
            n = max(8, int(2 * 3.1416 * rad / step))
            import math
            cands = [(math.cos(2 * math.pi * i / n) * rad, math.sin(2 * math.pi * i / n) * rad) for i in range(n)]
        for dx, dy in cands:
            # candidates are centres around the anchor
            x, y = ax + dx - w / 2, ay + dy - h / 2
            if bound is None and a[2] > 0 and _overlaps([x, y, w, h], a, GAP):
                continue
            if free(x, y):
                d = dx * dx + dy * dy
                if best is None or d < best[0]:
                    best = (d, x, y)
        if best is not None:
            break
    if best is None:
        raise ValueError("no free %dx%d space found%s" % (w, h, " inside that frame (make it bigger)" if bound else ""))
    return {"x": round(best[1], 1), "y": round(best[2], 1), "w": w, "h": h}


def screenshot(target=None, pad=80.0, max_px=1600):
    """PNG of a world rect (a termling, a shape/frame, [x,y,w,h]) or the user's view."""
    rect = None
    if isinstance(target, list) and len(target) == 4:
        rect = [float(v) for v in target]
    elif target not in (None, "", "view"):
        t = _term(target)
        if t is not None and t.get("rect"):
            rect = [float(v) for v in t["rect"]]
        else:
            s = next((s for s in read_board().get("shapes", []) if s.get("id") == target), None)
            if s is None:
                s = next((z for z in _frames() if z.get("name") == target), None)
                rect = [float(v) for v in s["rect"]] if s else None
            else:
                rect = _shape_rect(s)
                if rect is None:   # an arrow: frame its two ends
                    (x0, y0), (x1, y1) = s.get("a", [0, 0]), s.get("b", [0, 0])
                    rect = [min(x0, x1), min(y0, y1), abs(x1 - x0), abs(y1 - y0)]
        if rect is None:
            raise ValueError("nothing called %r to photograph" % target)
    if rect is not None:
        rect = [rect[0] - pad, rect[1] - pad, rect[2] + 2 * pad, rect[3] + 2 * pad]
    os.makedirs(SHOTS, exist_ok=True)
    path = os.path.join(SHOTS, uuid.uuid4().hex[:10] + ".png")
    send(CMDS, {"cmd": "screenshot", "path": path, "rect": rect, "max": int(max_px)})
    deadline = time.time() + 8
    while time.time() < deadline:
        if os.path.exists(path) and os.path.getsize(path) > 0:
            time.sleep(0.15)   # let the write finish
            with open(path, "rb") as f:
                data = f.read()
            os.remove(path)
            return data, rect
        time.sleep(0.1)
    raise ValueError("the Cove didn't produce a screenshot (is it running a build with the screenshot command?)")


class Image:
    def __init__(self, png, meta):
        self.png, self.meta = png, meta


TOOLS = [
    {"name": "whoami",
     "description": "Your own termling: id, session, name, frame (container), agent, position. Errors if you're not running inside the Cove.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "list_terminals",
     "description": "Every termling in the Cove: id, session, name, agent (claude/codex/muse/opencode/shell), busy/attention, the frame it belongs to (container), cwd, project, title. Also the board's frames ('zones': id, name, rect). Read-only.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "board",
     "description": "Read the shapes on the Cove's board: the user's frames, boxes, text and arrows, plus agents' notes. mine=true returns only the shapes you own. Read-only.",
     "inputSchema": {"type": "object", "properties": {"mine": {"type": "boolean"}}}},
    {"name": "find",
     "description": "Find the termling(s) matching a natural-language description of what they're doing, e.g. 'the agent working on the auth refactor', 'the one running the tests'. Ranks termlings over their name, agent, title, project, last event and cwd. Returns {id, why, ranked:[{id,why}], source}. Doesn't change the user's focus.",
     "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}},
    {"name": "status",
     "description": "Tell the user how your work stands. needs_you, blocked and done put a '!' badge on your termling and queue you for the user's attention: focus jumps to you as soon as they're free, so you don't need to repeat it. working clears it. The Stop/Notification hooks already ping when you finish or wait for input; use this for anything more specific. summary: one short line.",
     "inputSchema": {"type": "object", "properties": {
         "state": {"type": "string", "enum": STATUSES}, "summary": {"type": "string"}},
         "required": ["state"]}},
    {"name": "rename",
     "description": "Name your own termling (shown on its nameplate), e.g. 'auth-refactor', 'tests'. Empty resets to the default. You can only name yourself.",
     "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}},
    {"name": "join_frame",
     "description": "Put your own termling into an existing frame on the board, by the frame's name or shape id (see list_terminals 'zones'). It walks over, stays inside, and moves when the frame moves. Only for yourself: the user arranges everyone else.",
     "inputSchema": {"type": "object", "properties": {"frame": {"type": "string"}}, "required": ["frame"]}},
    {"name": "leave_frame",
     "description": "Take your own termling out of its frame onto open ground.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "add_note",
     "description": "Put a note, todo list or text label on the board next to your termling, e.g. your plan as a todo list. You own it: only you (and the user) can change it. Returns its id for update_note/link/delete_notes.",
     "inputSchema": {"type": "object", "properties": {
         "type": {"type": "string", "enum": NOTE_TYPES},
         "text": {"type": "string"},
         "items": {"type": "array", "items": {"type": "string"}, "description": "todo items (type=todo)"},
         "color": {"type": "string"}},
         "required": ["type"]}},
    {"name": "add_link",
     "description": "Put a link on the board next to your termling as a bookmark card (title, preview image, favicon), as pasting a URL into tldraw does. GitHub pull requests and issues show their live state (open/draft/merged/closed) and +/- lines, re-checked every few minutes, so this is the way to hand the user a PR you opened. You own the card (delete it with delete_notes). Returns its id.",
     "inputSchema": {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}},
    {"name": "update_note",
     "description": "Change one of your own board shapes: replace text/color/items, append add_items, check/uncheck/remove a todo item (by index or text), or move/resize it (x, y, w, h).",
     "inputSchema": {"type": "object", "properties": {
         "id": {"type": "string"}, "text": {"type": "string"}, "color": {"type": "string"},
         "x": {"type": "number"}, "y": {"type": "number"}, "w": {"type": "number"}, "h": {"type": "number"},
         "items": {"type": "array", "items": {"type": "string"}},
         "add_items": {"type": "array", "items": {"type": "string"}},
         "check": {}, "uncheck": {}, "remove": {}},
         "required": ["id"]}},
    {"name": "link",
     "description": "Draw an arrow from one of your own shapes, one of your children, or 'me' (your termling) to a termling (its id) or a board shape (its id). The arrow is yours. dash: draw (default) / solid / dashed / dotted.",
     "inputSchema": {"type": "object", "properties": {
         "from": {"type": "string"}, "to": {"type": "string"}, "text": {"type": "string"},
         "dash": {"type": "string"}, "color": {"type": "string"}},
         "required": ["to"]}},
    {"name": "add_frame",
     "description": "Draw a titled frame on the board (a box that holds termlings, e.g. one per PR). Omit x/y and it's put in free space near `near` (default: you) or inside the frame `inside`, clear of everything already on the board. Sizes are world units; a default termling is roughly the size of your own 'rect' in whoami, so leave room for it plus its notes. You own the frame (move/resize it with update_note x/y/w/h). Returns {id, rect}.",
     "inputSchema": {"type": "object", "properties": {
         "title": {"type": "string"}, "w": {"type": "number"}, "h": {"type": "number"},
         "x": {"type": "number"}, "y": {"type": "number"},
         "near": {"description": "termling id/name, shape id, or [x,y]"},
         "inside": {"type": "string", "description": "frame id or name to nest this frame in"},
         "color": {"type": "string"}, "dash": {"type": "string", "enum": ["draw", "solid", "dashed", "dotted"]}},
         "required": ["title", "w", "h"]}},
    {"name": "find_space",
     "description": "Where a w x h rect fits on the board without overlapping termlings or shapes: nearest free spot to `near` (default you), optionally within a frame (`inside`). Returns {x, y, w, h}. Read-only.",
     "inputSchema": {"type": "object", "properties": {
         "w": {"type": "number"}, "h": {"type": "number"}, "near": {}, "inside": {"type": "string"}},
         "required": ["w", "h"]}},
    {"name": "screenshot",
     "description": "Look at the board: returns a PNG of a termling (id/name), a shape or frame (id/name), an [x,y,w,h] world rect, or 'view' (what the user's window shows, the default). Renders off to the side without moving the user's camera. Use it to check your layout before and after placing things.",
     "inputSchema": {"type": "object", "properties": {
         "target": {}, "pad": {"type": "number"}, "max_px": {"type": "number"}}}},
    {"name": "spawn",
     "description": "Spawn a CHILD termling (a new terminal) that you own, placed in a frame (`frame`, id or name) or, without one, in a small frame of its own in free space next to you, with a dashed arrow from your termling to it (link=false to skip). A claude child's folder-trust dialog is accepted when cwd is in your own repo (or a worktree of it); otherwise the result has trust_prompt=true for the user to answer. command runs in its shell (e.g. 'claude'; a claude child is shift+tabbed into auto mode unless auto_mode=false); prompt (with a claude/codex command) becomes the agent's first message. host (e.g. 'kirans-macbook-pro') runs the child's shell/command on that Mac through cove-remote instead: same path as cwd there, native scrollback, survives dropped links and this Mac sleeping, and the remote session keeps running if the termling closes (see the cove-remote skill). Returns {id, session, pane_id, rect, zone}. Then use send / read / wait / place / kill on it. Children can spawn their own children.",
     "inputSchema": {"type": "object", "properties": {
         "name": {"type": "string"}, "frame": {"type": "string"}, "cwd": {"type": "string"},
         "command": {"type": "string"}, "prompt": {"type": "string"},
         "host": {"type": "string", "description": "run it on this ssh host via cove-remote (e.g. kirans-macbook-pro)"},
         "auto_mode": {"type": "boolean", "description": "claude children: shift+tab into auto mode (default true)"},
         "link": {"type": "boolean"},
         "link_text": {"type": "string"}},
         "required": ["name"]}},
    {"name": "children",
     "description": "Your spawned termlings (and their descendants): id, session, name, parent, frame, agent, alive, last hook event, and any report() messages they've sent you.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "send",
     "description": "Type into one of YOUR children: text, then Enter (enter=false to leave it unsubmitted). Works for a shell or an agent's prompt (multi-line text is pasted). Use keys=['ctrl+c'] / ['escape'] etc. for single keys instead of text.",
     "inputSchema": {"type": "object", "properties": {
         "to": {"type": "string"}, "text": {"type": "string"}, "enter": {"type": "boolean"},
         "keys": {"type": "array", "items": {"type": "string"}}},
         "required": ["to"]}},
    {"name": "read",
     "description": "Read a termling's screen text: the last `lines` lines of its screen (all=true: include scrollback). Read-only; works on any termling.",
     "inputSchema": {"type": "object", "properties": {
         "id": {"type": "string"}, "lines": {"type": "number"}, "all": {"type": "boolean"}},
         "required": ["id"]}},
    {"name": "wait",
     "description": "Block until one (mode 'any', default) or all (mode 'all') of your children finish a turn since you last sent them something (their Stop hook), need input (Notification), report() to you, or exit. Returns per child: event, reports, and its screen tail. Times out after `timeout` seconds (default 900) with timed_out=true; just call it again.",
     "inputSchema": {"type": "object", "properties": {
         "ids": {"type": "array", "items": {"type": "string"}, "description": "default: all your live children"},
         "mode": {"type": "string", "enum": ["any", "all"]}, "timeout": {"type": "number"},
         "lines": {"type": "number", "description": "screen lines to include (default 40)"}}}},
    {"name": "report",
     "description": "Tell the agent that spawned you how it went (only if you were spawned by another agent; see whoami 'parent'). Lands in its wait()/children(). Put the verdict first, e.g. 'APPROVED: ...' or 'CHANGES_REQUESTED: ...'.",
     "inputSchema": {"type": "object", "properties": {
         "text": {"type": "string"}, "state": {"type": "string", "enum": ["done", "failed", "progress"]}},
         "required": ["text"]}},
    {"name": "place",
     "description": "Move one of YOUR children into one of the board's frames (walks over; teleport=true drops it there) or to a point [x,y].",
     "inputSchema": {"type": "object", "properties": {
         "id": {"type": "string"}, "frame": {"type": "string"}, "pos": {"type": "array", "items": {"type": "number"}},
         "teleport": {"type": "boolean"}},
         "required": ["id"]}},
    {"name": "kill",
     "description": "Close one of YOUR children: ends its shell and agent and removes its termling (and its descendants, and the arrows you drew to it).",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]}},
    {"name": "delete_notes",
     "description": "Delete board shapes you own, by id.",
     "inputSchema": {"type": "object", "properties": {
         "ids": {"type": "array", "items": {"type": "string"}}}, "required": ["ids"]}},
]


def _arrow(t, src, dst, text=None, dash=None, color=None):
    sess = my_session()
    sid = "%s.%s" % (sess or "agent", uuid.uuid4().hex[:6])
    cmd = {"cmd": "board", "op": "add", "type": "arrow", "id": sid, "owner": sess,
           "from": _endpoint(src, t), "to": _endpoint(dst, t)}
    for k, v in (("text", text), ("dash", dash), ("color", color)):
        if v:
            cmd[k] = v
    return dict(send(CMDS, cmd), id=sid)


def _child_view(sess, rec, terms_by_sess):
    t = terms_by_sess.get(sess)
    ev = _events(sess)
    return {"session": sess, "name": rec.get("name"), "parent": rec.get("parent"),
            "alive": t is not None or _pids_of_session(sess)[0] is not None,
            "id": t.get("id") if t else None,
            "frame": t.get("zone") if t else None, "agent": t.get("agent") if t else None,
            "last_event": ev[-1]["event"] if ev else None,
            "new_events": len(ev) - int(rec.get("seen", 0))}


def call_tool(name, args):
    if name == "whoami":
        t = me()
        if not t:
            return {"error": "not inside a Cove termling",
                    "session": my_session(), "pane": os.environ.get("KITTY_WINDOW_ID")}
        lin = read_lineage()
        kids = [s for s, r in lin.items() if r.get("parent") == my_session() and not r.get("dead")]
        return dict(t, parent=(lin.get(my_session()) or {}).get("parent") or os.environ.get("COVE_PARENT"),
                    children=kids)
    if name == "list_terminals":
        st = read_state()
        return {"terminals": st.get("terminals", []), "zones": st.get("zones", []),
                "you": (me() or {}).get("id")}
    if name == "board":
        shapes = read_board().get("shapes", [])
        if args.get("mine"):
            shapes = [s for s in shapes if s.get("owner") == my_session()]
        return {"shapes": shapes}
    if name == "find":
        return cove_find.find(args["query"])

    if name == "status":
        state = str(args["state"])
        if state not in STATUSES:
            raise ValueError("state must be one of " + ", ".join(STATUSES))
        t = require_me()
        cwd = str(t.get("cwd", ""))
        return send(NOTIFY, {"ts": int(time.time()), "pane": t.get("pane_id"), "event": state,
                             "summary": str(args.get("summary", "")), "cwd": cwd,
                             "project": os.path.basename(cwd)})
    if name == "rename":
        t = require_me()
        return send(CMDS, {"cmd": "rename", "id": t["id"], "name": str(args["name"])})
    if name == "join_frame":
        t = require_me()
        want = str(args["frame"])
        hit = next((z for z in _frames() if z.get("id") == want or z.get("name") == want), None)
        if hit is None:
            names = ["%s (%s)" % (z.get("name") or "unnamed", z.get("id")) for z in _frames()]
            raise ValueError("no frame %r on the board; frames (name (id)): %s" % (want, ", ".join(names)))
        return send(CMDS, {"cmd": "assign", "id": t["id"], "zone": hit.get("name") or hit.get("id")})
    if name == "leave_frame":
        t = require_me()
        return send(CMDS, {"cmd": "assign", "id": t["id"], "zone": ""})

    if name == "add_note":
        t = require_me()
        sess = my_session()
        if not sess:
            raise ValueError("no COVE_SESSION: board shapes need an owner")
        kind = str(args["type"])
        if kind not in NOTE_TYPES:
            raise ValueError("type must be one of " + ", ".join(NOTE_TYPES))
        sid = "%s.%s" % (sess, uuid.uuid4().hex[:6])
        cmd = {"cmd": "board", "op": "add", "type": kind, "id": sid, "near": t["id"], "owner": sess}
        for k in ("text", "items", "color"):
            if k in args:
                cmd[k] = args[k]
        return dict(send(CMDS, cmd), id=sid)
    if name == "add_link":
        t = require_me()
        sess = my_session()
        if not sess:
            raise ValueError("no COVE_SESSION: board shapes need an owner")
        url = str(args["url"]).strip()
        if not re.match(r"^https?://\S+$", url):
            raise ValueError("url must be an http(s) URL")
        sid = "%s.%s" % (sess, uuid.uuid4().hex[:6])
        cmd = {"cmd": "board", "op": "add", "type": "bookmark", "id": sid, "near": t["id"],
               "owner": sess, "url": url}
        return dict(send(CMDS, cmd), id=sid)
    if name == "update_note":
        require_own(args["id"])
        cmd = {"cmd": "board", "op": "update", "id": args["id"]}
        for k in ("text", "color", "items", "add_items", "check", "uncheck", "remove", "x", "y", "w", "h"):
            if k in args:
                cmd[k] = args[k]
        return send(CMDS, cmd)
    if name == "link":
        t = require_me()
        sess = my_session()
        src = args.get("from", "me")
        if src not in (None, "", "me"):
            if _term(src) is not None:
                src = require_child(src)["id"]
            else:
                require_own(src)
        return _arrow(t, src, args["to"], args.get("text"), args.get("dash"), args.get("color"))
    if name == "find_space":
        return find_space(args["w"], args["h"], args.get("near"), args.get("inside"))
    if name == "add_frame":
        t = require_me()
        sess = my_session()
        if not sess:
            raise ValueError("no COVE_SESSION: board shapes need an owner")
        if "x" in args and "y" in args:
            spot = {"x": float(args["x"]), "y": float(args["y"])}
        else:
            spot = find_space(args["w"], args["h"], args.get("near"), args.get("inside"))
        sid = "%s.%s" % (sess, uuid.uuid4().hex[:6])
        cmd = {"cmd": "board", "op": "add", "type": "frame", "id": sid, "owner": sess,
               "text": str(args["title"]), "x": spot["x"], "y": spot["y"],
               "w": float(args["w"]), "h": float(args["h"])}
        for k in ("color", "dash"):
            if k in args:
                cmd[k] = args[k]
        r = send(CMDS, cmd)
        return dict(r, id=sid, rect=[spot["x"], spot["y"], float(args["w"]), float(args["h"])])
    if name == "screenshot":
        png, rect = screenshot(args.get("target"), float(args.get("pad", 80)), int(args.get("max_px", 1600)))
        return Image(png, {"rect": rect or read_state().get("view")})

    if name == "spawn":
        t = require_me()
        sess = my_session()
        if not sess:
            raise ValueError("no COVE_SESSION: a child needs an owner")
        child = "cove-%d" % random.randint(100000000, 999999999)
        cwd = os.path.expanduser(str(args.get("cwd") or t.get("cwd") or os.getcwd()))
        zone, pos, own_frame = "", None, None
        if args.get("frame"):
            zone, _ = _container_rect(str(args["frame"]))
        else:
            # No frame: give it a small one of its own in free space beside you.
            # A loose termling wanders off onto whatever's nearby.
            mine = t.get("rect") or [0, 0, 330, 185]
            fw, fh = round(mine[2] * 1.8), round(mine[3] * 2.4)
            spot = find_space(fw, fh, near="me")
            zone = "%s.%s" % (sess, uuid.uuid4().hex[:6])
            send(CMDS, {"cmd": "board", "op": "add", "type": "frame", "id": zone, "owner": sess,
                        "text": str(args["name"]), "x": spot["x"], "y": spot["y"], "w": fw, "h": fh,
                        "color": "grey"})
            own_frame = zone
        wrapper = os.path.join(HERE, "..", "cove-shell.sh")
        out = _kitten("launch", "--type=os-window", "--cwd", cwd,
                      "--env", "COVE_SPAWN_SESSION=" + child, "--env", "COVE_PARENT=" + sess,
                      os.path.abspath(wrapper))
        try:
            pane = int(out.strip().splitlines()[-1])
        except (ValueError, IndexError):
            raise ValueError("kitten launch didn't return a window id: %r" % out)
        send(CMDS, {"cmd": "spawn_place", "pane": pane, "zone": zone, "pos": pos,
                    "name": str(args["name"])})
        lin = read_lineage()
        lin[child] = {"parent": sess, "name": str(args["name"]), "created": int(time.time()), "seen": 0,
                      "pane": pane, "kitty": _kitty_pid()}
        if own_frame:
            lin[child]["frame"] = own_frame   # made for it: kill removes it too
        write_lineage(lin)
        ct = _wait_for_pane(pane, child, zone)
        if ct is None:
            raise ValueError("launched window %d but it never showed up on the board" % pane)
        res = {"id": ct["id"], "session": child, "pane_id": pane, "rect": ct.get("rect"),
               "zone": ct.get("zone"), "cwd": cwd}
        if args.get("link", True):   # always from the spawner's own termling
            res["arrow"] = _arrow(t, "me", ct["id"], args.get("link_text"), "dashed", "grey")["id"]
            lin = read_lineage()
            lin[child]["arrow"] = res["arrow"]
            write_lineage(lin)
        command = str(args.get("command") or "").strip()
        if args.get("prompt"):
            if not command:
                raise ValueError("prompt needs a command to hand it to (e.g. 'claude')")
            os.makedirs(os.path.join(DIR, "prompts"), exist_ok=True)
            pf = os.path.join(DIR, "prompts", child + ".md")
            with open(pf, "w") as f:
                f.write(str(args["prompt"]))
            command += ' "$(cat %s)"' % pf
        host = str(args.get("host") or "").strip()
        inner = command
        if host:
            # The local shell expands $(cat prompt) before cove-remote quotes it
            # into the remote command line, so the prompt file needn't exist there.
            remote = os.path.abspath(os.path.join(HERE, "..", "bin", "cove-remote"))
            command = "%s attach --cwd %s %s" % (shlex.quote(remote), shlex.quote(cwd), shlex.quote(host))
            if inner:
                command += " -- " + inner
            res["host"] = host
            lin = read_lineage()
            lin[child]["host"] = host   # kill ends the remote session too
            write_lineage(lin)
        if command:
            time.sleep(0.8)   # let the shell draw its prompt
            _type(ct, command, True)
            _mark_sent(child)
            res["typed"] = command
            if re.match(r"^\s*claude\b", inner):
                res.update(_settle_claude(ct, _same_project(cwd, t.get("cwd", "")),
                                          bool(args.get("auto_mode", True))))
                if res["trust_prompt"]:
                    res["note"] = ("it's asking whether to trust %s, outside your repo; that's the "
                                   "user's call: status(needs_you, ...) and wait" % cwd)
        return res
    if name == "children":
        sess = my_session()
        lin = read_lineage()
        by = {t.get("session"): t for t in _terms(lin) if t.get("session")}
        kids = [_child_view(s, r, by) for s, r in lin.items()
                if not r.get("dead") and _is_descendant(s, sess, lin)]
        return {"children": kids, "reports": _mail(sess)}
    if name == "send":
        c = require_child(args["to"])
        for k in args.get("keys") or []:
            _kitten("send-key", "--match", "id:%d" % int(c["pane_id"]), str(k))
        text = str(args.get("text") or "")
        if text or not args.get("keys"):
            _type(c, text, bool(args.get("enter", True)))
        _mark_sent(c["session"])
        return {"ok": True, "to": c.get("session") or c["id"], "id": c["id"]}   # session first: ids change on kitty restarts
    if name == "read":
        c = _term(args["id"])
        if c is None:
            raise ValueError("no termling %r" % args["id"])
        return {"id": c["id"], "name": c.get("name"),
                "screen": _screen(c, int(args.get("lines", 60)), bool(args.get("all", False)))}
    if name == "report":
        sess = my_session()
        parent = (read_lineage().get(sess) or {}).get("parent") or os.environ.get("COVE_PARENT")
        if not parent:
            raise ValueError("no parent: you weren't spawned by another agent")
        os.makedirs(MAIL, exist_ok=True)
        t = me() or {}
        _append(os.path.join(MAIL, parent + ".jsonl"),
                {"ts": int(time.time()), "from": sess, "id": t.get("id"), "name": t.get("name"),
                 "state": str(args.get("state", "done")), "text": str(args["text"])})
        return {"ok": True, "to": parent}
    if name == "wait":
        sess = my_session()
        lin = read_lineage()
        if args.get("ids"):
            targets = [require_child(i)["session"] for i in args["ids"]]
        else:
            live = {t.get("session") for t in _terms(lin)}
            targets = [s for s, r in lin.items() if r.get("parent") == sess and not r.get("dead") and s in live]
        if not targets:
            return {"error": "no live children to wait for"}
        mode = args.get("mode", "any")
        timeout = min(float(args.get("timeout", 900)), 3600.0)
        lines = int(args.get("lines", 40))
        mail0 = len(_mail(sess))
        deadline = time.time() + timeout
        while True:
            lin = read_lineage()
            live = {t.get("session"): t for t in _terms(lin)}
            mail = _mail(sess)[mail0:]
            done = {}
            for s in targets:
                ev = _events(s)[int((lin.get(s) or {}).get("seen", 0)):]
                reps = [m for m in mail if m.get("from") == s]
                if s not in live and _pids_of_session(s)[0] is None:
                    # Gone for real: its abduco session has ended. (Missing from
                    # state.json alone isn't enough: right after a reload the Cove
                    # hasn't relearned sessions yet.)
                    done[s] = {"event": "exited"}
                elif reps or ev:
                    done[s] = {"event": ev[-1]["event"] if ev else "report"}
                if s in done:
                    done[s]["reports"] = reps
                    done[s]["name"] = (lin.get(s) or {}).get("name")
            if (mode == "any" and done) or (mode == "all" and len(done) == len(targets)) or time.time() > deadline:
                for s, d in done.items():
                    if s in live:
                        d["id"] = live[s]["id"]
                        try:
                            d["screen"] = _screen(live[s], lines)
                        except ValueError as e:
                            d["screen"] = "(unreadable: %s)" % e
                    _mark_sent(s)   # consumed: the next wait looks past these
                return {"finished": done, "timed_out": not done or (mode == "all" and len(done) < len(targets)),
                        "still_running": [s for s in targets if s not in done]}
            time.sleep(1.0)
    if name == "place":
        c = require_child(args["id"])
        cmd = {"cmd": "place", "id": c["id"], "teleport": bool(args.get("teleport", False))}
        if args.get("frame"):
            cmd["zone"] = _container_rect(str(args["frame"]))[0]
        if args.get("pos"):
            cmd["pos"] = args["pos"]
        return send(CMDS, cmd)
    if name == "kill":
        c = require_child(args["id"])
        lin = read_lineage()
        victims = [c["session"]] + [s for s in lin if _is_descendant(s, c["session"], lin)]
        arrows = []
        for s in victims:
            if (lin.get(s) or {}).get("host"):
                # Closing the termling only detaches cove-remote; end the session.
                try:
                    subprocess.run([os.path.join(HERE, "..", "bin", "cove-remote"), "kill",
                                    lin[s]["host"], s], capture_output=True, timeout=15)
                except (OSError, subprocess.SubprocessError):
                    pass
            _kill_session(s)
            if s in lin:
                lin[s]["dead"] = int(time.time())
                for k in ("arrow", "frame"):
                    if lin[s].get(k):
                        arrows.append(lin[s][k])
        write_lineage(lin)
        # Everything that belonged to the killed termlings goes: the arrow and
        # frame we made for each (keyed by its owner's session: ours for the
        # child, the child's for its own children), plus any arrow still tied to
        # one of them. Only deleting ids with *our* prefix left the child's
        # arrows to its children dangling on the board.
        owners = tuple(s + "." for s in [my_session()] + victims)
        gone = {"term:" + s for s in victims}
        ids = [a for a in arrows if str(a).startswith(owners)]
        for sh in read_board().get("shapes", []):
            if sh.get("type") == "arrow" and (sh.get("bind_a") in gone or sh.get("bind_b") in gone):
                ids.append(str(sh["id"]))
        ids = sorted(set(ids))
        if ids:
            try:
                send(CMDS, {"cmd": "board", "op": "delete", "ids": ids})
            except ValueError:
                pass
        return {"ok": True, "killed": victims}

    if name == "delete_notes":
        ids = [str(i) for i in args["ids"]]
        for i in ids:
            require_own(i)
        return send(CMDS, {"cmd": "board", "op": "delete", "ids": ids})
    raise ValueError("unknown tool: " + str(name))


def reply(rid, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}) + "\n")
    sys.stdout.flush()


def reply_error(rid, code, msg):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": msg}}) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            continue
        method = req.get("method")
        rid = req.get("id")
        if method == "initialize":
            reply(rid, {"protocolVersion": "2024-11-05",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "cove", "version": "0.3.0"}})
        elif method == "tools/list":
            reply(rid, {"tools": TOOLS})
        elif method == "tools/call":
            params = req.get("params", {})
            try:
                result = call_tool(params.get("name"), params.get("arguments", {}) or {})
                if isinstance(result, Image):
                    reply(rid, {"content": [
                        {"type": "image", "data": base64.b64encode(result.png).decode(), "mimeType": "image/png"},
                        {"type": "text", "text": json.dumps(result.meta)}]})
                else:
                    reply(rid, {"content": [{"type": "text", "text": json.dumps(result)}]})
            except Exception as e:
                reply(rid, {"content": [{"type": "text", "text": "error: " + str(e)}], "isError": True})
        elif method and method.startswith("notifications/"):
            pass  # notifications get no response
        elif rid is not None:
            reply_error(rid, -32601, "method not found: " + str(method))


if __name__ == "__main__":
    main()
