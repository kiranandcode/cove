package main

// The wire protocol between `attach` (local) and the session daemon (remote),
// carried over ssh stdio through `bridge`. Every frame is
//
//	[type u8][length u32 big-endian][payload]
//
// Output and input are byte streams with absolute offsets, so after a dropped
// connection the client resumes exactly where it left off: the daemon replays
// the output it missed from a ring buffer and skips input it already has.

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"sync"
)

const (
	fHello    = 1  // C→S json hello
	fWelcome  = 2  // S→C json welcome
	fInput    = 3  // C→S u64 input offset + bytes
	fOutput   = 4  // S→C u64 output offset + bytes
	fResize   = 5  // C→S json {cols, rows}
	fPing     = 6  // C→S u64 client nanos
	fPong     = 7  // S→C the ping payload, echoed
	fMeta     = 8  // S→C json session metadata (agent, cwd, ...)
	fPut      = 9  // C→S json cove-dir file write (state.json, replies.jsonl)
	fAppend   = 10 // S→C json cove-dir lines the remote agent wrote (notify, commands, ...)
	fExit     = 11 // S→C json {code}: the session's program ended
	fInputAck = 12 // S→C u64 input bytes received so far
	fKill     = 13 // C→S end the session; S→C json {ok, error?}
)

const protocolVersion = 3 // 3: fKill replies only after verified tree closure

const maxFrame = 16 << 20

// The bridge prints this once its pty is raw, so the client knows everything
// after it is frames (anything before is the remote pty's cooked-mode noise).
const readyMarker = "\x00COVE-REMOTE-READY\x00"

type hello struct {
	Session string            `json:"session"`
	Client  string            `json:"client"` // input offsets are per client process
	Resume  int64             `json:"resume"` // output offset to resume from; -1 = fresh attach
	Cols    int               `json:"cols"`
	Rows    int               `json:"rows"`
	Cwd     string            `json:"cwd,omitempty"`
	Cmd     string            `json:"cmd,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
	Replay  int64             `json:"replay"` // on a fresh attach, how much history to replay
}

type welcome struct {
	InAck    int64 `json:"in_ack"`    // input bytes the daemon already has
	OutStart int64 `json:"out_start"` // oldest output offset still buffered
	Head     int64 `json:"head"`      // output offset of the next byte
	From     int64 `json:"from"`      // where this connection's output starts
	Created  bool  `json:"created"`   // the daemon was started for this hello
	Pid      int   `json:"pid"`
	Exited   bool  `json:"exited"`
	Proto    int   `json:"proto"` // 2+: fPut data may be gzipped
}

type meta struct {
	Agent string `json:"agent"`
	Busy  bool   `json:"busy"`
	Idle  bool   `json:"idle"`
	Cwd   string `json:"cwd"`
	Pid   int    `json:"pid"`
	Echo  bool   `json:"echo"` // tty is cooked with echo on (a plain line read)
}

type fileMsg struct {
	Path   string `json:"path"` // relative to the cove dir
	Data   []byte `json:"data"`
	Append bool   `json:"append,omitempty"`
	Gz     bool   `json:"gz,omitempty"`
}

type frame struct {
	t byte
	p []byte
}

func readFrame(r *bufio.Reader) (frame, error) {
	var hdr [5]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return frame{}, err
	}
	n := binary.BigEndian.Uint32(hdr[1:])
	if n > maxFrame {
		return frame{}, errors.New("frame too large")
	}
	p := make([]byte, n)
	if _, err := io.ReadFull(r, p); err != nil {
		return frame{}, err
	}
	return frame{hdr[0], p}, nil
}

// frameWriter serialises frames from several goroutines onto one stream.
type frameWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (fw *frameWriter) write(t byte, parts ...[]byte) error {
	n := 0
	for _, p := range parts {
		n += len(p)
	}
	buf := make([]byte, 5, 5+n)
	buf[0] = t
	binary.BigEndian.PutUint32(buf[1:], uint32(n))
	for _, p := range parts {
		buf = append(buf, p...)
	}
	fw.mu.Lock()
	defer fw.mu.Unlock()
	_, err := fw.w.Write(buf)
	return err
}

func (fw *frameWriter) json(t byte, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return fw.write(t, b)
}

func (fw *frameWriter) offset(t byte, off int64, data []byte) error {
	var h [8]byte
	binary.BigEndian.PutUint64(h[:], uint64(off))
	return fw.write(t, h[:], data)
}

func u64(p []byte) (int64, []byte) {
	if len(p) < 8 {
		return 0, nil
	}
	return int64(binary.BigEndian.Uint64(p[:8])), p[8:]
}
