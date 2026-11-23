package admin

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"os/exec"
	"runtime"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/brushknight/agents-deck/backend/internal/deskterm"
	"github.com/brushknight/agents-deck/backend/internal/hats"
	"github.com/brushknight/agents-deck/backend/internal/model"
	"github.com/brushknight/agents-deck/backend/internal/sshdeck"
)

type sshState struct {
	GroupSlots map[string]int `json:"groupSlots,omitempty"`
	Pinned     []string       `json:"pinned,omitempty"`
	Terminal   bool           `json:"terminal"`
	Host       string         `json:"host"`
	Connection string         `json:"connection"`
	Sessions   []model.Agent  `json:"sessions"`
	LastSeen   time.Time      `json:"lastSeen"`
}

type sshWatch struct {
	mu         sync.Mutex
	state      sshState
	cancel     context.CancelFunc
	retry      time.Time
	generation uint64
}

func (a *Admin) sshDashboard(w http.ResponseWriter, r *http.Request) {
	m := &a.ssh
	m.mu.Lock()
	defer m.mu.Unlock()
	if r.Method == http.MethodPost {
		var body struct {
			Host *string `json:"host"`
		}
		if readBody(r, 1024, &body) != nil || body.Host == nil {
			writeErr(w, 400, "provide an SSH host")
			return
		}
		host := strings.TrimSpace(*body.Host)
		if len(host) > 253 || host != "" && !sshdeck.ValidHost(host) {
			writeErr(w, 400, "use an SSH alias or user@hostname")
			return
		}
		if err := a.editConfig(func(c map[string]any) error { c["sshCodexHost"] = host; return nil }); err != nil {
			writeErr(w, 500, err.Error())
			return
		}
	}
	writeJSON(w, 200, a.sshSnapshot(nil))
}

// Caller holds a.ssh.mu. Seed a newly pinned session until the watcher emits
// its first snapshot so subsequent dashboard reads also see the selection.
func (a *Admin) sshSnapshot(added *model.Agent) sshState {
	m := &a.ssh
	cfg := a.readConfig()
	host := str(cfg, "sshCodexHost", "")
	pins := sshPins(cfg, host)
	if host != m.state.Host || !slices.Equal(pins, m.state.Pinned) {
		if m.cancel != nil {
			m.cancel()
		}
		m.generation++
		m.cancel = nil
		m.retry = time.Time{}
		if host != m.state.Host {
			m.state = sshState{Host: host}
		}
		m.state.Pinned = pins
	}
	if added != nil && slices.Contains(pins, added.ID) &&
		!slices.ContainsFunc(m.state.Sessions, func(s model.Agent) bool { return s.ID == added.ID }) {
		m.state.Sessions = append(m.state.Sessions, *added)
	}
	if host != "" && sshdeck.ValidHost(host) && m.cancel == nil && !time.Now().Before(m.retry) && !a.Demo {
		ctx, cancel := context.WithCancel(context.Background())
		m.cancel = cancel
		if m.state.Connection == "" {
			m.state.Connection = "connecting"
		}
		go m.run(ctx, host, m.generation, pins)
	}
	state := m.state
	assignments, _ := cfg["sshDeckGroups"].(map[string]any)
	for _, id := range pins {
		if slot, ok := assignments[host+"/"+id].(float64); ok {
			if state.GroupSlots == nil {
				state.GroupSlots = map[string]int{}
			}
			state.GroupSlots[id] = int(slot)
		}
	}
	state.Terminal = runtime.GOOS == "darwin"
	if state.Connection == "online" && time.Since(state.LastSeen) > 30*time.Second {
		state.Connection = "offline"
	}
	return state
}

