#!/usr/bin/env python3
"""cove-recover.py -- bring termlings back after the laptop crashes or reboots.

abduco keeps termlings alive across a kitty restart, but not across a reboot.
What does survive is on disk:
  - the Cove's durable layout (user://cove-layout.json): name/pos/frame per abduco session
  - lineage.json: which agent spawned which child termling (and the board arrow)
  - Claude transcripts: each one carries the SessionStart hook's "session cove-N" line,
    so it says which termling it ran in, its cwd and its session id
  - agents/<cove-session>.json, written by hooks/cove-hello.sh from 2026-09-26 on
  - live.json: the abduco sessions alive at the last snapshot, and which ran an agent
    (written every 30 s by `watch`, which run.sh/dev.sh start; stop.sh empties it)

Relaunching a termling under its OLD abduco session name makes the Cove restore its
name, position and frame by itself; typing `claude --resume <id>` there puts the
agent back into the conversation it was in.

  cove-recover.py list [--since HOURS] [--all]   what would come back
  cove-recover.py restore [--since HOURS] [--only cove-1,cove-2] [--dry-run]
  cove-recover.py snapshot [--clear]     write live.json now (--clear: an intended full stop)
  cove-recover.py watch [--restore]      snapshot every 30 s while the Cove runs; with
                                         --restore, first bring back what a reboot killed
"""
import argparse, glob, json, os, re, shlex, subprocess, sys, time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.expanduser("~/.local/state/cove")
LAYOUT = os.path.expanduser("~/Library/Application Support/Godot/app_userdata/Cove/cove-layout.json")
PROJECTS = os.path.expanduser("~/.claude/projects")
TAG = re.compile(r"Cove termling \(session (cove-\d+)\)")
SOCK = os.environ.get("COVE_KITTY_SOCKET", "unix:/tmp/cove-kitty")
KITTEN = os.path.join(HERE, "..", "kitty", "launcher", "kitty.app", "Contents", "MacOS", "kitten")


def _json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return 0.0


def scan_transcripts(since):
    """cove session -> newest Claude session that ran in it."""
    out = {}
    for path in glob.glob(os.path.join(PROJECTS, "*", "*.jsonl")):
        if os.path.getmtime(path) < since:
            continue
        sess, sid, cwd, last, title, ended = None, None, None, 0.0, "", False
        with open(path, errors="replace") as f:
            for line in f:
                if sess is None and "Cove termling (session" in line:
                    m = TAG.search(line)
                    if m:
                        sess = m.group(1)
                if '"timestamp"' not in line and '"aiTitle"' not in line and '"customTitle"' not in line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("type") == "ai-title" and not title:
                    title = rec.get("aiTitle", "")
                if rec.get("type") == "custom-title":
                    title = rec.get("customTitle", title)
                if rec.get("isSidechain"):
                    continue
                t = _ts(rec.get("timestamp"))
                if t:
                    last = max(last, t)
                    sid = rec.get("sessionId", sid)
                    cwd = rec.get("cwd", cwd)
                    if rec.get("type") == "user":
                        c = json.dumps(rec.get("message", {}).get("content", ""))
                        ended = "<command-name>/exit</command-name>" in c
        if not sess or not sid or last < since:
            continue
        if sess not in out or last > out[sess]["last"]:
            out[sess] = {"agent": "claude", "id": sid, "cwd": cwd, "last": last,
                         "title": title, "ended": ended}
    return out


def manifest(since):
    found = scan_transcripts(since)
    # What the hook recorded beats the transcript scan (it knows about resumes exactly).
    for p in glob.glob(os.path.join(STATE, "agents", "cove-*.json")):
        rec = _json(p, {})
        sess = os.path.basename(p)[:-5]
        if rec.get("id") and rec.get("time", 0) >= since:
            old = found.get(sess)
            if not old or old["id"] == rec["id"] or rec["time"] >= old["last"]:
                found[sess] = dict(old or {}, agent=rec.get("agent", "claude"), id=rec["id"],
                                   cwd=rec.get("cwd") or (old or {}).get("cwd"),
                                   last=max(rec["time"], (old or {}).get("last", 0)),
                                   title=(old or {}).get("title", ""), ended=(old or {}).get("ended", False))
    layout = _json(LAYOUT, {}).get("by_session", {})
    lineage = _json(os.path.join(STATE, "lineage.json"), {})
    live = _json(os.path.join(STATE, "live.json"), {})
    live_set = set(live.get("sessions", []))
    rows = []
    for sess, a in found.items():
        lin = lineage.get(sess, {})
        if sess in live_set and "agents" in live and not live["agents"].get(sess):
            a = dict(a, agent="", id="")   # its agent had already exited: a shell comes back
        rows.append(dict(a, session=sess, name=layout.get(sess, {}).get("name") or lin.get("name") or "",
                         parent=lin.get("parent", ""), host=lin.get("host", ""),
                         dead=bool(lin.get("dead")), live=sess in live_set))
    # Termlings that were alive (per the snapshot) but ran no agent: bring back as shells.
    for sess in live_set - set(found):
        lin = lineage.get(sess, {})
        rows.append(dict(session=sess, agent="", id="", cwd=live.get("cwd", {}).get(sess), last=live.get("time", 0),
                         title="", ended=False, name=layout.get(sess, {}).get("name") or lin.get("name") or "",
                         parent=lin.get("parent", ""), host=lin.get("host", ""), dead=bool(lin.get("dead")), live=True))
    rows.sort(key=lambda r: -r["last"])
    return rows, live


