// Tasks an agent has been given of its own, beside the deck's built-in ones.
//
// The quick list on an agent's card holds eight tasks every agent has. Beyond
// those, an agent keeps two bands of its own:
//
//   - custom: tasks a person made, by speaking one into an empty cell or by
//     keeping a prompt from the session's history. These come first, because
//     what you made is what you look for.
//   - mined: tasks the deck found in the session's own prompts. These come
//     after, and only the latest ten are kept: one nobody pinned and nobody
//     uses should age out rather than pile up.
//
// A task's place is a rank within its band, not a cell of the board: a phone
// draws four to a row and a tablet seven or ten, so a cell number would mean a
// different place on every screen. Dragging moves a task inside its own band.
//
// They live here, in the service, rather than on a phone, so the tablet, the
// phone and the dashboard all show one list. One small file, rewritten whole:
// a deck has a handful of these, not thousands, and a rewrite is what makes a
// half-written file impossible.

package tasks

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/brushknight/agents-deck/backend/internal/model"
)

// MinedMax is how many mined tasks one agent keeps; the oldest unpinned one
// goes when another arrives.
const MinedMax = 10

// Max is how many tasks of its own one agent may keep in total.
const Max = 24

// NameMax is how long a task's name may be, in runes.
const NameMax = 28

// TextMax is how much of a prompt a task carries.
const TextMax = 4000

// Task is one of an agent's own tasks, as the state carries it.
type Task = model.Task

// ErrEmpty is a task with nothing to send.
var ErrEmpty = errors.New("a task needs some text")

// ErrFull is an agent already keeping as many tasks as it may.
var ErrFull = errors.New("this agent keeps all the tasks it can; remove one first")

type Store struct {
	Path string

	mu     sync.Mutex
	loaded bool
	byID   map[string][]Task // agent id -> its tasks, custom band first, by rank
	// checked is how many of an agent's prompts the miner has looked at, so a
	// session that joins again carries on rather than starting over.
	checked map[string]int
}

// diskFile is what is written. The first shape was a bare map of tasks; that
// is still read, so an older deck's file is not thrown away.
type diskFile struct {
	Tasks   map[string][]Task `json:"tasks"`
	Checked map[string]int    `json:"checked,omitempty"`
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
	s.byID, s.checked = map[string][]Task{}, map[string]int{}
	b, err := os.ReadFile(s.Path)
	if err != nil {
		return
	}
	var f diskFile
	if json.Unmarshal(b, &f) == nil && f.Tasks != nil {
		s.byID = f.Tasks
		if f.Checked != nil {
			s.checked = f.Checked
		}
	} else {
		// The older shape: agent id -> tasks, with nothing else in it.
		_ = json.Unmarshal(b, &s.byID)
	}
	for id, list := range s.byID {
		s.byID[id] = ordered(list)
	}
}

func (s *Store) save() {
	if s.Path == "" {
		return
	}
	b, err := json.MarshalIndent(diskFile{Tasks: s.byID, Checked: s.checked}, "", "  ")
	if err != nil {
		return
	}
	tmp := s.Path + ".tmp"
	if os.WriteFile(tmp, append(b, '\n'), 0o600) == nil {
		_ = os.Rename(tmp, s.Path)
	}
}

// ordered sorts a list into the order it is drawn in and renumbers the ranks,
// so a rank is always a task's position in its band.
func ordered(list []Task) []Task {
	out := append([]Task(nil), list...)
	sort.SliceStable(out, func(i, j int) bool {
		if a, b := out[i].Band(), out[j].Band(); a != b {
			return a < b
		}
		if out[i].Rank != out[j].Rank {
			return out[i].Rank < out[j].Rank
		}
		// Nothing else to go on: the one made first comes first. A file from
		// an older deck has no ranks at all, only the cell it was made in.
		if out[i].Slot != out[j].Slot {
			return out[i].Slot < out[j].Slot
		}
		return out[i].Added.Before(out[j].Added)
	})
	band, rank := 0, 0
	for i := range out {
		if out[i].Band() != band {
			band, rank = out[i].Band(), 0
		}
		out[i].Rank = rank
		rank++
	}
	return out
}

