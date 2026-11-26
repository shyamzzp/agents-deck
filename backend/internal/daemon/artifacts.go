// What the agents made, and opening one on this Mac.
//
// The scanning is in internal/artifacts: this is where the deck's own agents
// are walked, and where a file is handed to the computer to open. Only a file
// one of the agents wrote can be opened, and only one a browser is worth
// opening for: a path that was never seen being written is refused, whoever
// asks.
package daemon

import (
	"fmt"
	"os/exec"
	"runtime"
	"sort"

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
	return openInBrowser(path)
}

// missing says what could not be opened in its own words, and answers 404
// through the server's own check.
type missing string

func (m missing) Error() string { return string(m) }

func (m missing) Is(target error) bool { return target == server.ErrNotFound }

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
