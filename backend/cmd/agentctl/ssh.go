package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"

	"github.com/shyamzzp/agents-deck/backend/internal/model"
	"github.com/shyamzzp/agents-deck/backend/internal/sshdeck"
)

const sshEndpoint = "/admin/v1/ssh-codex"

type hostInfo struct {
	Host       string
	Connection string
}

func sshConfig(args []string) error {
	if len(args) == 0 || args[0] != "--ssh" || len(args) > 2 {
		return errors.New("usage: agentctl config --ssh [user@host|--clear]")
	}
	var info hostInfo
	if err := call("GET", sshEndpoint, nil, &info); err != nil {
		return err
	}
	st, err := os.Stdin.Stat()
	interactive := err == nil && st.Mode()&os.ModeCharDevice != 0 && isTerminal()
	host := info.Host
	configure := len(args) == 2
	if configure {
		host = strings.TrimSpace(args[1])
		if host == "--clear" {
			host = ""
		} else if host == "" {
			return errors.New("enter username@hostname or use --clear")
		}
	} else if interactive {
		if host == "" {
			fmt.Fprint(os.Stderr, "Enter your SSH username@hostname (or SSH alias): ")
		} else {
			fmt.Fprintf(os.Stderr, "SSH host [%s] (Enter to sign in): ", host)
		}
		scanner := bufio.NewScanner(os.Stdin)
		if scanner.Scan() {
			if input := strings.TrimSpace(scanner.Text()); input != "" {
				host = input
			}
			configure = host != ""
		}
		if err := scanner.Err(); err != nil {
			return err
		}
	}
	if configure {
		previous := info.Host
		if host != "" {
			cmd, err := sshdeck.Login(context.Background(), host, interactive)
			if err != nil {
				return err
			}
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			if err := os.MkdirAll(filepath.Join(home, ".ssh"), 0700); err != nil {
				return err
			}
			if interactive {
				fmt.Fprintln(os.Stderr, "Signing in with SSH. Enter your password or key passphrase if prompted.")
			}
			cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
			if err := cmd.Run(); err != nil {
				return fmt.Errorf("SSH login to %s failed: %w", host, err)
			}
		}
		if err := call("POST", sshEndpoint, map[string]string{"host": host}, &info); err != nil {
			if previous != host {
				sshdeck.StopLogin(host)
			}
			return err
		}
		if previous != host {
			sshdeck.StopLogin(previous)
		}
		if host != "" {
			fmt.Printf("Signed in to %s.\n", host)
			return nil
		}
	}
	if info.Host == "" {
		fmt.Println("No SSH host configured. Set one with agentctl config --ssh username@hostname.")
	} else {
		fmt.Printf("%s (%s)\n", info.Host, info.Connection)
	}
	return nil
}

func runSSH(ctx context.Context, action, id string, out any) error {
	var info hostInfo
	if err := call("GET", sshEndpoint, nil, &info); err != nil {
		return err
	}
	cmd, err := sshdeck.Command(ctx, info.Host, action, id)
	if err != nil {
		return err
	}
	cmd.Stderr = os.Stderr
	if action == "attach" {
		cmd.Stdin, cmd.Stdout = os.Stdin, os.Stdout
		return cmd.Run()
	}
	raw, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("SSH %s: %w", action, err)
	}
	return json.Unmarshal(raw, out)
}

func listSSH(args []string, sortBy string, asJSON bool) error {
	if len(args) > 1 {
		return errors.New("usage: agentctl ls --ssh [--json] [ID]")
	}
	if sortBy != "active" && sortBy != "position" && sortBy != "slot" {
		return fmt.Errorf("unknown sort order %q", sortBy)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if len(args) == 1 {
		var a model.Agent
		if err := runSSH(ctx, "show", args[0], &a); err != nil {
			return err
		}
		return enc.Encode(a)
	}
	var agents []model.Agent
	if err := runSSH(ctx, "list", "", &agents); err != nil {
		return err
	}
	if asJSON {
		return enc.Encode(agents)
	}
	if len(agents) == 0 {
		fmt.Println("No unarchived remote Codex sessions.")
		return nil
	}
	for i := range agents {
		a := &agents[i]
		a.Title = termText(a.Title)
		a.Folder = termText(a.Folder)
		if a.Waiting != nil {
			a.Waiting.Title = termText(a.Waiting.Title)
		}
	}
	inv := paneInventory()
	if err := printList(model.State{Agents: agents}, sortBy, inv.Remote); err != nil {
		return err
	}
	matched := map[string]bool{}
	for _, p := range inv.Remote {
		matched[p.Key()] = true
	}
	for _, p := range inv.HostPanes {
		if matched[p.Key()] {
			continue
		}
		fmt.Printf("\nCodebox SSH connection (thread unidentified): %s\n", p.Label())
	}
	return nil
}

func termText(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, s)
}
