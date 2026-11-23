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
		Host, ID string
		Pinned   *bool
	}
	if readBody(r, 1024, &req) != nil || !deskterm.ValidID(req.ID) || !sshdeck.ValidHost(req.Host) || req.Pinned == nil {
		writeErr(w, 400, "invalid Codebox selection")
		return
	}
	if *req.Pinned {
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
		if err = cmd.Run(); err != nil {
			writeErr(w, 409, "Session unavailable. Reopen the picker to refresh the list.")
			return
		}
	}
	err := a.editConfig(func(cfg map[string]any) error {
		if str(cfg, "sshCodexHost", "") != req.Host {
			return errors.New("the configured SSH host changed")
		}
		pins := sshPins(cfg, req.Host)
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
	writeJSON(w, 200, map[string]bool{"pinned": *req.Pinned})
}
