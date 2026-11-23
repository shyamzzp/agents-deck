// Package groups holds the deck's group dividers: a named line across the
// grid that separates the agents above it from the agents below it.
// config.json "groups" holds them, like "hats" holds hat overrides.
//
// A group is an anchor, not a tag. An agent belongs to the group whose
// divider is the last one at or before its slot, so moving an agent between
// groups is the ordinary move (POST /v1/agents/{id}/move) and nothing else
// has to know about groups: the panel view, the boards and page = slot/16
// keep working exactly as before.
package groups

import (
	"encoding/json"
	"errors"
	"fmt"
	"github.com/brushknight/agents-deck/backend/internal/configfile"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/brushknight/agents-deck/backend/internal/model"
	"github.com/brushknight/agents-deck/backend/internal/store"
)

// Row is the deck's width in tiles. A divider is anchored at the start of a
// row so an arranged board stays arranged: slots keep their meaning and a
// group never splits a row of the 4x4 grid the boards draw.
const Row = 4

// MaxName is how much of a name the divider has room for.
const MaxName = 24

// Max is how many dividers one deck can hold: one per row.
const Max = (store.MaxSlot + 1) / Row

// Validate reports whether a divider can sit at slot under this name.
func Validate(slot int, name string) error {
	switch {
	case slot < Row:
		return fmt.Errorf("a divider sits at slot %d or later (the first group needs no line above it)", Row)
	case slot > store.MaxSlot:
		return fmt.Errorf("slot %d is past the last one (%d)", slot, store.MaxSlot)
	case slot%Row != 0:
		return fmt.Errorf("slot %d is mid-row: a divider sits at a multiple of %d", slot, Row)
	case CleanName(name) == "":
		return errors.New("a group needs a name")
	case utf8.RuneCountInString(CleanName(name)) > MaxName:
		return fmt.Errorf("a name is at most %d characters", MaxName)
	}
	return nil
}

// CleanName is the name as it is stored: trimmed, with inner whitespace
// collapsed so a name can't push the divider out of shape.
func CleanName(name string) string { return strings.Join(strings.Fields(name), " ") }

// Book holds the dividers from config.json, re-read when the file changes.
type Book struct {
	Path string // config.json

	mu    sync.Mutex
	mtime time.Time
	size  int64
	list  []model.Group
}

// All lists the dividers, by slot. The answer is a copy.
func (b *Book) All() []model.Group {
	src := b.groups()
	out := make([]model.Group, len(src))
	copy(out, src)
	return out
}

// Of names the group an agent at slot belongs to ("" before the first
// divider, where agents belong to no group).
func (b *Book) Of(slot int) string {
	name := ""
	for _, g := range b.groups() {
		if g.Slot > slot {
			break
		}
		name = g.Name
	}
	return name
}

func (b *Book) groups() []model.Group {
	b.mu.Lock()
	defer b.mu.Unlock()
	st, err := os.Stat(b.Path)
	if err != nil {
		b.list, b.mtime, b.size = nil, time.Time{}, 0
		return nil
	}
	if b.list != nil && st.ModTime().Equal(b.mtime) && st.Size() == b.size {
		return b.list
	}
	var c struct {
		Groups []model.Group `json:"groups"`
	}
	if raw, err := os.ReadFile(b.Path); err == nil {
		_ = json.Unmarshal(raw, &c)
	}
	b.list = []model.Group{}
	seen := map[int]bool{}
	for _, g := range c.Groups {
		g.Name = CleanName(g.Name)
		if Validate(g.Slot, g.Name) != nil || seen[g.Slot] {
			continue
		}
		seen[g.Slot] = true
		b.list = append(b.list, g)
	}
	sort.Slice(b.list, func(i, j int) bool { return b.list[i].Slot < b.list[j].Slot })
	b.mtime, b.size = st.ModTime(), st.Size()
	return b.list
}

// Set puts a divider at slot under this name, or renames the one already
// there. An empty name removes it. Every other key of config.json is kept.
func (b *Book) Set(slot int, name string) error {
	name = CleanName(name)
	remove := name == ""
	if remove {
		if slot < Row || slot > store.MaxSlot || slot%Row != 0 {
			return fmt.Errorf("no divider can sit at slot %d", slot)
		}
	} else if err := Validate(slot, name); err != nil {
		return err
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return configfile.Edit(b.Path, func(cfg map[string]any) error {
		var all []model.Group
		if raw, err := json.Marshal(cfg["groups"]); err == nil {
			_ = json.Unmarshal(raw, &all)
		}
		kept := make([]model.Group, 0, len(all)+1)
		for _, g := range all {
			if g.Slot != slot {
				g.Name = CleanName(g.Name)
				kept = append(kept, g)
			}
		}
		all = kept
		if !remove {
			if len(all) >= Max {
				return fmt.Errorf("a deck holds at most %d groups", Max)
			}
			all = append(all, model.Group{Slot: slot, Name: name})
		}
		sort.Slice(all, func(i, j int) bool { return all[i].Slot < all[j].Slot })
		if len(all) == 0 {
			delete(cfg, "groups")
		} else {
			cfg["groups"] = all
		}
		if remove {
			assignments, _ := cfg["sshDeckGroups"].(map[string]any)
			for key, value := range assignments {
				if value == float64(slot) {
					delete(assignments, key)
				}
			}
			if len(assignments) == 0 {
				delete(cfg, "sshDeckGroups")
			}
		}
		b.list = nil
		return nil
	})
}
