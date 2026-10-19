#if canImport(AppKit)
import AppKit
#endif
import Foundation

/// Guesses whether romaji keystrokes were meant as Latin letters (English, names, code) rather than Japanese,
/// so the letters as typed can be offered as a conversion candidate.
///
/// Modeled on Mozc's LanguageAwareRewriter: letters left inside the kana are a strong sign, and a reading that is not a
/// word while the letters are one is a weak sign. Two more strong signs come from measuring Ogura's samples
/// of typed input: kana sequences romaji typing does not produce (hello → へっぉ), and letters
/// Japanese romaji almost never uses. A strong sign alone can also be a typo, so the candidate goes first only when the
/// letters are a known word as well.
public enum LatinInputGuess {
    public struct Result: Sendable, Equatable {
        /// The text to offer (the known spelling when there is one, such as "iPhone")
        public var text: String
        /// Where to put it in the candidate list
        public var rank: Int
    }

    /// - Parameters:
    ///   - input: The keys typed
    ///   - kana: The input after romaji-to-kana conversion
    ///   - readingIsWord: Whether the dictionary has a word for the whole reading
    ///   - knownWord: Returns the spelling of `input` as a known word, or nil when it is not one
    public static func guess(input: String, kana: String, readingIsWord: Bool, knownWord: (String) -> String?) -> Result? {
        guard input.count >= 2, input.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.'".contains($0)) }),
              input.contains(where: \.isLetter), input != kana else {
            return nil
        }
        let strong = hasRomajiResidue(kana) || hasUnusedKanaSequence(kana) || hasRareRomajiLetter(input)
        if strong {
            if let word = knownWord(input) {
                return Result(text: word, rank: 0)
            }
            return Result(text: input, rank: 1)
        }
        // Mozc leaves out short inputs here: they are too often a word of either language
        if !readingIsWord, input.count >= 4, let word = knownWord(input) {
            return Result(text: word, rank: 2)
        }
        return nil
    }

    /// A Latin word inside otherwise Japanese input: `word` as it should be written (the same letters as the keys,
    /// perhaps in other case), typed with `keys`
    public struct Span: Sendable, Equatable {
        public var word: String
        public var keys: Range<Int>
    }

