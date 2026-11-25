// Package model holds the wire types of protocol v1 (docs/protocol.md).
package model

import "time"

type Status string

const (
	Starting Status = "starting"
	Running  Status = "running"
	Waiting  Status = "waiting"
	Idle     Status = "idle"
	Error    Status = "error"
	Exited   Status = "exited"
)

type State struct {
	Server Server  `json:"server"`
	Agents []Agent `json:"agents"`
	// Groups are the deck's group dividers, by slot (absent: no groups).
	// Only the grid view draws them; the panel and the boards ignore them.
	Groups []Group `json:"groups,omitempty"`
	// Magic is this screen's part in the magic trick (absent: none, or the
	// trick is off). Only the giver and the receiver get it.
	Magic *Magic `json:"magic,omitempty"`
	// Limits is how much of each account's usage is gone, as Claude Code
	// and Codex last reported it (absent: nothing reported yet).
	Limits []Limits `json:"limits,omitempty"`
}

// Limits is one account's usage limits in one tool: Claude Code per account
// (config folder), Codex per login. Only what the tools report themselves,
// for direct use of Claude Code and Codex.
type Limits struct {
	Tool    string        `json:"tool"`              // claude | codex
	Account string        `json:"account,omitempty"` // the account's name; "" with one account, and for Codex
	Plan    string        `json:"plan,omitempty"`    // the plan, as the tool names it ("" when not known)
	Level   string        `json:"level"`             // the worst window shown: ok | near | low | out
	AsOf    time.Time     `json:"asOf"`              // when the tool last reported
	Source  string        `json:"source"`            // statusline | transcript | rollout
	Windows []LimitWindow `json:"windows"`
}

// LimitWindow is one limit: a rolling window (the week), one model's week,
// or a spend limit.
type LimitWindow struct {
	ID       string    `json:"id"`                // seven_day, five_hour, model_week:<model>, spend, or <limit>:<window> for Codex
	Label    string    `json:"label"`             // "week", "Fable week", "5 hours", "spend"
	Minutes  int       `json:"minutes,omitempty"` // the window's length, when known
	Model    string    `json:"model,omitempty"`   // a per-model limit: the model family ("fable")
	Used     int       `json:"used"`              // percent used, 0..100 (a spend limit can pass 100)
	ResetsAt time.Time `json:"resetsAt,omitzero"` // when it resets
	Level    string    `json:"level"`             // ok (< 80) | near (80..94) | low (95..99) | out (100, or hit)
	Hit      bool      `json:"hit,omitempty"`     // the tool said this limit stopped it
	Reset    bool      `json:"reset,omitempty"`   // reset since the last report: Used is not known now
	Hidden   bool      `json:"hidden,omitempty"`  // kept for the record, not shown (five_hour)
}

// Magic: the giver (its agents are taken) or the receiver (it takes them
// with a knock), whether they are taken now, and where this screen's tiles
// fly: in from Arrive, out to Leave (corners: top-left, top-right,
// bottom-left, bottom-right).
type Magic struct {
	Role   string `json:"role"` // giver | receiver
	Taken  bool   `json:"taken"`
	Arrive string `json:"arrive"`
	Leave  string `json:"leave"`
}

// Group is a named line across the grid, anchored at Slot (a multiple of the
// deck's width). The agents from one divider up to the next belong to it; the
// agents before the first divider belong to no group.
type Group struct {
	Slot int    `json:"slot"`
	Name string `json:"name"`
}

type Server struct {
	Name    string    `json:"name"`
	Version string    `json:"version"`
	Time    time.Time `json:"time"`
}

// LastPromptMax is how much of an agent's last prompt the deck keeps: enough
// for the sidebar on Home to show it all, mostly. Boards get the first 160
// characters (link.options).
const LastPromptMax = 1000

// LastAnswerMax is how much of an agent's last answer the deck keeps, the
// same as a prompt. Boards get the first 160 characters (link.options).
const LastAnswerMax = 1000

