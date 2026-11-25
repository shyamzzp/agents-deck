// Package words asks macOS what a request means.
//
// The deck mines each agent's own tasks out of the prompts of the session
// behind its card. Judged on the words alone that gets the shape of a request
// right and its meaning wrong: "look at today's meetings" and "check the
// meetings scheduled for today" are one task, and "run the tests" is already
// one of the eight every agent has.
//
// macOS has a sentence model in the system (NLEmbedding), which costs nothing
// to ship and nothing to download. Go here has no Apple frameworks (no cgo in
// this service), so, as with Bluetooth, a small helper beside agentctl does
// that part and this package talks to it in JSON lines (clients/words).
//
// Everything degrades rather than fails: no helper, an old macOS, a helper
// that dies -- the caller gets nothing back and judges on the words, which is
// a worse list of tasks, not a broken one.
package words

import (
	"bufio"
	"encoding/json"
	"errors"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"time"
)

// EnvHelper names the helper to run instead of the one next to agentctl
// (tests, development). "none" turns meaning off.
const EnvHelper = "AGENTS_DECK_WORDS_HELPER"

// ErrUnavailable: no helper on this computer, or it would not start.
var ErrUnavailable = errors.New("this computer has no sentence model helper")

// batch is how many sentences go in one request. A vector is 512 floats, so a
// batch is a few hundred kilobytes of JSON: enough to keep the helper busy,
// small enough that nothing sits in memory for long.
const batch = 48

// retry is how long a helper that failed is left alone before it is tried
// again, so a computer without one is not asked every half minute forever.
const retry = 10 * time.Minute

// cacheMax is how many sentences are remembered. The same task texts are
// judged over and over as sessions come and go; a prompt is about 60 bytes
// and its vector 2 KiB, so this is a few megabytes at the very most.
const cacheMax = 2000

// Find is the helper to run: $AGENTS_DECK_WORDS_HELPER, else deck-words next
// to this executable (inside the app on macOS), else "".
func Find() string {
	if p, ok := os.LookupEnv(EnvHelper); ok {
		if p == "none" {
			return ""
		}
		return p
	}
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	exe, _ = filepath.EvalSymlinks(exe)
	name := "deck-words"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	p := filepath.Join(filepath.Dir(exe), name)
	if st, err := os.Stat(p); err == nil && !st.IsDir() {
		return p
	}
	return ""
}

// Sense turns sentences into vectors with the helper. The zero value is
// usable: the helper starts when something is first asked, and stops being
// asked once it has failed.
type Sense struct {
	// Helper is the program to run; empty means [Find] decides.
	Helper string

	mu     sync.Mutex
	cmd    *exec.Cmd
	in     *bufio.Writer
	out    *bufio.Reader
	failed time.Time
	why    error
	cache  map[string][]float32
}

type request struct {
	Texts []string `json:"texts"`
}

type reply struct {
	Dim     int         `json:"dim"`
	Vectors [][]float32 `json:"vectors"`
	Error   string      `json:"error"`
}

// Vectors is one vector per text, in the order they came, with an empty one
// for a sentence the model has nothing for. It reports [ErrUnavailable] when
// this computer cannot do it at all.
func (s *Sense) Vectors(texts []string) ([][]float32, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([][]float32, len(texts))
	var want []string
	var where []int
	for i, t := range texts {
		if v, ok := s.cache[t]; ok {
			out[i] = v
			continue
		}
		want = append(want, t)
		where = append(where, i)
	}
	if len(want) == 0 {
		return out, nil
	}
	if err := s.start(); err != nil {
		return nil, err
	}
	for from := 0; from < len(want); from += batch {
		to := min(from+batch, len(want))
		got, err := s.ask(want[from:to])
		if err != nil {
			s.stop(err)
			return nil, err
		}
		for i, v := range got {
			at := where[from+i]
			out[at] = v
			s.remember(want[from+i], v)
		}
	}
	return out, nil
}

// Close stops the helper. A Sense that is used again starts another one.
func (s *Sense) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stop(nil)
}

// Available says whether the helper is there and has not failed. It does not
// start one.
func (s *Sense) Available() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cmd != nil {
		return true
	}
	if !s.failed.IsZero() && time.Since(s.failed) < retry {
		return false
	}
	return s.helper() != ""
}

func (s *Sense) helper() string {
	if s.Helper != "" {
		return s.Helper
	}
	return Find()
}

func (s *Sense) start() error {
	if s.cmd != nil {
		return nil
	}
	if !s.failed.IsZero() && time.Since(s.failed) < retry {
		return s.why
	}
	path := s.helper()
	if path == "" {
		s.failed, s.why = time.Now(), ErrUnavailable
		return s.why
	}
	cmd := exec.Command(path)
	in, err := cmd.StdinPipe()
	if err != nil {
		s.failed, s.why = time.Now(), err
		return err
	}
	outPipe, err := cmd.StdoutPipe()
	if err != nil {
		s.failed, s.why = time.Now(), err
		return err
	}
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil {
		s.failed, s.why = time.Now(), err
		return err
	}
	s.cmd, s.in, s.out = cmd, bufio.NewWriter(in), bufio.NewReaderSize(outPipe, 1<<20)
	s.failed, s.why = time.Time{}, nil
	return nil
}

// stop ends the helper and remembers why, so a computer that cannot do this
// is left alone for a while.
func (s *Sense) stop(why error) {
	if s.cmd != nil {
		_ = s.cmd.Process.Kill()
		_ = s.cmd.Wait()
		s.cmd, s.in, s.out = nil, nil, nil
	}
	if why != nil {
		s.failed, s.why = time.Now(), why
	}
}

func (s *Sense) ask(texts []string) ([][]float32, error) {
	line, err := json.Marshal(request{Texts: texts})
	if err != nil {
		return nil, err
	}
	if _, err := s.in.Write(append(line, '\n')); err != nil {
		return nil, err
	}
	if err := s.in.Flush(); err != nil {
		return nil, err
	}
	// One reply per request, in order: the helper is one process answering one
	// caller, and this package holds its lock while it waits.
	raw, err := s.out.ReadBytes('\n')
	if err != nil {
		return nil, err
	}
	var r reply
	if err := json.Unmarshal(raw, &r); err != nil {
		return nil, err
	}
	if r.Error != "" {
		return nil, errors.New(r.Error)
	}
	if len(r.Vectors) != len(texts) {
		return nil, errors.New("helper answered with the wrong number of vectors")
	}
	return r.Vectors, nil
}

func (s *Sense) remember(text string, v []float32) {
	if s.cache == nil {
		s.cache = make(map[string][]float32, cacheMax)
	}
	if len(s.cache) >= cacheMax {
		// Nothing clever: the texts worth remembering are the ones asked for
		// again, and they are asked for again straight away.
		clear(s.cache)
	}
	s.cache[text] = v
}

// Cosine is how alike two sentences are, from -1 to 1. An empty vector (a
// sentence the model had nothing for) is alike to nothing.
func Cosine(a, b []float32) float32 {
	if len(a) == 0 || len(b) != len(a) {
		return 0
	}
	var dot, na, nb float64
	for i := range a {
		x, y := float64(a[i]), float64(b[i])
		dot += x * y
		na += x * x
		nb += y * y
	}
	if na == 0 || nb == 0 {
		return 0
	}
	return float32(dot / (math.Sqrt(na) * math.Sqrt(nb)))
}
