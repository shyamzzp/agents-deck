// Mining: which of a session's own prompts are worth asking again.
//
// Every agent's quick list starts with the built-in eight, and every agent is
// mined as well: the deck reads the prompts of the session behind the card and
// keeps the ones that read like a thing you would ask for again ("check the
// meetings scheduled for today"), not a thing you asked once about one moment
// ("fix this test", "why did that fail"). Those become the mined band, drawn
// after the ones a person made.
//
// The rule here is a heuristic, deliberately: it runs on the Mac beside the
// sessions, has nothing to download and nothing to keep warm, and it is wrong
// in a way a person can see and undo -- a task nobody wants is held and
// removed, and the band rotates on its own anyway. What it cannot do is see
// that "look at today's meetings" and "check the meetings scheduled for today"
// are one task; that is what sentence embeddings are for, and they come next.
//
// A prompt is kept when, with the politeness taken off the front:
//
//   - it starts with a verb -- what you want done, not what you wondered;
//   - it is 2 to 12 words, with at least two of them carrying meaning;
//   - it points at nothing in particular: no "this", "it", "here", no link;
//   - it does not trail off on an article ("fix the");
//   - it is not one of the built-in eight said differently.
package tasks

import (
	"sort"
	"strings"
	"time"

	"github.com/shyamzzp/agents-deck/backend/internal/model"
	"github.com/shyamzzp/agents-deck/backend/internal/words"
)

// wordsMin and wordsMax are how long a kept prompt may be. One word is a
// grunt ("continue"), and a paragraph is a briefing for one moment, not a
// task: the longest built-in task is twelve words of instruction.
const (
	wordsMin = 2
	wordsMax = 12
)

// politeness is what people put in front of what they actually want. Each is
// taken off the front until nothing matches, so "ok so can you please check
// the meetings" is judged as "check the meetings".
var politeness = []string{
	"can you please", "could you please", "would you please",
	"can you", "could you", "would you", "will you", "can we", "could we",
	"i want you to", "i need you to", "i would like you to",
	"id like you to", "i'd like you to", "you should", "you can",
	"let us", "lets", "let's", "please", "pls", "plz", "kindly",
	"hey", "hi", "hello", "ok", "okay", "so", "and", "also", "now", "then",
	"just", "maybe", "quickly", "first",
	// "make sure the tests pass" is a sentence about a state, not a thing to
	// do: with the "make sure" off the front it has no verb left, and the
	// rule below drops it. That is the point -- the ones people write are
	// corrections to the moment ("make sure the labels are centered").
	"make sure", "makes sure", "make sure that", "ensure",
}

// oneOff is a turn of phrase that ties a request to the hour it was made.
// A task made from one of these would be asked again about something that no
// longer exists ("delete the repo we just created").
var oneOff = []string{
	"we just", "you just", "i just", "just created", "just made",
	"just did", "just added", "just now", "right now", "at the moment",
	"for now", "this one", "that one", "the one we", "the one you",
	"last one", "as before", "like before", "once more",
}

