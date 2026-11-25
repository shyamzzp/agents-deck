// The tasks the deck finds in a session's own prompts.
//
// Every agent's card has the built-in eight; beyond those it keeps a band of
// its own, and the deck fills that band by reading what the session has
// actually been asked for. The judging is in internal/tasks: here is only when
// it runs.
//
// It runs rarely. A session is judged when it first joins the deck, and after
// that only when it has been asked something new; what it was judged up to is
// kept in the task file, so a session that leaves the deck and comes back
// carries on from there rather than making every tile over again behind
// someone who has already arranged, pinned or thrown them away.
package daemon

import (
	"time"

	"github.com/brushknight/agents-deck/backend/internal/store"
	"github.com/brushknight/agents-deck/backend/internal/tasks"
)

// mineLeast is how few mined tasks make a session worth topping up from the
// rest of the deck. Under three the band reads as broken rather than as a
// band, and a session on its first day has nothing of its own yet.
const mineLeast = 3

// mineTasks judges every session that has something new to judge.
func (d *Daemon) mineTasks() {
	if d.Tasks == nil {
		return
	}
	type job struct {
		id      string
		prompts []string
		fresh   bool // never looked at: a session that has just joined
	}
	var jobs []job
	d.Store.Each(func(e *store.Entry) bool {
		if e.A.ID == "" || e.A.Tool != "claude" {
			return false // only Claude sessions keep a transcript to read
		}
		fresh := !d.Tasks.Known(e.A.ID)
		if !fresh && len(e.History) <= d.Tasks.Checked(e.A.ID) {
			return false
		}
		jobs = append(jobs, job{
			id:      e.A.ID,
			prompts: append([]string(nil), e.History...),
			fresh:   fresh,
		})
		return false
	})
	for _, j := range jobs {
		d.Tasks.Mine(j.id, j.prompts)
		if j.fresh {
			d.Tasks.TopUp(j.id, mineLeast)
		}
	}
	if len(jobs) > 0 {
		// The tasks live beside the fleet rather than in it, so the boards
		// are told to read the state again.
		d.Store.Touch()
	}
}

// Tasks is the store of the agents' own tasks, when the service has one. The
// demo and the tests leave it nil and nothing is mined.
type TaskStore interface {
	Known(agent string) bool
	Checked(agent string) int
	Mine(agent string, prompts []string) int
	TopUp(agent string, least int) int
}

var _ TaskStore = (*tasks.Store)(nil)

// mineEvery is how often the prompts are judged. Reading a session's history
// is cheap, but it is work nobody is waiting for: once every half minute is
// sooner than anyone can ask for something and look at the card.
const mineEvery = 30 * time.Second
