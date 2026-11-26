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
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
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

// link is a published Artifact: a page on claude.ai that the deck can open
// like any other, and the one most worth listing. They show up in the
// Artifact tool's own answers, as a title and a link:
//
//   - (mine) Family Book Register — https://claude.ai/artifact/DjMW… — favicon 📖 — updated 2026-11-18
//
// so the title before the link is taken where there is one.
// The id is 22 characters; a shorter match is a link the text cut short with
// an ellipsis, which would open nothing.
var link = regexp.MustCompile(`https://claude\.ai/artifact/[A-Za-z0-9]{20,24}\b`)

// titled is that listing line, for the name to go with the link.
var titled = regexp.MustCompile(`(?:\(mine\)|\(shared\)|^|\n)\s*([^\n*—]{2,70}?)\s+—\s+(https://claude\.ai/artifact/[A-Za-z0-9]{20,24})`)

// updated is the date the listing gives each Artifact ("… — updated
// 2026-11-18"). Without it every link in one listing carries the moment the
// listing was read, so fifteen of them read "44h" together and the time says
// nothing about the thing itself.
var updated = regexp.MustCompile(`(https://claude\.ai/artifact/[A-Za-z0-9]{20,24})[^\n]{0,80}?updated (\d{4}-\d{2}-\d{2})`)

// opened is how many Artifacts one tool call may name before it stops being
// a visit to any of them: a call carrying one or two links went to those,
// while a listing that comes back with thirty is a shelf being read, not a
// thing being opened.
const opened = 3

// visits are the tools that go to an Artifact rather than mention one: a
// grep through the transcripts names a link without ever opening it, and the
// tile would read as though somebody had been there.
var visits = map[string]bool{
	"Artifact": true, "ArtifactComments": true, "ArtifactData": true,
	"WebFetch": true,
}

// named is the same thing as the tool writes it in JSON, where the title and
// the link are fields rather than a sentence.
var named = regexp.MustCompile(`"(?:title|name)":\s*"([^"]{2,70})"[^{}]{0,200}?"(?:type_)?url":\s*"(https://claude\.ai/artifact/[A-Za-z0-9]{20,24})"`)

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
	went map[string]trip // transcript path -> the Artifacts it opened
}

// trip is one transcript's visits, kept while the file stays as it was.
type trip struct {
	size int64
	mod  time.Time
	at   map[string]Seen
}

// Seen is what a sweep learned about one published Artifact: when it was last
// gone to, and what it is called.
type Seen struct {
	At   time.Time
	Name string
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
	links := map[string]Made{}
	// When each Artifact was last gone to, as opposed to merely listed.
	visit := map[string]time.Time{}
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
		if json.Unmarshal(sc.Bytes(), &l) != nil || l.Message == nil || l.Sidechain {
			continue
		}
		// Published Artifacts come back in the tool's own answers, which are
		// user-role lines, so those are read as well as what Claude wrote.
		if link.Match(sc.Bytes()) {
			at, _ := time.Parse(time.RFC3339Nano, l.Timestamp)
			text := unescape(string(l.Message.Content))
			when := dated(text)
			for url, name := range found(text) {
				// Its own date where the listing gives one; the moment the
				// deck read the listing only as a last resort.
				seen := at
				if d, ok := when[url]; ok {
					seen = d
				}
				links[url] = Made{Path: url, Name: name, Kind: "link", At: seen}
			}
		}
		if l.Type != "assistant" {
			continue
		}
		var blocks []struct {
			Type  string          `json:"type"`
			Name  string          `json:"name"`
			Input json.RawMessage `json:"input"`
		}
		if json.Unmarshal(l.Message.Content, &blocks) != nil {
			continue
		}
		at, _ := time.Parse(time.RFC3339Nano, l.Timestamp)
		for _, bl := range blocks {
			if bl.Type != "tool_use" {
				continue
			}
			// A call that names a handful of Artifacts went to them: read,
			// published, commented on, fetched. That is the last time this
			// one was opened, which is what its tile says.
			if went := link.FindAllString(string(bl.Input), -1); visits[bl.Name] && len(went) <= opened {
				for _, url := range went {
					if at.After(visit[url]) {
						visit[url] = at
					}
					// A session that opens an Artifact it never listed still
					// knows when it went there. It is carried out nameless,
					// for whichever session does know the name.
					if _, ok := links[url]; !ok {
						links[url] = Made{Path: url, Kind: "link"}
					}
				}
			}
			if !writes[bl.Name] {
				continue
			}
			var in struct {
				Path string `json:"file_path"`
			}
			if json.Unmarshal(bl.Input, &in) != nil || in.Path == "" {
				continue
			}
			kind, ok := kinds[strings.ToLower(filepath.Ext(in.Path))]
			if !ok || !worth(in.Path) {
				continue
			}
			latest[in.Path] = Made{
				Path:   in.Path,
				Name:   filepath.Base(in.Path),
				Folder: short(filepath.Dir(in.Path)),
				Kind:   kind,
				At:     at,
			}
		}
	}
	out := make([]Made, 0, len(latest)+len(links))
	for _, m := range latest {
		out = append(out, m)
	}
	for url, m := range links {
		// A link's time is when it was last opened. Only where nothing ever
		// went to it does it fall back to the date the listing gave.
		if when, ok := visit[url]; ok {
			m.At = when
		}
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

// found is every published Artifact in one message, by link, with the title
// beside it where the text gives one.
// unescape turns a line as it sits in the file into the text it stands for,
// as far as the patterns here care: it is a JSON string there, so the dash
// between a title and its link is \u2014 rather than the character itself.
func unescape(text string) string {
	return strings.NewReplacer(
		`\u2014`, "\u2014", `\u00b7`, "\u00b7", `\n`, "\n", `\"`, `"`,
	).Replace(text)
}

// dated is the date each Artifact in a listing was last updated.
func dated(text string) map[string]time.Time {
	out := map[string]time.Time{}
	for _, m := range updated.FindAllStringSubmatch(text, -1) {
		if d, err := time.ParseInLocation("2006-01-02", m[2], time.Local); err == nil {
			out[m[1]] = d
		}
	}
	return out
}

func found(text string) map[string]string {
	out := map[string]string{}
	for _, m := range link.FindAllString(text, -1) {
		out[m] = ""
	}
	for _, m := range named.FindAllStringSubmatch(text, -1) {
		if name := strings.TrimSpace(m[1]); name != "" {
			out[m[2]] = name
		}
	}
	for _, m := range titled.FindAllStringSubmatch(text, -1) {
		name := strings.TrimSpace(strings.Trim(m[1], `"\'- :`))
		for _, tag := range []string{"(mine)", "(shared)"} {
			name = strings.TrimSpace(strings.TrimPrefix(name, tag))
		}
		// A name made of escapes or punctuation is no name at all.
		if name != "" && !strings.Contains(name, `\u`) && len(name) < 70 {
			out[m[2]] = name
		}
	}
	// A link with no title beside it was mentioned in passing rather than
	// made or listed: "artifact 5M7UeX" on a tile says nothing, and a page
	// of those buries the ones worth opening.
	for url, name := range out {
		if name == "" {
			delete(out, url)
		}
	}
	return out
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

// Openable says whether the deck would open this in a browser: a published
// Artifact's link, or a file of one of the kinds listed that is still there.
func Openable(path string) bool {
	if link.MatchString(path) {
		return true
	}
	if _, ok := kinds[strings.ToLower(filepath.Ext(path))]; !ok {
		return false
	}
	st, err := os.Stat(path)
	return err == nil && !st.IsDir()
}

// Visits is when each published Artifact was last gone to, across every
// session on this Mac rather than only the ones still on the deck. A link is
// often published in one session and opened again in another weeks later, and
// the session that opened it has usually long since ended.
//
// A sweep reads every transcript under the given roots, which is a third of a
// second over six hundred megabytes, and each file is remembered while it
// stays as it was, so the sweep after that costs nothing.
func (b *Book) Visits(roots []string) map[string]Seen {
	out := map[string]Seen{}
	done := map[string]bool{}
	for _, root := range roots {
		filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() || filepath.Ext(p) != ".jsonl" || done[p] {
				return nil
			}
			done[p] = true
			for url, seen := range b.visits(p) {
				was := out[url]
				if seen.At.After(was.At) {
					was.At = seen.At
				}
				if was.Name == "" {
					was.Name = seen.Name
				}
				out[url] = was
			}
			return nil
		})
	}
	return out
}

