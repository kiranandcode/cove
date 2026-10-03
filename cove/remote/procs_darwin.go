package main

// Process-tree inspection straight from the kernel. The pro's lsof can hang
// for minutes and ps is slow, so the session daemon asks sysctl and
// proc_pidinfo instead.

/*
#include <libproc.h>
#include <sys/proc_info.h>
*/
import "C"

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
	"unsafe"

	"golang.org/x/sys/unix"
)

// argv returns a process's command line, or its short name if that's hidden.
func argv(pid int, comm string) string {
	raw, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil || len(raw) < 4 {
		return comm
	}
	argc := int(*(*int32)(unsafe.Pointer(&raw[0])))
	rest := raw[4:]
	// skip the exec path and its NUL padding
	i := bytes.IndexByte(rest, 0)
	if i < 0 {
		return comm
	}
	rest = rest[i:]
	for len(rest) > 0 && rest[0] == 0 {
		rest = rest[1:]
	}
	args := make([]string, 0, argc)
	for len(args) < argc && len(rest) > 0 {
		j := bytes.IndexByte(rest, 0)
		if j < 0 {
			j = len(rest)
		}
		args = append(args, string(rest[:j]))
		if j == len(rest) {
			break
		}
		rest = rest[j+1:]
	}
	return strings.Join(args, " ")
}

// procTable maps each pid to its children and its short name.
func procTable() (kids map[int][]int, comm, identities map[int]string, ok bool) {
	procs, err := unix.SysctlKinfoProcSlice("kern.proc.all")
	if err != nil {
		return nil, nil, nil, false
	}
	kids, comm, identities = map[int][]int{}, map[int]string{}, map[int]string{}
	for _, p := range procs {
		pid, ppid := int(p.Proc.P_pid), int(p.Eproc.Ppid)
		kids[ppid] = append(kids[ppid], pid)
		comm[pid] = unix.ByteSliceToString(p.Proc.P_comm[:])
		t := p.Proc.P_starttime
		identities[pid] = fmt.Sprintf("%d:%d", t.Sec, t.Usec)
	}
	return kids, comm, identities, true
}

func processIdentity(pid int) (string, bool) {
	p, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || int(p.Proc.P_pid) != pid {
		return "", false
	}
	t := p.Proc.P_starttime
	return fmt.Sprintf("%d:%d", t.Sec, t.Usec), true
}

func cwdOf(pid int) string {
	var vpi C.struct_proc_vnodepathinfo
	n := C.proc_pidinfo(C.int(pid), C.PROC_PIDVNODEPATHINFO, 0, unsafe.Pointer(&vpi), C.int(unsafe.Sizeof(vpi)))
	if n <= 0 {
		return ""
	}
	return C.GoString(&vpi.pvi_cdir.vip_path[0])
}

// ttyGetReq reads a pty's termios (for the echo flags in the metadata).
const ttyGetReq = unix.TIOCGETA

// terminfoSys follows the kitty checkout's terminfo in TERMINFO_DIRS.
const terminfoSys = "/usr/share/terminfo"

// keepAwake holds a caffeinate for the daemon's life: the point of running
// something remotely is that it keeps going.
func keepAwake(pid int) {
	cf := exec.Command("/usr/bin/caffeinate", "-ims", "-w", fmt.Sprint(pid))
	if cf.Start() == nil {
		go cf.Wait()
	}
}