type Agent struct {
	ID   string `json:"id"`
	Slot int    `json:"slot"`
	// AttentionSlot is its spot on the "Needs you" grid, 1..16 (4 x 4, by
	// rows), or 0 while it isn't there. The service decides it (store/attention.go).
	AttentionSlot int        `json:"attentionSlot"`
	Title         string     `json:"title"`
	AITitle       string     `json:"aiTitle"`
	Tool          string     `json:"tool"`
	Status        Status     `json:"status"`
	StatusSince   time.Time  `json:"statusSince"`
	Cwd           string     `json:"cwd"`
	Folder        string     `json:"folder"`
	Branch        string     `json:"branch"`
	Model         string     `json:"model"`
	ModelLabel    string     `json:"modelLabel"`
	Effort        string     `json:"effort,omitempty"` // reasoning effort of its latest turn (low, medium, high, xhigh, max)
	Activity      *Activity  `json:"activity"`
	LastPrompt    string     `json:"lastPrompt"`            // up to LastPromptMax characters; boards get the first 160
	LastAnswer    string     `json:"lastAnswer"`            // its reply that ended its latest finished turn, as plain text; up to LastAnswerMax characters, boards get the first 160
	LastAnswerAt  time.Time  `json:"lastAnswerAt,omitzero"` // when it gave that reply (zero: no answer yet)
	Waiting       *Prompt    `json:"waiting"`
	Error         *ErrInfo   `json:"error"`
	Tokens        Tokens     `json:"tokens"`
	Context       Context    `json:"context"`
	CostUSD       float64    `json:"costUsd"`
	Turns         int        `json:"turns"`
	Focused       bool       `json:"focused"`
	Attached      bool       `json:"attached"`
	Resumable     bool       `json:"resumable"`               // exited Claude agent that POST /resume can bring back
	Lost          bool       `json:"lost,omitempty"`          // ended with the tmux server, not by itself: POST /v1/restore brings it back
	Unseen        bool       `json:"unseen"`                  // finished a turn you haven't looked at yet ("hungry")
	External      bool       `json:"external"`                // owned by another app (Codex): view and focus only
	App           string     `json:"app,omitempty"`           // the app it runs in when not agentctl's: "orca", "herdr", "cmux" (answer, interrupt and focus work there)
	Subagents     []Subagent `json:"subagents,omitempty"`     // subagents still working, oldest first
	Queued        int        `json:"queued"`                  // prompts waiting to be typed in once its turn ends ("mode": "queue")
	QueuedNext    string     `json:"queuedNext,omitempty"`    // the text of the next of those, for the card to show
	Tasks         []Task     `json:"tasks,omitempty"`         // tasks kept for this agent, beside the deck's built-in ones
	Slowed        bool       `json:"slowed"`                  // in background mode while the computer is busy (the CPU guard; macOS)
	SlowedByYou   bool       `json:"slowedByYou"`             // slowed with Slow it, not by the guard's own pick
	CPU           float64    `json:"cpu,omitempty"`           // percent of the whole computer, only while it is busy
	Hat           *Hat       `json:"hat,omitempty"`           // the pixel hat for its working folder (nil: none)
	Account       *Account   `json:"account,omitempty"`       // the Claude account it runs in (nil: only one account is set up)
	Project       *Project   `json:"project,omitempty"`       // the project its working folder is in (nil: none)
	ProjectFolder string     `json:"projectFolder,omitempty"` // the project folder it matched, in full ("" = no project)
	Pet           *Pet       `json:"pet,omitempty"`           // its pet (nil: Agent pets is off)
	StartedAt     time.Time  `json:"startedAt"`
	UpdatedAt     time.Time  `json:"updatedAt"`
	LastActive    time.Time  `json:"lastActive,omitzero"` // its latest message sent or received (zero: not known yet)
	OutUntil      time.Time  `json:"outUntil,omitzero"`   // its account (or its model) is out of usage until then (zero: not out)
}

// Hat is the pixel hat an agent wears, picked by its working folder: shape
// and colour from a stable hash of the folder (Auto), or chosen by hand.
type Hat struct {
	Shape string `json:"shape"` // hard hat, cap, beanie, helmet, wizard, beret, chef, crown, headphones, propeller, top hat, cowboy, bandana
	Color string `json:"color"` // teal, blue, yellow, green, purple, pink, sky, ink
	Auto  bool   `json:"auto"`  // picked by the hash, not by hand
	// Critter is the creature drawn for this folder: "" is the deck's own
	// critter, and one of egg, cracked, baby, kid, grown, strong, mighty or
	// legend draws that creature instead. Picked by hand beside the hat, and
	// nothing grows into it: it is a look, not a pet.
	Critter string `json:"critter,omitempty"`
}

// Pet is an agent's pet (Settings > General > Agent pets): it eats the
// agent's input and output tokens and grows a level at a time.
type Pet struct {
	Name      string    `json:"name"`               // "" until it hatches
	Stage     string    `json:"stage"`              // egg | baby | kid | grown | strong | mighty | legend
	Level     int       `json:"level"`              // 0 while an egg; never goes down
	Ate       int64     `json:"ate"`                // tokens eaten, all time (input + output)
	LevelFrom int64     `json:"levelFrom"`          // Ate where the current level started (0 for an egg), for progress bars
	NextAt    int64     `json:"nextAt"`             // Ate that reaches the next level (for an egg: that makes it ready)
	Hearts    int       `json:"hearts"`             // 0..4
	Mood      string    `json:"mood"`               // fed | hungry | weak | asleep (hibernating)
	Ready     bool      `json:"ready"`              // an egg that has eaten enough and waits to be seen hatching (POST /v1/agents/{id}/pet/hatch)
	Hat       *PetHat   `json:"hat,omitempty"`      // its mystery hat, rolled when it hatched; omitted until it is a kid (level 5)
	HatchedAt time.Time `json:"hatchedAt,omitzero"` // omitted while an egg
}