// verbs are what a task starts with: a thing to do. The list is the work a
// deck actually sees asked for, and a prompt starting with anything else
// ("why does", "the build", "what about") is a question about one moment.
var verbs = map[string]bool{
	"add": true, "analyse": true, "analyze": true, "answer": true,
	"apply": true, "ask": true, "audit": true, "benchmark": true,
	"build": true, "bump": true, "carry": true, "change": true,
	"check": true, "clean": true, "clear": true, "close": true,
	"collect": true, "commit": true, "compare": true, "compile": true,
	"confirm": true, "connect": true, "convert": true, "copy": true,
	"count": true, "cover": true, "create": true, "debug": true,
	"delete": true, "deploy": true, "describe": true, "diff": true,
	"disable": true, "document": true, "draft": true, "draw": true,
	"drop": true, "enable": true, "explain": true, "export": true,
	"extract": true, "figure": true, "fill": true, "find": true,
	"finish": true, "fix": true, "format": true, "generate": true,
	"give": true, "go": true, "group": true, "handle": true, "import": true,
	"improve": true, "init": true, "inspect": true, "install": true,
	"keep": true, "kill": true, "lint": true, "list": true, "look": true,
	"make": true, "measure": true, "merge": true, "migrate": true,
	"move": true, "open": true, "optimise": true, "optimize": true,
	"pause": true, "plan": true, "plot": true, "print": true, "profile": true,
	"publish": true, "pull": true, "push": true, "read": true,
	"rebase": true, "rebuild": true, "recheck": true, "refactor": true,
	"release": true, "reload": true, "remove": true, "rename": true,
	"render": true, "repeat": true, "replace": true, "report": true,
	"rerun": true, "reset": true, "restart": true, "restore": true,
	"resume": true, "review": true, "revert": true, "rewrite": true,
	"run": true, "save": true, "scan": true, "search": true, "send": true,
	"set": true, "setup": true, "show": true, "simplify": true, "skip": true,
	"sort": true, "split": true, "start": true, "stash": true, "stop": true,
	"summarise": true, "summarize": true, "sync": true, "take": true,
	"tell": true, "test": true, "tidy": true, "trace": true, "track": true,
	"translate": true, "try": true, "tune": true, "uninstall": true,
	"update": true, "upgrade": true, "upload": true, "use": true,
	"validate": true, "verify": true, "walk": true, "watch": true,
	"write": true,
}

// deixis is a word that only means something where it was said. A prompt with
// one in it belongs to the moment it was asked, not to a tile on a board.
// "that" is only one of them at the end of a sentence ("fix that"), because in
// the middle it is usually a conjunction ("check that the build passes").
var deixis = map[string]bool{
	"this": true, "these": true, "those": true, "it": true, "its": true,
	"here": true, "above": true, "below": true, "instead": true,
	"them": true, "they": true, "him": true, "her": true, "yours": true,
	"mine": true, "earlier": true, "previous": true,
}

// small words carry no meaning of their own; a prompt needs at least two that
// are not in here.
var small = map[string]bool{
	"the": true, "a": true, "an": true, "to": true, "of": true, "and": true,
	"or": true, "for": true, "in": true, "on": true, "with": true,
	"at": true, "by": true, "as": true, "from": true, "into": true,
	"is": true, "are": true, "be": true, "do": true, "does": true,
	"did": true, "has": true, "have": true, "had": true, "was": true,
	"were": true, "my": true, "your": true, "our": true, "we": true,
	"i": true, "you": true, "me": true, "us": true, "all": true,
	"any": true, "some": true, "what": true, "which": true, "that": true,
	"then": true, "than": true, "if": true, "but": true, "not": true,
	"no": true, "up": true, "out": true, "off": true, "over": true,
	"again": true, "also": true, "now": true, "too": true, "very": true,
	"will": true, "can": true, "please": true, "its": true, "it": true,
	"this": true, "there": true,
}

// trailing is a word a request cannot end on: it was going somewhere and the
// rest is missing, or it was cut off ("fix the", "look at").
var trailing = map[string]bool{
	"the": true, "a": true, "an": true, "to": true, "of": true, "for": true,
	"in": true, "on": true, "with": true, "and": true, "or": true,
	"at": true, "by": true, "from": true, "into": true, "about": true,
	"my": true, "your": true, "our": true, "is": true, "was": true,
}

// builtin is the gist of each of the eight tasks every agent already has.
// A prompt that asks for one of those again is not worth a cell of its own,
// however it was phrased, so the content words are compared rather than the
// sentence.
var builtin = []string{
	"verify the changes you have made and say what you checked",
	"run the test suite and report the result",
	"commit the current changes with a message",
	"push the committed changes to the remote on github",
	"open a pull request for this branch against the default branch",
	"summarise what you have changed so far file by file",
	"find out why the failing tests fail and fix the cause",
	"carry on with what you were doing",
}

