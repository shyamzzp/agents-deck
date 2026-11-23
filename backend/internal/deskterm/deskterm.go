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
	"github.com/brushknight/agents-deck/backend/internal/store"
)

//go:embed terminal.js
var terminalScript string

type Pane struct {
	Connection string `json:"connection,omitempty"`
	Linked     bool   `json:"linked,omitempty"`
	App        string `json:"app"`
	Window     int    `json:"window"`
	Tab        int    `json:"tab"`
	Pane       int    `json:"pane"`
	TTY        string `json:"tty"`
	ID         string `json:"id"`
}

func (p Pane) Label() string {
	label := fmt.Sprintf("%s W%d T%d", p.App, p.Window, p.Tab)
	if p.App == "iTerm2" {
		label += fmt.Sprintf(" P%d", p.Pane)
	}
	return label
}

type Inventory struct {
	CodexBinary string          `json:"-"`
	Preferred   string          `json:"preferred"`
	Host        string          `json:"host"`
	Remote      map[string]Pane `json:"remote"`
	Local       map[string]Pane `json:"local"`
	HostPanes   []Pane          `json:"hostPanes"`
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

func ValidID(id string) bool { return uuid.MatchString(id) }

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

// CodexIndex includes only mirrored CLI/app threads. Empty values mark ambiguous names.
func CodexIndex(entries []store.Entry) (map[string]string, map[string]string) {
	ids, names := map[string]string{}, map[string]string{}
	for _, e := range entries {
		if e.A.Tool != "codex" || !e.External || e.A.App != "" || !ValidID(e.SessionID) {
			continue
		}
		ids[e.SessionID] = e.A.ID
		title := e.A.Title
		if title == "" || title == e.A.Folder {
			continue
		}
		if _, seen := names[title]; seen {
			names[title] = ""
		} else {
			names[title] = e.A.ID
		}
	}
	return ids, names
}

// Codex prefixes busy titles with a braille spinner. iTerm may append the
// folder and foreground process. Match the entire remaining thread name.
func paneThread(title string, names map[string]string) string {
	title = strings.TrimSpace(strings.TrimLeftFunc(title, func(r rune) bool { return r >= 0x2800 && r <= 0x28ff }))
	for _, suffix := range []string{` (codex")`, " (codex)"} {
		title = strings.TrimSuffix(title, suffix)
	}
	if id, ok := names[title]; ok {
		return id
	}
	name, _, _ := strings.Cut(title, " | ")
	return names[name]
}

func Discover(ctx context.Context, host string, localTTY map[string]string, threadIDs, names map[string]string) (Inventory, error) {
	inv := Inventory{Host: host, Remote: map[string]Pane{}, Local: map[string]Pane{}}
	if runtime.GOOS != "darwin" {
		return inv, nil
	}
	var gui struct {
		Preferred string
		Panes     []struct {
			Pane
			Title string
		}
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
	raw, err = exec.CommandContext(ctx, "/bin/ps", "-ww", "-U", u.Uid, "-o", "tty=,stat=,pid=,lstart=,command=").Output()
	if err != nil {
		return inv, err
	}
	procs := map[string][][]string{}
	for _, line := range strings.Split(string(raw), "\n") {
		f := strings.Fields(line)
		if len(f) >= 9 && strings.Contains(f[1], "+") && !strings.Contains(f[1], "T") {
			procs["/dev/"+f[0]] = append(procs["/dev/"+f[0]], f[2:])
		}
	}
	bare := map[string]Pane{}
	sshTitles := map[string]string{}
	candidates := map[string][]Pane{}
	for _, guiPane := range gui.Panes {
		p := guiPane.Pane
		for id, tty := range localTTY {
			if p.TTY == tty && inv.Local[id].App == "" {
				inv.Local[id] = p
			}
		}
		for _, f := range procs[p.TTY] {
			args := f[6:]
			if id := threadIDs[resumeID(args)]; id != "" && inv.Local[id].App == "" {
				inv.Local[id] = p
			}
			if filepath.Base(args[0]) == "codex" {
				if filepath.IsAbs(args[0]) {
					inv.CodexBinary = args[0]
				}
				if resumeID(args) == "" {
					if id := paneThread(guiPane.Title, names); id != "" {
						candidates[id] = append(candidates[id], p)
					}
				}
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
			// A direct Codex launch can also resolve its thread interactively.
			if len(command) == 0 || (id == "" && filepath.Base(command[0]) == "codex") {
				p.Connection = strings.Join(f[:6], "-")
				inv.HostPanes = append(inv.HostPanes, p)
				bare[f[0]] = p
				sshTitles[p.Key()] = guiPane.Title
			}
		}
	}
	for id, panes := range candidates {
		if len(panes) == 1 && inv.Local[id].App == "" {
			inv.Local[id] = panes[0]
		}
	}
	if len(bare) > 0 {
		// A plain SSH shell can identify the thread on the remote side. Compare the
		// full TCP tuple; a multiplexed or NAT-translated client may have no match.
		probe, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		cmd, err := sshdeck.Command(probe, host, "terminals", "")
		var links map[string]string
		if err == nil {
			raw, err := cmd.Output()
			if err == nil {
				_ = json.Unmarshal(raw, &links)
			}
		}
		hasEndpoints := false
		for k := range links {
			if strings.Contains(k, "->") {
				hasEndpoints = true
				break
			}
		}
		if hasEndpoints {
			for pid, p := range bare {
				out, _ := exec.CommandContext(probe, "/usr/sbin/lsof", "-nP", "-a", "-p", pid, "-iTCP", "-sTCP:ESTABLISHED", "-Fn").Output()
				for _, line := range strings.Split(string(out), "\n") {
					if id := links[strings.TrimPrefix(line, "n")]; id != "" && inv.Remote[id].App == "" {
						inv.Remote[id] = p
					}
				}
			}
		}
		matchSSHTitles(&inv, sshTitles, links)
	}
	return inv, nil
}

// A bare SSH client exposes the host in ps. Inside it, Codex may set a
// per-pane title even when its shared app-server owns all the rollout files.
func matchSSHTitles(inv *Inventory, titles, links map[string]string) {
	occupied := map[string]bool{}
	for _, p := range inv.Remote {
		occupied[p.Key()] = true
	}
	candidates := map[string][]Pane{}
	for _, p := range inv.HostPanes {
		title := strings.TrimSpace(titles[p.Key()])
		// iTerm appends the foreground process, sometimes on a new line.
		title = strings.TrimSpace(strings.TrimSuffix(title, " (ssh)"))
		title = strings.TrimSpace(strings.TrimLeftFunc(title, func(r rune) bool {
			return r >= 0x2800 && r <= 0x28ff
		}))
		if id := links[sshdeck.TitleKey(title)]; title != "" && ValidID(id) {
			candidates[id] = append(candidates[id], p)
		}
	}
	for id, panes := range candidates {
		if len(panes) == 1 && !occupied[panes[0].Key()] && inv.Remote[id].App == "" {
			inv.Remote[id] = panes[0]
		}
	}
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
func (p Pane) Key() string { return p.App + "/" + p.ID + "/" + p.Connection }
