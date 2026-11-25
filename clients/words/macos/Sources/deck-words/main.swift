// deck-words: sentences in, vectors out.
//
// The deck mines tasks out of what a session has been asked for, and the hard
// part is not reading the prompts: it is seeing that "look at today's
// meetings" and "check the meetings scheduled for today" are one task, and
// that "run the tests" is the built-in one said shorter. Words alone cannot
// see that. macOS can: NLEmbedding has a sentence model built into the
// system, so this costs nothing to ship and nothing to download.
//
// Go has no Apple frameworks of its own (no cgo in this service), so this
// helper sits beside agentctl the way deck-ble does, reads one JSON request
// per line and writes one JSON reply per line:
//
//   {"texts":["check the meetings","run the tests"]}
//   {"dim":512,"vectors":[[0.01,...],[...]]}
//
// A sentence the model has nothing for comes back as an empty vector rather
// than as an error, so one odd prompt never spoils a batch. If the system has
// no English sentence model at all, the helper says so on its first line and
// stops; the service then judges on the words alone.
import Foundation
import NaturalLanguage

struct Request: Decodable {
    var texts: [String]
}

struct Reply: Encodable {
    var dim: Int
    var vectors: [[Float]]
}

struct Failure: Encodable {
    var error: String
}

let out = FileHandle.standardOutput

func say<T: Encodable>(_ value: T) {
    guard var data = try? JSONEncoder().encode(value) else { return }
    data.append(0x0a)
    out.write(data)
}

guard let model = NLEmbedding.sentenceEmbedding(for: .english) else {
    say(Failure(error: "this macOS has no English sentence model"))
    exit(1)
}

// The model is per language and per process: loaded once here, and every
// request after that is a lookup.
let dim = model.dimension

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard let data = line.data(using: .utf8),
          let req = try? JSONDecoder().decode(Request.self, from: data) else {
        say(Failure(error: "bad request"))
        continue
    }
    var vectors: [[Float]] = []
    vectors.reserveCapacity(req.texts.count)
    for text in req.texts {
        let one = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !one.isEmpty, let v = model.vector(for: one) else {
            vectors.append([])
            continue
        }
        vectors.append(v.map { Float($0) })
    }
    say(Reply(dim: dim, vectors: vectors))
}