// chore is a word that marks standing work: something asked because of the
// day or the state of the work, which will be asked again for the same reason
// ("check the meetings scheduled for today", "run the migrations").
var chore = map[string]bool{
	"today": true, "tomorrow": true, "daily": true, "weekly": true,
	"monthly": true, "morning": true, "evening": true, "week": true,
	"month": true, "every": true, "each": true, "regularly": true,
	"meeting": true, "meetings": true, "calendar": true, "schedule": true,
	"scheduled": true, "standup": true, "inbox": true, "email": true,
	"emails": true, "mail": true, "messages": true, "notifications": true,
	"tests": true, "test": true, "suite": true, "build": true,
	"builds": true, "lint": true, "format": true, "deploy": true,
	"backup": true, "logs": true, "log": true, "status": true,
	"pipeline": true, "ci": true, "dashboard": true, "metrics": true,
	"report": true, "timesheet": true, "worklog": true, "standups": true,
	"branch": true, "main": true, "upstream": true, "dependencies": true,
	"migrations": true, "queue": true, "backlog": true, "tickets": true,
	"issues": true, "coverage": true, "benchmarks": true, "usage": true,
}

// surface verbs are the ones people use to change one thing in front of them:
// a button moved, a line removed, a folder opened. Asked once, they belong to
// that one thing; asked again and again, they are work, and the repeat is
// what tells the two apart.
var surface = map[string]bool{
	"add": true, "remove": true, "delete": true, "drop": true,
	"create": true, "make": true, "move": true, "rename": true,
	"open": true, "close": true, "give": true, "tell": true, "show": true,
	"change": true, "replace": true, "set": true, "put": true, "take": true,
	"write": true, "draw": true, "fill": true, "keep": true, "use": true,
	"try": true, "go": true, "look": true, "read": true, "ask": true,
	"answer": true, "explain": true, "describe": true, "say": true,
}

// repeatAlike is how much two prompts must have in common to count as the
// same request asked twice, said differently.
const repeatAlike = 0.7

// The thresholds the sentence model is read at, set from the model itself
// rather than from the usual 0.85 a large one would want. Measured over
// 22,155 pairs of real prompts from this machine's sessions: the median pair
// scores 0.35, nine in ten are under 0.52, ninety-nine in a hundred under
// 0.68, and only one in a thousand reaches 0.81.
//
//   - 0.80 is where the pairs are the same request said again about another
//     day or another file ("give me the 24th" and "give me the 28th", "update
//     the pdf" and "reload the pdf"), which is what grouping is for.
//   - 0.70 for the built-in eight, because the model's absolute scores are
//     coarse: at 0.66 "tell me the size of the folder" reads as "summarise
//     what you have changed", and absorbing that would lose a real task.
const (
	senseAlike   = 0.80 // the same request, said in other words
	senseBuiltin = 0.70 // one of the built-in eight, said in other words
)

// Sense is what tells the judge whether two requests mean the same thing.
// internal/words is the one the service uses; nil means judge on the words
// alone, which is a worse list of tasks, not a broken one.
type Sense interface {
	Vectors(texts []string) ([][]float32, error)
}

// Judge decides which of a session's prompts are worth a tile.
//
// Words alone cannot see that "look at today's meetings" and "check the
// meetings scheduled for today" are one task, or that "run the tests" is the
// built-in one said shorter. With a [Sense] it can, and the deck's own
// history says what sort of thing is worth keeping at all: a task someone
// pinned is what standing work looks like on this deck, and one they threw
// away is what a request that belongs to one afternoon looks like.
type Judge struct {
	Sense Sense

	// Standing and OneOff are what someone has already said about tasks like
	// this by pinning them and by throwing them away.
	Standing []string
	OneOff   []string
}

