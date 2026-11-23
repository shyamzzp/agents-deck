// Package sshdeck connects the deck to its Codex helper through OpenSSH.
package sshdeck

import (
	"context"
	"errors"
	"os/exec"
	"regexp"
	"strings"
)

var hostPattern = regexp.MustCompile(`^([A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9][A-Za-z0-9.-]*$`)
var idPattern = regexp.MustCompile(`^[a-fA-F0-9][a-fA-F0-9-]{3,35}$`)

func ValidHost(host string) bool { return len(host) <= 253 && hostPattern.MatchString(host) }

// %C is OpenSSH's hash of the destination, user, port and jump host.
const controlPath = "-oControlPath=~/.ssh/agents-deck-%C"

func baseArgs() []string {
	return []string{controlPath, "-oUserKnownHostsFile=~/.ssh/known_hosts", "-oClearAllForwardings=yes", "-oForwardAgent=no", "-oForwardX11=no", "-oPermitLocalCommand=no", "-oConnectTimeout=8", "-oServerAliveInterval=10", "-oServerAliveCountMax=2"}
}

func Login(ctx context.Context, host string, interactive bool) (*exec.Cmd, error) {
	if !ValidHost(host) {
		return nil, errors.New("enter an SSH username@hostname or alias")
	}
	args := append(baseArgs(), "-T", "-oControlMaster=auto", "-oControlPersist=15m")
	if interactive {
		args = append(args, "-oBatchMode=no", "-oStrictHostKeyChecking=ask")
	} else {
		args = append(args, "-oBatchMode=yes", "-oStrictHostKeyChecking=yes")
	}
	return exec.CommandContext(ctx, "ssh", append(args, "--", host, "true")...), nil
}

// Stop accepting new channels for a removed host. Existing terminals may finish.
func StopLogin(host string) {
	if ValidHost(host) {
		_ = exec.Command("ssh", controlPath, "-O", "stop", "--", host).Run()
	}
}

func Command(ctx context.Context, host, action, id string) (*exec.Cmd, error) {
	if !ValidHost(host) {
		return nil, errors.New("configure an SSH host with agentctl config --ssh username@hostname")
	}
	args := append(baseArgs(), "-oStrictHostKeyChecking=yes", "-oControlMaster=no")
	if action == "attach" {
		args = append(args, "-t")
	} else {
		args = append(args, "-T", "-oBatchMode=yes")
		if action != "queue" {
			args = append(args, "-n")
		}
	}
	command := `exec "$HOME/.local/bin/agents-deck-codex-reader"`
	switch action {
	case "watch":
		if id != "" {
			ids := strings.Fields(id)
			for _, v := range ids {
				if len(v) != 36 || !idPattern.MatchString(v) {
					return nil, errors.New("invalid pinned session ID")
				}
			}
			command += " watch " + strings.Join(ids, " ")
		}
	case "queue":
		if len(id) != 36 || !idPattern.MatchString(id) {
			return nil, errors.New("invalid Codex thread")
		}
		// Only the validated UUID enters the remote command. Text arrives via stdin.
		command = `exec codex queue --thread ` + id + ` --message="$(cat)"`
	case "list", "terminals":
		command += " " + action
	case "show", "attach":
		if !idPattern.MatchString(id) {
			return nil, errors.New("use the session UUID or at least four characters of its ID")
		}
		command += " " + action + " " + id
	default:
		return nil, errors.New("unknown SSH operation")
	}
	return exec.CommandContext(ctx, "ssh", append(args, "--", host, command)...), nil
}
