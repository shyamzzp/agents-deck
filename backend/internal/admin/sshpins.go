package admin

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"time"

	"github.com/brushknight/agents-deck/backend/internal/deskterm"
	"github.com/brushknight/agents-deck/backend/internal/model"
	"github.com/brushknight/agents-deck/backend/internal/sshdeck"
	"github.com/brushknight/agents-deck/backend/internal/store"
)

func sshPins(cfg map[string]any, host string) []string {
	byHost, _ := cfg["sshDeckPins"].(map[string]any)
	raw, _ := byHost[host].([]any)
	var result []string
	for _, v := range raw {
		if id, ok := v.(string); ok && deskterm.ValidID(id) {
			result = append(result, id)
		}
	}
	return result
}

type sshChoice struct {
	Context    model.Context `json:"context"`
	ID         string        `json:"id"`
	Title      string        `json:"title"`
	Folder     string        `json:"folder"`
	Status     string        `json:"status"`
	LastActive time.Time     `json:"lastActive"`
}

// Use the same reader action as agentctl ls --ssh, returning picker fields only.
func (a *Admin) sshSessions(w http.ResponseWriter, r *http.Request) {
	host := r.URL.Query().Get("host")
	if !sshdeck.ValidHost(host) || host != str(a.readConfig(), "sshCodexHost", "") {
		writeErr(w, 409, "the configured SSH host changed")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	cmd, err := sshdeck.Command(ctx, host, "list", "")
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	raw, err := cmd.Output()
	if err != nil {
		writeErr(w, 502, "Could not list Codebox sessions. Check the SSH connection and try again.")
		return
	}
	var sessions []sshChoice
	if err = json.Unmarshal(raw, &sessions); err != nil {
		writeErr(w, 502, "Invalid session list from SSH host")
		return
	}
	writeJSON(w, 200, sessions)
}

func (a *Admin) sshPin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Host, ID              string
		GroupCell, SourceCell *int
		Dismiss               bool
		SwapID                string
		GroupSlot             *int
		Pinned                *bool
	}
	if readBody(r, 1024, &req) != nil || !deskterm.ValidID(req.ID) || !sshdeck.ValidHost(req.Host) || req.Pinned == nil {
		writeErr(w, 400, "invalid Codebox selection")
		return
	}
	if req.Dismiss && (*req.Pinned || req.GroupSlot != nil || req.GroupCell != nil || req.SwapID != "") {
		writeErr(w, 400, "dismiss requires an unpinned session")
		return
	}
	if req.SwapID != "" && (!deskterm.ValidID(req.SwapID) || req.SwapID == req.ID || req.GroupCell == nil) {
		writeErr(w, 400, "invalid swap target")
		return
	}
	var added *model.Agent
	if req.GroupSlot != nil && *req.Pinned {
		// A drag starts from a tile already identified by the SSH watcher.
		a.ssh.mu.Lock()
		if a.ssh.state.Host == req.Host {
			for _, session := range a.ssh.state.Sessions {
				if session.ID == req.ID {
					added = &session
					break
				}
			}
		}
		a.ssh.mu.Unlock()
	}
	if *req.Pinned && added == nil {
		if str(a.readConfig(), "sshCodexHost", "") != req.Host {
			writeErr(w, 409, "the configured SSH host changed")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()
		cmd, err := sshdeck.Command(ctx, req.Host, "show", req.ID)
		if err != nil {
			writeErr(w, 400, err.Error())
			return
		}
		raw, err := cmd.Output()
		var session model.Agent
		if err != nil || json.Unmarshal(raw, &session) != nil || session.ID != req.ID {
			writeErr(w, 409, "Session unavailable. Reopen the picker to refresh the list.")
			return
		}
		added = &session
	}
	a.ssh.mu.Lock()
	defer a.ssh.mu.Unlock()
	err := a.editConfig(func(cfg map[string]any) error {
		if str(cfg, "sshCodexHost", "") != req.Host {
			return errors.New("the configured SSH host changed")
		}
		if req.Dismiss || *req.Pinned {
			key := req.Host + "/" + req.ID
			hidden, _ := cfg["sshDeckDismissed"].(map[string]any)
			if req.Dismiss {
				if hidden == nil {
					hidden = map[string]any{}
				}
				hidden[key] = true
			} else {
				delete(hidden, key)
			}
			if len(hidden) == 0 {
				delete(cfg, "sshDeckDismissed")
			} else {
				cfg["sshDeckDismissed"] = hidden
			}
		}
		pins := sshPins(cfg, req.Host)
		for _, cell := range []*int{req.GroupCell, req.SourceCell} {
			if cell != nil && (*cell < 0 || *cell > store.MaxSlot+len(pins) || req.GroupSlot == nil) {
				return errors.New("invalid group cell")
			}
		}
		if req.GroupSlot != nil || !*req.Pinned {
			slot := 0
			if req.GroupSlot != nil {
				slot = *req.GroupSlot
			}
			key := req.Host + "/" + req.ID
			assignments, _ := cfg["sshDeckGroups"].(map[string]any)
			cells, _ := cfg["sshDeckCells"].(map[string]any)
			if cells == nil {
				cells = map[string]any{}
			}
			if req.SwapID != "" {
				other := req.Host + "/" + req.SwapID
				if assignments[other] != float64(slot) || slot == 0 {
					return errors.New("the target session moved")
				}
				if previous, ok := assignments[key]; ok {
					assignments[other] = previous
				} else {
					delete(assignments, other)
				}
				delete(cells, other)
				if assignments[other] != nil && req.SourceCell != nil {
					cells[other] = *req.SourceCell
				}
			}
			delete(cells, key)
			if slot > 0 && req.GroupCell != nil {
				cells[key] = *req.GroupCell
			}
			if len(cells) > 0 {
				cfg["sshDeckCells"] = cells
			} else {
				delete(cfg, "sshDeckCells")
			}
			if slot == 0 {
				delete(assignments, key)
			} else {
				lines, _ := cfg["groups"].([]any)
				found := slices.ContainsFunc(lines, func(v any) bool {
					g, _ := v.(map[string]any)
					return g["slot"] == float64(slot) && slot > 0
				})
				if !*req.Pinned || !found {
					return errors.New("the selected group is unavailable")
				}
				if assignments == nil {
					assignments = map[string]any{}
				}
				assignments[key] = slot
			}
			if len(assignments) == 0 {
				delete(cfg, "sshDeckGroups")
			} else {
				cfg["sshDeckGroups"] = assignments
			}
		}
		idx := slices.Index(pins, req.ID)
		if *req.Pinned && idx < 0 {
			pins = append(pins, req.ID)
		} else if !*req.Pinned && idx >= 0 {
			pins = slices.Delete(pins, idx, idx+1)
		}
		byHost, _ := cfg["sshDeckPins"].(map[string]any)
		if byHost == nil {
			byHost = map[string]any{}
		}
		if len(pins) == 0 {
			delete(byHost, req.Host)
		} else {
			byHost[req.Host] = pins
		}
		if len(byHost) == 0 {
			delete(cfg, "sshDeckPins")
		} else {
			cfg["sshDeckPins"] = byHost
		}
		return nil
	})
	if err != nil {
		writeErr(w, 409, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"pinned": *req.Pinned, "state": a.sshSnapshot(added)})
}