// List is an agent's own tasks, in the order the board draws them.
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

// Checked is how many of an agent's prompts the miner has read.
func (s *Store) Checked(agent string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.load()
	return s.checked[agent]
}

// SetChecked records how far the miner has read, so a session that joins
// again is mined from there on rather than from its first prompt. Recording
// nothing read still counts as having looked (see [Store.Known]).
func (s *Store) SetChecked(agent string, turns int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.load()
	if had, ok := s.checked[agent]; ok && turns <= had {
		return
	}
	s.checked[agent] = turns
	s.save()
}

// Known says whether the miner has looked at this session at all. One it has
// never looked at has just joined the deck, which is when a session with
// nothing of its own worth keeping is given what the rest of the deck asks
// for (see [Store.TopUp]).
func (s *Store) Known(agent string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.load()
	_, ok := s.checked[agent]
	return ok
}

// Add keeps text as one of agent's tasks. source is model.TaskCustom for one a
// person made and model.TaskMined for one the miner found; an empty name is
// taken from the text. A task whose text is already kept comes back as it is.
func (s *Store) Add(agent, name, text, source string, slot int) (Task, error) {
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
	if source != model.TaskMined {
		source = model.TaskCustom
	}
	if slot < 0 {
		slot = 0
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.load()
	for _, t := range s.byID[agent] {
		if t.Text == text {
			return t, nil
		}
	}
	if len(s.byID[agent]) >= Max && s.droppable(agent) == "" {
		return Task{}, ErrFull
	}
	t := Task{
		ID: id(), Name: name, Text: text, Slot: slot,
		Source: source, Added: time.Now().UTC(),
		Rank: 1 << 20, // last in its band until it is dragged somewhere else
	}
	s.byID[agent] = ordered(append(s.byID[agent], t))
	s.rotate(agent)
	s.save()
	for _, x := range s.byID[agent] {
		if x.ID == t.ID {
			return x, nil
		}
	}
	return t, nil
}

// droppable names the task that rotation would drop next: the oldest mined one
// that is not pinned, or "" when every task is custom or pinned.
func (s *Store) droppable(agent string) string {
	out, oldest := "", time.Time{}
	for _, t := range s.byID[agent] {
		if t.Pinned || t.Source != model.TaskMined {
			continue
		}
		if out == "" || t.Added.Before(oldest) {
			out, oldest = t.ID, t.Added
		}
	}
	return out
}

// rotate keeps the mined band at MinedMax and the list at Max by dropping the
// oldest unpinned mined task. One someone made, and a pinned one, are kept.
func (s *Store) rotate(agent string) {
	for {
		list := s.byID[agent]
		mined := 0
		for _, t := range list {
			if t.Source == model.TaskMined {
				mined++
			}
		}
		if mined <= MinedMax && len(list) <= Max {
			return
		}
		drop := s.droppable(agent)
		if drop == "" {
			return // nothing left that may be dropped
		}
		s.removeLocked(agent, drop)
	}
}

// Move puts a task at rank to within its own band: a custom task moves among
// the custom ones, a mined task among the mined ones, and neither crosses
// into the other's places. It reports whether the task was there.
func (s *Store) Move(agent, taskID string, to int) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.load()
	list := s.byID[agent]
	at := -1
	for i, t := range list {
		if t.ID == taskID {
			at = i
			break
		}
	}
	if at < 0 {
		return false
	}
	moving := list[at]
	band := moving.Band()
	var same, others []Task
	for i, t := range list {
		switch {
		case i == at:
		case t.Band() == band:
			same = append(same, t)
		default:
			others = append(others, t)
		}
	}
	if to < 0 {
		to = 0
	}
	if to > len(same) {
		to = len(same)
	}
	same = append(same[:to:to], append([]Task{moving}, same[to:]...)...)
	// The ranks they carried are what ordered() sorts on, so the new order has
	// to be written onto them or the sort would put everything straight back.
	for i := range same {
		same[i].Rank = i
	}
	s.byID[agent] = ordered(append(same, others...))
	s.save()
	return true
}