// Found is one request the miner kept, with what made it worth keeping: how
// many times the session asked for it, and whether it reads as standing work.
type Found struct {
	Text    string
	Repeats int
	Chore   bool
	Last    int // the turn it was last asked on, counted from 0

	// What ordering is judged on besides the two above: how many words carry
	// meaning, whether it only changes one thing in front of you, and how
	// much more it reads like the deck's standing work than like the things
	// people throw away.
	content  int
	surface  bool
	standing float32
}

// Candidates judges a whole session's prompts together, because what makes a
// request worth a tile is mostly that it comes back.
//
// Each prompt goes through [Reusable] first; what survives is grouped with the
// others that ask the same thing in other words, and the groups come back
// strongest first:
//
//   - the session asked for it more than once -- the plainest evidence there
//     is that it will be asked again;
//   - it names standing work: the day, the meetings, the tests, the build;
//   - it asks for something to be looked at or acted on rather than for one
//     thing in front of you to be changed ("update the plan of action" reads
//     stronger than "remove the hour").
//
// Weak ones are kept rather than dropped, and the caller takes as many as it
// has room for. A band with a middling tile in it can be pinned, arranged or
// thrown away in a second, and rotates out by itself; a band with nothing in
// it teaches nobody what the band is for, and reads as broken.
//
// The shortest wording of a group is the one kept: it is the one that reads
// as a task rather than as that afternoon's sentence.
func Candidates(prompts []string) []Found { return Judge{}.Candidates(prompts) }

// Candidates judges a session's prompts, with whatever sense of the words the
// judge was given.
func (j Judge) Candidates(prompts []string) []Found {
	type group struct {
		words []string
		vec   []float32
		found Found
	}
	var groups []*group
	kept := make([]string, 0, len(prompts))
	for _, p := range prompts {
		if text, ok := Reusable(p); ok {
			kept = append(kept, text)
		} else {
			kept = append(kept, "")
		}
	}
	meaning := j.meaning(kept)
	for i, text := range kept {
		if text == "" {
			continue
		}
		ws := fields(text)
		vec := meaning[text]
		var at *group
		for _, g := range groups {
			if overlap(ws, g.words) >= repeatAlike ||
				words.Cosine(vec, g.vec) >= senseAlike {
				at = g
				break
			}
		}
		if at == nil {
			groups = append(groups, &group{words: ws, vec: vec, found: Found{Text: text, Repeats: 1, Last: i}})
			continue
		}
		at.found.Repeats++
		at.found.Last = i
		if len(ws) < len(at.words) { // the shortest wording reads best as a task
			at.words, at.found.Text, at.vec = ws, text, vec
		}
	}
	marks := j.marks()
	out := make([]Found, 0, len(groups))
	for _, g := range groups {
		f := g.found
		for _, w := range g.words {
			if chore[w] {
				f.Chore = true
			}
			if !small[w] && len([]rune(w)) > 1 {
				f.content++
			}
		}
		f.surface = surface[g.words[0]]
		if len(g.vec) > 0 {
			// One of the eight said in other words is not worth a cell: the
			// word rule only catches it when the words are the same ones.
			if near(g.vec, marks.builtin) >= senseBuiltin {
				continue
			}
			// How much this reads like the work this deck keeps, against how
			// much it reads like the things it throws away. The difference,
			// not either score: every score from this model sits inside a
			// narrow band, and the difference is what moves.
			f.standing = near(g.vec, marks.standing) - near(g.vec, marks.oneOff)
			if f.standing >= standingClear {
				f.Chore = true // standing work, whatever words it used
			}
		}
		out = append(out, f)
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.Repeats != b.Repeats {
			return a.Repeats > b.Repeats
		}
		if a.Chore != b.Chore {
			return a.Chore
		}
		if a.surface != b.surface {
			return b.surface
		}
		if a.content != b.content {
			return a.content > b.content
		}
		if a.standing != b.standing {
			return a.standing > b.standing
		}
		// Of two alike, the one asked for most recently: it is the one the
		// session is working on now.
		return a.Last > b.Last
	})
	return out
}

