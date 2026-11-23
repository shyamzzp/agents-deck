package admin

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

type sshSession struct {
	ID     string `json:"id"`
	Title  string `json:"title"`
	Status string `json:"status"`
}

type sshState struct {
	Host       string       `json:"host"`
	Connection string       `json:"connection"`
	Sessions   []sshSession `json:"sessions"`
	LastSeen   time.Time    `json:"lastSeen"`
}

type sshWatch struct {
	mu         sync.Mutex
	state      sshState
	cancel     context.CancelFunc
	retry      time.Time
	generation uint64
}

var sshTarget = regexp.MustCompile(`^([A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9][A-Za-z0-9.-]*$`)

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
		if len(host) > 253 || host != "" && !sshTarget.MatchString(host) {
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
	if host != "" && sshTarget.MatchString(host) && m.cancel == nil && !time.Now().Before(m.retry) && !a.Demo {
		ctx, cancel := context.WithCancel(context.Background())
		m.cancel = cancel
		if m.state.Connection == "" {
			m.state.Connection = "connecting"
		}
		go m.run(ctx, host, m.generation)
	}
	state := m.state
	if state.Connection == "online" && time.Since(state.LastSeen) > 30*time.Second {
		state.Connection = "offline"
	}
	writeJSON(w, 200, state)
}

func (m *sshWatch) run(ctx context.Context, host string, generation uint64) {
	// No inherited tunnels, agent forwarding or interactive prompts.
	cmd := exec.CommandContext(ctx, "ssh", "-T", "-n", "-oBatchMode=yes",
		"-oStrictHostKeyChecking=yes", "-oUserKnownHostsFile=~/.ssh/known_hosts",
		"-oClearAllForwardings=yes", "-oForwardAgent=no", "-oForwardX11=no",
		"-oControlPath=none", "-oPermitLocalCommand=no", "-oConnectTimeout=8",
		"-oServerAliveInterval=10", "-oServerAliveCountMax=2", "--", host,
		"exec \"$HOME/.local/bin/agents-deck-codex-reader\"")
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
	out, err := cmd.StdoutPipe()
	if err != nil || cmd.Start() != nil {
		return
	}
	defer cmd.Wait()
	// A hung helper can coexist with a healthy SSH connection.
	timer := time.AfterFunc(40*time.Second, func() { _ = cmd.Process.Kill() })
	defer timer.Stop()
	scanner := bufio.NewScanner(out)
	scanner.Buffer(make([]byte, 4096), 128<<10)
	for scanner.Scan() {
		var sessions []sshSession
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
