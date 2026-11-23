package main

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Return a binding only for a foreground Codex client on the SSH login TTY.
// A shared app-server's files and a detached tmux pane are not evidence.
var rolloutID = regexp.MustCompile(`(?i)([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\.jsonl$`)
var threadUUID = regexp.MustCompile(`(?i)^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$`)

func terminalLinks() error {
	links := map[string]string{}
	dirs, _ := filepath.Glob("/proc/[0-9]*/comm")
	for _, name := range dirs {
		comm, _ := os.ReadFile(name)
		if strings.TrimSpace(string(comm)) != "codex" {
			continue
		}
		dir := filepath.Dir(name)
		stat, _ := os.ReadFile(filepath.Join(dir, "stat"))
		_, tail, ok := strings.Cut(string(stat), ") ")
		f := strings.Fields(tail)
		if !ok || len(f) < 6 || f[2] != f[5] {
			continue
		}
		tty, _ := os.Readlink(filepath.Join(dir, "fd", "0"))
		if !strings.HasPrefix(tty, "/dev/pts/") {
			continue
		}
		env, _ := os.ReadFile(filepath.Join(dir, "environ"))
		var sshTTY, conn string
		for _, kv := range strings.Split(string(env), "\x00") {
			key, val, _ := strings.Cut(kv, "=")
			switch key {
			case "SSH_TTY":
				sshTTY = val
			case "SSH_CONNECTION":
				conn = val
			}
		}
		words := strings.Fields(conn)
		if sshTTY != tty || len(words) != 4 {
			continue
		}
		argv, _ := os.ReadFile(filepath.Join(dir, "cmdline"))
		args := strings.Split(strings.TrimSuffix(string(argv), "\x00"), "\x00")
		var id string
		if len(args) > 2 && args[1] == "resume" {
			for _, v := range args[2:] {
				if v == "--" {
					continue
				}
				if threadUUID.MatchString(v) {
					id = v
				}
				break
			}
		}
		if id == "" {
			fds, _ := filepath.Glob(filepath.Join(dir, "fd", "*"))
			for _, fd := range fds {
				path, _ := os.Readlink(fd)
				if !strings.HasPrefix(filepath.Base(path), "rollout-") {
					continue
				}
				match := rolloutID.FindStringSubmatch(path)
				if len(match) == 0 {
					continue
				}
				if id != "" && id != match[1] {
					id = ""
					break
				}
				id = match[1]
			}
		}
		if id != "" {
			links[net.JoinHostPort(words[0], words[1])+"->"+net.JoinHostPort(words[2], words[3])] = id
		}
	}
	return json.NewEncoder(os.Stdout).Encode(links)
}
