package deskterm

import (
	"strings"
	"testing"
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