// Pin keeps a task through every rotation, or lets it rotate again.
func (s *Store) Pin(agent, taskID string, pinned bool) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.load()
	for i, t := range s.byID[agent] {
		if t.ID == taskID {
			s.byID[agent][i].Pinned = pinned
			s.save()
			return true
		}
	}
	return false
}

// Remove takes one of an agent's tasks away. It reports whether it was there.
func (s *Store) Remove(agent, taskID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.load()
	if !s.removeLocked(agent, taskID) {
		return false
	}
	s.save()
	return true
}

func (s *Store) removeLocked(agent, taskID string) bool {
	list := s.byID[agent]
	for i, t := range list {
		if t.ID == taskID {
			s.byID[agent] = ordered(append(list[:i:i], list[i+1:]...))
			if len(s.byID[agent]) == 0 {
				delete(s.byID, agent)
			}
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
	delete(s.checked, agent)
	s.save()
}

// Texts is every task's text for one agent, for the miner to compare against.
func (s *Store) Texts(agent string) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.load()
	out := make([]string, 0, len(s.byID[agent]))
	for _, t := range s.byID[agent] {
		out = append(out, t.Text)
	}
	return out
}

// ShortName is a tile's name taken from the prompt itself: the first few words
// that carry meaning, hyphenated, as the built-in tasks are named
// ("push-github", "verify-changes").
func ShortName(text string) string {
	// Caveman: articles, pronouns, modals and politeness carry nothing, so a
	// spoken "can you please run the tests again and tell me" becomes
	// run-tests-again.
	skip := map[string]bool{
		"the": true, "a": true, "an": true, "to": true, "of": true,
		"and": true, "for": true, "in": true, "on": true, "with": true,
		"please": true, "can": true, "you": true, "your": true, "it": true,
		"this": true, "that": true, "me": true, "my": true, "is": true,
		"are": true, "be": true, "do": true, "then": true, "so": true,
		"could": true, "would": true, "should": true, "will": true,
		"want": true, "need": true, "like": true, "just": true, "also": true,
		"now": true, "we": true, "i": true, "us": true, "let": true,
		"lets": true, "have": true, "has": true, "get": true, "got": true,
		"make": true, "sure": true, "there": true, "here": true, "about": true,
		"from": true, "into": true, "at": true, "by": true, "as": true,
		"all": true, "some": true, "any": true, "its": true, "their": true,
	}
	var words []string
	for _, w := range strings.Fields(strings.ToLower(text)) {
		w = keepLetters(w)
		if w == "" || skip[w] {
			continue
		}
		words = append(words, w)
		if len(words) == 3 {
			break
		}
	}
	if len(words) == 0 {
		// Nothing but small words: take the text as it came, still without
		// the punctuation a name has no use for.
		for _, w := range strings.Fields(strings.ToLower(text)) {
			w = keepLetters(w)
			if w == "" {
				continue
			}
			words = append(words, w)
			if len(words) == 3 {
				break
			}
		}
	}
	return clip(strings.Join(words, "-"), NameMax)
}

// keepLetters is one word of a name: letters and digits, nothing else. A
// name is read and typed, so an apostrophe or a bracket in the middle of one
// ("today's") only gets in the way.
func keepLetters(w string) string {
	var b strings.Builder
	for _, r := range w {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return b.String()
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

// id is a short, unguessable handle for one task.
func id() string {
	var b [6]byte
	if _, err := rand.Read(b[:]); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 36)
	}
	return hex.EncodeToString(b[:])
}