// Reusable judges one prompt. It reports whether the prompt reads like
// something worth asking again, and the text to keep for it: what was asked
// with the politeness taken off the front.
func Reusable(prompt string) (string, bool) {
	text := strings.TrimSpace(prompt)
	if text == "" {
		return "", false
	}
	// One line only. A prompt with a pasted error, a code block or a list in
	// it is a briefing about one moment, not a task.
	if strings.ContainsAny(text, "\n\r") || strings.Contains(text, "```") {
		return "", false
	}
	low := strings.ToLower(text)
	// A slash command runs itself; a link belongs to the thing it points at.
	if strings.HasPrefix(low, "/") || strings.HasPrefix(low, "!") ||
		strings.Contains(low, "http://") || strings.Contains(low, "https://") ||
		strings.Contains(low, "www.") {
		return "", false
	}
	for _, o := range oneOff {
		if strings.Contains(low, o) {
			return "", false
		}
	}
	text = strip(text)
	if text == "" {
		return "", false
	}
	words := fields(text)
	if len(words) < wordsMin || len(words) > wordsMax {
		return "", false
	}
	if !verbs[words[0]] {
		return "", false
	}
	if trailing[words[len(words)-1]] || words[len(words)-1] == "that" {
		return "", false
	}
	content := 0
	for _, w := range words {
		if deixis[w] {
			return "", false
		}
		// A letter on its own is a label in a list ("option a b c d"), not a
		// word that says what to do.
		if !small[w] && len([]rune(w)) > 1 {
			content++
		}
	}
	if content < 2 {
		return "", false
	}
	for _, b := range builtin {
		if overlap(words, fields(b)) >= 0.6 {
			return "", false
		}
	}
	return text, true
}

// strip takes the politeness off the front of a request, over and over, so
// "ok so can you please check the deck" is judged on "check the deck".
func strip(text string) string {
	for again := true; again; {
		again = false
		low := strings.ToLower(text)
		for _, p := range politeness {
			if low == p {
				return ""
			}
			if strings.HasPrefix(low, p+" ") {
				text = strings.TrimSpace(text[len(p):])
				again = true
				break
			}
		}
		text = strings.TrimLeft(text, " ,.;:")
	}
	return strings.TrimRight(strings.TrimSpace(text), " ,.;:!?")
}

// fields are a sentence's words, lowercased and without the punctuation.
func fields(text string) []string {
	var out []string
	for _, w := range strings.Fields(strings.ToLower(text)) {
		w = strings.Trim(w, ".,:;!?\"'`()[]{}")
		if w != "" {
			out = append(out, w)
		}
	}
	return out
}

// overlap is how much of two requests is the same words that carry meaning,
// from 0 (nothing in common) to 1 (the same request said in the same words).
func overlap(a, b []string) float64 {
	set := func(ws []string) map[string]bool {
		out := map[string]bool{}
		for _, w := range ws {
			if !small[w] {
				out[w] = true
			}
		}
		return out
	}
	x, y := set(a), set(b)
	if len(x) == 0 || len(y) == 0 {
		return 0
	}
	same := 0
	for w := range x {
		if y[w] {
			same++
		}
	}
	// Against the smaller of the two, so a short prompt that says all of what
	// a long built-in task says still counts as the same request.
	least := len(x)
	if len(y) < least {
		least = len(y)
	}
	return float64(same) / float64(least)
}

