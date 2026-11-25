package daemon

import (
	"path/filepath"
	"sort"
	"time"

	"github.com/shyamzzp/agents-deck/backend/internal/codex"
)

// Catalog includes the local history and agents owned by enabled harnesses.
// The original live list stays available to clients that expect Claude sessions.
type catalogRow struct {
	LiveCandidate
	Tool       string    `json:"tool"`
	App        string    `json:"app,omitempty"`
	AgentID    string    `json:"agentId,omitempty"`
	Status     string    `json:"status,omitempty"`
	LastActive time.Time `json:"lastActive"`
}

func (d *Daemon) SessionCatalog() (any, string) {
	rows := []catalogRow{}
	listed := map[string]bool{}
	entries := d.Store.Entries()
	board := map[string]string{}
	for _, e := range entries {
		board[e.A.ID] = string(e.A.Status)
	}
	d.live.mu.Lock()
	for _, c := range d.live.candidates {
		id := liveAgentID(c.SessionID)
		_, c.OnBoard = board[id]
		rows = append(rows, catalogRow{LiveCandidate: c, Tool: "claude", AgentID: id, Status: board[id], LastActive: c.Started})
		listed[id] = true
	}
	d.live.mu.Unlock()
	var warning string
	if (d.Cfg.Codex == nil || *d.Cfg.Codex) && codex.HistoryAvailable() {
		threads, err := codex.AllThreads()
		if err != nil {
			warning = "Could not read local Codex history."
		}
		for _, t := range threads {
			if t.RolloutPath == "" {
				continue
			}
			id := codex.AgentID(t.ID)
			status, onBoard := board[id]
			if !onBoard {
				status = "saved"
			}
			c := LiveCandidate{SessionID: "codex:" + t.ID, Title: t.DisplayTitle(), Folder: filepath.Base(t.Cwd), Cwd: t.Cwd, OnBoard: onBoard}
			rows = append(rows, catalogRow{LiveCandidate: c, Tool: "codex", AgentID: id, LastActive: time.UnixMilli(t.UpdatedAtMs), Status: status})
			listed[id] = true
		}
	}
	for _, e := range entries {
		a := e.A
		if listed[a.ID] {
			continue
		}
		c := LiveCandidate{SessionID: "deck:" + a.ID, Title: a.Title, Cwd: a.Cwd, Folder: a.Folder, Started: a.StartedAt, OnBoard: true}
		rows = append(rows, catalogRow{LiveCandidate: c, Tool: a.Tool, App: a.App, AgentID: a.ID, Status: string(a.Status), LastActive: a.LastActive})
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].LastActive.After(rows[j].LastActive) })
	return rows, warning
}
