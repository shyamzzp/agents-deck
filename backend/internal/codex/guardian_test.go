package codex

import (
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// A page full of newer reviews must not push ordinary threads off the live deck.
func TestGuardianDiscovery(t *testing.T) {
	bin := sqlite3()
	if bin == "" {
		t.Skip("sqlite3 unavailable")
	}
	home := t.TempDir()
	t.Setenv("CODEX_HOME", home)
	db := filepath.Join(home, "state_5.sqlite")
	sql := `create table threads(id,rollout_path,cwd,title,name,git_branch,model,updated_at_ms,archived,source,thread_source);
 insert into threads values('parent','','','Guardian discussion','','','',strftime('%s','now')*1000,0,'cli','user');
 insert into threads select 'peer','','','','','','',updated_at_ms,0,'{"subagent":{"other":"worker"}}','subagent' from threads where id='parent';
 with recursive nums(n) as (values(1) union all select n+1 from nums where n<40)
 insert into threads select 'review'||n,'','','','','','',strftime('%s','now')*1000+1,0,
 case when n%2=0 then '{"subagent":{"other":"guardian"}}' else null end,
 case when n%2=0 then 'subagent' else 'guardian_review' end from nums;`
	if out, err := exec.Command(bin, db, sql).CombinedOutput(); err != nil {
		t.Fatalf("%s: %v", out, err)
	}
	for _, read := range []func() ([]Thread, error){AllThreads, func() ([]Thread, error) { return RecentThreads(time.Hour) }} {
		got, err := read()
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 2 || !(got[0].ID == "parent" && got[1].ID == "peer" || got[0].ID == "peer" && got[1].ID == "parent") {
			t.Fatalf("unexpected threads: %+v", got)
		}
	}
}