// Mine reads the prompts of one session that the deck has not judged yet and
// keeps the ones worth asking again. It reports how many it kept.
//
// A session that joins the deck again carries on from where the last pass
// stopped rather than mining its whole history over, so the tasks someone has
// already seen, arranged, pinned or thrown away are not made again behind
// them.
func (s *Store) Mine(agent string, prompts []string) int {
	from := s.Checked(agent)
	if from > len(prompts) {
		from = 0 // the transcript was replaced: read it again
	}
	kept := 0
	standing, oneOff := s.labels()
	judge := Judge{Sense: s.Sense, Standing: standing, OneOff: oneOff}
	thrown := s.Thrown(agent)
	// Judged over the whole session, kept only from where the last pass
	// stopped: a request asked three times before someone threw its tile away
	// is not made again behind them, but the third asking still counts as
	// evidence for the next request like it.
	for _, f := range judge.Candidates(prompts) {
		if kept >= MinedMax {
			// One pass never fills more than the band holds: the rest would
			// only push each other out again before anyone saw them.
			break
		}
		if f.Last < from {
			continue
		}
		if s.alike(agent, f.Text) {
			continue
		}
		if thrownAway(f.Text, thrown) {
			continue // someone took this one off the board already
		}
		// The strongest first, and the slot carries that order into the rank,
		// so the band reads strongest first as well.
		if _, err := s.Add(agent, "", f.Text, model.TaskMined, kept); err == nil {
			kept++
		}
	}
	s.SetChecked(agent, len(prompts))
	return kept
}

// thrownAway says whether this request, or one asking the same thing, was
// taken off the board before.
func thrownAway(text string, thrown []string) bool {
	ws := fields(text)
	for _, gone := range thrown {
		if overlap(ws, fields(gone)) >= 0.8 {
			return true
		}
	}
	return false
}

// alike says whether the agent already keeps a task that asks for this.
func (s *Store) alike(agent, text string) bool {
	words := fields(text)
	for _, have := range s.Texts(agent) {
		if overlap(words, fields(have)) >= 0.8 {
			return true
		}
	}
	return false
}

// sharedLeast is how many other sessions must have mined the same request
// before the deck offers it to one that has nothing.
//
// Two is the smallest number that is evidence of anything. Measured on a real
// deck without it, one session's "give me table" was handed to ten cards at
// once, which reads as a deck that has lost its mind rather than as help.
const sharedLeast = 2

// TopUp gives a session that yielded little what the rest of the deck keeps
// asking for, until it has least tasks of its own.
//
// A session joined on its first day has nothing to mine, and an empty band
// under the built-in eight teaches nobody what the band is for. What is
// offered is held to a higher bar than what a session mines for itself,
// because it was never asked for here: at least [sharedLeast] other sessions
// mined it, and it has to read as standing work ("check the meetings
// scheduled for today"), not as a thing one of them did once.
//
// What is offered is marked [model.Task.Shared], so one deck-wide guess never
// becomes the evidence for the next. It reports how many it added.
func (s *Store) TopUp(agent string, least int) int {
	have := 0
	for _, t := range s.List(agent) {
		if t.Source == model.TaskMined {
			have++
		}
	}
	if have >= least {
		return 0
	}
	type pool struct {
		text  string
		seen  int
		added time.Time
	}
	by := map[string]*pool{}
	for other, list := range s.All() {
		if other == agent {
			continue
		}
		for _, t := range list {
			if t.Source != model.TaskMined || t.Shared {
				continue
			}
			p, ok := by[t.Text]
			if !ok {
				p = &pool{text: t.Text}
				by[t.Text] = p
			}
			p.seen++
			if t.Added.After(p.added) {
				p.added = t.Added
			}
		}
	}
	all := make([]*pool, 0, len(by))
	for _, p := range by {
		all = append(all, p)
	}
	sort.Slice(all, func(i, j int) bool {
		if all[i].seen != all[j].seen {
			return all[i].seen > all[j].seen
		}
		return all[i].added.After(all[j].added)
	})
	added := 0
	for _, p := range all {
		if have+added >= least {
			break
		}
		if p.seen < sharedLeast || !standing(p.text) {
			// Sorted strongest first, so once one falls short the rest do.
			break
		}
		if s.alike(agent, p.text) {
			continue
		}
		if t, err := s.Add(agent, "", p.text, model.TaskMined, added); err == nil {
			s.markShared(agent, t.ID)
			added++
		}
	}
	return added
}

