package daemon

import (
	"context"
	"github.com/shyamzzp/agents-deck/backend/internal/model"
	"github.com/shyamzzp/agents-deck/backend/internal/store"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestMessageQueuesOnlyTheSelectedCodexThread(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture uses a POSIX executable")
	}
	dir := t.TempDir()
	recorder := filepath.Join(dir, "record")
	t.Setenv("DECK_ARG_RECORD", recorder)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := os.WriteFile(filepath.Join(dir, "codex"), []byte("#!/bin/sh\nif [ \"$2\" = --help ]; then exit 0; fi\nprintf '%s\\n' \"$@\" > \"$DECK_ARG_RECORD\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	d := Daemon{Store: store.New("", "test", "test")}
	const id = "00000000-1111-4222-8333-444444444444"
	const msg = `-$HOME; $(literal) "question"`
	d.Store.Add(&store.Entry{SessionID: id, External: true, A: model.Agent{ID: "test-tile", Tool: "codex", Status: model.Idle}})
	if err := d.Message(context.Background(), "test-tile", msg); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(recorder)
	if err != nil || string(data) != "queue\n--thread\n"+id+"\n--message="+msg+"\n" {
		t.Fatalf("incorrect queue arguments: %q, %v", data, err)
	}
}
