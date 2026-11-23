// The reader streams recent Codex activity and serves explicit CLI requests.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/brushknight/agents-deck/backend/internal/codex"
	"github.com/brushknight/agents-deck/backend/internal/model"
	"github.com/brushknight/agents-deck/backend/internal/store"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func entry(t codex.Thread) *store.Entry {
	a := model.Agent{ID: t.ID, Title: t.DisplayTitle(), Cwd: t.Cwd, Folder: filepath.Base(t.Cwd),
		Branch: t.Branch, Model: t.Model, Status: model.Idle, Tool: "codex", External: true}
	if t.UpdatedAtMs > 0 {
		a.LastActive = time.UnixMilli(t.UpdatedAtMs).UTC()
	}
	return &store.Entry{A: a, Transcript: t.RolloutPath}
}

func details(t codex.Thread, e *store.Entry) model.Agent {
	codex.Tail(e)
	a := e.A
	// Rollout replay timestamps transitions at read time. Only expose observed activity times.
	a.StatusSince = time.Time{}
	a.Title = t.DisplayTitle()
	if st, err := os.Stat(e.Transcript); err != nil {
		a.Status = "unknown"
	} else if time.Since(st.ModTime()) > 10*time.Minute {
		a.Status = model.Idle
		a.Waiting = nil
		a.Activity = nil
	}
	return a
}

func match(threads []codex.Thread, id string) (codex.Thread, error) {
	var found codex.Thread
	for _, t := range threads {
		if strings.HasPrefix(t.ID, strings.ToLower(id)) {
			if found.ID != "" {
				return codex.Thread{}, errors.New("ambiguous session ID; use a longer prefix")
			}
			found = t
		}
	}
	if found.ID == "" {
		return found, errors.New("no unarchived session matches that ID")
	}
	return found, nil
}

func run(args []string) error {
	enc := json.NewEncoder(os.Stdout)
	if len(args) == 0 {
		return watch(enc)
	}
	threads, err := codex.AllThreads()
	if err != nil {
		return err
	}
	if len(args) == 1 && args[0] == "list" {
		agents := make([]model.Agent, 0, len(threads))
		for _, t := range threads {
			e := entry(t)
			if time.Since(e.A.LastActive) < 6*time.Hour {
				agents = append(agents, details(t, e))
			} else {
				e.A.Status = "saved"
				agents = append(agents, e.A)
			}
		}
		return enc.Encode(agents)
	}
	if len(args) != 2 {
		return errors.New("expected list, show ID or attach ID")
	}
	t, err := match(threads, args[1])
	if err != nil {
		return err
	}
	switch args[0] {
	case "show":
		return enc.Encode(details(t, entry(t)))
	case "attach":
		cmd := exec.Command("codex", "resume", "--", t.ID)
		cmd.Dir = t.Cwd
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		return cmd.Run()
	default:
		return errors.New("unknown reader command")
	}
}

func watch(enc *json.Encoder) error {
	cache := map[string]*store.Entry{}
	for {
		threads, err := codex.RecentThreads(6 * time.Hour)
		if err != nil {
			return err
		}
		next := map[string]*store.Entry{}
		agents := make([]model.Agent, 0, len(threads))
		for _, t := range threads {
			e := cache[t.ID]
			if e == nil || e.Transcript != t.RolloutPath {
				e = entry(t)
			}
			next[t.ID] = e
			a := details(t, e)
			title := []rune(a.Title)
			if len(title) > 256 {
				a.Title = string(title[:256]) + "…"
			}
			agents = append(agents, a)
		}
		cache = next
		if err := enc.Encode(agents); err != nil {
			return err
		}
		time.Sleep(5 * time.Second)
	}
}