def pick(rows, live, args):
    if args.only:
        want = set(args.only.split(","))
        return [r for r in rows if r["session"] in want]
    if args.all:
        return rows
    if live.get("sessions"):
        return [r for r in rows if r["live"]]
    # No snapshot yet: an agent that /exit-ed or was killed by its parent was not running.
    return [r for r in rows if not r["ended"] and not r["dead"]]


def running_sessions():
    try:
        out = subprocess.run(["abduco"], capture_output=True, text=True).stdout
    except OSError:
        return set()
    return set(re.findall(r"\b(cove-\d+)\s*$", out, re.M))


def order_parents_first(rows):
    by = {r["session"]: r for r in rows}
    done, out = set(), []
    def visit(r):
        if r["session"] in done:
            return
        done.add(r["session"])
        if r["parent"] in by:
            visit(by[r["parent"]])
        out.append(r)
    for r in rows:
        visit(r)
    return out


def show(rows):
    for r in rows:
        when = datetime.fromtimestamp(r["last"]).strftime("%m-%d %H:%M") if r["last"] else "?"
        flag = "live" if r["live"] else ("exited" if r["ended"] else ("dead" if r["dead"] else ""))
        par = (" <- " + r["parent"]) if r["parent"] else ""
        print("%-16s %s %-6s %-36s %-30.30s %-30.30s %s%s" % (
            r["session"], when, flag, r["id"] or "(shell)", r["name"] or r["title"],
            (r["cwd"] or "").replace(os.path.expanduser("~"), "~"), r["host"], par))


def restore(rows, dry):
    have = running_sessions()
    asleep = _json(os.path.join(STATE, "live.json"), {}).get("asleep", {})
    for r in order_parents_first(rows):
        if r["session"] in have:
            print("skip %s: already running" % r["session"])
            continue
        cwd = r["cwd"] if r["cwd"] and os.path.isdir(r["cwd"]) else os.path.expanduser("~")
        cmd = ""
        if r["agent"] == "claude" and r["id"]:
            cmd = "claude --resume %s" % r["id"]
        elif r["agent"] == "codex" and r["id"]:
            cmd = "codex resume %s" % r["id"]
        if r["session"] in asleep and not r["host"]:
            # It was asleep (cove-sleep.py): bring it back asleep, not using memory.
            cmd = "%s %s %s" % (os.path.join(HERE, "cove-wake.py"), *asleep[r["session"]])
        if r["host"]:
            cmd = "%s attach --cwd %s %s%s" % (shlex.quote(os.path.join(HERE, "bin", "cove-remote")),
                                               shlex.quote(cwd), shlex.quote(r["host"]), (" -- " + cmd) if cmd else "")
        launch = [KITTEN, "@", "--to", SOCK,
                  "launch", "--type=os-window", "--cwd", cwd, "--env", "COVE_SPAWN_SESSION=" + r["session"]]
        if r["parent"]:
            launch += ["--env", "COVE_PARENT=" + r["parent"]]
        launch.append(os.path.join(HERE, "cove-shell.sh"))
        print("%s %s  [%s] %s" % ("would restore" if dry else "restore", r["session"], r["name"] or r["title"], cmd))
        if dry:
            continue
        p = subprocess.run(launch, capture_output=True, text=True)
        if p.returncode:
            print("  launch failed: %s" % (p.stderr.strip() or p.stdout.strip()))
            continue
        pane = p.stdout.strip().splitlines()[-1]
        if cmd:
            time.sleep(1.0)   # let the shell draw its prompt
            subprocess.run([KITTEN, "@", "--to", SOCK,
                            "send-text", "--match", "id:" + pane, cmd + "\r"], capture_output=True)
        time.sleep(0.3)


