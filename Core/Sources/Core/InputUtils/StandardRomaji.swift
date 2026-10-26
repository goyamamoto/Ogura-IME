import Foundation

/// Japanese as people type it in romaji, by the spellings of the catalog that are compared (`RomajiSpellings.margin`:
/// Hepburn, Kunrei, Nihon-shiki, Hepburn's loanword spellings, and the input methods' spellings with their own reason,
/// such as jyu): how much likelier Zenzai must find a word read as kana than as letters for it to be Japanese. Bare c
/// and q are never compared: an input method reads co as こ, but nobody types Japanese so (この子で is konokode, so
/// konocode means code)
enum StandardRomaji {
    /// The spellings of one kana, or of one with a small kana after it, with their margins
    private static let syllables: [String: Float] = Dictionary(
        RomajiSpellings.all.compactMap { spelling in spelling.margin.map { (spelling.spelling, $0) } }, uniquingKeysWith: { first, _ in first }
    )
    /// The most letters a syllable has (xtsu)
    private static let longest = Self.syllables.keys.map(\.count).max() ?? 0
    /// The margin of a word of ん, っ and ー alone (n, -): the standard spellings'
    private static let standardMargin = RomajiSpellings.all.first { $0.kind == .standard }?.margin ?? SegmentsManager.naturalJapaneseMargin

    /// Whether `word`, in lower-case letters, is Japanese as people type it (see `margin`)
    static func spells(_ word: some Sequence<Character>) -> Bool {
        Self.margin(word) != nil
    }

    /// How much likelier Zenzai must find `word`, in lower-case letters, read as kana than as letters for it to be
    /// Japanese: the strictest margin of its syllables, spelled the way that keeps it lowest; nil when it is not spelled
    /// by the syllables compared (see `syllables`), with ん written n (before a consonant or at the end) or nn, っ
    /// written by doubling the consonant after it (kitte; matcha, maccha), and ー written - after a syllable (e-to)
    static func margin(_ word: some Sequence<Character>) -> Float? {
        let letters = Array(word)
        // For each place, the lowest margin of the strictest syllable on a way to spell up to it (-infinity: only ん, っ
        // and ー so far); nil: no way
        var reached = [Float?](repeating: nil, count: letters.count + 1)
        reached[0] = -.infinity
        func reach(_ index: Int, with margin: Float) {
            reached[index] = min(reached[index] ?? .infinity, margin)
        }
        for start in letters.indices {
            guard let sofar = reached[start] else {
                continue
            }
            let letter = letters[start]
            if letter == "-" {
                if start > 0 {
                    reach(start + 1, with: sofar)
                }
                continue
            }
            for length in 1 ... max(1, min(Self.longest, letters.count - start)) {
                if let margin = Self.syllables[String(letters[start ..< start + length])] {
                    reach(start + length, with: max(sofar, margin))
                }
            }
            for end in Self.nOrSmallTsu(letters, at: start) {
                reach(end, with: sofar)
            }
        }
        guard let margin = reached[letters.count] else {
            return nil
        }
        return margin == -.infinity ? Self.standardMargin : margin
    }

    /// Where ん or っ typed at `start` of `letters` ends: ん written n (before a consonant or at the end) or nn, っ written
    /// by doubling the consonant after it (the syllable after it must start with the next letter: kk, tch, cch)
    private static func nOrSmallTsu(_ letters: [Character], at start: Int) -> [Int] {
        let letter = letters[start]
        let next = start + 1 < letters.count ? letters[start + 1] : nil
        if letter == "n" {
            return (next == "n" ? [start + 2] : []) + (next.map { !"aiueoy".contains($0) } ?? true ? [start + 1] : [])
        }
        if let next, !"aiueo".contains(letter), next == letter || letter == "t" && next == "c" {
            return [start + 1]
        }
        return []
    }
}