func (m *sshWatch) run(ctx context.Context, host string, generation uint64, pins []string) {
	// No inherited tunnels, agent forwarding or interactive prompts.
	cmd, cmdErr := sshdeck.Command(ctx, host, "watch", strings.Join(pins, " "))
	defer func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		if generation == m.generation {
			m.cancel()
			m.cancel = nil
			m.state.Connection = "offline"
			m.retry = time.Now().Add(8 * time.Second)
		}
	}()
	if cmdErr != nil {
		return
	}
	out, err := cmd.StdoutPipe()
	if err != nil || cmd.Start() != nil {
		return
	}
	defer cmd.Wait()
	// A hung helper can coexist with a healthy SSH connection.
	timer := time.AfterFunc(40*time.Second, func() { _ = cmd.Process.Kill() })
	defer timer.Stop()
	scanner := bufio.NewScanner(out)
	scanner.Buffer(make([]byte, 4096), 2<<20)
	for scanner.Scan() {
		var sessions []model.Agent
		if err := json.Unmarshal(scanner.Bytes(), &sessions); err != nil || len(sessions) > 32+len(pins) {
			break
		}
		for i := range sessions {
			if sessions[i].Hat == nil && sessions[i].Cwd != "" {
				hat := hats.Auto(sessions[i].Cwd)
				sessions[i].Hat = &hat
			}
		}
		timer.Reset(40 * time.Second)
		m.mu.Lock()
		if generation != m.generation {
			m.mu.Unlock()
			break
		}
		m.state.Sessions = sessions
		m.state.LastSeen = time.Now()
		m.state.Connection = "online"
		m.mu.Unlock()
	}
	_ = cmd.Process.Kill()
}

// Only the signed-in local dashboard can request a Terminal window.
// Pass each SSH argument as a separate AppleScript parameter.
func (a *Admin) sshAttach(w http.ResponseWriter, r *http.Request) {
	if runtime.GOOS != "darwin" {
		writeErr(w, 400, "use agentctl attach --ssh from a terminal")
		return
	}
	var req struct{ Host, ID string }
	if readBody(r, 1024, &req) != nil {
		writeErr(w, 400, "invalid session")
		return
	}
	a.ssh.mu.Lock()
	snapshot := a.ssh.state
	a.ssh.mu.Unlock()
	found := false
	for _, s := range snapshot.Sessions {
		if s.ID == req.ID {
			found = true
			break
		}
	}
	if !found || snapshot.Host != req.Host || snapshot.Connection != "online" || time.Since(snapshot.LastSeen) > 30*time.Second {
		writeErr(w, 409, "refresh the deck and select an online session")
		return
	}
	inv, err := a.terminalInventory(r.Context())
	if err != nil {
		writeErr(w, 503, err.Error())
		return
	}
	if inv.Host != req.Host {
		writeErr(w, 409, "SSH host changed")
		return
	}
	if p := inv.Remote[req.ID]; p.App != "" {
		if err := deskterm.Focus(r.Context(), p, "pane"); err != nil {
			writeErr(w, 409, err.Error())
			return
		}
		writeJSON(w, 200, map[string]string{"focused": p.Label()})
		return
	}
	cmd, err := sshdeck.Command(r.Context(), req.Host, "attach", req.ID)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	script := `on run args
 set commandText to ""
 repeat with arg in args
  set commandText to commandText & " " & quoted form of (contents of arg)
 end repeat
 tell application "Terminal"
  do script commandText
  activate
 end tell
end run`
	if inv.Preferred == "iTerm2" {
		script = `on run args
 set commandText to ""
 repeat with arg in args
  set commandText to commandText & " " & quoted form of (contents of arg)
 end repeat
 tell application id "com.googlecode.iterm2"
  activate
  if (count of windows) is 0 then
   create window with default profile command commandText
  else
   tell current window to create tab with default profile command commandText
  end if
 end tell
end run`
	}
	args := append([]string{"-e", script, "--", cmd.Path}, cmd.Args[1:]...)
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	if err := exec.CommandContext(ctx, "/usr/bin/osascript", args...).Run(); err != nil {
		writeErr(w, 500, "could not open Terminal; run agentctl attach --ssh "+req.ID)
		return
	}
	writeJSON(w, 200, map[string]bool{"opened": true})
}
