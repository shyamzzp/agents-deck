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
	LastPrompt    string     `json:"lastPrompt"` // up to LastPromptMax characters; boards get the first 160
	Waiting       *Prompt    `json:"waiting"`
	Error         *ErrInfo   `json:"error"`
	Tokens        Tokens     `json:"tokens"`
	Context       Context    `json:"context"`
	CostUSD       float64    `json:"costUsd"`
	Turns         int        `json:"turns"`
	Focused       bool       `json:"focused"`
	Attached      bool       `json:"attached"`
	Resumable     bool       `json:"resumable"`            // exited Claude agent that POST /resume can bring back
	Lost          bool       `json:"lost,omitempty"`       // ended with the tmux server, not by itself: POST /v1/restore brings it back
	Unseen        bool       `json:"unseen"`               // finished a turn you haven't looked at yet ("hungry")
	External      bool       `json:"external"`             // owned by another app (Codex): view and focus only
	App           string     `json:"app,omitempty"`        // the app it runs in when not agentctl's: "orca", "herdr", "cmux" (answer, interrupt and focus work there)
	Subagents     []Subagent `json:"subagents,omitempty"`  // subagents still working, oldest first
	Queued        int        `json:"queued"`               // prompts waiting to be typed in once its turn ends ("mode": "queue")
	QueuedNext    string     `json:"queuedNext,omitempty"` // the text of the next of those, for the card to show
	Tasks         []Task     `json:"tasks,omitempty"`      // tasks kept for this agent, beside the deck's built-in ones
	Hat           *Hat       `json:"hat,omitempty"`        // the pixel hat for its working folder (nil: none)
	Account       *Account   `json:"account,omitempty"`    // the Claude account it runs in (nil: only one account is set up)
	StartedAt     time.Time  `json:"startedAt"`
	UpdatedAt     time.Time  `json:"updatedAt"`
	LastActive    time.Time  `json:"lastActive,omitzero"` // its latest message sent or received (zero: not known yet)
}

// Hat is the pixel hat an agent wears, picked by its working folder: shape
// and colour from a stable hash of the folder (Auto), or chosen by hand.
type Hat struct {
	Shape string `json:"shape"` // hard hat, cap, beanie, helmet, wizard, beret, chef, crown, headphones, propeller, top hat, cowboy, bandana
	Color string `json:"color"` // teal, blue, yellow, green, purple, pink, sky, ink
	Auto  bool   `json:"auto"`  // picked by the hash, not by hand
}

// Account is the Claude Code account (config folder) a session runs in.
type Account struct {
	Name  string `json:"name"`
	Color string `json:"color"` // teal, blue, yellow, green, purple, pink, sky, ink (the hat colours)
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

// Band is 0 for a task someone made and 1 for one the deck mined, which is
// the order they are drawn in.
func (t Task) Band() int {
	if t.Source == TaskMined {
		return 1
	}
	return 0
}
