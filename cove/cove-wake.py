#!/usr/bin/env python3
"""cove-wake.py AGENT SESSION_ID [SNAPSHOT] -- what a termling runs while its agent sleeps.

cove-sleep.py stops an idle agent to free its memory and types this in its
place. It repaints the agent's last screen (SNAPSHOT, saved by cove-sleep.py),
so the termling looks as it did rather than showing a shell; the Cove draws it
faded in a grey outline. It holds next to nothing and waits for the termling to be used: a key, a
wheel scroll or a click (mouse reporting is on, so those reach it) resumes the
same conversation in the same terminal. Printable keys are pushed back as input
(TIOCSTI), so what you started typing lands in the agent's prompt. ctrl-c
leaves a plain shell instead.
"""
import fcntl, os, shutil, signal, sys, termios, time, tty

RESUME = {
    "claude": ["claude", "--resume"],
    "codex": ["codex", "resume"],
    "opencode": ["opencode", "--session"],
}
# What the killed TUI may have left switched on: alt screen, hidden cursor, mouse
# reporting, bracketed paste, kitty keyboard flags.
RESET = "\033[?1049l\033[?25h\033[?1002l\033[?1003l\033[?2004l\033[<99u"
MOUSE_ON = "\033[?1000h\033[?1006h"    # report clicks + wheel (SGR encoding)
MOUSE_OFF = "\033[?1006l\033[?1000l"


def paint(lines, hint):
    """The last screen, bottom-aligned to the terminal's current height; with no
    snapshot, just the hint line."""
    rows = shutil.get_terminal_size().lines
    out = RESET + "\033[?25l\033[H\033[2J"
    if lines:
        out += "\r\n".join(l.decode("utf-8", "replace") for l in lines[-rows:]) + "\033[0m"
    else:
        out += hint
    sys.stdout.write(out + MOUSE_ON)
    sys.stdout.flush()


def main():
    if len(sys.argv) not in (3, 4) or sys.argv[1] not in RESUME:
        print(__doc__.splitlines()[0], file=sys.stderr)
        return 2
    agent, sid = sys.argv[1], sys.argv[2]
    snap = sys.argv[3] if len(sys.argv) == 4 else ""
    cmd = RESUME[agent] + [sid]
    fd = sys.stdin.fileno()
    lines = []
    if snap:
        try:
            with open(snap, "rb") as f:
                lines = f.read().rstrip(b"\n").split(b"\n")
        except OSError:
            pass
    hint = ("\033[2m💤 %s asleep since %s to free memory · type or scroll to wake · ctrl-c for a shell\033[0m"
            % (agent, time.strftime("%a %H:%M")))
    paint(lines, hint)
    signal.signal(signal.SIGWINCH, lambda *_: paint(lines, hint))
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        data = os.read(fd, 64)
        time.sleep(0.05)   # the rest of an escape sequence / a fast typist
        try:
            os.set_blocking(fd, False)
            data += os.read(fd, 1024)
        except BlockingIOError:
            pass
        finally:
            os.set_blocking(fd, True)
    finally:
        signal.signal(signal.SIGWINCH, signal.SIG_DFL)
        sys.stdout.write(MOUSE_OFF + "\033[0m\033[H\033[2J\033[?25h")   # the agent repaints from a clean screen
        sys.stdout.flush()
        termios.tcsetattr(fd, termios.TCSAFLUSH, old)
    if snap:
        try:
            os.unlink(snap)
        except OSError:
            pass
    if b"\x03" in data:
        sys.stdout.write("\033[2m%s was asleep; resume it with: %s\033[0m\r\n" % (agent, " ".join(cmd)))
        return 130
    sys.stdout.write("\033[2m⏳ waking %s…\033[0m\r\n" % agent)
    sys.stdout.flush()
    # Give typed text back to the agent; mouse/escape sequences were only the nudge.
    if not data.startswith(b"\033"):
        text = bytes(b for b in data if b >= 0x20 or b in (0x09,))
        for i in range(len(text)):
            try:
                fcntl.ioctl(fd, termios.TIOCSTI, text[i:i + 1])
            except OSError:
                break
    os.execvp(cmd[0], cmd)


if __name__ == "__main__":
    sys.exit(main())
