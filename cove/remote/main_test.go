package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func setShortHome(t *testing.T) {
	t.Helper()
	home, err := os.MkdirTemp("/tmp", "cove-remote-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(home) })
	t.Setenv("HOME", home)
}

func serveKillControl(t *testing.T, sess string, ok bool, proto int, exitFirst bool) <-chan error {
	t.Helper()
	dir := sessionDir(sess)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("unix", filepath.Join(dir, "sock"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	done := make(chan error, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			done <- err
			return
		}
		defer c.Close()
		r := bufio.NewReader(c)
		f, err := readFrame(r)
		if err == nil && f.t != fHello {
			err = fmt.Errorf("expected hello, got %d", f.t)
		}
		if err != nil {
			done <- err
			return
		}
		fw := &frameWriter{w: c}
		if err := fw.json(fWelcome, welcome{Proto: proto}); err != nil {
			done <- err
			return
		}
		f, err = readFrame(r)
		if err == nil && f.t != fKill {
			err = fmt.Errorf("expected kill, got %d", f.t)
		}
		if err != nil {
			done <- err
			return
		}
		result := map[string]any{"ok": ok}
		if !ok {
			result["error"] = "tree did not exit"
		}
		if ok && exitFirst {
			if err := fw.json(fExit, map[string]int{"code": 0}); err != nil {
				done <- err
				return
			}
		}
		if err := fw.json(fKill, result); err != nil {
			done <- err
			return
		}
		if ok && !exitFirst {
			err = fw.json(fExit, map[string]int{"code": 0})
		}
		done <- err
	}()
	return done
}

func TestLocalKillUsesLiveDaemonControl(t *testing.T) {
	setShortHome(t)
	done := serveKillControl(t, "cove-test", true, protocolVersion, false)
	if err := localKill("cove-test"); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestLocalKillReturnsDaemonFailure(t *testing.T) {
	setShortHome(t)
	done := serveKillControl(t, "cove-test", false, protocolVersion, false)
	err := localKill("cove-test")
	if err == nil || !strings.Contains(err.Error(), "tree did not exit") {
		t.Fatalf("expected daemon failure, got %v", err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestLocalKillRejectsOldDaemon(t *testing.T) {
	setShortHome(t)
	done := serveKillControl(t, "cove-test", true, protocolVersion-1, false)
	err := localKill("cove-test")
	if err == nil || !strings.Contains(err.Error(), "too old") {
		t.Fatalf("expected rolling-upgrade failure, got %v", err)
	}
	_ = <-done
}

func TestLocalKillRequiresAckEvenWhenExitArrivesFirst(t *testing.T) {
	setShortHome(t)
	done := serveKillControl(t, "cove-test", true, protocolVersion, true)
	if err := localKill("cove-test"); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestLocalKillAbsenceAndStartupWindow(t *testing.T) {
	setShortHome(t)
	if err := localKill("cove-missing"); err != nil {
		t.Fatalf("verified absence should be idempotent: %v", err)
	}
	if err := os.MkdirAll(sessionDir("cove-starting"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := localKill("cove-starting"); err == nil {
		t.Fatal("a session directory without control socket is unknown, not stopped")
	}
}

func TestLocalKillRetiresVerifiedStaleSession(t *testing.T) {
	setShortHome(t)
	sess := "cove-stale"
	cmd := exec.Command("/bin/sh", "-c", "sleep 60 & wait")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(done)
	}()
	t.Cleanup(func() {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		select {
		case <-done:
		case <-time.After(time.Second):
		}
	})
	root, err := waitProcessRef(cmd.Process.Pid, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	dir := sessionDir(sess)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(map[string]any{"pid": root.pid, "root_identity": root.identity})
	if err := os.WriteFile(filepath.Join(dir, "info.json"), b, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := localKill(sess); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("stale session process was not reaped")
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("stale session directory remains: %v", err)
	}
}

func TestRunServeKillControlEndToEnd(t *testing.T) {
	setShortHome(t)
	t.Setenv("COVE_REMOTE_NO_CAFFEINATE", "1")
	sess := "cove-end-to-end"
	h := hello{Session: sess, Client: "test", Resume: -1, Rows: 24, Cols: 80,
		Cwd: os.Getenv("HOME"), Cmd: "sleep 60"}
	b, err := json.Marshal(h)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- runServe(base64.StdEncoding.EncodeToString(b)) }()
	t.Cleanup(func() { _ = localKill(sess) })

	sock := filepath.Join(sessionDir(sess), "sock")
	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, err := os.Stat(sock); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("session control socket did not appear")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err := localKill(sess); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("session daemon did not exit after verified kill")
	}
	if _, err := os.Stat(sessionDir(sess)); !os.IsNotExist(err) {
		t.Fatalf("retired session directory remains: %v", err)
	}
}

func TestRunServeWaitsForTransientCleanupLock(t *testing.T) {
	setShortHome(t)
	t.Setenv("COVE_REMOTE_NO_CAFFEINATE", "1")
	sess := "cove-lock-race"
	lock, err := acquireSessionLock(sess, 0)
	if err != nil {
		t.Fatal(err)
	}
	h := hello{Session: sess, Client: "test", Resume: -1, Rows: 24, Cols: 80,
		Cwd: os.Getenv("HOME"), Cmd: "sleep 60"}
	b, _ := json.Marshal(h)
	done := make(chan error, 1)
	go func() { done <- runServe(base64.StdEncoding.EncodeToString(b)) }()
	time.Sleep(100 * time.Millisecond)
	releaseSessionLock(lock)
	t.Cleanup(func() { _ = localKill(sess) })

	sock := filepath.Join(sessionDir(sess), "sock")
	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, err := os.Stat(sock); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("server lost the startup race with transient cleanup")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err := localKill(sess); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("session daemon did not exit")
	}
}
