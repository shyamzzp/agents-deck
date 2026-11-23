package deskterm

import (
	"strings"
	"testing"

	"github.com/brushknight/agents-deck/backend/internal/sshdeck"
)

func TestForegroundSSH(t *testing.T) {
	const id = "01234567-89ab-4def-8123-456789abcdef"
	cases := []struct{ args, host, command string }{
		{"-L 5901:localhost:5901 user@box -v", "user@box", ""},
		{"-oBatchMode=yes -t -- box codex resume -- " + id, "box", "codex resume -- " + id},
		{"-o ProxyJump=jump box", "box", ""},
		{"-N -L 5901:localhost:5901 box", "", ""},
		{"-T -n -- box exec reader", "box", "exec reader"},
	}
	for _, c := range cases {
		host, cmd := sshArgs(strings.Fields(c.args))
		if host != c.host || strings.Join(cmd, " ") != c.command {
			t.Errorf("%s -> %q %q", c.args, host, cmd)
		}
	}
	if got := resumeID(strings.Fields("codex resume -- " + id)); got != id {
		t.Fatal(got)
	}
	for _, args := range [][]string{{"codex"}, {"codex", "resume", "--last"}, {"bash", "-c", "codex", "resume", id}} {
		if got := resumeID(args); got != "" {
			t.Fatal(args, got)
		}
	}
}

func TestLocalCodexPaneTitles(t *testing.T) {
	names := map[string]string{"Work item": "session", "Duplicate": "", "Work item extended": "other"}
	for title, want := range map[string]string{
		"Work item":                      "session",
		`⠧ Work item | project (codex")`: "session",
		"Work item extended (codex)":     "other",
		"Some Work item":                 "",
		"Duplicate | project":            "",
	} {
		if got := paneThread(title, names); got != want {
			t.Errorf("%q: got %q, want %q", title, got, want)
		}
	}
}

func TestMatchSSHTitles(t *testing.T) {
	const id = "01234567-89ab-4def-8123-456789abcdef"
	const other = "12345678-89ab-4def-8123-456789abcdef"
	a := Pane{App: "iTerm2", ID: "first", Connection: "conn-a"}
	b := Pane{App: "iTerm2", ID: "second", Connection: "conn-b"}
	links := map[string]string{sshdeck.TitleKey("Fix issue | project"): id, sshdeck.TitleKey("Duplicate"): ""}
	cases := []struct {
		name, first, second, known string
		want                       bool
	}{
		{"whole title with spinner and transport", "⠧ Fix issue | project\n (ssh)", "", "", true},
		{"generic host title", "login shell (ssh)", "", "", false},
		{"partial title", "Fix issue (ssh)", "", "", false},
		{"different panes with same title", "Fix issue | project", "Fix issue | project (ssh)", "", false},
		{"duplicate catalog title", "Duplicate (ssh)", "", "", false},
		{"already owned by another thread", "Fix issue | project", "", other, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			inv := Inventory{Remote: map[string]Pane{}, HostPanes: []Pane{a, b}}
			if c.known != "" {
				inv.Remote[c.known] = a
			}
			matchSSHTitles(&inv, map[string]string{a.Key(): c.first, b.Key(): c.second}, links)
			if got := inv.Remote[id]; (got == a) != c.want {
				t.Fatalf("match = %+v", got)
			}
		})
	}
}
