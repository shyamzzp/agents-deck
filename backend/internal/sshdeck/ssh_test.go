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

func TestLoginAndReaderShareSocket(t *testing.T) {
	login, err := Login(context.Background(), "test-box", true)
	if err != nil {
		t.Fatal(err)
	}
	reader, err := Command(context.Background(), "test-box", "watch", "")
	if err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{login.Args, reader.Args} {
		if !strings.Contains(strings.Join(args, " "), controlPath) {
			t.Fatal("missing shared socket")
		}
	}
	if !strings.Contains(strings.Join(login.Args, " "), "-oBatchMode=no") ||
		!strings.Contains(strings.Join(reader.Args, " "), "-oBatchMode=yes") {
		t.Fatal("only interactive login should prompt")
	}
}
