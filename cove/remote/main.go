// cove-remote: live terminals on another machine (a Mac or Linux) that feel local.
//
//	cove-remote attach HOST [-- command]   run in a termling (local)
//	cove-remote ls HOST                    list the sessions on HOST
//	cove-remote kill HOST SESSION          end a session on HOST
//	cove-remote bridge | serve             the remote halves (ssh runs these)
//
// See cove/skills/cove-remote/SKILL.md.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "attach":
		err = runAttach(os.Args[2:])
	case "bridge":
		err = runBridge()
	case "serve":
		if len(os.Args) < 3 {
			usage()
		}
		err = runServe(os.Args[2])
	case "ls", "kill":
		if len(os.Args) < 3 {
			usage()
		}
		self, _ := os.Executable()
		self, _ = filepath.EvalSymlinks(self)
		rest := ""
		for _, a := range os.Args[3:] {
			rest += " " + shellQuote(a)
		}
		remoteVerb := "local-" + os.Args[1]
		if os.Args[1] == "kill" {
			remoteVerb = "local-kill-v2" // old remote binaries must fail closed
		}
		run := func() error {
			cmd := exec.Command("ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", os.Args[2],
				shellQuote(self)+" "+remoteVerb+rest)
			cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
			return cmd.Run()
		}
		err = run()
		if sshFailed(err) && wakeCommand(os.Args[2]) != "" {
			fmt.Fprintf(os.Stderr, "cove-remote: waking %s\n", os.Args[2])
			if err = runWake(os.Args[2], os.Stderr); err == nil {
				err = run()
			}
		}
	case "local-ls":
		err = localLs()
	case "local-kill", "local-kill-v2":
		if len(os.Args) < 3 {
			usage()
		}
		err = localKill(os.Args[2])
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "cove-remote:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  cove-remote attach [flags] HOST [-- command...]
  cove-remote ls HOST
  cove-remote kill HOST SESSION`)
	os.Exit(2)
}

func localLs() error {
	dirs, _ := filepath.Glob(filepath.Join(baseDir(), "*", "info.json"))
	for _, p := range dirs {
		var info struct {
			Session string `json:"session"`
			Cmd     string `json:"cmd"`
			Cwd     string `json:"cwd"`
			Pid     int    `json:"pid"`
			Daemon  int    `json:"daemon"`
		}
		b, err := os.ReadFile(p)
		if err != nil || json.Unmarshal(b, &info) != nil {
			continue
		}
		state := "running"
		if c, err := net.Dial("unix", filepath.Join(filepath.Dir(p), "sock")); err != nil {
			state = "dead"
		} else {
			c.Close()
		}
		m := scanTree(info.Pid)
		cwd := cwdOf(m.Pid)
		if cwd == "" {
			cwd = info.Cwd
		}
		fmt.Printf("%-22s %-8s %-8s %s  %s\n", info.Session, state, m.Agent, cwd, info.Cmd)
	}
	return nil
}

func localKill(sess string) error {
	if !sessionRe.MatchString(sess) {
		return fmt.Errorf("bad session name %q", sess)
	}
	dir := sessionDir(sess)
	sock := filepath.Join(dir, "sock")
	c, err := net.DialTimeout("unix", sock, 2*time.Second)
	if err != nil {
		if _, statErr := os.Stat(dir); os.IsNotExist(statErr) {
			return nil // verified absence makes retries harmless
		}
		return killStaleSession(sess, dir)
	}
	defer c.Close()
	if err := c.SetDeadline(time.Now().Add(15 * time.Second)); err != nil {
		return err
	}
	fw := &frameWriter{w: c}
	h := hello{Session: sess, Client: fmt.Sprintf("kill-%d-%d", os.Getpid(), time.Now().UnixNano()),
		Resume: -1, Replay: 1}
	if err := fw.json(fHello, h); err != nil {
		return err
	}
	r := bufio.NewReaderSize(c, 64<<10)
	f, err := readFrame(r)
	if err != nil || f.t != fWelcome {
		return fmt.Errorf("session %s rejected kill control", sess)
	}
	var w welcome
	if json.Unmarshal(f.p, &w) != nil || w.Proto < protocolVersion {
		return fmt.Errorf("session %s daemon is too old for verified kill; update cove-remote", sess)
	}
	if err := fw.write(fKill); err != nil {
		return err
	}
	acked, exited := false, false
	for {
		f, err = readFrame(r)
		if err != nil {
			return fmt.Errorf("session %s kill was not confirmed: %w", sess, err)
		}
		if f.t == fKill {
			var result struct {
				OK    bool   `json:"ok"`
				Error string `json:"error"`
			}
			if json.Unmarshal(f.p, &result) != nil {
				return fmt.Errorf("session %s returned an invalid kill result", sess)
			}
			if !result.OK {
				return fmt.Errorf("session %s kill failed: %s", sess, result.Error)
			}
			acked = true
		}
		if f.t == fExit {
			exited = true
		}
		if acked && exited {
			return nil
		}
	}
}

func killStaleSession(sess, dir string) error {
	lock, err := acquireSessionLock(sess, 0)
	if err != nil {
		return fmt.Errorf("session %s is starting or running but its control socket is unavailable", sess)
	}
	defer releaseSessionLock(lock)
	if c, err := net.DialTimeout("unix", filepath.Join(dir, "sock"), 200*time.Millisecond); err == nil {
		c.Close()
		return fmt.Errorf("session %s control became available; retry", sess)
	}
	b, err := os.ReadFile(filepath.Join(dir, "info.json"))
	if err != nil {
		return fmt.Errorf("session %s has no verifiable metadata: %w", sess, err)
	}
	var info struct {
		Pid          int    `json:"pid"`
		RootIdentity string `json:"root_identity"`
	}
	if err := json.Unmarshal(b, &info); err != nil || info.Pid <= 1 || info.RootIdentity == "" {
		return fmt.Errorf("session %s metadata predates verified cleanup", sess)
	}
	root := processRef{pid: info.Pid, identity: info.RootIdentity}
	if err := killProcessTree(root, nil); err != nil {
		return fmt.Errorf("kill stale session %s: %w", sess, err)
	}
	if err := retireSessionDir(dir); err != nil {
		return fmt.Errorf("retire stale session %s: %w", sess, err)
	}
	return nil
}
