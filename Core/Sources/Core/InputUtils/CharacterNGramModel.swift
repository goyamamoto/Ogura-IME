import Foundation

/// A character n-gram model of how words are spelled, with Witten-Bell smoothing. Built from counts of n-grams
/// (n = 1 ... order) where ^ marks the start of a word and $ its end.
struct CharacterNGramModel: Sendable {
    let order: Int
    private let counts: [String: Double]
    /// For each context: the total count of what follows it, and how many different characters follow it
    private let contexts: [String: (total: Double, kinds: Double)]
    private let vocabularySize: Double

    /// - Parameter path: One "ngram<TAB>count" per line
    init(contentsOf path: URL, order: Int = 4) throws {
        self.order = order
        var counts: [String: Double] = [:]
        for line in try String(contentsOf: path, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if parts.count == 2, let count = Double(parts[1]) {
                counts[String(parts[0])] = count
            }
        }
        var contexts: [String: (total: Double, kinds: Double)] = [:]
        for (ngram, count) in counts {
            let context = String(ngram.dropLast())
            let current = contexts[context] ?? (0, 0)
            contexts[context] = (current.total + count, current.kinds + 1)
        }
        self.counts = counts
        self.contexts = contexts
        self.vocabularySize = Double(counts.keys.filter { $0.count == 1 }.count)
    }

    /// log P(character | history), where history holds up to `order - 1` characters before it
    func logProbability(of character: Character, after history: Substring) -> Double {
        var probability = 1 / (self.vocabularySize + 1)
        for length in 0 ..< self.order {
            guard length <= history.count else {
                break
            }
            let context = String(history.suffix(length))
            guard let (total, kinds) = self.contexts[context], total > 0 else {
                continue
            }
            probability = ((self.counts[context + String(character)] ?? 0) + kinds * probability) / (total + kinds)
        }
        return log(probability)
    }
}
