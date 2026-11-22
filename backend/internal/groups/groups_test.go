package groups

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/brushknight/agents-deck/backend/internal/model"
)

func book(t *testing.T) *Book {
	t.Helper()
	return &Book{Path: filepath.Join(t.TempDir(), "config.json")}
}

func TestValidate(t *testing.T) {
	cases := []struct {
		name string
		slot int
		in   string
		ok   bool
	}{
		{"a row start", 4, "UCSF", true},
		{"a later row", 16, "Personal", true},
		{"slot 0 has no line above it", 0, "First", false},
		{"mid-row", 6, "UCSF", false},
		{"past the last slot", 256, "UCSF", false},
		{"no name", 4, "   ", false},
		{"name too long", 4, "123456789012345678901234567890", false},
		{"name of exactly MaxName", 4, "123456789012345678901234", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if err := Validate(c.slot, c.in); (err == nil) != c.ok {
				t.Fatalf("Validate(%d, %q) = %v, want ok=%v", c.slot, c.in, err, c.ok)
			}
		})
	}
}

func TestCleanName(t *testing.T) {
	if got := CleanName("  UCSF   patching  "); got != "UCSF patching" {
		t.Fatalf("CleanName = %q", got)
	}
}

func TestSetAddsRenamesAndRemoves(t *testing.T) {
	b := book(t)
	if err := b.Set(8, "Personal"); err != nil {
		t.Fatal(err)
	}
	if err := b.Set(4, "UCSF"); err != nil {
		t.Fatal(err)
	}
	all := b.All()
	if len(all) != 2 || all[0].Slot != 4 || all[1].Slot != 8 {
		t.Fatalf("dividers are kept in slot order: %+v", all)
	}

	if err := b.Set(4, "UCSF patching"); err != nil { // rename in place
		t.Fatal(err)
	}
	if all = b.All(); len(all) != 2 || all[0].Name != "UCSF patching" {
		t.Fatalf("renamed in place, not added again: %+v", all)
	}

	if err := b.Set(4, ""); err != nil { // an empty name removes it
		t.Fatal(err)
	}
	if all = b.All(); len(all) != 1 || all[0].Slot != 8 {
		t.Fatalf("removed only that divider: %+v", all)
	}
}

func TestSetKeepsEveryOtherConfigKey(t *testing.T) {
	b := book(t)
	seed := []byte(`{"hats":{"/x":{"shape":"crown"}},"startAtLogin":true}`)
	if err := os.WriteFile(b.Path, seed, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := b.Set(4, "UCSF"); err != nil {
		t.Fatal(err)
	}
	var cfg map[string]any
	raw, err := os.ReadFile(b.Path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatal(err)
	}
	if _, ok := cfg["hats"]; !ok {
		t.Error("hats was dropped")
	}
	if cfg["startAtLogin"] != true {
		t.Error("startAtLogin was dropped")
	}
	if _, ok := cfg["groups"]; !ok {
		t.Error("groups was not written")
	}

	if err := b.Set(4, ""); err != nil { // the last one goes: the key goes too
		t.Fatal(err)
	}
	raw, _ = os.ReadFile(b.Path)
	cfg = nil
	_ = json.Unmarshal(raw, &cfg)
	if _, ok := cfg["groups"]; ok {
		t.Error("an empty groups key is left behind")
	}
	if _, ok := cfg["hats"]; !ok {
		t.Error("hats was dropped on removal")
	}
}

func TestSetRejectsBadInput(t *testing.T) {
	b := book(t)
	for _, c := range []struct {
		name string
		slot int
		in   string
	}{
		{"mid-row", 5, "UCSF"},
		{"slot 0", 0, "UCSF"},
		{"past the end", 260, "UCSF"},
		{"removing mid-row", 5, ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			if err := b.Set(c.slot, c.in); err == nil {
				t.Fatalf("Set(%d, %q) was accepted", c.slot, c.in)
			}
		})
	}
}

func TestSetRefusesBrokenConfig(t *testing.T) {
	b := book(t)
	if err := os.WriteFile(b.Path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := b.Set(4, "UCSF"); err == nil {
		t.Fatal("a broken config.json was overwritten instead of refused")
	}
}

func TestAllSkipsJunkAndDuplicates(t *testing.T) {
	b := book(t)
	seed := `{"groups":[
		{"slot":8,"name":"Personal"},
		{"slot":4,"name":"  UCSF  "},
		{"slot":6,"name":"mid-row"},
		{"slot":0,"name":"no line above slot 0"},
		{"slot":8,"name":"a second line at 8"},
		{"slot":12,"name":""}
	]}`
	if err := os.WriteFile(b.Path, []byte(seed), 0o600); err != nil {
		t.Fatal(err)
	}
	all := b.All()
	want := []model.Group{{Slot: 4, Name: "UCSF"}, {Slot: 8, Name: "Personal"}}
	if len(all) != len(want) {
		t.Fatalf("All() = %+v, want %+v", all, want)
	}
	for i := range want {
		if all[i] != want[i] {
			t.Fatalf("All()[%d] = %+v, want %+v", i, all[i], want[i])
		}
	}
}

func TestAllIsACopy(t *testing.T) {
	b := book(t)
	if err := b.Set(4, "UCSF"); err != nil {
		t.Fatal(err)
	}
	b.All()[0].Name = "clobbered"
	if got := b.All()[0].Name; got != "UCSF" {
		t.Fatalf("the caller changed the book through All(): %q", got)
	}
}

func TestOfNamesTheGroupASlotFallsIn(t *testing.T) {
	b := book(t)
	for _, g := range []model.Group{{Slot: 4, Name: "UCSF"}, {Slot: 12, Name: "Personal"}} {
		if err := b.Set(g.Slot, g.Name); err != nil {
			t.Fatal(err)
		}
	}
	for _, c := range []struct {
		slot int
		want string
	}{
		{0, ""}, {3, ""}, // before the first divider: no group
		{4, "UCSF"}, {11, "UCSF"},
		{12, "Personal"}, {255, "Personal"},
	} {
		if got := b.Of(c.slot); got != c.want {
			t.Errorf("Of(%d) = %q, want %q", c.slot, got, c.want)
		}
	}
}

func TestNoConfigFileMeansNoGroups(t *testing.T) {
	b := book(t)
	if all := b.All(); len(all) != 0 {
		t.Fatalf("All() = %+v, want none", all)
	}
	if got := b.Of(8); got != "" {
		t.Fatalf("Of() = %q, want none", got)
	}
}

func TestRereadsWhenTheFileChangesUnderIt(t *testing.T) {
	b := book(t)
	if err := b.Set(4, "UCSF"); err != nil {
		t.Fatal(err)
	}
	_ = b.All() // caches
	seed := `{"groups":[{"slot":4,"name":"edited by hand"}]}`
	if err := os.WriteFile(b.Path, []byte(seed), 0o600); err != nil {
		t.Fatal(err)
	}
	// Size differs from the cached one, so the cache is dropped even where the
	// filesystem's timestamps are coarse.
	if got := b.All(); len(got) != 1 || got[0].Name != "edited by hand" {
		t.Fatalf("All() = %+v, want the edited name", got)
	}
}
