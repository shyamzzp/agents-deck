// Tasks an agent has been given of its own, beside the deck's built-in ones.
//
// The quick list on an agent's card holds eight tasks every agent has. A
// prompt from the session's history can be kept as a ninth: it lands in the
// same grid, under a short name taken from the prompt itself, and tapping it
// sends that prompt again. They live here rather than on a phone so the
// tablet, the phone and the dashboard all show the same grid.
//
// One small file, rewritten whole: a deck has a handful of these, not
// thousands, and a rewrite is what makes a half-written file impossible.

package tasks

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/brushknight/agents-deck/backend/internal/model"
)

// Max is how many of its own tasks one agent may keep. Beyond that the oldest
// is dropped: the grid is a handful of buttons, not a history.
const Max = 24

// NameMax is how long a task's name may be, in runes.
const NameMax = 28

// TextMax is how much of a prompt a task carries.
const TextMax = 4000

// Task is one of an agent's own tasks, as the state carries it.
type Task = model.Task

type Store struct {
	Path string

	mu     sync.Mutex
	loaded bool
	byID   map[string][]Task // agent id -> its tasks, oldest first
}

func Open(path string) *Store {
	s := &Store{Path: path}
	s.mu.Lock()
	s.load()
	s.mu.Unlock()
	return s
}

func (s *Store) load() {
	if s.loaded {
		return
	}
	s.loaded = true
	s.byID = map[string][]Task{}
	b, err := os.ReadFile(s.Path)
	if err != nil {
		return
	}
	_ = json.Unmarshal(b, &s.byID)
}

func (s *Store) save() {
	if s.Path == "" {
		return
	}
	b, err := json.MarshalIndent(s.byID, "", "  ")
	if err != nil {
		return
	}
	tmp := s.Path + ".tmp"
	if os.WriteFile(tmp, append(b, '\n'), 0o600) == nil {
		_ = os.Rename(tmp, s.Path)
	}
}

// List is an agent's own tasks, oldest first (the order they are drawn in).
func (s *Store) List(agent string) []Task {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.load()
	return append([]Task(nil), s.byID[agent]...)
}

// All is every agent's tasks, for the state the clients read.
func (s *Store) All() map[string][]Task {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.load()
	out := make(map[string][]Task, len(s.byID))
	for id, list := range s.byID {
		out[id] = append([]Task(nil), list...)
	}
	return out
}

// Add keeps text as one of agent's tasks under name (or a name taken from the
// text when it is empty) and returns it. A task whose text is already kept is
// not kept twice.
func (s *Store) Add(agent, name, text string) (Task, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return Task{}, ErrEmpty
	}
	if r := []rune(text); len(r) > TextMax {
		text = string(r[:TextMax])
	}
	if strings.TrimSpace(name) == "" {
		name = ShortName(text)
	}
	name = clip(strings.TrimSpace(name), NameMax)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.load()
	for _, t := range s.byID[agent] {
		if t.Text == text {
			return t, nil
		}
	}
	t := Task{ID: id(), Name: name, Text: text, Added: time.Now().UTC()}
	list := append(s.byID[agent], t)
	if len(list) > Max {
		list = list[len(list)-Max:]
	}
	s.byID[agent] = list
	s.save()
	return t, nil
}

// Remove takes one of an agent's tasks away. It reports whether it was there.
func (s *Store) Remove(agent, taskID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.load()
	list := s.byID[agent]
	for i, t := range list {
		if t.ID == taskID {
			s.byID[agent] = append(list[:i:i], list[i+1:]...)
			if len(s.byID[agent]) == 0 {
				delete(s.byID, agent)
			}
			s.save()
			return true
		}
	}
	return false
}

// Forget drops every task of an agent that is no longer on the deck.
func (s *Store) Forget(agent string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.load()
	if _, ok := s.byID[agent]; !ok {
		return
	}
	delete(s.byID, agent)
	s.save()
}

// ShortName is a tile's name taken from the prompt itself: the first few words
// that carry meaning, hyphenated, as the built-in tasks are named
// ("push-github", "verify-changes").
func ShortName(text string) string {
	skip := map[string]bool{
		"the": true, "a": true, "an": true, "to": true, "of": true,
		"and": true, "for": true, "in": true, "on": true, "with": true,
		"please": true, "can": true, "you": true, "your": true, "it": true,
		"this": true, "that": true, "me": true, "my": true, "is": true,
		"are": true, "be": true, "do": true, "then": true, "so": true,
	}
	var words []string
	for _, w := range strings.Fields(strings.ToLower(text)) {
		w = strings.Trim(w, ".,:;!?\"'`()[]{}")
		if w == "" || skip[w] {
			continue
		}
		words = append(words, w)
		if len(words) == 3 {
			break
		}
	}
	if len(words) == 0 {
		// Nothing but small words: take the text as it came.
		words = strings.Fields(strings.ToLower(text))
		if len(words) > 3 {
			words = words[:3]
		}
	}
	return clip(strings.Join(words, "-"), NameMax)
}

func clip(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return strings.TrimRight(string(r[:n]), "-")
}

// Default is the store's file beside the service's other state.
func Default(dir string) string { return filepath.Join(dir, "agent-tasks.json") }

// ErrEmpty is a task with nothing to send.
var ErrEmpty = errors.New("a task needs some text")

// id is a short, unguessable handle for one task.
func id() string {
	var b [6]byte
	if _, err := rand.Read(b[:]); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 36)
	}
	return hex.EncodeToString(b[:])
}
