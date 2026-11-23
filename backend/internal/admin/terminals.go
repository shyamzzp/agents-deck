package admin

import (
	"context"
	"net/http"
	"runtime"
	"strings"
	"time"

	"github.com/brushknight/agents-deck/backend/internal/deskterm"
	"github.com/brushknight/agents-deck/backend/internal/tmux"
)

func (a *Admin) terminalInventory(ctx context.Context) (deskterm.Inventory, error) {
	host := str(a.readConfig(), "sshCodexHost", "")
	ttys := map[string]string{}
	ids := map[string]string{}
	if a.Store != nil && runtime.GOOS == "darwin" {
		clients := tmux.ClientList()
		for _, e := range a.Store.Entries() {
			if e.LiveTTY != "" {
				ttys[e.A.ID] = e.LiveTTY
			}
			if e.SessionID != "" {
				ids[e.SessionID] = e.A.ID
			}
			for _, c := range clients {
				if e.TmuxName != "" && c.Session == e.TmuxName && ttys[e.A.ID] == "" {
					ttys[e.A.ID] = c.TTY
				}
			}
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 7*time.Second)
	defer cancel()
	return deskterm.Discover(ctx, host, ttys, ids)
}

func (a *Admin) terminals(w http.ResponseWriter, r *http.Request) {
	inv, err := a.terminalInventory(r.Context())
	if err != nil {
		writeErr(w, 503, err.Error())
		return
	}
	writeJSON(w, 200, inv)
}

func (a *Admin) focusTerminal(w http.ResponseWriter, r *http.Request) {
	var req struct{ Host, ID, Mode, Key string }
	if readBody(r, 2048, &req) != nil {
		writeErr(w, 400, "invalid terminal selection")
		return
	}
	inv, err := a.terminalInventory(r.Context())
	if err != nil {
		writeErr(w, 503, err.Error())
		return
	}
	p := inv.Local[req.ID]
	if req.Host != "" {
		if req.Host != inv.Host {
			writeErr(w, 409, "the configured SSH host changed")
			return
		}
		p = inv.Remote[req.ID]
		if req.Mode == "host-tab" || req.Mode == "host-pane" {
			var matches []deskterm.Pane
			for _, candidate := range inv.HostPanes {
				if req.Key == "" || req.Key == candidate.Key() {
					matches = append(matches, candidate)
				}
			}
			if len(matches) != 1 {
				writeErr(w, 409, "select one connected codebox tab")
				return
			}
			p = matches[0]
			req.Mode = strings.TrimPrefix(req.Mode, "host-")
		}
	}
	if p.App == "" || req.Key != "" && req.Key != p.Key() {
		writeErr(w, 409, "no matching terminal is open")
		return
	}
	if req.Mode != "pane" && req.Mode != "tab" {
		writeErr(w, 400, "choose pane or tab")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	if err = deskterm.Focus(ctx, p, req.Mode); err != nil {
		writeErr(w, 409, err.Error())
		return
	}
	writeJSON(w, 200, map[string]string{"focused": p.Label()})
}
