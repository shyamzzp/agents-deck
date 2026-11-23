// Package sshdeck connects the deck to its Codex helper through OpenSSH.
package sshdeck

import (
	"context"
	"errors"
	"os/exec"
	"regexp"
)

var hostPattern = regexp.MustCompile(`^([A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9][A-Za-z0-9.-]*$`)
var idPattern = regexp.MustCompile(`^[a-fA-F0-9][a-fA-F0-9-]{3,35}$`)

func ValidHost(host string) bool { return len(host) <= 253 && hostPattern.MatchString(host) }

func Command(ctx context.Context, host, action, id string) (*exec.Cmd, error) {
	if !ValidHost(host) {
		return nil, errors.New("configure an SSH host with agentctl config --ssh user@host")
	}
	args := []string{"-oStrictHostKeyChecking=yes", "-oUserKnownHostsFile=~/.ssh/known_hosts", "-oClearAllForwardings=yes", "-oForwardAgent=no", "-oForwardX11=no", "-oControlPath=none", "-oPermitLocalCommand=no", "-oConnectTimeout=8", "-oServerAliveInterval=10", "-oServerAliveCountMax=2"}
	if action == "attach" {
		args = append(args, "-t")
	} else {
		args = append(args, "-T", "-n", "-oBatchMode=yes")
	}
	command := `exec "$HOME/.local/bin/agents-deck-codex-reader"`
	switch action {
	case "watch":
	case "list":
		command += " list"
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
