package daemon

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/shyamzzp/agents-deck/backend/internal/codex"
	"github.com/shyamzzp/agents-deck/backend/internal/model"
	"github.com/shyamzzp/agents-deck/backend/internal/paths"
	"github.com/shyamzzp/agents-deck/backend/internal/store"
)

func TestCatalogSourcesAndSavedCodexAdd(t *testing.T) {
	sqlite, err := exec.LookPath("sqlite3")
	if err != nil {
		t.Skip("requires sqlite3")
	}
	root := t.TempDir()
	t.Setenv("CODEX_HOME", root)
	t.Setenv("AGENTSTERM_HOME", root)
	const id = "12345678-1234-4123-8000-123456789abc"
	db := filepath.Join(root, "state_5.sqlite")
	sql := "create table threads(id,rollout_path,cwd,title,name,git_branch,model,updated_at_ms integer,archived integer,thread_source);" +
		"insert into threads values('" + id + "','rollout-old','work','Old issue','','','',1,0,'cli');" +
		"insert into threads select 'review',rollout_path,cwd,title,name,git_branch,model,1,0,'guardian_review' from threads limit 1;" +
		"insert into threads select 'archived',rollout_path,cwd,title,name,git_branch,model,1,1,'cli' from threads limit 1;"
	if out, err := exec.Command(sqlite, db, sql).CombinedOutput(); err != nil {
		t.Fatal(string(out), err)
	}
	d := &Daemon{Store: store.New("", "test", "0")}
	d.live.candidates = []LiveCandidate{{SessionID: "manual", Title: "Claude terminal"}}
	d.Store.Add(&store.Entry{A: model.Agent{ID: "other", Tool: "gemini", App: "orca"}})
	list, warn := d.SessionCatalog()
	rows := list.([]catalogRow)
	if warn != "" || len(rows) != 3 {
		t.Fatalf("catalog: %+v %q", rows, warn)
	}
	seen := map[string]bool{}
	for _, r := range rows {
		seen[r.SessionID] = r.OnBoard
	}
	if on, ok := seen["codex:"+id]; !ok || on || !seen["deck:other"] {
		t.Fatalf("initial results: %+v", seen)
	}
	if err := d.AddLive("codex:"+id, 7); err != nil {
		t.Fatal(err)
	}
	if err := d.refreshCodex(); err != nil {
		t.Fatal(err)
	}
	if e, ok := d.Store.Get(codex.AgentID(id)); !ok || e.A.Slot != 7 {
		t.Fatal("saved thread lost its slot")
	}
	var cfg Config
	data, err := os.ReadFile(paths.Config())
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(data, &cfg); err != nil || len(cfg.CodexPins) != 1 || cfg.CodexPins[0] != id {
		t.Fatalf("persistent selection: %+v %v", cfg.CodexPins, err)
	}
	if err := d.Dismiss(codex.AgentID(id)); err != nil {
		t.Fatal(err)
	}
	if err := d.refreshCodex(); err != nil {
		t.Fatal(err)
	}
	if _, ok := d.Store.Get(codex.AgentID(id)); ok {
		t.Fatal("dismissed thread came back")
	}
}
