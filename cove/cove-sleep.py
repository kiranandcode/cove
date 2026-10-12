#!/usr/bin/env python3
"""cove-sleep.py -- put an idle termling's agent to sleep to free its memory.

    cove-sleep.py AGENT PID PANE [MIN_IDLE_S]      AGENT: claude | codex | opencode

An agent TUI holds a few hundred MB, plus its MCP servers; a board of agents
that went quiet days ago runs the Mac out of RAM and swap. (macOS already
compresses and swaps idle pages; that is what fills up. Only ending the process
gives the memory back.) Cove.gd (_apply_sleep_policy) calls this for an agent
that has been idle and off screen for hours. It stops the agent and types
cove-wake.py into the termling, which resumes the same conversation in place
the moment the termling is typed into or scrolled.

The agent's own records decide, and anything unclear leaves it running:
  claude    ~/.claude/sessions/PID.json: "idle" (not busy / waiting / shell) for MIN_IDLE_S
  codex     the one rollout in ~/.codex/sessions for its cwd written since it started,
            quiet for MIN_IDLE_S
  opencode  the one session in opencode.db for its cwd updated since it started,
            quiet for MIN_IDLE_S
Two live agents of the same kind in one directory can't be told apart: skipped.
"""
import glob, json, os, signal, sqlite3, subprocess, sys, time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
KITTEN = os.environ.get("COVE_KITTEN") or os.path.join(
    HERE, "..", "kitty", "launcher", "kitty.app", "Contents", "MacOS", "kitten")
SOCK = os.environ.get("COVE_KITTY_SOCKET", "unix:/tmp/cove-kitty")
SNAPSHOTS = "/tmp/cove/sleep"   # the last screen of each sleeping agent, for cove-wake.py to repaint


class Skip(Exception):
    pass


def log(msg):
    print("%s %s" % (time.strftime("%m-%d %H:%M:%S"), msg), flush=True)


def ps(*args):
    return subprocess.run(["/bin/ps", *args], capture_output=True, text=True).stdout


def cwd_of(pid):
    out = subprocess.run(["/usr/sbin/lsof", "-a", "-d", "cwd", "-p", str(pid), "-Fn"],
                         capture_output=True, text=True).stdout
    return next((l[1:] for l in out.splitlines() if l.startswith("n")), "")


def started_at(pid):
    s = ps("-o", "lstart=", "-p", str(pid)).strip()
    return datetime.strptime(s, "%a %b %d %H:%M:%S %Y").timestamp() if s else 0.0


def alone_in_cwd(agent, pid, cwd):
    """No other live `agent` TUI shares this cwd (else its session is ambiguous)."""
    for line in ps("-Ao", "pid=,args=").splitlines():
        p, args = line.split(None, 1)
        argv = args.split()
        if "app-server" in argv:
            continue   # codex's shared background daemon, not a TUI
        if int(p) != pid and os.path.basename(argv[0]) == agent and cwd_of(int(p)) == cwd:
            return False
    return True


def claude_session(pid, min_idle):
    try:
        with open(os.path.expanduser("~/.claude/sessions/%d.json" % pid)) as f:
            info = json.load(f)
    except (OSError, ValueError):
        raise Skip("no Claude session file")
    if not info.get("sessionId") or info.get("kind", "interactive") != "interactive":
        raise Skip("not an interactive session")
    idle = time.time() - info.get("statusUpdatedAt", 0) / 1000
    if info.get("status") != "idle" or idle < min_idle:
        raise Skip("%s for %.1f h" % (info.get("status"), idle / 3600))
    return info["sessionId"], idle


def codex_session(pid, min_idle):
    cwd, since = cwd_of(pid), started_at(pid)
    if not cwd or not alone_in_cwd("codex", pid, cwd):
        raise Skip("another codex shares %s" % cwd)
    found = []
    for path in glob.glob(os.path.expanduser("~/.codex/sessions/*/*/*/rollout-*.jsonl")):
        mtime = os.path.getmtime(path)
        if mtime < since:
            continue
        try:
            with open(path) as f:
                meta = json.loads(f.readline()).get("payload", {})
        except (OSError, ValueError):
            continue
        if meta.get("cwd") == cwd and meta.get("id"):
            found.append((mtime, meta["id"]))
    if len(found) != 1:
        raise Skip("%d codex sessions in %s since it started" % (len(found), cwd))
    idle = time.time() - found[0][0]
    if idle < min_idle:
        raise Skip("active %.1f h ago" % (idle / 3600))
    return found[0][1], idle


