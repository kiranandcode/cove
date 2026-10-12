"""The spatial harness: how an agent sees and works the Cove's board.

After tldraw's "Harnessing the agents" (tldraw.dev/blog/harnessing-the-agents):

- look: context scoped to a region. Full shape data and a screenshot for what's
  inside it, a cheap overview of everything else (frames with their counts,
  compact shapes), and where the user is looking. Pull more by looking again.
- lint: the board's own warnings, e.g. two notes overlapping, a note covering a
  termling, a shape hanging off a frame's edge, an arrow whose end is gone.
  Every board-editing tool also lints what it just changed.
- run: code mode. Python against a live board API instead of one tool call per
  shape; everything it changes lands as one batch, so the user undoes it with
  one Cmd+Z and a failing script changes nothing.

Agents still only change shapes they own (the same rule as update_note), and
Godot outlines whatever an agent looks at or edits with its name (presence).

The functions take the cove_mcp module as `m`, for its board/state readers.
"""
import contextlib, io, json, math, os, signal, traceback, uuid

TEXTY = {"note", "text", "todo", "bookmark", "image", "file", "files", "calendar", "reminders"}
CONTAINERS = {"frame"}
COMPACT_MAX = 60          # beyond this many outside shapes, summarise by frame
RUN_TIMEOUT = 20          # seconds a run() script may take
CREW = 1.6                # a termling's crew and shadow stand below its screen


# --- geometry -------------------------------------------------------------------

def rect_of(s):
    """World [x, y, w, h] of a shape (arrows and lines by their points), or None."""
    if all(k in s for k in ("x", "y", "w", "h")):
        try:
            return [float(s["x"]), float(s["y"]), float(s["w"]), float(s["h"])]
        except (TypeError, ValueError):
            return None
    pts = []
    for k in ("a", "b"):
        if isinstance(s.get(k), list) and len(s[k]) >= 2:
            pts.append(s[k])
    for p in s.get("points") or s.get("pts") or []:
        if isinstance(p, list) and len(p) >= 2:
            pts.append(p)
    if not pts:
        return None
    xs, ys = [float(p[0]) for p in pts], [float(p[1]) for p in pts]
    return [min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)]


def inter(a, b, slack=0.0):
    """Do a and b overlap by more than `slack` in both directions?"""
    return (min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]) > slack and
            min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]) > slack)


def contains(o, i, slack=0.5):
    return (o[0] - slack <= i[0] and o[1] - slack <= i[1] and
            i[0] + i[2] <= o[0] + o[2] + slack and i[1] + i[3] <= o[1] + o[3] + slack)


def grow(r, d):
    return [r[0] - d, r[1] - d, r[2] + 2 * d, r[3] + 2 * d]


def union(rs):
    rs = [r for r in rs if r]
    if not rs:
        return None
    x0, y0 = min(r[0] for r in rs), min(r[1] for r in rs)
    x1, y1 = max(r[0] + r[2] for r in rs), max(r[1] + r[3] for r in rs)
    return [x0, y0, x1 - x0, y1 - y0]


def rnd(r):
    return [round(v) for v in r] if r else None


def label(s, n=40):
    t = str(s.get("text") or s.get("title") or s.get("url") or s.get("path") or "")
    if not t and s.get("items"):
        t = "; ".join(str(i.get("text", "")) for i in s["items"][:3])
    t = " ".join(t.split())
    return t if len(t) <= n else t[: n - 1] + "…"


def kind(s):
    return s.get("geo") or s.get("type")


def term_rect(t, with_crew=False):
    r = t.get("rect")
    if not r:
        return None
    r = [float(v) for v in r]
    if with_crew:
        r[3] *= CREW
    return r


# --- where: resolve a region ----------------------------------------------------

