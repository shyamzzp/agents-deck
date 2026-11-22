package claude

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Claude Code reports one session twice when a fork leaves a background
// record behind and the session is also attached to a terminal. Both hash to
// the same agent id, so the deck must keep the attached one: the stale
// blocked record makes a live session look like it needs you.
func TestDedupePrefersAttachedSession(t *testing.T) {
	const id = "28f1590a-6540-45db-81c9-649757352ab7"
	early := time.Date(2026, 11, 22, 10, 46, 0, 0, time.UTC)
	late := early.Add(6 * time.Hour)

	for _, tc := range []struct {
		name string
		in   []Live
	}{
		{"background first", []Live{
			{SessionID: id, Background: true, Blocked: true, Started: early},
			{SessionID: id, Busy: true, PID: 73399, Started: late},
		}},
		{"background last", []Live{
			{SessionID: id, Busy: true, PID: 73399, Started: late},
			{SessionID: id, Background: true, Blocked: true, Started: early},
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := dedupe(tc.in)
			if len(got) != 1 {
				t.Fatalf("got %d entries, want 1", len(got))
			}
			if got[0].Background || got[0].Blocked {
				t.Errorf("kept the stale background record: %+v", got[0])
			}
			if got[0].PID != 73399 {
				t.Errorf("PID = %d, want the attached session 73399", got[0].PID)
			}
		})
	}
}

func TestDedupeKeepsDistinctSessionsAndNewestOfAKind(t *testing.T) {
	t0 := time.Date(2026, 11, 22, 10, 0, 0, 0, time.UTC)
	in := []Live{
		{SessionID: "a", Background: true, Started: t0},
		{SessionID: "a", Background: true, Started: t0.Add(time.Hour)},
		{SessionID: "b", Started: t0},
	}
	got := dedupe(in)
	if len(got) != 2 {
		t.Fatalf("got %d entries, want 2", len(got))
	}
	if !got[0].Started.Equal(t0.Add(time.Hour)) {
		t.Errorf("kept the older of two background records: %+v", got[0])
	}
	if got[1].SessionID != "b" {
		t.Errorf("order not preserved: %+v", got)
	}
}

// End to end through ActiveSessions: the fake claude reports the two rows
// Claude Code really emits for a forked session that is also attached.
func TestActiveSessionsCollapsesDuplicateSessionID(t *testing.T) {
	const id = "28f1590a-6540-45db-81c9-649757352ab7"
	json := `[
	  {"id":"28f1590a","cwd":"/tmp","kind":"background","startedAt":1795324592675,
	   "sessionId":"` + id + `","name":"hello-agents1","state":"blocked"},
	  {"pid":73399,"cwd":"/tmp","kind":"interactive","startedAt":1795347722639,
	   "sessionId":"` + id + `","name":"hello-agents1","status":"busy"}
	]`
	bin := filepath.Join(t.TempDir(), "claude")
	script := "#!/bin/sh\ncat <<'EOF'\n" + json + "\nEOF\n"
	if err := os.WriteFile(bin, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}

	out, ok := ActiveSessions(bin, "", nil, nil)
	if !ok {
		t.Fatal("ActiveSessions returned ok=false")
	}
	if len(out) != 1 {
		t.Fatalf("got %d sessions for one session id, want 1: %+v", len(out), out)
	}
	if out[0].Blocked {
		t.Error("the stale background record won: a live session shows as needing you")
	}
	if out[0].PID != 73399 || !out[0].Busy {
		t.Errorf("want the attached busy session, got %+v", out[0])
	}
}
