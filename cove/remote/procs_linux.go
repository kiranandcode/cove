package main

// Process-tree inspection on Linux, read straight from /proc (no ps, no lsof,
// no subprocesses: the daemon runs this every second).

import (
	"bytes"
	"os"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

// argv returns a process's command line, or its short name if that's hidden
// (kernel threads, zombies, another user's process).
func argv(pid int, comm string) string {
	raw, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/cmdline")
	raw = bytes.TrimRight(raw, "\x00")
	if err != nil || len(raw) == 0 {
		return comm
	}
	return string(bytes.ReplaceAll(raw, []byte{0}, []byte{' '}))
}

// procTable maps each pid to its children and its short name.
func procTable() (kids map[int][]int, comm, identities map[int]string, ok bool) {
	ents, err := os.ReadDir("/proc")
	if err != nil {
		return nil, nil, nil, false
	}
	kids, comm, identities = map[int][]int{}, map[int]string{}, map[int]string{}
	for _, e := range ents {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		// /proc/PID/stat is "pid (comm) state ppid ..."; comm may itself
		// contain spaces and parentheses, so split at the last ')'.
		b, err := os.ReadFile("/proc/" + e.Name() + "/stat")
		if err != nil {
			continue // exited since the ReadDir
		}
		s := string(b)
		lp, rp := strings.IndexByte(s, '('), strings.LastIndexByte(s, ')')
		if lp < 0 || rp < lp {
			continue
		}
		f := strings.Fields(s[rp+1:])
		if len(f) < 2 {
			continue
		}
		ppid, _ := strconv.Atoi(f[1])
		kids[ppid] = append(kids[ppid], pid)
		comm[pid] = s[lp+1 : rp]
		if len(f) > 19 {
			identities[pid] = f[19]
		}
	}
	return kids, comm, identities, true
}

func processIdentity(pid int) (string, bool) {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return "", false
	}
	s := string(b)
	rp := strings.LastIndexByte(s, ')')
	if rp < 0 {
		return "", false
	}
	f := strings.Fields(s[rp+1:])
	if len(f) <= 19 {
		return "", false
	}
	return f[19], true // field 22: clock tick when this process started
}

func cwdOf(pid int) string {
	p, err := os.Readlink("/proc/" + strconv.Itoa(pid) + "/cwd")
	if err != nil {
		return ""
	}
	return p
}

// ttyGetReq reads a pty's termios (for the echo flags in the metadata).
const ttyGetReq = unix.TCGETS

// terminfoSys follows the kitty checkout's terminfo in TERMINFO_DIRS: an
// empty entry is ncurses' built-in search path, which on Debian/Ubuntu spans
// /etc/terminfo, /lib/terminfo and /usr/share/terminfo.
const terminfoSys = ""

// keepAwake is a no-op: a Linux box doesn't sleep under a live session (the
// devbox's idle-stop timer counts cove-remote sessions as activity).
func keepAwake(pid int) {}