def resolve_region(m, where, shapes, terms):
    """[x,y,w,h] for "me" (your frame, else you and your shapes), "view" (the
    user's window), a frame/shape id or name, a termling id/name, or a rect."""
    if isinstance(where, list) and len(where) == 4:
        return [float(v) for v in where], "rect"
    if where in (None, "", "me"):
        t = m.me()
        if t is None:
            return resolve_region(m, "view", shapes, terms)
        fr = next((s for s in shapes if s.get("id") == t.get("container")), None)
        if fr and rect_of(fr):
            return grow(rect_of(fr), 40), "your frame %s" % (fr.get("text") or fr["id"])
        sess = m.my_session()
        mine = [rect_of(s) for s in shapes if sess and s.get("owner") == sess]
        r = union([term_rect(t, True)] + mine)
        return grow(r, 250), "you and your shapes"
    if where == "view":
        return [float(v) for v in m.read_state().get("view", [0, 0, 1600, 1000])], "the user's view"
    for s in shapes:
        if s.get("id") == where or (s.get("type") in ("frame", "geo") and s.get("text") == where):
            r = rect_of(s)
            if r:
                return grow(r, 40), "%s %s" % (kind(s), label(s) or s["id"])
    t = m._term(where)
    if t is not None and t.get("rect"):
        return grow(term_rect(t, True), 200), "termling %s" % (t.get("name") or t["id"])
    raise ValueError("nothing called %r to look at: give 'me', 'view', a frame/shape id or name, "
                     "a termling id/name, or [x, y, w, h]" % (where,))


# --- lint -------------------------------------------------------------------------

def lint(m, shapes, terms, focus=None, region=None):
    """Problems on the board. focus: only issues touching these shape ids.
    region: only shapes meeting this rect. Each issue: {kind, ids, msg, yours}."""
    sess = m.my_session()
    by = {s.get("id"): s for s in shapes}
    live_sessions = {t.get("session") for t in terms if t.get("session")}
    live_ids = {str(t.get("id")) for t in terms}
    rects = {s["id"]: rect_of(s) for s in shapes if s.get("id")}

    def relevant(s):
        r = rects.get(s.get("id"))
        if focus is not None:
            return s.get("id") in focus
        return r is not None and (region is None or inter(r, region))

    def yours(*ids):
        return bool(sess) and any((by.get(i) or {}).get("owner") == sess or str(i).startswith(sess + ".")
                                  for i in ids)

    issues, seen = [], set()

    def add(kind_, ids, msg):
        key = (kind_,) + tuple(sorted(ids))
        if key not in seen:
            seen.add(key)
            issues.append({"kind": kind_, "ids": list(ids), "msg": msg, "yours": yours(*ids)})

    subjects = [s for s in shapes if relevant(s)]
    for s in subjects:
        sid, r, ty = s.get("id"), rects.get(s.get("id")), s.get("type")
        if ty == "arrow":
            for end in ("bind_a", "bind_b"):
                ref = str(s.get(end) or "")
                if not ref:
                    continue
                if ref.startswith("term:") and ref[5:] not in live_sessions:
                    add("dangling_arrow", [sid], "arrow %s points at termling %s, which is gone" % (sid, ref[5:]))
                elif ref.startswith("term#") and ref[5:] not in live_ids:
                    add("dangling_arrow", [sid], "arrow %s points at a termling that is gone" % sid)
                elif not ref.startswith(("term", "anchor:")) and ref not in by:
                    add("dangling_arrow", [sid], "arrow %s points at shape %s, which is gone" % (sid, ref))
            continue
        if r is None or r[2] <= 0 or r[3] <= 0 or ty in ("line", "draw", "highlight"):
            continue
        # 1. overlapping content: text-ish shapes on top of each other.
        for o in shapes:
            oid = o.get("id")
            if oid == sid or o.get("type") in ("arrow", "line", "draw", "highlight") or o.get("type") in CONTAINERS:
                continue
            orr = rects.get(oid)
            if not orr or not inter(r, orr, 4.0):
                continue
            a_geo, b_geo = ty == "geo", o.get("type") == "geo"
            if ty in CONTAINERS or (a_geo != b_geo):
                continue   # text on or around a box is how people label boxes
            if a_geo and (contains(r, orr) or contains(orr, r)):
                continue   # a box nested in a box
            if not a_geo and not (ty in TEXTY and o.get("type") in TEXTY):
                continue
            add("overlap", [sid, oid], "%s %s '%s' overlaps %s %s '%s'" % (
                kind(s), sid, label(s, 24), kind(o), oid, label(o, 24)))
        # 2. covering a termling's screen or crew.
        if ty not in CONTAINERS:
            for t in terms:
                tr = term_rect(t, True)
                # A box drawn around a termling is its zone, not clutter on it.
                if tr and inter(r, tr, 4.0) and not contains(r, term_rect(t)):
                    add("covers_termling", [sid], "%s %s '%s' covers termling %s (%s)" % (
                        kind(s), sid, label(s, 24), t.get("name") or t.get("id"), t.get("id")))
        # 3. hanging off a frame's edge: half in, half out.
        for f in shapes:
            if f.get("type") not in CONTAINERS or f.get("id") == sid:
                continue
            fr = rects.get(f.get("id"))
            if fr and inter(r, fr, 4.0) and not contains(fr, r) and not contains(r, fr):
                add("straddles_frame", [sid, f["id"]], "%s %s '%s' hangs off the edge of frame %s '%s'" % (
                    kind(s), sid, label(s, 24), f["id"], label(f, 24)))
    return issues


