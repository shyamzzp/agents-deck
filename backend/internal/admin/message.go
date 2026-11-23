package admin

import (
	"context"
	"net/http"
	"strings"
	"time"
	"unicode"

	"github.com/brushknight/agents-deck/backend/internal/deskterm"
	"github.com/brushknight/agents-deck/backend/internal/sshdeck"
)

func (a *Admin) message(w http.ResponseWriter, r *http.Request) {
	var req struct{ Host, ID, Text string }
	if readBody(r, 64<<10, &req) != nil || req.ID == "" || strings.TrimSpace(req.Text) == "" || len(req.Text) > 8192 || strings.IndexFunc(req.Text, unicode.IsControl) >= 0 {
		writeErr(w, 400, "Enter a single-line message of up to 8192 bytes.")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	if a.Demo {
		writeErr(w, 409, "Demo agents do not have a running CLI.")
		return
	}
	if req.Host == "" {
		if a.SendMessage == nil {
			writeErr(w, 409, "No local session is available.")
			return
		}
		if err := a.SendMessage(ctx, req.ID, req.Text); err != nil {
			writeErr(w, 409, err.Error())
			return
		}
	} else {
		a.ssh.mu.Lock()
		snapshot := a.sshSnapshot(nil)
		a.ssh.mu.Unlock()
		found := false
		for _, s := range snapshot.Sessions {
			if s.ID == req.ID {
				found = true
				break
			}
		}
		if !found || !deskterm.ValidID(req.ID) || snapshot.Host != req.Host || snapshot.Connection != "online" {
			writeErr(w, 409, "Select an online Codebox session.")
			return
		}
		cmd, err := sshdeck.Command(ctx, req.Host, "queue", req.ID)
		if err != nil {
			writeErr(w, 400, err.Error())
			return
		}
		cmd.Stdin = strings.NewReader(req.Text)
		if err = cmd.Run(); err != nil {
			writeErr(w, 502, "Codebox did not confirm delivery. Check the session before retrying.")
			return
		}
	}
	writeJSON(w, 200, map[string]bool{"sent": true})
}
