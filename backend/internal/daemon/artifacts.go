// What the agents made, and opening one on this Mac.
//
// The scanning is in internal/artifacts: this is where the deck's own agents
// are walked, and where a file is handed to the computer to open. Only a file
// one of the agents wrote can be opened, and only one a browser is worth
// opening for: a path that was never seen being written is refused, whoever
// asks.
package daemon

import (
	"context"
	"fmt"
	"net/url"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/shyamzzp/agents-deck/backend/internal/artifacts"
	"github.com/shyamzzp/agents-deck/backend/internal/server"
	"github.com/shyamzzp/agents-deck/backend/internal/store"
)

// artifactsMax is how many the list carries: a page of things to look at,
// newest first, not an index of everything ever written.
const artifactsMax = 120

// artifactsEvery is how often the sweep runs again. A sweep whose files have
// not changed costs about thirty milliseconds, so the list is never more than
// this far behind an agent publishing a page or opening a link.
const artifactsEvery = 15 * time.Second

// Artifacts is every agent's made things, newest first, as the last sweep
// left them.
func (d *Daemon) Artifacts() []artifacts.Made {
	return d.keptArtifacts().get()
}

// freshenArtifacts starts the next sweep when the list is due one. It runs
// off the daemon's tick and returns at once.
func (d *Daemon) freshenArtifacts() {
	d.keptArtifacts().due()
}

// keptArtifacts is the kept list, made on first use.
func (d *Daemon) keptArtifacts() *kept[[]artifacts.Made] {
	d.madeOnce.Do(func() {
		d.madeList = newKept(artifactsEvery, d.sweepArtifacts)
	})
	return d.madeList
}

// sweepArtifacts reads what every session made and when each published
// Artifact was last opened. This is the work the page is kept out of.
func (d *Daemon) sweepArtifacts() []artifacts.Made {
	var out []artifacts.Made
	roots := map[string]bool{}
	for _, e := range d.Store.Entries() {
		if e.Transcript == "" {
			continue
		}
		// Every session's folder, not only this one's: a link opened by a
		// session that has since ended still counts as having been opened.
		roots[filepath.Dir(filepath.Dir(e.Transcript))] = true
		out = append(out, d.made.Of(e.Transcript, e.A.ID, e.A.Title)...)
	}
	// A published Artifact's time is when it was last opened. The listing's
	// own date stands only for one nothing ever went to.
	went := d.made.Visits(keys(roots))
	// Opening one in a browser is going to it as surely as any tool call,
	// and it leaves nothing behind in a transcript: the browsers' own
	// history says when (browser.go).
	for url, at := range artifacts.Browsed() {
		was := went[url]
		if at.After(was.At) {
			was.At = at
			went[url] = was
		}
	}
	// And opening one from the deck itself, which nothing else records.
	d.wentMu.Lock()
	for url, at := range d.went {
		was := went[url]
		if at.After(was.At) {
			was.At = at
			went[url] = was
		}
	}
	d.wentMu.Unlock()
	have := map[string]bool{}
	for i, m := range out {
		if m.Kind != "link" {
			continue
		}
		have[m.Path] = true
		if seen, ok := went[m.Path]; ok && !seen.At.IsZero() {
			out[i].At = seen.At
		}
		if out[i].Name == "" {
			out[i].Name = went[m.Path].Name
		}
	}
	// A page published by a session the deck no longer carries is still a
	// page that was published: it is listed under the name it was published
	// with, however long ago that session ended.
	for url, seen := range went {
		if have[url] || seen.Name == "" || seen.At.IsZero() {
			continue
		}
		out = append(out, artifacts.Made{
			Path: url, Name: seen.Name, Kind: "link", At: seen.At,
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].At.Equal(out[j].At) {
			return out[i].At.After(out[j].At)
		}
		return out[i].Path < out[j].Path
	})
	// A published Artifact is often mentioned in several sessions: one
	// listed it, another opened it. The deck lists the thing once, timed by
	// whichever went to it last and named by whichever knows its name.
	at := map[string]int{}
	kept := out[:0]
	for _, m := range out {
		i, ok := at[m.Path]
		if !ok {
			at[m.Path] = len(kept)
			kept = append(kept, m)
			continue
		}
		if kept[i].Name == "" && m.Name != "" {
			kept[i].Name = m.Name
			kept[i].Folder = m.Folder
			kept[i].Agent = m.Agent
			kept[i].Title = m.Title
		}
	}
	out = kept
	// A link nobody ever named is one the deck cannot label: it was carried
	// this far only for its time.
	named := out[:0]
	for _, m := range out {
		if m.Kind == "link" && m.Name == "" {
			continue
		}
		named = append(named, m)
	}
	out = named
	if len(out) > artifactsMax {
		out = out[:artifactsMax]
	}
	return out
}

