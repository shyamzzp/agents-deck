// agents-deck-codex-reader streams read-only session summaries over SSH stdout.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/brushknight/agents-deck/backend/internal/codex"
	"github.com/brushknight/agents-deck/backend/internal/model"
	"github.com/brushknight/agents-deck/backend/internal/store"
)

type summary struct {
	ID     string       `json:"id"`
	Title  string       `json:"title"`
	Status model.Status `json:"status"`
}

func main() {
	enc := json.NewEncoder(os.Stdout)
	cache := map[string]*store.Entry{}
	for {
		threads, err := codex.RecentThreads(6 * time.Hour)
		if err != nil {
			fmt.Fprintln(os.Stderr, "Cannot read Codex session database")
			os.Exit(1)
		}
		next := map[string]*store.Entry{}
		sessions := []summary{}
		for _, t := range threads {
			e := cache[t.ID]
			if e == nil || e.Transcript != t.RolloutPath {
				e = &store.Entry{Transcript: t.RolloutPath, A: model.Agent{Status: model.Idle}}
			}
			codex.Tail(e)
			next[t.ID] = e
			status := e.A.Status
			if info, err := os.Stat(t.RolloutPath); err != nil {
				status = "unknown"
			} else if time.Since(info.ModTime()) > 10*time.Minute {
				status = model.Idle
			}
			title := []rune(strings.Join(strings.Fields(t.DisplayTitle()), " "))
			if len(title) > 120 {
				title = title[:120]
			}
			sessions = append(sessions, summary{t.ID, string(title), status})
		}
		cache = next
		if enc.Encode(sessions) != nil {
			return
		}
		time.Sleep(5 * time.Second)
	}
}