// visits is one transcript's, kept while the file has not changed.
func (b *Book) visits(path string) map[string]Seen {
	st, err := os.Stat(path)
	if err != nil {
		return nil
	}
	b.mu.Lock()
	if v, ok := b.went[path]; ok && v.size == st.Size() && v.mod.Equal(st.ModTime()) {
		b.mu.Unlock()
		return v.at
	}
	b.mu.Unlock()

	at := visited(path)
	b.mu.Lock()
	if b.went == nil {
		b.went = map[string]trip{}
	}
	b.went[path] = trip{size: st.Size(), mod: st.ModTime(), at: at}
	b.mu.Unlock()
	return at
}

// visited reads a transcript for the calls that went to an Artifact.
func visited(path string) map[string]Seen {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	out := map[string]Seen{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		if !link.Match(sc.Bytes()) {
			continue
		}
		var l struct {
			Type      string `json:"type"`
			Timestamp string `json:"timestamp"`
			// A published Artifact is written down as it is published: the
			// address, what it is called, and the file it was made from.
			// This is the only place a published page says its own name, and
			// it is not part of any message, so a scan of what Claude said
			// walks straight past it.
			FrameURL string `json:"frameUrl"`
			Title    string `json:"title"`
			Message  *struct {
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal(sc.Bytes(), &l) != nil {
			continue
		}
		if l.Type == "frame-link" && l.FrameURL != "" {
			if url := link.FindString(l.FrameURL); url != "" {
				at, _ := time.Parse(time.RFC3339Nano, l.Timestamp)
				was := out[url]
				if at.After(was.At) {
					was.At = at
				}
				if name := strings.TrimSpace(l.Title); name != "" {
					was.Name = name
				}
				out[url] = was
			}
			continue
		}
		if l.Type != "assistant" || l.Message == nil {
			continue
		}
		var blocks []struct {
			Type  string          `json:"type"`
			Name  string          `json:"name"`
			Input json.RawMessage `json:"input"`
		}
		if json.Unmarshal(l.Message.Content, &blocks) != nil {
			continue
		}
		at, err := time.Parse(time.RFC3339Nano, l.Timestamp)
		if err != nil {
			continue
		}
		for _, bl := range blocks {
			if bl.Type != "tool_use" || !visits[bl.Name] {
				continue
			}
			went := link.FindAllString(string(bl.Input), -1)
			if len(went) > opened {
				continue
			}
			for _, url := range went {
				if was := out[url]; at.After(was.At) {
					was.At = at
					out[url] = was
				}
			}
		}
	}
	return out
}