def lint_after(m, touched_shapes, extra_ids=()):
    """Lint the shapes a command just changed, using the post-change shapes Godot
    returned (board.json lags by ~0.4 s) over the rest of board.json."""
    fresh = {s["id"]: s for s in touched_shapes or [] if isinstance(s, dict) and s.get("id")}
    ids = set(fresh) | set(extra_ids)
    if not ids:
        return []
    shapes = [s for s in m.read_board().get("shapes", []) if s.get("id") not in fresh] + list(fresh.values())
    return lint(m, shapes, m.read_state().get("terminals", []), focus=ids)


# --- look -------------------------------------------------------------------------

def _detail(s):
    d = dict(s)
    for k in ("pts", "points"):
        if isinstance(d.get(k), list) and len(d[k]) > 4:
            d[k] = "%d points" % len(d[k])
    for k in list(d):
        if isinstance(d[k], float):
            d[k] = round(d[k], 1)
    return d


def _term_brief(t, sess, kids):
    d = {"id": t.get("id"), "name": t.get("name"), "agent": t.get("agent"),
         "rect": rnd(t.get("rect")), "frame": t.get("zone") or None}
    if t.get("busy"):
        d["busy"] = True
    if t.get("attention"):
        d["needs_user"] = True
    if t.get("session") == sess:
        d["you"] = True
    elif t.get("session") in kids:
        d["your_child"] = True
    return d


