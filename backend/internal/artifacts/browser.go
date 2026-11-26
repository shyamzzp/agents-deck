// Artifacts opened in a browser.
//
// The deck knows an Artifact was gone to when an agent's tool call named it,
// or when somebody opened it from the deck itself. Neither covers the plainest
// case of all: the person opening the link in their own browser. That leaves
// no trace in any transcript, and the tile goes on saying the artifact was
// last touched days ago while its tab is open on the screen.
//
// The browsers keep that themselves. Chrome and the browsers built on it
// (Brave, Edge, Arc, Vivaldi, Chromium) each keep a History database per
// profile; Safari keeps one of its own. Only the artifact addresses are read
// out of them, never anything else that was visited.
package artifacts

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// browserWait is how long a history read may take before it is given up on: a
// browser writing to its own database can hold it, and the deck has a page to
// draw either way.
const browserWait = 4 * time.Second

// chromeRoots are the Chrome-shaped browsers, each with profiles under it.
var chromeRoots = []string{
	"Google/Chrome", "Google/Chrome Beta", "Chromium",
	"BraveSoftware/Brave-Browser", "Microsoft Edge", "Arc",
	"Vivaldi", "com.operasoftware.Opera",
}

// Browsed is when each Artifact was last opened in a browser on this Mac.
func Browsed() map[string]time.Time {
	out := map[string]time.Time{}
	home, err := os.UserHomeDir()
	if err != nil {
		return out
	}
	for _, db := range historyFiles(home) {
		for url, at := range db.read() {
			if at.After(out[url]) {
				out[url] = at
			}
		}
	}
	return out
}

// history is one browser's history database and how its times are kept.
type history struct {
	path string
	// query returns the address and a number; epoch turns that number into a
	// time. Chrome counts microseconds from 1601, Safari seconds from 2001.
	query string
	epoch func(float64) time.Time
}

func historyFiles(home string) []history {
	var out []history
	support := filepath.Join(home, "Library", "Application Support")
	for _, root := range chromeRoots {
		dirs, _ := filepath.Glob(filepath.Join(support, root, "*", "History"))
		for _, p := range dirs {
			out = append(out, history{
				path: p,
				query: `select url, last_visit_time from urls ` +
					`where url like 'https://claude.ai/artifact/%'`,
				epoch: func(v float64) time.Time {
					return time.UnixMicro(int64(v) - 11644473600*1e6)
				},
			})
		}
	}
	safari := filepath.Join(home, "Library", "Safari", "History.db")
	if _, err := os.Stat(safari); err == nil {
		out = append(out, history{
			path: safari,
			query: `select i.url, v.visit_time from history_items i ` +
				`join history_visits v on v.history_item = i.id ` +
				`where i.url like 'https://claude.ai/artifact/%'`,
			epoch: func(v float64) time.Time {
				return time.Unix(int64(v)+978307200, 0)
			},
		})
	}
	return out
}

// read asks one database what it has. The file is opened immutable, which
// reads it as it sits without taking a lock or writing a journal beside it:
// the browser goes on using it untouched.
func (h history) read() map[string]time.Time {
	ctx, stop := context.WithTimeout(context.Background(), browserWait)
	defer stop()
	cmd := exec.CommandContext(ctx, "sqlite3", "-separator", "\t",
		"file:"+h.path+"?immutable=1", h.query)
	out, err := cmd.Output()
	if err != nil {
		// No sqlite3, no permission (Safari's is behind Full Disk Access),
		// or a database this browser keeps differently: there is simply
		// nothing to learn here.
		return nil
	}
	found := map[string]time.Time{}
	for _, line := range strings.Split(string(out), "\n") {
		url, num, ok := strings.Cut(line, "\t")
		if !ok {
			continue
		}
		v, err := strconv.ParseFloat(strings.TrimSpace(num), 64)
		if err != nil || v <= 0 {
			continue
		}
		// A shared link carries ?sk=…, and an Artifact opened from a chat
		// carries ?via=…: the thing itself is the address without them.
		if link := link.FindString(url); link != "" {
			at := h.epoch(v)
			if at.After(found[link]) {
				found[link] = at
			}
		}
	}
	return found
}
