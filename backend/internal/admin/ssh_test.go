package admin

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestSSHDisconnectAndReconnect(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("test transport uses a shell")
	}
	dir := t.TempDir()
	// Closing stdout models a dropped transport. A second connection reports idle.
	script := "#!/bin/sh\nif [ -e \"$FIXTURE/done\" ]; then s=idle; else s=running; fi\n" +
		"echo \"[{\\\"id\\\":\\\"one\\\",\\\"status\\\":\\\"$s\\\"}]\"\n" +
		"while [ ! -e \"$FIXTURE/drop\" ]; do /bin/sleep .05; done\n"
	if err := os.WriteFile(filepath.Join(dir, "ssh"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	t.Setenv("FIXTURE", dir)
	a := &Admin{Config: filepath.Join(dir, "config.json")}
	call := func(method, body string, code int) sshState {
		t.Helper()
		r := httptest.NewRequest(method, "/admin/v1/ssh-codex", strings.NewReader(body))
		w := httptest.NewRecorder()
		a.sshDashboard(w, r)
		if w.Code != code {
			t.Fatalf("response %d: %s", w.Code, w.Body)
		}
		var state sshState
		if err := json.Unmarshal(w.Body.Bytes(), &state); err != nil {
			t.Fatal(err)
		}
		return state
	}
	await := func(connection string) sshState {
		t.Helper()
		end := time.Now().Add(15 * time.Second)
		for time.Now().Before(end) {
			if state := call("GET", "", 200); state.Connection == connection {
				return state
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Fatalf("did not reach %s", connection)
		return sshState{}
	}
	call("POST", `{"host":"-oProxyCommand=invalid"}`, 400)
	call("POST", `{"host":"test-box"}`, 200)
	defer call("POST", `{"host":""}`, 200)
	if got := await("online"); len(got.Sessions) != 1 || got.Sessions[0].Status != "running" {
		t.Fatal(got)
	}
	for _, name := range []string{"done", "drop"} {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if got := await("offline"); len(got.Sessions) != 1 {
		t.Fatal("lost last snapshot")
	}
	if err := os.Remove(filepath.Join(dir, "drop")); err != nil {
		t.Fatal(err)
	}
	a.ssh.mu.Lock()
	a.ssh.retry = time.Time{}
	a.ssh.mu.Unlock()
	if got := await("online"); got.Sessions[0].Status != "idle" {
		t.Fatal(got)
	}
	if got := call("POST", `{"host":""}`, 200); got.Host != "" || len(got.Sessions) != 0 {
		t.Fatal(got)
	}
}
