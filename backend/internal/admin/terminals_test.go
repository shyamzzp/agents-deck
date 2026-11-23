package admin

import (
	"github.com/brushknight/agents-deck/backend/internal/deskterm"
	"testing"
)

func TestManualLinkExpiresWhenSSHProcessChanges(t *testing.T) {
	p := deskterm.Pane{App: "iTerm2", ID: "one", Connection: "old-process", Window: 1, Tab: 1, Pane: 2}
	inv := deskterm.Inventory{Host: "test-box", Remote: map[string]deskterm.Pane{}, HostPanes: []deskterm.Pane{p}}
	b := terminalBindings{byPane: map[string]string{inv.Host + "/" + p.Key(): "thread"}}
	b.apply(&inv)
	if !inv.Remote["thread"].Linked {
		t.Fatal("missing live binding")
	}
	inv.HostPanes[0].Connection = "new-process"
	inv.Remote = map[string]deskterm.Pane{}
	b.apply(&inv)
	if len(inv.Remote) != 0 || len(b.byPane) != 0 {
		t.Fatal("stale link survived")
	}
}
