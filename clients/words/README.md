# deck-words: what a request means

The deck fills each agent's band of tasks from the prompts of the session
behind its card (`docs/features.md`, "Tasks the deck found"). Judging that on
the words alone gets the shape of a request right and its meaning wrong: it
cannot see that "look at today's meetings" and "check the meetings scheduled
for today" are one task, or that "run the tests" is already one of the eight
every agent has.

macOS can see it. `NLEmbedding.sentenceEmbedding(for: .english)` is a sentence
model built into the system: nothing to ship, nothing to download, nothing to
keep warm. The service is Go with no cgo, so, as with Bluetooth, a small
helper beside `agentctl` does the Apple-framework part and the service talks
to it in JSON lines.

## Running it

    swift build -c release          # .build/release/deck-words

The service runs `deck-words` next to its own executable (inside
`agents deck.app` on macOS). `AGENTS_DECK_WORDS_HELPER` names another one, and
`none` turns it off; with no helper the deck judges on the words alone, which
is a worse list of tasks, not a broken one.

## The protocol

One JSON request per line on stdin, one JSON reply per line on stdout.

| in | out |
| --- | --- |
| `{"texts":["check the meetings","run the tests"]}` | `{"dim":512,"vectors":[[…512 floats…],[…]]}` |

- A sentence the model has no vector for comes back as `[]`, so one odd prompt
  does not spoil a batch.
- A line that is not a request answers `{"error":"bad request"}` and the
  helper carries on.
- A system with no English sentence model answers `{"error":"…"}` once and
  exits 1. The service notices and falls back.

The vectors are compared with cosine similarity in the service
(`backend/internal/words`). What the numbers look like in practice, measured
on this model: a paraphrase of the same request scores 0.53 to 0.75, two
unrelated requests 0.13 to 0.47. The thresholds in the miner are set from
those measurements, not from the usual 0.85 that larger models give.
