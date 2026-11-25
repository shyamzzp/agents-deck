package daemon

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/shyamzzp/agents-deck/backend/internal/deskterm"
	"github.com/shyamzzp/agents-deck/backend/internal/model"
	"github.com/shyamzzp/agents-deck/backend/internal/tmux"
)

// Message addresses the selected session independently of terminal focus.
func (d *Daemon) Message(ctx context.Context, id, text string) error {
	e, ok := d.Store.Get(id)
	if !ok || e.A.Status == model.Exited {
		return errors.New("This session has closed.")
	}
	if e.A.Tool == "codex" && deskterm.ValidID(e.SessionID) {
		home, _ := os.UserHomeDir()
		path, _ := exec.LookPath("codex")
		for _, bin := range []string{path, LookPathLogin("codex"), filepath.Join(home, ".npm-global", "bin", "codex"), filepath.Join(home, ".local", "bin", "codex")} {
			if !filepath.IsAbs(bin) || exec.CommandContext(ctx, bin, "queue", "--help").Run() != nil {
				continue
			}
			if err := exec.CommandContext(ctx, bin, "queue", "--thread", e.SessionID, "--message="+text).Run(); err != nil {
				return errors.New("Codex did not confirm delivery. Check the thread before retrying.")
			}
			return nil
		}
		return errors.New("Install a Codex CLI with the queue command to send to this thread.")
	}
	if e.A.Status != model.Idle {
		return errors.New("Wait for this CLI to return to its input prompt.")
	}
	switch e.A.App {
	case "orca":
		return d.orcaClient().Send(e.OrcaTerminal, text, true)
	case "cmux":
		c := d.cmuxClient()
		if err := c.SendText(e.CmuxSurface, text); err != nil {
			return err
		}
		return c.SendKey(e.CmuxSurface, "enter")
	case "herdr":
		c := d.herdrClient(e.HerdrSocket)
		if err := c.SendText(e.HerdrPane, text); err != nil {
			return err
		}
		return c.SendKeys(e.HerdrPane, "enter")
	}
	if !e.External && e.TmuxName != "" {
		return tmux.SendKeys(e.TmuxName, text, "Enter")
	}
	return errors.New("This session is monitored only. Open its terminal to send a message.")
}