// PetHat is a pet's mystery hat: one of the deck's hat shapes or "devil
// horns", in a hat colour.
type PetHat struct {
	Shape string `json:"shape"`
	Color string `json:"color"`
}

// Account is the Claude Code account (config folder) a session runs in.
type Account struct {
	Name  string `json:"name"`
	Color string `json:"color"` // teal, blue, yellow, green, purple, pink, sky, ink (the hat colours)
}

// Project is the project an agent works in: the one whose folder holds its
// working folder, the deepest such folder winning. The service decides it
// (admin/projectmatch.go).
type Project struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// Subagent is one of an agent's subagents that is still working.
type Subagent struct {
	ID    string `json:"id"`
	Title string `json:"title"`          // the task description it was given
	Type  string `json:"type,omitempty"` // agent type (Explore, general-purpose, fork…)
	Tool  string `json:"tool,omitempty"` // tool of its latest call, for the critter's pose
}

type Activity struct {
	Tool   string `json:"tool"`
	Detail string `json:"detail"`
}

type Prompt struct {
	ID      string   `json:"id"`
	Kind    string   `json:"kind"` // permission | question | input
	Title   string   `json:"title"`
	Detail  string   `json:"detail"`
	Context string   `json:"context"`
	Options []Option `json:"options"`
}

type Option struct {
	Key      string `json:"key"`
	Label    string `json:"label"`
	Primary  bool   `json:"primary,omitempty"`
	Selected bool   `json:"selected,omitempty"` // ticked: a pick-any question's answer so far
}

type ErrInfo struct {
	Message string `json:"message"`
}

type Tokens struct {
	Input      int64 `json:"input"`
	Output     int64 `json:"output"`
	CacheRead  int64 `json:"cacheRead"`
	CacheWrite int64 `json:"cacheWrite"`
}

type Context struct {
	Used   int64 `json:"used"`
	Window int64 `json:"window"`
}

// Task is one of an agent's own tasks: a prompt kept under a short name, which
// the card draws as a tile beside the deck's built-in ones (internal/tasks).
type Task struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Text string `json:"text"`
	// Slot is the cell of the card's quick list it was made in, counted from
	// the first cell of the board; 0 leaves it to fall in after the ones
	// before it. The built-in tasks hold the first cells. It seeds the rank
	// of a task made by hand and is not used after that.
	Slot int `json:"slot,omitempty"`

	// Source is where the task came from: "custom" for one a person made,
	// "mined" for one the deck found in the session's own prompts. The two
	// are drawn as bands, custom first, so what you made is what you see.
	Source string `json:"source,omitempty"`

	// Rank orders the tasks within their band, from 0. It is a position in a
	// list rather than a cell of the board: a phone draws four to a row and a
	// tablet seven or ten, so a cell number would mean a different place on
	// each.
	Rank int `json:"rank"`

	// Pinned keeps a task through every rotation, mined or not.
	Pinned bool `json:"pinned,omitempty"`

	// State is what became of the last time this task was sent to its
	// agent's terminal: TaskRunning while the agent works on it,
	// TaskStopped when it was interrupted, TaskDone when its turn ended, ""
	// when it has not been sent since the service started. A task is not an
	// agent: it never sleeps or exits, it is simply there until it is asked
	// for again.
	State string `json:"state,omitempty"`

	// Ran is when it was last sent, so a card can count the time a running
	// task has been working.
	Ran time.Time `json:"ran,omitempty"`

	// Shared is a task the deck offered this agent because the rest of the
	// deck keeps asking for it, rather than one mined from this session's own
	// prompts. One of these is never evidence for another: what the deck
	// counts is what sessions asked for themselves.
	Shared bool `json:"shared,omitempty"`

	Added time.Time `json:"added"`
}

// TaskCustom and TaskMined are the two bands of an agent's quick list.
const (
	TaskCustom = "custom"
	TaskMined  = "mined"
)

// What a task is doing, as the API spells it. A task has no sleeping or
// exited state: it is a line waiting to be asked again.
const (
	TaskRunning = "running"     // its agent is working on it now
	TaskStopped = "interrupted" // its turn was cut short
	TaskDone    = "done"        // its turn ended on its own
)

// Band is 0 for a task someone made and 1 for one the deck mined, which is
// the order they are drawn in.
func (t Task) Band() int {
	if t.Source == TaskMined {
		return 1
	}
	return 0
}
