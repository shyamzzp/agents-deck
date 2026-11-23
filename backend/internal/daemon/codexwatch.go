package daemon

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	"github.com/brushknight/agents-deck/backend/internal/codex"
	"github.com/brushknight/agents-deck/backend/internal/deskterm"
	"github.com/brushknight/agents-deck/backend/internal/model"
	"github.com/brushknight/agents-deck/backend/internal/proc"
	"github.com/brushknight/agents-deck/backend/internal/store"
)

// errExternal answers actions that only the owning app can perform.
var errExternal = errors.New("this is a Codex app session — answer, interrupt or stop it in the Codex app")

// externalErr is the reason an external agent can't take an action.
func externalErr(e store.Entry) error {
	if e.A.Tool == "claude" {
		return errLive
	}
	return errExternal
}

// codexWatch mirrors recent Codex app/CLI threads onto the board.
type codexWatch struct {
	mu     sync.Mutex
	hidden map[string]int64 // thread id -> updated_at_ms when hidden
}

func (d *Daemon) codexWindow() time.Duration {
	if d.Cfg.CodexWindowHours > 0 {
		return time.Duration(d.Cfg.CodexWindowHours * float64(time.Hour))
	}
	return 6 * time.Hour
}

// WatchCodex polls Codex's state every few seconds. Until Codex has made its
// data folder (it isn't installed, or hasn't run yet) it only looks for the
// folder, once a minute.
func (d *Daemon) WatchCodex() {
	if d.Cfg.Codex != nil && !*d.Cfg.Codex {
		return
	}
	for {
		if _, err := os.Stat(codex.Home()); err == nil {
			break
		}
		time.Sleep(time.Minute)
	}
	logged := false
	for {
		threads, err := codex.RecentThreads(d.codexWindow())
		if err != nil && !logged {
			log.Printf("codex: %v", err)
			logged = true
		}
		d.syncCodex(threads)
		time.Sleep(2 * time.Second)
	}
}

func (d *Daemon) syncCodex(threads []codex.Thread) {
	d.codex.mu.Lock()
	hidden := d.codex.hidden
	d.codex.mu.Unlock()
	want := map[string]codex.Thread{}
	for _, t := range threads {
		if t.RolloutPath == "" || hidden[t.ID] >= t.UpdatedAtMs && hidden[t.ID] != 0 {
			continue
		}
		want[codex.AgentID(t.ID)] = t
	}
	// Drop threads that aged out, were archived or hidden.
	for _, e := range d.Store.Entries() {
		if e.External && e.A.Tool == "codex" && !inApp(e) { // Orca's and herdr's agents are theirs
			if _, ok := want[e.A.ID]; !ok {
				d.Store.Remove(e.A.ID)
			}
		}
	}
	for id, t := range want {
		if _, ok := d.Store.Get(id); !ok {
			e := &store.Entry{External: true, SessionID: t.ID, Transcript: t.RolloutPath}
			e.A = model.Agent{ID: id, Tool: "codex", External: true, Status: model.Idle,
				Title: t.DisplayTitle(), Cwd: t.Cwd, Folder: filepath.Base(t.Cwd), Branch: t.Branch, Model: t.Model}
			d.Store.Add(e)
		}
		d.Store.Update(id, func(e *store.Entry) bool {
			changed := codex.Tail(e)
			if t.UpdatedAtMs > 0 && e.MarkActiveStep(time.UnixMilli(t.UpdatedAtMs)) { // Codex's own time
				changed = true
			}
			if title := t.DisplayTitle(); title != e.A.Title {
				e.A.Title, changed = title, true
			}
			if t.Branch != "" && t.Branch != e.A.Branch {
				e.A.Branch, changed = t.Branch, true
			}
			// The app was closed mid-turn: nothing written for a while means it isn't working.
			if e.A.Status == model.Running || e.A.Status == model.Waiting {
				if st, err := os.Stat(e.Transcript); err == nil && time.Since(st.ModTime()) > 10*time.Minute {
					e.SetStatus(model.Idle)
					changed = true
				}
			}
			return changed
		})
	}
}

// Focus an existing CLI pane or resume the thread in a new terminal on macOS.
func (d *Daemon) focusExternal(e store.Entry) error {
	if runtime.GOOS == "darwin" {
		if !deskterm.ValidID(e.SessionID) {
			return errors.New("invalid Codex thread ID")
		}
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		ids, names := deskterm.CodexIndex(d.Store.Entries())
		inv, err := deskterm.Discover(ctx, "", nil, ids, names)
		if err != nil {
			return err
		}
		if p, ok := inv.Local[e.A.ID]; ok {
			err = deskterm.Focus(ctx, p, "pane")
		} else {
			home, _ := os.UserHomeDir()
			fromPath, _ := exec.LookPath("codex")
			program := ""
			for _, candidate := range []string{inv.CodexBinary, LookPathLogin("codex"), fromPath, filepath.Join(home, ".npm-global", "bin", "codex"), filepath.Join(home, ".local", "bin", "codex")} {
				if filepath.IsAbs(candidate) && exec.CommandContext(ctx, candidate, "--version").Run() == nil {
					program = candidate
					break
				}
			}
			if program == "" {
				if err = proc.Open("codex://threads/" + e.SessionID); err != nil {
					return fmt.Errorf("could not find a working Codex CLI or desktop app; run codex resume %s in your terminal", e.SessionID)
				}
			} else {
				cwd := e.A.Cwd
				if st, statErr := os.Stat(cwd); statErr != nil || !st.IsDir() {
					cwd = home
				}
				err = deskterm.OpenCommand(ctx, inv.Preferred, "/bin/zsh", "-lc", `cd -- "$1" && exec "$2" resume -- "$3"`, "agentctl", cwd, program, e.SessionID)
			}
		}
		if err != nil {
			return err
		}
	} else if err := proc.Open("codex://threads/" + e.SessionID); err != nil {
		return err
	}
	d.Store.Update(e.A.ID, func(x *store.Entry) bool { was := x.A.Unseen; x.A.Unseen = false; return was })
	log.Printf("focus %s: opened codex thread", e.A.ID)
	return nil
}

// hideExternal keeps a Codex thread off the board until it has new activity.
func (d *Daemon) hideExternal(e store.Entry) {
	d.codex.mu.Lock()
	if d.codex.hidden == nil {
		d.codex.hidden = map[string]int64{}
	}
	d.codex.hidden[e.SessionID] = time.Now().UnixMilli()
	d.codex.mu.Unlock()
	d.Store.Remove(e.A.ID)
}