def look(m, where=None, screenshot=True, max_px=1400):
    st = m.read_state()
    shapes = m.read_board().get("shapes", [])
    terms = st.get("terminals", [])
    region, what = resolve_region(m, where, shapes, terms)
    sess = m.my_session()
    lin = m.read_lineage()
    kids = {s for s in lin if not lin[s].get("dead") and m._is_descendant(s, sess, lin)} if sess else set()

    inside, outside = [], []
    for s in shapes:
        r = rect_of(s)
        (inside if r and inter(r, region) else outside).append(s)
    t_in = [t for t in terms if t.get("rect") and inter(term_rect(t, True), region)]
    t_out = [t for t in terms if t not in t_in]

    out = {
        "region": rnd(region), "region_is": what,
        "user_view": rnd(st.get("view")),
        "you": next((_term_brief(t, sess, kids) for t in terms if sess and t.get("session") == sess), None),
        "inside": {"shapes": [dict(_detail(s), yours=True) if sess and s.get("owner") == sess else _detail(s)
                              for s in inside],
                   "termlings": [_term_brief(t, sess, kids) for t in t_in]},
    }
    # Outside: a compact line per shape, or, on a big board, per frame.
    if len(outside) <= COMPACT_MAX:
        rest = [{"id": s.get("id"), "type": kind(s), "text": label(s), "rect": rnd(rect_of(s))}
                for s in outside if s.get("type") != "arrow"]
    else:
        frames = [s for s in outside if s.get("type") in CONTAINERS and rect_of(s)]
        rest = []
        held = set()
        for f in frames:
            fr = rect_of(f)
            n = [s for s in outside if s is not f and rect_of(s) and contains(fr, rect_of(s))]
            held.update(id(s) for s in n)
            rest.append({"id": f["id"], "type": "frame", "text": label(f), "rect": rnd(fr),
                         "holds": len(n), "termlings": sum(1 for t in t_out if t.get("rect") and contains(fr, term_rect(t)))})
        loose = [s for s in outside if id(s) not in held and s.get("type") not in CONTAINERS
                 and s.get("type") != "arrow" and rect_of(s)]
        cx, cy = region[0] + region[2] / 2, region[1] + region[3] / 2
        loose.sort(key=lambda s: math.hypot(rect_of(s)[0] - cx, rect_of(s)[1] - cy))
        rest += [{"id": s.get("id"), "type": kind(s), "text": label(s), "rect": rnd(rect_of(s))} for s in loose[:30]]
        if len(loose) > 30:
            rest.append({"more_loose_shapes": len(loose) - 30, "bounds": rnd(union([rect_of(s) for s in loose[30:]]))})
    out["elsewhere"] = {"shapes": rest, "termlings": [_term_brief(t, sess, kids) for t in t_out],
                        "arrows": sum(1 for s in outside if s.get("type") == "arrow")}
    issues = lint(m, shapes, terms, region=region)
    out["lint"] = [i for i in issues if i["yours"]]
    if len(issues) > len(out["lint"]):
        out["lint_others"] = "%d issue(s) in shapes that aren't yours; lint(where=...) lists them" % (
            len(issues) - len(out["lint"]))
    out["hint"] = ("look(where=<frame/shape/termling/[x,y,w,h]>) for detail elsewhere; "
                   "run(code) to change many shapes at once")
    # Show the user where this agent is looking.
    try:
        m._append(m.CMDS, {"cmd": "presence", "kind": "look", "rect": region, "session": sess})
    except OSError:
        pass
    if not screenshot:
        return out
    try:
        png, _ = m.screenshot(region, pad=0.0, max_px=max_px)
    except ValueError as e:
        out["screenshot_error"] = str(e)
        return out
    return m.Image(png, out)


# --- run: code mode ---------------------------------------------------------------

ADD_TYPES = ["note", "text", "todo", "frame", "rectangle", "ellipse", "diamond", "triangle", "bookmark"]
DEFAULT_SIZE = {"note": (200, 200), "todo": (300, 100), "frame": (900, 660), "text": (160, 30), "bookmark": (300, 320)}
STYLE = ("color", "fill", "dash", "size", "font")


