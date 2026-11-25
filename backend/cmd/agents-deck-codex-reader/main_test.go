package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/shyamzzp/agents-deck/backend/internal/codex"
)

func TestAttachSavedSession(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("test Codex executable uses a shell")
	}
	sqlite, err := exec.LookPath("sqlite3")
	if err != nil {
		t.Skip("sqlite3 unavailable")
	}
	dir := t.TempDir()
	t.Setenv("CODEX_HOME", dir)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	cwd := filepath.Join(dir, "project with spaces")
	if err := os.Mkdir(cwd, 0700); err != nil {
		t.Fatal(err)
	}
	const id = "12345678-1234-4888-8000-000000000001"
	sql := "create table threads(id,rollout_path,cwd,title,name,git_branch,model,updated_at_ms,archived); insert into threads values('" + id + "','','" + strings.ReplaceAll(cwd, "'", "''") + "','old','','','',1,0);"
	if out, err := exec.Command(sqlite, filepath.Join(dir, "state_5.sqlite"), sql).CombinedOutput(); err != nil {
		t.Fatalf("%s: %v", out, err)
	}
	threads, err := codex.AllThreads()
	if err != nil || len(threads) != 1 {
		t.Fatalf("history: %d, %v", len(threads), err)
	}
	// A stub records the actual Codex invocation without starting a model turn.
	mark := filepath.Join(dir, "invocation")
	t.Setenv("TEST_INVOCATION", mark)
	stub := "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" > \"$TEST_INVOCATION\"\n"
	if err := os.WriteFile(filepath.Join(dir, "codex"), []byte(stub), 0700); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"attach", "12345678"}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(mark)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(got)), "\n")
	if len(lines) != 4 || filepath.Base(lines[0]) != "project with spaces" || strings.Join(lines[1:], " ") != "resume -- "+id {
		t.Fatalf("unexpected invocation %q", lines)
	}
	if _, err := match(append(threads, threads...), "1234"); err == nil {
		t.Fatal("ambiguous prefix accepted")
	}
	if _, err := match(threads, "ffff"); err == nil {
		t.Fatal("unknown prefix accepted")
	}
}