def opencode_session(pid, min_idle):
    cwd, since = cwd_of(pid), started_at(pid)
    if not cwd or not alone_in_cwd("opencode", pid, cwd):
        raise Skip("another opencode shares %s" % cwd)
    db = os.path.expanduser("~/.local/share/opencode/opencode.db")
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=5)
        rows = con.execute("SELECT id, time_updated FROM session WHERE directory = ? AND parent_id IS NULL"
                           " AND time_archived IS NULL AND time_updated >= ?", (cwd, since * 1000)).fetchall()
        con.close()
    except sqlite3.Error as e:
        raise Skip("opencode.db: %s" % e)
    if len(rows) != 1:
        raise Skip("%d opencode sessions in %s since it started" % (len(rows), cwd))
    idle = time.time() - rows[0][1] / 1000
    if idle < min_idle:
        raise Skip("active %.1f h ago" % (idle / 3600))
    return rows[0][0], idle


SESSION = {"claude": claude_session, "codex": codex_session, "opencode": opencode_session}


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def stop(pid):
    os.kill(pid, signal.SIGTERM)
    for _ in range(150):
        if not alive(pid):
            return
        time.sleep(0.1)
    log("pid %d ignored SIGTERM; SIGKILL" % pid)
    # It leads its own job's process group (the shell's job control), so its MCP
    # servers go with it; never the shell's group.
    try:
        if os.getpgid(pid) == pid:
            os.killpg(pid, signal.SIGKILL)
        else:
            os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def snapshot(pane, sid):
    """Save what the termling shows now (with colours), so the sleeping termling
    keeps showing it instead of a shell prompt. "" if kitty wouldn't say."""
    p = subprocess.run([KITTEN, "@", "--to", SOCK, "get-text", "--match", "id:%d" % pane,
                        "--extent", "screen", "--ansi"], capture_output=True)
    if p.returncode or not p.stdout.strip():
        return ""
    os.makedirs(SNAPSHOTS, exist_ok=True)
    path = os.path.join(SNAPSHOTS, "%s.ansi" % sid)
    with open(path, "wb") as f:
        f.write(p.stdout)
    return path


def main():
    if len(sys.argv) < 4 or sys.argv[1] not in SESSION:
        print(__doc__.splitlines()[2].strip(), file=sys.stderr)
        return 2
    agent, pid, pane = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    min_idle = float(sys.argv[4]) if len(sys.argv) > 4 else 3 * 3600
    if os.path.basename(ps("-o", "comm=", "-p", str(pid)).strip()) != agent:
        log("pane %d: pid %d is no longer %s; leaving it" % (pane, pid, agent))
        return 1
    try:
        sid, idle = SESSION[agent](pid, min_idle)
    except Skip as e:
        log("pane %d: %s %d stays awake: %s" % (pane, agent, pid, e))
        return 1
    log("pane %d: %s %d (%s, idle %.1f h) -> asleep" % (pane, agent, pid, sid, idle / 3600))
    snap = snapshot(pane, sid)
    stop(pid)
    time.sleep(1.5)   # the shell redraws its prompt
    # ^U clears anything left on the prompt line; the leading space keeps the
    # command out of zsh history (with HIST_IGNORE_SPACE).
    cmd = "\x15 %s %s %s%s\r" % (os.path.join(HERE, "cove-wake.py"), agent, sid,
                                 " " + snap if snap else "")
    p = subprocess.run([KITTEN, "@", "--to", SOCK, "send-text", "--match", "id:%d" % pane, cmd],
                       capture_output=True, text=True)
    if p.returncode:
        log("pane %d: send-text failed (%s); resume it by hand with session %s"
            % (pane, (p.stderr or p.stdout).strip(), sid))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