// standingClear is how much more a request has to read like the deck's
// standing work than like the things people throw away before it counts as
// standing whatever words it used. The scores from this model sit in a narrow
// band, so a tenth of a point between them is a real difference.
const standingClear = 0.1

// seeds are what standing work looks like before anyone has pinned anything.
// A new deck has no labels of its own; these are the shape of the thing, not
// a list to match against.
var seeds = struct{ standing, oneOff []string }{
	standing: []string{
		"check the meetings scheduled for today",
		"run the tests and tell me what failed",
		"summarise what happened today",
		"update the plan with where we got to",
		"check what is waiting for me",
		"take the latest from the main branch",
		"write up the week in the timesheet",
	},
	oneOff: []string{
		"remove the rounded borders from the buttons",
		"move this button to the left a bit",
		"open the folder",
		"give me a table",
		"change the title to something shorter",
		"delete the file we made earlier",
	},
}

// marked is every sentence the judge compares a request against, as vectors.
type marked struct{ builtin, standing, oneOff [][]float32 }

// marks embeds what the judge compares against: the eight built-in tasks, and
// what this deck has said about tasks like these by pinning them and throwing
// them away. Without a sense of the words it is empty and nothing uses it.
func (j Judge) marks() marked {
	if j.Sense == nil {
		return marked{}
	}
	all := make([]string, 0, len(builtin)+len(seeds.standing)+len(seeds.oneOff)+len(j.Standing)+len(j.OneOff))
	all = append(all, builtin...)
	all = append(all, seeds.standing...)
	all = append(all, j.Standing...)
	all = append(all, seeds.oneOff...)
	all = append(all, j.OneOff...)
	vecs, err := j.Sense.Vectors(all)
	if err != nil || len(vecs) != len(all) {
		return marked{}
	}
	at := 0
	take := func(n int) [][]float32 {
		out := vecs[at : at+n]
		at += n
		return out
	}
	return marked{
		builtin:  take(len(builtin)),
		standing: append(take(len(seeds.standing)), take(len(j.Standing))...),
		oneOff:   append(take(len(seeds.oneOff)), take(len(j.OneOff))...),
	}
}

// meaning is a vector for each request worth judging, by its text. A judge
// with no sense of the words, or a helper that will not run, gives none, and
// everything that reads it falls back to the words.
func (j Judge) meaning(texts []string) map[string][]float32 {
	if j.Sense == nil {
		return nil
	}
	want := make([]string, 0, len(texts))
	seen := map[string]bool{}
	for _, t := range texts {
		if t == "" || seen[t] {
			continue
		}
		seen[t] = true
		want = append(want, t)
	}
	if len(want) == 0 {
		return nil
	}
	vecs, err := j.Sense.Vectors(want)
	if err != nil || len(vecs) != len(want) {
		return nil
	}
	out := make(map[string][]float32, len(want))
	for i, t := range want {
		out[t] = vecs[i]
	}
	return out
}

// near is how alike a request is to the closest of a set of sentences.
func near(v []float32, set [][]float32) float32 {
	best := float32(0)
	for _, other := range set {
		if c := words.Cosine(v, other); c > best {
			best = c
		}
	}
	return best
}

// standing says whether a request reads as work that comes round again rather
// than as something one session did once.
func standing(text string) bool {
	for _, w := range fields(text) {
		if chore[w] {
			return true
		}
	}
	return false
}

// markShared records that a task was offered by the deck rather than mined
// here, so it is never counted as evidence for offering it elsewhere.
func (s *Store) markShared(agent, taskID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.load()
	for i, t := range s.byID[agent] {
		if t.ID == taskID {
			s.byID[agent][i].Shared = true
			s.save()
			return
		}
	}
}
