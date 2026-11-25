package admin

import (
	"context"
	"net/http"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/shyamzzp/agents-deck/backend/internal/deskterm"
	"github.com/shyamzzp/agents-deck/backend/internal/tmux"
)

func (a *Admin) terminalInventory(ctx context.Context) (deskterm.Inventory, error) {
	host := str(a.readConfig(), "sshCodexHost", "")
	ttys := map[string]string{}
	var ids, names map[string]string
	if a.Store != nil && runtime.GOOS == "darwin" {
		clients := tmux.ClientList()
		entries := a.Store.Entries()
		ids, names = deskterm.CodexIndex(entries)
		for _, e := range entries {
			if e.LiveTTY != "" {
				ttys[e.A.ID] = e.LiveTTY
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
	inv, err := deskterm.Discover(ctx, host, ttys, ids, names)
	if err == nil {
		a.bindings.apply(&inv)
	}
	return inv, err
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

// An explicit link follows the live client and its terminal, never a window
// number. Drop it when that SSH process exits or a different host is selected.
type terminalBindings struct {
	mu     sync.Mutex
	byPane map[string]string
}

func (b *terminalBindings) apply(inv *deskterm.Inventory) {
	b.mu.Lock()
	defer b.mu.Unlock()
	live := map[string]bool{}
	occupied := map[string]string{}
	for id, p := range inv.Remote {
		occupied[p.Key()] = id
	}
	for _, p := range inv.HostPanes {
		key := inv.Host + "/" + p.Key()
		live[key] = true
		id := b.byPane[key]
		if owner := occupied[p.Key()]; owner != "" && owner != id {
			delete(b.byPane, key)
			continue
		}
		if id != "" && inv.Remote[id].App == "" {
			p.Linked = true
			inv.Remote[id] = p
		}
	}
	for key := range b.byPane {
		if !live[key] {
			delete(b.byPane, key)
		}
	}
}

func (a *Admin) linkTerminal(w http.ResponseWriter, r *http.Request) {
	var req struct{ Host, ID, Mode, Key string }
	if readBody(r, 2048, &req) != nil || !deskterm.ValidID(req.ID) || (req.Mode != "link" && req.Mode != "unlink") {
		writeErr(w, 400, "invalid thread or link action")
		return
	}
	inv, err := a.terminalInventory(r.Context())
	if err != nil {
		writeErr(w, 503, err.Error())
		return
	}
	for _, p := range inv.HostPanes {
		if req.Host != inv.Host || req.Key != p.Key() {
			continue
		}
		b := &a.bindings
		b.mu.Lock()
		defer b.mu.Unlock()
		key := inv.Host + "/" + p.Key()
		if req.Mode == "unlink" {
			if b.byPane[key] != req.ID {
				writeErr(w, 409, "the link changed; refresh")
				return
			}
			delete(b.byPane, key)
		} else {
			if b.byPane == nil {
				b.byPane = map[string]string{}
			}
			for k, id := range b.byPane {
				if id == req.ID {
					delete(b.byPane, k)
				}
			}
			b.byPane[key] = req.ID
		}
		writeJSON(w, 200, map[string]string{"pane": p.Label()})
		return
	}
	writeErr(w, 409, "the selected SSH connection is no longer open")
}
