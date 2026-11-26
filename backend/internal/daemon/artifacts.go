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

// Artifacts is every agent's made things, newest first.
func (d *Daemon) Artifacts() []artifacts.Made {
	var out []artifacts.Made
	for _, e := range d.Store.Entries() {
		if e.Transcript == "" {
			continue
		}
		out = append(out, d.made.Of(e.Transcript, e.A.ID, e.A.Title)...)
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].At.Equal(out[j].At) {
			return out[i].At.After(out[j].At)
		}
		return out[i].Path < out[j].Path
	})
	// A published Artifact is often mentioned in several sessions; the deck
	// lists the thing once, under whichever saw it last.
	seen := map[string]bool{}
	kept := out[:0]
	for _, m := range out {
		if seen[m.Path] {
			continue
		}
		seen[m.Path] = true
		kept = append(kept, m)
	}
	out = kept
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
	found := false
	for _, m := range d.Artifacts() {
		if m.Path == path {
			found = true
			break
		}
	}
	if !found {
		return missing("nothing on the deck made " + path)
	}
	if !artifacts.Openable(path) {
		return missing(path + " is not there any more")
	}
	// Already open somewhere: bring that tab forward rather than opening the
	// same page again. Only if it is not there does a new tab open.
	if focusTab(path) {
		return nil
	}
	return openInBrowser(path)
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
