package main

import (
	"os"
	"os/exec"
	"syscall"
	"testing"
	"time"
)

func TestSignalProcessRefRejectsReusedIdentity(t *testing.T) {
	identity, ok := processIdentity(os.Getpid())
	if !ok {
		t.Fatal("could not identify test process")
	}
	alive, err := signalProcessRef(
		processRef{pid: os.Getpid(), identity: identity + "-stale"}, syscall.SIGKILL)
	if err != nil {
		t.Fatal(err)
	}
	if alive {
		t.Fatal("stale process identity was treated as live")
	}
}

func TestKillProcessTreeClosesDescendants(t *testing.T) {
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

	deadline := time.Now().Add(time.Second)
	root, err := waitProcessRef(cmd.Process.Pid, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	var refs []processRef
	for {
		refs, err = captureProcessTree(root)
		if err != nil {
			t.Fatal(err)
		}
		if len(refs) >= 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("test process did not create a descendant")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err := killProcessTree(root, refs); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("root process was not reaped")
	}
}

func TestKillProcessTreeFindsSessionMembersAfterRootExit(t *testing.T) {
	cmd := exec.Command("/bin/sh", "-c", "sleep 0.2; sleep 60 &")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	root, err := waitProcessRef(cmd.Process.Pid, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Wait(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = killProcessTree(root, nil) })
	deadline := time.Now().Add(time.Second)
	for {
		refs, err := captureProcessTree(root)
		if err != nil {
			t.Fatal(err)
		}
		if len(refs) > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("background session member did not survive root")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err := killProcessTree(root, nil); err != nil {
		t.Fatal(err)
	}
	refs, err := captureProcessTree(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(refs) != 0 {
		t.Fatalf("session members survived verified kill: %+v", refs)
	}
}
