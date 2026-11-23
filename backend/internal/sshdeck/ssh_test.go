package sshdeck

import (
	"context"
	"strings"
	"testing"
)

func TestSSHArguments(t *testing.T) {
	for _, id := range []string{"x;id", "abcd-$(id)", "-abc", "abcd\ncmd"} {
		if _, err := Command(context.Background(), "test-box", "attach", id); err == nil {
			t.Fatalf("accepted %q", id)
		}
	}
	cmd, err := Command(context.Background(), "test-box", "attach", "abcd1234")
	if err != nil {
		t.Fatal(err)
	}
	joined := " " + strings.Join(cmd.Args, " ") + " "
	if !strings.Contains(joined, " -t ") || strings.Contains(joined, " -n ") {
		t.Fatal("interactive SSH lacks its TTY or stdin")
	}
}
