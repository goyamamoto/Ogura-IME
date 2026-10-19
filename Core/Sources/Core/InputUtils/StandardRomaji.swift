import Foundation

/// Japanese written in the standard romaji systems: Hepburn, Kunrei and Nihon-shiki, with the spellings Hepburn gives
/// the sounds of loanwords (she, fa, ti, wi). An input method reads more as kana (co as こ, le as ぇ, two as とぉ), but
/// no one writing Japanese spells it so: この子で is konokode, so konocode means code
enum StandardRomaji {
    /// The spellings of one kana, or of one with a small kana after it
    private static let syllables: Set<String> = {
        var syllables: Set<String> = ["a", "i", "u", "e", "o", "ya", "yu", "yo", "ye", "wa", "wi", "we", "wo",
                                      "shi", "chi", "tsu", "fu", "ji", "kwa", "gwa"]
        for consonant in ["k", "g", "s", "z", "t", "d", "n", "h", "b", "p", "m", "r", "v"] {
            for vowel in ["a", "i", "u", "e", "o"] {
                syllables.insert(consonant + vowel)
            }
        }
        for consonant in ["ky", "gy", "sy", "sh", "zy", "j", "ty", "ch", "dy", "ny", "hy", "by", "py", "my", "ry", "ts", "f"] {
            for vowel in ["a", "u", "e", "o"] {
                syllables.insert(consonant + vowel)
            }
        }
        syllables.formUnion(["tsi", "fi", "fyu"])
        return syllables
    }()

    /// Whether `word`, in lower-case letters, is Japanese in standard romaji: syllables, with ん written n (before a
    /// consonant or at the end) or nn, っ written by doubling the consonant after it (kitte; matcha, maccha), and ー
    /// written - after a syllable (e-to)
    static func spells(_ word: some Sequence<Character>) -> Bool {
        let letters = Array(word)
        var reachable = Array(repeating: false, count: letters.count + 1)
        reachable[0] = true
        for start in letters.indices where reachable[start] {
            let letter = letters[start]
            if letter == "-" {
                reachable[start + 1] = start > 0
                continue
            }
            for length in 1 ... min(3, letters.count - start) where self.syllables.contains(String(letters[start ..< start + length])) {
                reachable[start + length] = true
            }
            let next = start + 1 < letters.count ? letters[start + 1] : nil
            if letter == "n" {
                if next == "n" {
                    reachable[start + 2] = true
                }
                if next.map({ !"aiueoy".contains($0) }) ?? true {
                    reachable[start + 1] = true
                }
            } else if let next, !"aiueo".contains(letter), next == letter || letter == "t" && next == "c" {
                // っ: the syllable after it must start with the next letter (kk, tch, cch)
                reachable[start + 1] = true
            }
        }
        return reachable[letters.count]
    }
}
