package main

import (
	"fmt"
	"sort"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

type processRef struct {
	pid      int
	identity string
	depth    int
}

// scanTree mirrors Cove.gd's _scan_sessions: the agent is the first
// claude/codex/opencode below the session's shell. The process table and
// command lines come from the kernel (procs_darwin.go, procs_linux.go).
func scanTree(root int) meta {
	m := meta{Agent: "shell", Pid: root}
	kids, comm, _, ok := procTable()
	if !ok {
		return m
	}
	queue := append([]int(nil), kids[root]...)
	agentPid := -1
	for guard := 0; len(queue) > 0 && guard < 256; guard++ {
		cur := queue[0]
		queue = queue[1:]
		lc := strings.ToLower(argv(cur, comm[cur]))
		switch {
		case strings.Contains(lc, "opencode"):
			m.Agent, agentPid = "opencode", cur
		case strings.Contains(lc, "codex") && m.Agent == "shell":
			m.Agent, agentPid = "codex", cur
		case strings.Contains(lc, "claude") && m.Agent == "shell":
			m.Agent, agentPid = "claude", cur
		}
		queue = append(queue, kids[cur]...)
	}
	if agentPid != -1 {
		m.Pid = agentPid
	}
	m.Busy = m.Agent != "shell"
	// The root is the login shell (a `-c cmd; exec shell` wrapper execs into
	// one), so a bare prompt is "no children".
	m.Idle = m.Agent == "shell" && len(kids[root]) == 0
	return m
}

func captureProcessTree(root processRef) ([]processRef, error) {
	_, _, identities, ok := procTable()
	if !ok {
		return nil, fmt.Errorf("cannot read process table")
	}
	refs := make([]processRef, 0, 8)
	if identity, exists := identities[root.pid]; exists && identity != root.identity {
		if sid, err := unix.Getsid(root.pid); err == nil && sid == root.pid {
			return nil, fmt.Errorf("session root pid was reused")
		}
	}
	for pid, identity := range identities {
		sid, err := unix.Getsid(pid)
		if err != nil || sid != root.pid {
			continue
		}
		refs = append(refs, processRef{pid: pid, identity: identity})
	}
	return refs, nil
}

func waitProcessRef(pid int, timeout time.Duration) (processRef, error) {
	deadline := time.Now().Add(timeout)
	for {
		if identity, ok := processIdentity(pid); ok {
			return processRef{pid: pid, identity: identity}, nil
		}
		if time.Now().After(deadline) {
			return processRef{}, fmt.Errorf("cannot identify process %d", pid)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func mergeProcessRefs(base, extra []processRef) []processRef {
	seen := map[string]bool{}
	out := make([]processRef, 0, len(base)+len(extra))
	for _, refs := range [][]processRef{base, extra} {
		for _, ref := range refs {
			key := fmt.Sprintf("%d:%s", ref.pid, ref.identity)
			if !seen[key] {
				seen[key] = true
				out = append(out, ref)
			}
		}
	}
	return out
}

func signalProcessRef(ref processRef, sig syscall.Signal) (bool, error) {
	identity, alive := processIdentity(ref.pid)
	if !alive || identity != ref.identity {
		return false, nil
	}
	err := syscall.Kill(ref.pid, sig)
	if err == syscall.ESRCH {
		return false, nil
	}
	return true, err
}

func waitProcessRefsGone(refs []processRef, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for {
		alive := false
		for _, ref := range refs {
			identity, exists := processIdentity(ref.pid)
			if exists && identity == ref.identity {
				alive = true
				break
			}
		}
		if !alive {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(25 * time.Millisecond)
	}
}

// Stop the root before the second tree capture so it cannot create an
// untracked descendant, then kill only pid+birth identities we actually own.
func killProcessTree(root processRef, known []processRef) error {
	latest, err := captureProcessTree(root)
	refs := mergeProcessRefs(known, latest)
	if err != nil || len(refs) == 0 {
		return err
	}
	stopped := make([]processRef, 0, len(refs))
	resume := true
	defer func() {
		if resume {
			for _, ref := range stopped {
				_, _ = signalProcessRef(ref, syscall.SIGCONT)
			}
		}
	}()
	for _, ref := range refs {
		alive, err := signalProcessRef(ref, syscall.SIGSTOP)
		if err != nil {
			return err
		}
		if alive {
			stopped = append(stopped, ref)
		}
	}
	stable := false
	for round := 0; round < 4; round++ {
		latest, err := captureProcessTree(root)
		if err != nil {
			return err
		}
		merged := mergeProcessRefs(refs, latest)
		if len(merged) == len(refs) {
			stable = true
			break
		}
		refs = merged
		sort.Slice(refs, func(i, j int) bool { return refs[i].depth < refs[j].depth })
		for _, ref := range refs {
			if alive, err := signalProcessRef(ref, syscall.SIGSTOP); err != nil {
				return err
			} else if alive {
				stopped = mergeProcessRefs(stopped, []processRef{ref})
			}
		}
	}
	if !stable {
		return fmt.Errorf("owned process tree did not stabilize")
	}
	sort.Slice(refs, func(i, j int) bool { return refs[i].depth > refs[j].depth })
	for _, ref := range refs {
		if _, err := signalProcessRef(ref, syscall.SIGKILL); err != nil {
			return err
		}
	}
	if !waitProcessRefsGone(refs, 2*time.Second) {
		return fmt.Errorf("owned process tree did not exit")
	}
	resume = false
	return nil
}