    /// Finds the parts of the input that look like Latin words (pig in butahapigdesu → ぶたはぴgです), so the converter
    /// can write them as is while it converts the rest. A part qualifies when it shows a strong sign of not being Japanese
    /// and is a known word, so most typos inside Japanese input are left alone. Longer words win over the shorter words
    /// they overlap (windows over window).
    /// - Parameters:
    ///   - keys: The keys typed
    ///   - prefixKana: `prefixKana[i]` is the conversion of the first `i` keys (`keys.count + 1` items)
    ///   - isComplete: Whether the input is complete (the convert key was pressed). Until then a word may not end at
    ///     the last key, unless it has a capital: its letters may still become kana with the next key (but becomes ぶた with a)
    ///   - endsWell: Whether a word may end before the key at the given position: at the end, before a capital, or
    ///     before what usually follows a word in Japanese (a particle). Only words with a capital are held to it, so
    ///     Kyo, a name to the spell checker, does not end Kyouha as Kyo|うは
    ///   - knownWord: Returns the spelling of a word, or nil when it is not one
    public static func latinSpans(
        keys: [Character],
        prefixKana: [String],
        isComplete: Bool,
        endsWell: (Int) -> Bool = { _ in true },
        knownWord: (String) -> String?
    ) -> [Span] {
        guard let kana = prefixKana.last, prefixKana.count == keys.count + 1,
              hasRomajiResidue(kana) || hasUnusedKanaSequence(kana) || hasRareRomajiLetter(String(keys)) else {
            return []
        }
        // Key positions where the conversion so far is also the start of the whole conversion, so a word can begin or end there
        let boundaries = prefixKana.indices.filter { kana.hasPrefix(prefixKana[$0]) }
        var spans: [Span] = []
        // A word does not start right after letters that stay Latin (acde in Macde, which the spell checker takes for ACDE),
        // unless it starts with a capital (Pro in MacBookPro)
        for start in boundaries where keys.indices.contains(start)
            && (keys[start].isUppercase || !(prefixKana[start].last.map { $0.isASCII && $0.isLetter } ?? false)) {
            for end in start + 3 ... max(start + 3, keys.count) where end <= keys.count {
                let spanKeys = String(keys[start ..< end])
                guard spanKeys.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                    break
                }
                let typedCapital = spanKeys.contains(where: \.isUppercase)
                // A word typed with a capital is meant as Latin letters, so it shows as one even before the input is complete
                guard isComplete || end < keys.count || typedCapital, !typedCapital || endsWell(end) else {
                    continue
                }
                if kana.hasPrefix(prefixKana[end]) {
                    let spanKana = String(kana.dropFirst(prefixKana[start].count).prefix(prefixKana[end].count - prefixKana[start].count))
                    guard typedCapital || spanKana.contains(where: { $0.isASCII && $0.isLetter }) || hasUnusedKanaSequence(spanKana)
                            || hasRareRomajiLetter(spanKeys) else {
                        continue
                    }
                } else if !typedCapital {
                    // The word's last key and the next one make one kana (sh in kaisha). Only a capital typed with Shift
                    // tells a word ends there (iPad in iPadwo, where dwo would be どぉ)
                    continue
                }
                if let word = knownWord(spanKeys) {
                    spans.append(Span(word: word, keys: start ..< end))
                }
            }
        }
        var chosen: [Span] = []
        for span in spans.sorted(by: { $0.keys.count > $1.keys.count }) where !chosen.contains(where: { $0.keys.overlaps(span.keys) }) {
            chosen.append(span)
        }
        return chosen
    }

    /// Two or more capitals in a row (SHIFT, ABC). They are Latin letters even when not a known word: Japanese romaji is
    /// not typed in capitals. Read as romaji they would run together (sh and i make し)
    public static func capitalRuns(keys: [Character]) -> [Span] {
        var runs: [Span] = []
        var index = 0
        while index < keys.count {
            var end = index
            while end < keys.count, keys[end].isASCII, keys[end].isUppercase {
                end += 1
            }
            if end - index >= 2 {
                runs.append(Span(word: String(keys[index ..< end]), keys: index ..< end))
            }
            index = max(end, index + 1)
        }
        return runs
    }

    /// Latin letters left over after romaji-to-kana conversion. A trailing "n" is not counted: it becomes ん when committed
    static func hasRomajiResidue(_ kana: String) -> Bool {
        var text = Substring(kana)
        if text.hasSuffix("n") {
            text = text.dropLast()
        }
        return text.contains { $0.isASCII && $0.isLetter }
    }

    /// Kana sequences that Japanese romaji typing does not produce, such as a small vowel after っ (hello → へっぉ) or ょ after て (python → pyてょn)
    static func hasUnusedKanaSequence(_ kana: String) -> Bool {
        let characters = Array(kana)
        let smallVowels: Set<Character> = ["ぁ", "ぃ", "ぅ", "ぇ", "ぉ"]
        let smallY: Set<Character> = ["ゃ", "ゅ", "ょ"]
        // Small vowels Japanese uses for loanword sounds, keyed by the kana before them
        let allowedSmallVowels: [Character: Set<Character>] = [
            "う": ["ぃ", "ぇ", "ぉ"], "く": ["ぁ", "ぃ", "ぇ", "ぉ"], "ぐ": ["ぁ", "ぃ", "ぇ", "ぉ"], "す": ["ぃ"], "ず": ["ぃ"],
            "つ": ["ぁ", "ぃ", "ぇ", "ぉ"], "て": ["ぃ"], "で": ["ぃ"], "と": ["ぅ"], "ど": ["ぅ"], "ふ": ["ぁ", "ぃ", "ぇ", "ぉ"],
            "ゔ": ["ぁ", "ぃ", "ぇ", "ぉ"], "し": ["ぇ"], "ち": ["ぇ"], "じ": ["ぇ"], "い": ["ぇ"]
        ]
        let beforeSmallY: Set<Character> = Set("きしちにひみりぎじぢびぴてでふゔ")
        for (index, character) in characters.enumerated() {
            let previous = index > 0 ? characters[index - 1] : nil
            if smallVowels.contains(character), !(previous.flatMap { allowedSmallVowels[$0] }?.contains(character) ?? false) {
                return true
            }
            if smallY.contains(character), !(previous.map(beforeSmallY.contains) ?? false) {
                return true
            }
            if character == "っ", index == characters.count - 1 {
                return true
            }
        }
        return false
    }

    /// Letters Japanese romaji typing almost never uses: l, q, v, x, and c outside "ch"
    static func hasRareRomajiLetter(_ input: String) -> Bool {
        let characters = Array(input.lowercased())
        for (index, character) in characters.enumerated() {
            switch character {
            case "l", "q", "v", "x":
                return true
            case "c" where index + 1 >= characters.count || characters[index + 1] != "h":
                return true
            default:
                continue
            }
        }
        return false
    }

    /// The spelling of `input` as an English word in the system spell checker: `input` itself when it is spelled
    /// correctly, or a suggestion that differs only in case ("iphone" → "iPhone")
    @MainActor
    public static func systemKnownWord(_ input: String) -> String? {
        if let cached = knownWordCache[input] {
            return cached
        }
        let word = lookUpKnownWord(input)
        if knownWordCache.count > 2000 {
            knownWordCache.removeAll()
        }
        knownWordCache[input] = .some(word)
        return word
    }

    /// Words looked up while typing, so the spell checker is asked about each part of the input only once
    @MainActor private static var knownWordCache: [String: String?] = [:]

    @MainActor
    private static func lookUpKnownWord(_ input: String) -> String? {
        if input.dropFirst().contains(where: \.isUppercase) {
            // The spell checker accepts any word with a capital inside (it takes haWindows for a name like iPhone),
            // so check the letters in lower case
            let word = lookUpKnownWord(input.lowercased())
            if input.first?.isUppercase == true {
                // Keep the case typed (GitHub)
                return word.map { _ in input }
            }
            // A capital typed with Shift starts a word, so a word cannot run into one from lower case letters (haMac in
            // watasihaMacwotukau), unless the word is written that way (iPhone)
            return word == input ? input : nil
        }
        #if canImport(AppKit)
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: input, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        if range.location == NSNotFound {
            return input
        }
        let guesses = checker.guesses(forWordRange: NSRange(location: 0, length: input.utf16.count), in: input, language: "en", inSpellDocumentWithTag: 0)
        // Keep the capitals typed and take the ones of the known spelling: Ctrl stays Ctrl though the suggestion is
        // ctrl, and iphone becomes iPhone
        return guesses?.first { $0.caseInsensitiveCompare(input) == .orderedSame }.map { guess in
            String(zip(input, guess).map { $0.isUppercase || $1.isUppercase ? Character($0.uppercased()) : $0 })
        }
        #else
        return nil
        #endif
    }
}