class Board:
    """The API a run() script gets as `board` (its methods are also bare names).

    Read:   shapes, get(id), terms, me, view, frames, find_space(w, h, near=None, inside=None),
            screen(termling, lines=40), lint()
    Change: add(type, text="", x=None, y=None, w=None, h=None, **style) -> id
            note/text/todo(items=[...])/frame(title, ...)/rect/ellipse/diamond/triangle(...) -> id
            arrow(frm, to, text="", **style) -> id     (frm: 'me', one of your shapes or children)
            update(id, **fields), move(id, x, y), delete(*ids)
    style: color (black grey light-violet violet blue light-blue yellow orange green light-green
    light-red red white), fill (none semi solid pattern), dash (draw solid dashed dotted),
    size (s m l xl), font (draw sans serif mono). Coordinates are world units.
    """

    def __init__(self, m):
        self._m = m
        self._sess = m.my_session()
        self.shapes = m.read_board().get("shapes", [])
        st = m.read_state()
        self.terms = st.get("terminals", [])
        self.view = st.get("view")
        self.me = m.me()
        self.frames = [s for s in self.shapes if s.get("type") == "frame"]
        self._ops = []
        self._made = []
        self._by = {s.get("id"): s for s in self.shapes}

    # read
    def get(self, sid):
        return self._by.get(sid)

    def rect(self, ref):
        s = self._by.get(ref)
        if s is not None:
            return rect_of(s)
        t = self._m._term(ref)
        return term_rect(t) if t else None

    def find_space(self, w, h, near=None, inside=None):
        extra = [rect_of(self._by[i]) for i in self._made if rect_of(self._by[i])]
        return self._m.find_space(w, h, near, inside, extra=extra)

    def screen(self, ref, lines=40):
        t = self._m._term(ref)
        if t is None:
            raise ValueError("no termling %r" % (ref,))
        return self._m._screen(t, int(lines))

    def lint(self):
        return lint(self._m, self.shapes, self.terms, focus=set(self._made))

    # change
    def _own(self, sid):
        s = self._by.get(sid)
        if s is None:
            raise ValueError("no shape %r" % (sid,))
        if sid not in self._made and (not self._sess or s.get("owner") != self._sess):
            raise ValueError("shape %r isn't yours; you can only change shapes you created" % (sid,))

    def add(self, type, text="", x=None, y=None, w=None, h=None, items=None, url=None, **style):
        if not self._sess:
            raise ValueError("no COVE_SESSION: board shapes need an owner")
        if type == "rect":
            type = "rectangle"
        if type not in ADD_TYPES:
            raise ValueError("type must be one of " + ", ".join(ADD_TYPES))
        bad = set(style) - set(STYLE) - {"rotation"}
        if bad:
            raise ValueError("unknown fields: " + ", ".join(sorted(bad)))
        dw, dh = DEFAULT_SIZE.get(type, (200, 140))
        w, h = float(w if w is not None else dw), float(h if h is not None else dh)
        if x is None or y is None:
            spot = self.find_space(w, h, near="me")
            x, y = spot["x"], spot["y"]
        sid = "%s.%s" % (self._sess, uuid.uuid4().hex[:6])
        op = {"op": "add", "type": type, "id": sid, "owner": self._sess, "text": str(text),
              "x": float(x), "y": float(y), "w": w, "h": h}
        if type == "text" and "w" not in style and w == dw:
            op.pop("w")   # let Godot autosize the label
        if items is not None:
            op["items"] = [str(i) for i in items]
        if url is not None:
            op["url"] = str(url)
        op.update({k: v for k, v in style.items()})
        self._ops.append(op)
        s = {"id": sid, "type": "geo" if type in ("rectangle", "ellipse", "diamond", "triangle") else type,
             "x": float(x), "y": float(y), "w": w, "h": h, "text": str(text), "owner": self._sess}
        if s["type"] == "geo":
            s["geo"] = type
        self.shapes.append(s)
        self._by[sid] = s
        self._made.append(sid)
        return sid

    def note(self, text, **kw):
        return self.add("note", text, **kw)

    def text(self, text, **kw):
        return self.add("text", text, **kw)

    def todo(self, title="To do", items=(), **kw):
        return self.add("todo", title, items=list(items), **kw)

    def frame(self, title, **kw):
        return self.add("frame", title, **kw)

    def rect_shape(self, text="", **kw):
        return self.add("rectangle", text, **kw)

    def ellipse(self, text="", **kw):
        return self.add("ellipse", text, **kw)

    def diamond(self, text="", **kw):
        return self.add("diamond", text, **kw)

    def triangle(self, text="", **kw):
        return self.add("triangle", text, **kw)

    def _end(self, ref, is_from):
        if ref in (None, "", "me"):
            if not self.me:
                raise ValueError("'me' needs you to be in a Cove termling")
            return int(self.me["id"])
        if ref in self._by:
            if is_from:
                self._own(ref)
            return ref
        t = self._m._term(ref)
        if t is not None:
            if is_from:
                t = self._m.require_child(ref)
            return int(t["id"])
        raise ValueError("no shape or termling %r" % (ref,))

    def arrow(self, frm, to, text="", **style):
        if not self._sess:
            raise ValueError("no COVE_SESSION: board shapes need an owner")
        sid = "%s.%s" % (self._sess, uuid.uuid4().hex[:6])
        op = {"op": "add", "type": "arrow", "id": sid, "owner": self._sess,
              "from": self._end(frm, True), "to": self._end(to, False)}
        if text:
            op["text"] = str(text)
        op.update(style)
        self._ops.append(op)
        s = {"id": sid, "type": "arrow", "owner": self._sess,
             "bind_a": str(op["from"]), "bind_b": str(op["to"])}
        self.shapes.append(s)
        self._by[sid] = s
        self._made.append(sid)
        return sid

    def update(self, sid, **fields):
        self._own(sid)
        ok = {"text", "items", "add_items", "check", "uncheck", "remove", "x", "y", "w", "h", "rotation"} | set(STYLE)
        bad = set(fields) - ok
        if bad:
            raise ValueError("can't update: " + ", ".join(sorted(bad)))
        self._ops.append(dict(fields, op="update", id=sid))
        s = self._by[sid]
        for k in ("x", "y", "w", "h", "text"):
            if k in fields:
                s[k] = fields[k]

    def move(self, sid, x, y):
        self.update(sid, x=float(x), y=float(y))

    def delete(self, *ids):
        for i in ids:
            self._own(i)
        self._ops.append({"op": "delete", "ids": list(ids)})
        gone = set(ids)
        self.shapes[:] = [s for s in self.shapes if s.get("id") not in gone]
        for i in ids:
            self._by.pop(i, None)
        self._made = [i for i in self._made if i not in gone]


