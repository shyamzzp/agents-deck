// Package deskterm locates live SSH clients by their foreground TTY on macOS.
package deskterm

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/brushknight/agents-deck/backend/internal/sshdeck"
)

//go:embed terminal.js
var terminalScript string

type Pane struct {
	App    string `json:"app"`
	Window int    `json:"window"`
	Tab    int    `json:"tab"`
	Pane   int    `json:"pane"`
	TTY    string `json:"tty"`
	ID     string `json:"id"`
}

func (p Pane) Label() string {
	label := fmt.Sprintf("%s W%d T%d", p.App, p.Window, p.Tab)
	if p.App == "iTerm2" {
		label += fmt.Sprintf(" P%d", p.Pane)
	}
	return label
}

type Inventory struct {
	Preferred string          `json:"preferred"`
	Host      string          `json:"host"`
	Remote    map[string]Pane `json:"remote"`
	Local     map[string]Pane `json:"local"`
	HostPanes []Pane          `json:"hostPanes"`
}

var uuid = regexp.MustCompile(`(?i)^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$`)

// Destination and remote command from a foreground OpenSSH client. Skip option
// operands, in particular tunnel specs, rather than treating them as hosts.
func sshArgs(args []string) (string, []string) {
	var dest string
	for i := 0; i < len(args); i++ {
		x := args[i]
		if x == "--" {
			continue
		}
		if strings.HasPrefix(x, "-") {
			// SSH allows its options on either side of the destination.
			if x == "-N" || x == "-f" {
				return "", nil
			}
			if len(x) == 2 && strings.Contains("BbcDEeFIiJLlmOoPpQRSWw", x[1:]) {
				i++
			}
			continue
		}
		if dest == "" {
			dest = x
			continue
		}
		return dest, args[i:]
	}
	return dest, nil
}

func resumeID(args []string) string {
	if len(args) < 3 || filepath.Base(args[0]) != "codex" || args[1] != "resume" {
		return ""
	}
	rest := args[2:]
	if rest[0] == "--" {
		rest = rest[1:]
	}
	if len(rest) > 0 && uuid.MatchString(rest[0]) {
		return strings.ToLower(rest[0])
	}
	return ""
}

func Discover(ctx context.Context, host string, localTTY map[string]string, threadIDs map[string]string) (Inventory, error) {
	inv := Inventory{Host: host, Remote: map[string]Pane{}, Local: map[string]Pane{}}
	if runtime.GOOS != "darwin" {
		return inv, nil
	}
	var gui struct {
		Preferred string
		Panes     []Pane
	}
	raw, err := exec.CommandContext(ctx, "/usr/bin/osascript", "-l", "JavaScript", "-e", terminalScript, "--", "list").Output()
	if err != nil {
		return inv, fmt.Errorf("reading terminal windows: %w", err)
	}
	if err = json.Unmarshal(raw, &gui); err != nil {
		return inv, err
	}
	inv.Preferred = gui.Preferred
	u, err := user.Current()
	if err != nil {
		return inv, err
	}
	raw, err = exec.CommandContext(ctx, "/bin/ps", "-ww", "-U", u.Uid, "-o", "tty=,stat=,pid=,command=").Output()
	if err != nil {
		return inv, err
	}
	procs := map[string][][]string{}
	for _, line := range strings.Split(string(raw), "\n") {
		f := strings.Fields(line)
		if len(f) >= 4 && strings.Contains(f[1], "+") && !strings.Contains(f[1], "T") {
			procs["/dev/"+f[0]] = append(procs["/dev/"+f[0]], f[2:])
		}
	}
	bare := map[string]Pane{}
	for _, p := range gui.Panes {
		for id, tty := range localTTY {
			if p.TTY == tty && inv.Local[id].App == "" {
				inv.Local[id] = p
			}
		}
		for _, f := range procs[p.TTY] {
			args := f[1:]
			if id := threadIDs[resumeID(args)]; id != "" && inv.Local[id].App == "" {
				inv.Local[id] = p
			}
			if filepath.Base(args[0]) != "ssh" || host == "" {
				continue
			}
			dest, command := sshArgs(args[1:])
			if dest != host {
				continue
			}
			id := resumeID(command)
			if len(command) == 4 && command[0] == "exec" && command[1] == `"$HOME/.local/bin/agents-deck-codex-reader"` && command[2] == "attach" && uuid.MatchString(command[3]) {
				id = command[3]
			}
			if id != "" && inv.Remote[id].App == "" {
				inv.Remote[id] = p
			}
			if len(command) == 0 {
				inv.HostPanes = append(inv.HostPanes, p)
				bare[f[0]] = p
			}
		}
	}
	if len(bare) > 0 {
		// A plain SSH shell can identify the thread on the remote side. Compare the
		// full TCP tuple; a multiplexed or NAT-translated client may have no match.
		probe, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		cmd, err := sshdeck.Command(probe, host, "terminals", "")
		var links map[string]string
		if err == nil {
			raw, err := cmd.Output()
			if err == nil {
				_ = json.Unmarshal(raw, &links)
			}
		}
		if len(links) > 0 {
			for pid, p := range bare {
				out, _ := exec.CommandContext(probe, "/usr/sbin/lsof", "-nP", "-a", "-p", pid, "-iTCP", "-sTCP:ESTABLISHED", "-Fn").Output()
				for _, line := range strings.Split(string(out), "\n") {
					if id := links[strings.TrimPrefix(line, "n")]; id != "" && inv.Remote[id].App == "" {
						inv.Remote[id] = p
					}
				}
			}
		}
	}
	return inv, nil
}

func Focus(ctx context.Context, p Pane, mode string) error {
	if mode != "tab" && mode != "pane" {
		return fmt.Errorf("invalid focus mode %q", mode)
	}
	_, err := exec.CommandContext(ctx, "/usr/bin/osascript", "-l", "JavaScript", "-e", terminalScript, "--", mode, p.App, p.TTY, p.ID).Output()
	if err != nil {
		return fmt.Errorf("could not focus %s: %w", p.Label(), err)
	}
	return nil
}

// Key identifies a pane during selection without trusting window indices,
// which change when the user raises or rearranges windows.
func (p Pane) Key() string { return p.App + "/" + p.ID }
