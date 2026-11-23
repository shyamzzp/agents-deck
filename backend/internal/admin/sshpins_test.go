package admin

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestSSHPinsScopedAndIdempotent(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("test transport uses a shell")
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "ssh"), []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	a := &Admin{Config: filepath.Join(dir, "config.json")}
	if err := a.editConfig(func(cfg map[string]any) error { cfg["sshCodexHost"] = "test-box"; return nil }); err != nil {
		t.Fatal(err)
	}
	const id = "00000000-1111-4222-8333-444444444444"
	pin := func(host string, value bool, code int) {
		t.Helper()
		data, _ := json.Marshal(map[string]any{"host": host, "id": id, "pinned": value})
		w := httptest.NewRecorder()
		a.sshPin(w, httptest.NewRequest("POST", "/admin/v1/ssh-codex/pins", strings.NewReader(string(data))))
		if w.Code != code {
			t.Fatalf("got %d: %s", w.Code, w.Body)
		}
	}
	pin("other-host", true, 409)
	pin("test-box", true, 200)
	pin("test-box", true, 200)
	if got := sshPins(a.readConfig(), "test-box"); len(got) != 1 || got[0] != id {
		t.Fatal(got)
	}
	pin("test-box", false, 200)
	if len(sshPins(a.readConfig(), "test-box")) != 0 {
		t.Fatal("unpin failed")
	}
}
