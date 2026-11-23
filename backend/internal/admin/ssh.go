package admin

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/brushknight/agents-deck/backend/internal/model"
	"github.com/brushknight/agents-deck/backend/internal/sshdeck"
)

type sshState struct {
	Terminal   bool          `json:"terminal"`
	Host       string        `json:"host"`
	Connection string        `json:"connection"`
	Sessions   []model.Agent `json:"sessions"`
	LastSeen   time.Time     `json:"lastSeen"`
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
	host := str(a.readConfig(), "sshCodexHost", "")
	if host != m.state.Host {
		if m.cancel != nil {
			m.cancel()
		}
		m.generation++
		m.cancel = nil
		m.retry = time.Time{}
		m.state = sshState{Host: host}
	}
	if host != "" && sshdeck.ValidHost(host) && m.cancel == nil && !time.Now().Before(m.retry) && !a.Demo {
		ctx, cancel := context.WithCancel(context.Background())
		m.cancel = cancel
		if m.state.Connection == "" {
			m.state.Connection = "connecting"
		}
		go m.run(ctx, host, m.generation)
	}
	state := m.state
	state.Terminal = runtime.GOOS == "darwin"
	if state.Connection == "online" && time.Since(state.LastSeen) > 30*time.Second {
		state.Connection = "offline"
	}
	writeJSON(w, 200, state)
}

func (m *sshWatch) run(ctx context.Context, host string, generation uint64) {
	// No inherited tunnels, agent forwarding or interactive prompts.
	cmd, cmdErr := sshdeck.Command(ctx, host, "watch", "")
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
		if err := json.Unmarshal(scanner.Bytes(), &sessions); err != nil || len(sessions) > 32 {
			break
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
	cmd, err := sshdeck.Command(r.Context(), req.Host, "attach", req.ID)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	const script = `on run args
 set commandText to ""
 repeat with arg in args
  set commandText to commandText & " " & quoted form of (contents of arg)
 end repeat
 tell application "Terminal"
  do script commandText
  activate
 end tell
end run`
	args := append([]string{"-e", script, "--", cmd.Path}, cmd.Args[1:]...)
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	if err := exec.CommandContext(ctx, "/usr/bin/osascript", args...).Run(); err != nil {
		writeErr(w, 500, "could not open Terminal; run agentctl attach --ssh "+req.ID)
		return
	}
	writeJSON(w, 200, map[string]bool{"opened": true})
}
