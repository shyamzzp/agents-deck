// Package artifacts: what a session made that a browser can open.
//
// An agent's work leaves files behind, and some of them are things to look at
// rather than code to read: a page, a PDF, a diagram, a chart, a document.
// The deck lists those on a page of their own, newest first, and opening one
// opens it in the browser on the Mac the deck runs on.
//
// They are read out of the session's own transcript, where every file Claude
// wrote or changed is recorded as a tool call with its path. Nothing is
// indexed and nothing is watched: a scan is a read of a file the deck already
// knows about, kept while that file has not changed.
package artifacts

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Made is one thing a session made.
type Made struct {
	Agent  string    `json:"agent"`            // the agent that made it
	Title  string    `json:"title,omitempty"`  // …as the deck calls it
	Path   string    `json:"path"`             // where it is, in full
	Name   string    `json:"name"`             // its file name
	Folder string    `json:"folder,omitempty"` // the folder it sits in, shortened
	Kind   string    `json:"kind"`             // page | document | image | sheet
	At     time.Time `json:"at"`               // when it was last written
}

// What a browser is worth opening for, by extension. Code and configuration
// are left out: this is a page of things to look at.
var kinds = map[string]string{
	".html": "page", ".htm": "page", ".pdf": "document", ".md": "document",
	".svg": "image", ".png": "image", ".jpg": "image", ".jpeg": "image",
	".gif": "image", ".webp": "image", ".csv": "sheet",
}

// The tool calls that write a file, and where each keeps its path.
var writes = map[string]bool{
	"Write": true, "Edit": true, "MultiEdit": true, "NotebookEdit": true,
}

// Max is how many a scan keeps per session: a long session writes the same
// page a hundred times, and what matters is the latest of each.
const Max = 60

// Book scans transcripts and remembers what it found, while the file it
// found it in stays as it was.
type Book struct {
	mu   sync.Mutex
	seen map[string]scan // transcript path -> what it held
}

type scan struct {
	size int64
	mod  time.Time
	made []Made
}

// Of is what the session whose transcript is at path made, newest first.
// agent and title name it for the list.
func (b *Book) Of(path, agent, title string) []Made {
	if path == "" {
		return nil
	}
	st, err := os.Stat(path)
	if err != nil {
		return nil
	}
	b.mu.Lock()
	if s, ok := b.seen[path]; ok && s.size == st.Size() && s.mod.Equal(st.ModTime()) {
		out := name(s.made, agent, title)
		b.mu.Unlock()
		return out
	}
	b.mu.Unlock()

	made := Scan(path)
	b.mu.Lock()
	if b.seen == nil {
		b.seen = map[string]scan{}
	}
	b.seen[path] = scan{size: st.Size(), mod: st.ModTime(), made: made}
	b.mu.Unlock()
	return name(made, agent, title)
}

// Forget drops a transcript's scan (its session left the deck).
func (b *Book) Forget(path string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.seen, path)
}

func name(made []Made, agent, title string) []Made {
	out := make([]Made, len(made))
	for i, m := range made {
		m.Agent, m.Title = agent, title
		out[i] = m
	}
	return out
}

// Scan reads a transcript and lists what it made, newest first, one entry per
// file (the last time it was written).
func Scan(path string) []Made {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	latest := map[string]Made{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		var l struct {
			Type      string `json:"type"`
			Timestamp string `json:"timestamp"`
			Sidechain bool   `json:"isSidechain"`
			Message   *struct {
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal(sc.Bytes(), &l) != nil || l.Type != "assistant" ||
			l.Message == nil || l.Sidechain {
			continue
		}
		var blocks []struct {
			Type  string `json:"type"`
			Name  string `json:"name"`
			Input struct {
				Path string `json:"file_path"`
			} `json:"input"`
		}
		if json.Unmarshal(l.Message.Content, &blocks) != nil {
			continue
		}
		at, _ := time.Parse(time.RFC3339Nano, l.Timestamp)
		for _, bl := range blocks {
			if bl.Type != "tool_use" || !writes[bl.Name] || bl.Input.Path == "" {
				continue
			}
			kind, ok := kinds[strings.ToLower(filepath.Ext(bl.Input.Path))]
			if !ok || !worth(bl.Input.Path) {
				continue
			}
			latest[bl.Input.Path] = Made{
				Path:   bl.Input.Path,
				Name:   filepath.Base(bl.Input.Path),
				Folder: short(filepath.Dir(bl.Input.Path)),
				Kind:   kind,
				At:     at,
			}
		}
	}
	out := make([]Made, 0, len(latest))
	for _, m := range latest {
		out = append(out, m)
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].At.Equal(out[j].At) {
			return out[i].At.After(out[j].At)
		}
		return out[i].Path < out[j].Path
	})
	if len(out) > Max {
		out = out[:Max]
	}
	return out
}

// worth leaves out the files an agent writes about its own work rather than
// as the work: what Claude Code keeps under ~/.claude (its memory, its
// settings, its own transcripts) is not something to open in a browser.
func worth(path string) bool {
	return !strings.Contains(path, string(filepath.Separator)+".claude"+string(filepath.Separator))
}

// short writes a folder the way a person says it: ~ for home.
func short(dir string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return dir
	}
	if dir == home {
		return "~"
	}
	if rest, ok := strings.CutPrefix(dir, home+string(filepath.Separator)); ok {
		return "~/" + rest
	}
	return dir
}

// Openable says whether the deck would open this path in a browser: it has to
// be one of the kinds listed, and it has to be there.
func Openable(path string) bool {
	if _, ok := kinds[strings.ToLower(filepath.Ext(path))]; !ok {
		return false
	}
	st, err := os.Stat(path)
	return err == nil && !st.IsDir()
}