class _Timeout(Exception):
    pass


def run(m, code, dry_run=False):
    board = Board(m)
    ns = {"board": board, "json": json, "math": math, "__name__": "__cove_run__"}
    for name in ("shapes", "terms", "me", "view", "frames"):
        ns[name] = getattr(board, name)
    for name in dir(Board):
        if not name.startswith("_") and callable(getattr(Board, name)):
            ns[name] = getattr(board, name)
    out = io.StringIO()

    def alarm(*_):
        raise _Timeout()

    old = signal.signal(signal.SIGALRM, alarm)
    signal.alarm(RUN_TIMEOUT)
    try:
        with contextlib.redirect_stdout(out):
            exec(compile(code, "<run>", "exec"), ns)
    except _Timeout:
        return {"ok": False, "error": "the script ran past %ds; nothing was changed" % RUN_TIMEOUT,
                "stdout": out.getvalue()[-4000:]}
    except Exception as e:
        tb = [f for f in traceback.extract_tb(e.__traceback__) if f.filename == "<run>"]
        where = (" (line %d)" % tb[-1].lineno) if tb else ""
        return {"ok": False, "error": "%s: %s%s; nothing was changed" % (type(e).__name__, e, where),
                "stdout": out.getvalue()[-4000:]}
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)

    res = {"ok": True, "stdout": out.getvalue()[-4000:], "created": list(board._made), "ops": len(board._ops)}
    if "result" in ns:
        try:
            json.dumps(ns["result"])
            res["result"] = ns["result"]
        except (TypeError, ValueError):
            res["result"] = repr(ns["result"])
    if not board._ops:
        return res
    if dry_run:
        res["dry_run"] = True
        res["planned"] = board._ops
        res["lint"] = board.lint()   # planned rects; text heights are estimates
        return res
    r = m.send(m.CMDS, {"cmd": "board", "op": "batch", "ops": board._ops})
    touched = [o.get("id") for o in board._ops if o.get("id")]
    res["lint"] = lint_after(m, r.get("shapes"), [i for i in touched if i in board._by])
    res["confirmed"] = r.get("confirmed", False)
    return res