// ArtifactsJSON is GET /v1/artifacts.
func (d *Daemon) ArtifactsJSON() any {
	made := d.Artifacts()
	if made == nil {
		made = []artifacts.Made{}
	}
	return map[string]any{"artifacts": made}
}

// OpenArtifact opens one in the computer's browser. The path has to be one of
// the agents' own: anything else is refused, so the deck cannot be asked to
// open a file it never saw written.
func (d *Daemon) OpenArtifact(path string) error {
	found := d.listed(path)
	if !found {
		// A page written in the last few seconds is not in the kept list
		// yet. Rather than refuse what an agent has just made, the list is
		// swept again and asked once more.
		d.keptArtifacts().now()
		found = d.sweptFor(path)
	}
	if !found {
		return missing("nothing on the deck made " + path)
	}
	if !artifacts.Openable(path) {
		return missing(path + " is not there any more")
	}
	// Opened from the deck: it was last used now, so the page puts it back
	// at the front. The sweep runs behind the open rather than before it.
	d.wentMu.Lock()
	if d.went == nil {
		d.went = map[string]time.Time{}
	}
	d.went[path] = time.Now()
	d.wentMu.Unlock()
	d.keptArtifacts().now()

	// Already open somewhere: bring that tab forward rather than opening the
	// same page again. Only if it is not there does a new tab open.
	if focusTab(path) {
		return nil
	}
	return openInBrowser(path)
}

// listed says whether the kept list holds it.
func (d *Daemon) listed(path string) bool {
	for _, m := range d.Artifacts() {
		if m.Path == path {
			return true
		}
	}
	return false
}

// sweptFor is the same question asked of a sweep taken now.
func (d *Daemon) sweptFor(path string) bool {
	for _, m := range d.sweepArtifacts() {
		if m.Path == path {
			return true
		}
	}
	return false
}

// missing says what could not be opened in its own words, and answers 404
// through the server's own check.
type missing string

func (m missing) Error() string { return string(m) }

func (m missing) Is(target error) bool { return target == server.ErrNotFound }

// focusScript looks through the browsers' tabs for one already showing the
// file and brings it to the front. JavaScript rather than AppleScript, so an
// app's name can be a variable: AppleScript needs its terminology at compile
// time and a dynamic `tell application name` loses it.
//
// A browser the person has not allowed the deck to drive throws, which is
// caught: then it is as though the tab was not there, and the file opens in a
// new one.
const focusScript = `
function run(argv) {
  var target = argv[0], plain = decodeURI(target);
  var same = function (u) { return u === target || decodeURI(u) === plain; };
  var running = [];
  try {
    running = Application('System Events').applicationProcesses.name();
  } catch (e) { return 'none'; }
  var chromium = ['Google Chrome', 'Brave Browser', 'Microsoft Edge', 'Arc',
                  'Chromium', 'Vivaldi', 'Opera'];
  for (var i = 0; i < chromium.length; i++) {
    if (running.indexOf(chromium[i]) < 0) continue;
    try {
      var app = Application(chromium[i]);
      for (var w = 0; w < app.windows.length; w++) {
        var win = app.windows[w];
        for (var t = 0; t < win.tabs.length; t++) {
          if (!same(win.tabs[t].url())) continue;
          win.activeTabIndex = t + 1;
          win.index = 1;
          app.activate();
          return 'focused';
        }
      }
    } catch (e) {}
  }
  if (running.indexOf('Safari') >= 0) {
    try {
      var safari = Application('Safari');
      for (var w2 = 0; w2 < safari.windows.length; w2++) {
        var sw = safari.windows[w2];
        for (var t2 = 0; t2 < sw.tabs.length; t2++) {
          if (!same(sw.tabs[t2].url())) continue;
          sw.currentTab = sw.tabs[t2];
          sw.index = 1;
          safari.activate();
          return 'focused';
        }
      }
    } catch (e) {}
  }
  return 'none';
}
`

// fileURL is the path as a browser writes it in its address bar.
func fileURL(path string) string {
	return (&url.URL{Scheme: "file", Path: path}).String()
}

// focusTab brings the tab already showing this file to the front, and says
// whether it found one. macOS only: elsewhere a file simply opens.
func focusTab(path string) bool {
	if runtime.GOOS != "darwin" {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/osascript", "-l", "JavaScript",
		"-e", focusScript, fileURL(path))
	out, err := cmd.Output()
	return err == nil && strings.Contains(string(out), "focused")
}

// openInBrowser hands the file to whatever the computer opens it with.
func openInBrowser(path string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("/usr/bin/open", path)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", path)
	default:
		cmd = exec.Command("xdg-open", path)
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("could not open it: %w", err)
	}
	go func() { _ = cmd.Wait() }()
	return nil
}

// forgetArtifacts drops what was scanned for an agent that left the deck.
func (d *Daemon) forgetArtifacts(e store.Entry) {
	if e.Transcript != "" {
		d.made.Forget(e.Transcript)
	}
}

// keys is a set as a list, in a settled order.
func keys(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