def _abduco_sessions():
    """Live cove sessions per abduco (exited '+' ones left out), or None if it can't be listed."""
    try:
        p = subprocess.run(["abduco"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    out = []
    for line in p.stdout.splitlines()[1:]:
        m = re.search(r"\b(cove-\d+)\s*$", line)
        if m and not line.lstrip().startswith("+"):
            out.append(m.group(1))
    return out


def _agents_by_session(sessions, asleep=None):
    """cove session -> "claude"/"codex"/"opencode"/"" from the process tree under its
    abduco master. An agent put to sleep (cove-sleep.py) counts as its agent, and
    `asleep` (if given) gets session -> [agent, session id] for those."""
    try:
        ps = subprocess.run(["/bin/ps", "-Ao", "pid=,ppid=,command="], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    kids, cmd = {}, {}
    for line in ps.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        pid, ppid = int(parts[0]), int(parts[1])
        cmd[pid] = parts[2]
        kids.setdefault(ppid, []).append(pid)
    want = set(sessions)
    out = {s: "" for s in sessions}
    for pid, c in cmd.items():
        m = re.search(r"abduco.* -A (cove-\d+)", c)
        if not m or m.group(1) not in want:
            continue
        stack = list(kids.get(pid, []))
        while stack:
            q = stack.pop()
            w = cmd.get(q, "").split()
            i = next((k for k, x in enumerate(w) if x.endswith("/cove-wake.py")), -1)
            if i >= 0 and len(w) > i + 2:
                out[m.group(1)] = w[i + 1]
                if asleep is not None:
                    asleep[m.group(1)] = [w[i + 1], w[i + 2]]
                break
            argv0 = os.path.basename(cmd.get(q, "").split(" ", 1)[0])
            words = cmd.get(q, "").split()[:2]
            if argv0 in ("claude", "codex") or any(os.path.basename(w) in ("claude", "codex") for w in words):
                out[m.group(1)] = "codex" if "codex" in argv0 or any("codex" in w for w in words) else "claude"
                break
            stack.extend(kids.get(q, []))
    return out


def _write_live(obj):
    os.makedirs(STATE, exist_ok=True)
    tmp = os.path.join(STATE, "live.json.tmp")
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, os.path.join(STATE, "live.json"))


def snapshot(clear=False):
    if clear:
        _write_live({"time": time.time(), "sessions": [], "agents": {}, "cwd": {}, "stopped": True})
        return True
    sessions = _abduco_sessions()
    if not sessions:
        return False   # never replace the last good picture with an empty one
    cwd = {}
    for t in _json("/tmp/cove/state.json", {}).get("terminals", []):
        if t.get("session") and t.get("cwd"):
            cwd[t["session"]] = t["cwd"]
    asleep = {}
    agents = _agents_by_session(sessions, asleep)
    _write_live({"time": time.time(), "sessions": sessions, "agents": agents, "asleep": asleep, "cwd": cwd})
    return True


def _kitty_up():
    try:
        return subprocess.run([KITTEN, "@", "--to", SOCK, "ls"], capture_output=True, timeout=20).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def watch(restore_first, since):
    import fcntl
    os.makedirs(STATE, exist_ok=True)
    lock = open(os.path.join(STATE, "watch.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return   # another watcher has it
    for _ in range(120):
        if _kitty_up():
            break
        time.sleep(1)
    if restore_first:
        live = _json(os.path.join(STATE, "live.json"), {})
        was = set(live.get("sessions", []))
        now = set(_abduco_sessions() or [])
        # A reboot/crash: termlings were alive at the last snapshot and none survived.
        if was and not (was & now):
            print("cove-recover: %d termlings were alive at %s; restoring" % (
                len(was), datetime.fromtimestamp(live.get("time", 0)).strftime("%m-%d %H:%M")), flush=True)
            rows, live = manifest(time.time() - since * 3600)
            restore([r for r in rows if r["live"]], False)
    misses = 0
    while misses < 6:
        time.sleep(30)
        if _kitty_up():
            misses = 0
            snapshot()
        else:
            misses += 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["list", "restore", "snapshot", "watch"])
    ap.add_argument("--since", type=float, default=36, help="hours of transcripts to scan (default 36)")
    ap.add_argument("--all", action="store_true", help="include exited/killed agents")
    ap.add_argument("--only", help="comma-separated cove sessions")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--clear", action="store_true", help="snapshot: record an intended full stop")
    ap.add_argument("--restore", action="store_true", help="watch: restore after a reboot first")
    a = ap.parse_args()
    if a.action == "snapshot":
        sys.exit(0 if snapshot(a.clear) else 1)
    if a.action == "watch":
        return watch(a.restore, max(a.since, 24 * 7))
    rows, live = manifest(time.time() - a.since * 3600)
    sel = pick(rows, live, a)
    if a.action == "list":
        if live.get("time"):
            print("live snapshot from %s: %d sessions" % (
                datetime.fromtimestamp(live["time"]).strftime("%m-%d %H:%M"), len(live.get("sessions", []))))
        show(sel)
        print("%d of %d" % (len(sel), len(rows)))
    else:
        restore(sel, a.dry_run)


if __name__ == "__main__":
    main()
