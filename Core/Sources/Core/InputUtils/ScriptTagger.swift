import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

// A learned identification layer (docs/latin-identification.md): a semi-Markov CRF that splits the keys of the input
// into romaji keys and Latin words. A Latin word scores as a whole (whether it is a known word, how English it reads
// from start to end, what comes after it) as well as key by key, as the first key of a word or a later one. Its
// parameters are learned from data, not set by hand.

/// What a key of the input is
enum ScriptTag: Int, CaseIterable {
    case japanese = 0
    case latinBegin = 1
    case latinInside = 2

    init?(label: Character) {
        switch label {
        case "J": self = .japanese
        case "B": self = .latinBegin
        case "I": self = .latinInside
        default: return nil
        }
    }
}

/// The features of each key, and of each run of keys as one Latin word, hashed into a fixed number of weights
enum ScriptTaggerFeatures {
    /// The longest Latin word the tagger reads, in keys
    static let maxWordLength = 20

    /// Models of how romaji and Latin words are spelled, whose scores the tagger also reads
    struct CharacterModels {
        let romaji: CharacterNGramModel
        let latin: CharacterNGramModel

        /// Reads romaji.tsv and latin.tsv from `directory`
        init(directory: URL) throws {
            self.romaji = try CharacterNGramModel(contentsOf: directory.appendingPathComponent("romaji.tsv"))
            self.latin = try CharacterNGramModel(contentsOf: directory.appendingPathComponent("latin.tsv"))
        }

        /// For each key, how much more Latin than romaji it reads (in natural log), in whole steps: the key itself,
        /// the keys up to it, the keys from it, and how likely a Latin word is to end after it
        func scores(_ keys: [Character]) -> [[Int8]] {
            let order = self.latin.order
            var difference: [Double] = []
            var ending: [Double] = []
            var history = Substring(String(repeating: "^", count: order - 1))
            for key in keys {
                guard key.isASCII, key.isLetter else {
                    difference.append(0)
                    ending.append(0)
                    history = Substring(String(repeating: "^", count: order - 1))
                    continue
                }
                let character = Character(key.lowercased())
                difference.append(self.latin.logProbability(of: character, after: history) - self.romaji.logProbability(of: character, after: history))
                history = Substring(String(history + String(character)).suffix(order - 1))
                ending.append(self.latin.logProbability(of: "$", after: history))
            }
            func step(_ value: Double) -> Int8 {
                Int8(max(-12, min(12, value.rounded())))
            }
            return keys.indices.map { index in
                let before = difference[max(0, index - 3) ... index].reduce(0, +)
                let after = difference[index ..< min(keys.count, index + 4)].reduce(0, +)
                return [step(difference[index]), step(before / 2), step(after / 2), step(ending[index])]
            }
        }
    }

    /// What the romaji conversion tells about each key, kept small for training on many inputs
    struct KeyShape: Sendable {
        /// Before each key (and after the last), whether romaji is whole there, so a word can start
        var boundary: [Bool]
        /// After each key, whether letters are left unread (still being typed, or left over)
        var pending: [Bool]
        var isComplete: Bool
        /// For each key, the scores of the character models (see `CharacterModels.scores`), if the tagger reads them
        var modelScores: [[Int8]]?
        /// For each key, what the analysis of the input as Japanese says about it (see `morphology(of:analyzer:)`), if
        /// the tagger reads it
        var morphology: [[UInt32]]?
        /// For each key, which words the spell checker knows around it (see `lexicon(of:)`), if the tagger reads them
        var lexicon: [[UInt8]]?
        /// For each key, what is known about the keys from it as one word, for each length it can have (see
        /// `words(of:models:lexicon:)`)
        var words: [[UInt8]]
        /// For each key, what the analysis as Japanese of the keys before it, on their own, says (see `evidence`), when
        /// a first pass found a Latin word likely to start at it; for a second pass only
        var before: [[UInt32]]?
        /// For each key, what the analysis as Japanese of the keys from it, on their own, says (see `evidence`), when a
        /// first pass found a Latin word likely to end before it; for a second pass only. With `context`, for every key
        var after: [[UInt32]]?
        /// For each key, the best reading of it among the analyses from every position where a Latin word could end or
        /// start (see `conditionedAnalyses(of:analyzer:)`), when the tagger reads them
        var context: [[UInt32]]?
        /// For each key and each length of `words`, the dictionary's likeliest word for the kana of those keys (see
        /// `readings(of:words:analyzer:)`), when the tagger reads them
        var readings: [[UInt8]]?
        /// For each key, whether it is a letter romaji leaves unread for good (the p of まpー in map-1; see
        /// `stranded(of:)`), when the tagger reads them
        var stranded: [Bool]?

        init(boundary: [Bool], pending: [Bool], isComplete: Bool, modelScores: [[Int8]]?, morphology: [[UInt32]]?, lexicon: [[UInt8]]?, words: [[UInt8]], before: [[UInt32]]? = nil, after: [[UInt32]]? = nil, context: [[UInt32]]? = nil, readings: [[UInt8]]? = nil, stranded: [Bool]? = nil) {
            self.boundary = boundary
            self.pending = pending
            self.isComplete = isComplete
            self.modelScores = modelScores
            self.morphology = morphology
            self.lexicon = lexicon
            self.words = words
            self.before = before
            self.after = after
            self.context = context
            self.readings = readings
            self.stranded = stranded
        }

        /// With `evidence`, the analyses around every position where a Latin word could end or start are read too, by
        /// that analyzer (a fast one, see `JapaneseAnalyzer`); with `readingWords`, the dictionary's words for the kana
        /// of the words of the lexicon typed, by that analyzer; with `stranded`, the letters romaji leaves unread; with
        /// `hyphens`, words joined by hyphens are one word (e-mail)
        init(
            _ input: TypedInput,
            models: CharacterModels?,
            analyzer: JapaneseAnalyzer? = nil,
            lexicon: ScriptLexicon? = nil,
            evidence: JapaneseAnalyzer? = nil,
            readingWords: JapaneseAnalyzer? = nil,
            stranded: Bool = false,
            hyphens: Bool = false
        ) {
            let kana = input.prefixKana.last ?? ""
            self.boundary = (0 ... input.keys.count).map { kana.hasPrefix(input.prefixKana[$0]) }
            self.pending = (0 ..< input.keys.count).map { input.prefixKana[$0 + 1].last.map { $0.isASCII && $0.isLetter } ?? false }
            self.isComplete = input.isComplete
            self.modelScores = models?.scores(input.keys)
            self.morphology = analyzer.map { ScriptTaggerFeatures.morphology(of: input, analyzer: $0) }
            self.lexicon = lexicon.map { ScriptTaggerFeatures.lexicon(of: input.keys, in: $0, throughHyphens: hyphens) }
            self.words = ScriptTaggerFeatures.words(of: input.keys, models: models, lexicon: lexicon, throughHyphens: hyphens)
            self.readings = readingWords.map { ScriptTaggerFeatures.readings(of: input, words: self.words, analyzer: $0) }
            self.stranded = stranded ? ScriptTaggerFeatures.stranded(of: input) : nil
            if let evidence {
                let analyses = ScriptTaggerFeatures.conditionedAnalyses(of: input, analyzer: evidence)
                (self.before, self.after, self.context) = (analyses.before, analyses.after, analyses.context)
            }
        }
    }

    /// For each key: whether it starts a word of the analysis, the word's length, its value for each character, its
    /// part of speech, whether it is a word the dictionary does not know (kana or letters only filled in), the kind of
    /// characters it is written in, and the value of the whole reading for each character. All in small steps
    /// What a key gets when the analysis says nothing about it
    static let noMorphology = [UInt32](repeating: .max, count: 7)

    static func morphology(of input: TypedInput, analyzer: JapaneseAnalyzer) -> [[UInt32]] {
        guard let words = analyzer.analyze(Self.romajiText(of: input.elements[...], isComplete: input.isComplete)), !words.isEmpty else {
            return input.keys.map { _ in Self.noMorphology }
        }
        return Self.keyMorphology(of: input, words: words)
    }

    /// The input of `elements` as romaji, with capitals read as the romaji they would be in lower case (Ogura is おぐら,
    /// 小倉; Kyou is きょう, 今日), and the convert key after them when `isComplete`
    static func romajiText(of elements: ArraySlice<ComposingText.InputElement>, isComplete: Bool) -> ComposingText {
        var text = ComposingText()
        text.insertAtCursorPosition(elements.map { element in
            guard case .key(_, let key, let modifiers) = element.piece, key.isASCII, key.isUppercase else {
                return element
            }
            let lowercased = Character(key.lowercased())
            return .init(piece: .key(intention: KeyMap.h2zMap(lowercased), input: lowercased, modifiers: modifiers), inputStyle: element.inputStyle)
        })
        if isComplete, let first = elements.first {
            text.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: first.inputStyle)])
        }
        return text
    }

    /// What the analysis `words` of `input` as Japanese says about each of its keys (see `morphology(of:analyzer:)`)
    static func keyMorphology(of input: TypedInput, words: [JapaneseAnalyzer.Word]) -> [[UInt32]] {
        // The word each kana character belongs to, and whether it is the first character of it
        var wordOfCharacter: [(word: Int, isFirst: Bool)] = []
        for (index, word) in words.enumerated() {
            for offset in 0 ..< word.ruby.count {
                wordOfCharacter.append((index, offset == 0))
            }
        }
        let total = words.reduce(Float(0)) { $0 + $1.value } / Float(max(wordOfCharacter.count, 1))
        func step(_ value: Float, _ low: Float, _ high: Float) -> UInt32 {
            UInt32(max(low, min(high, value.rounded())) - low)
        }
        func script(_ text: String) -> UInt32 {
            if text.contains(where: { $0.isASCII && $0.isLetter }) { 0 } else if text.unicodeScalars.contains(where: { (0x4E00 ... 0x9FFF).contains($0.value) }) { 1 } else if text.unicodeScalars.allSatisfy({ (0x30A0 ... 0x30FF).contains($0.value) }) { 2 } else { 3 }
        }
        var previousCharacter = -1
        return input.keys.indices.map { index in
            // The kana character a key went into: the last one written so far, or the next to come
            let character = max(0, min(input.prefixKana[index].count, input.prefixKana[index + 1].count - 1, wordOfCharacter.count - 1))
            guard wordOfCharacter.indices.contains(character) else {
                return Self.noMorphology
            }
            let (wordIndex, isFirst) = wordOfCharacter[character]
            let word = words[wordIndex]
            let startsWord = isFirst && character != previousCharacter
            previousCharacter = character
            let length = UInt32(min(word.ruby.count, 6))
            let unknown = word.ruby == word.word && word.cid == CIDData.固有名詞.cid && word.mid == MIDData.一般.mid
                || word.ruby.contains(where: { $0.isASCII })
            return [
                startsWord ? 1 : 0,
                length,
                step(word.value / Float(max(word.ruby.count, 1)), -16, 0),
                UInt32(word.cid),
                unknown ? 1 : 0,
                script(word.word),
                step(total, -16, 0)
            ]
        }
    }

    /// What a boundary gets when the first pass did not find a Latin word likely to start or end there
    static let unselectedEvidence: [UInt32] = [0, 0, 0, 0, 0, 0]
    /// What the start of the input gets as the keys before it, and its end as the keys after it
    static let edgeEvidence: [UInt32] = [1, 0, 0, 0, 0, 0]

    /// The analysis as Japanese of the keys before each key in `starts`, on their own, and of the keys from each key in
    /// `ends`: a Latin word there leaves Japanese on each side that should read well on its own (Finder|uindou is
    /// Finder and ウインドウ; the whole read as romaji is フィン|でる|引導). For each: whether it was analyzed (2; 3 when
    /// no reading covers the keys), the length of the word next to the boundary, whether the dictionary does not know
    /// that word, its value for each character, its part of speech, and the value of the whole reading for each
    /// character; `edgeEvidence` at the ends of the input, `unselectedEvidence` elsewhere
    /// How many keys on each side of a boundary the evidence reads: the word next to it and a little more
    static let evidenceWindow = 12
    /// Analyses by the keys read (nil where no reading covers them), kept while the input grows: the keys before a
    /// boundary stay the same, and so do the keys after it once the input is `evidenceWindow` keys past it
    /// Guarded by the conversion lock (see `ConversionLock`), as everything the conversion runs
    nonisolated(unsafe) private static var evidenceCache: [String: [JapaneseAnalyzer.Word]?] = [:]

    /// What a key gets as context when no analysis around it reads it
    static let noContext = Self.noMorphology + [24]

    /// The analyses around every position: see `conditionedAnalyses(of:analyzer:)`
    struct PositionAnalyses {
        var before: [[UInt32]]
        var after: [[UInt32]]
        var context: [[UInt32]]
    }

    /// A window of the input read as Japanese on its own: its words, and what they say about each of its keys
    private struct WindowAnalysis {
        var words: [JapaneseAnalyzer.Word]
        var rows: [[UInt32]]
    }

    /// Windows by their keys (nil where no reading covers them), kept while the input grows: the window before a
    /// position stays the same, and so does the one from it once the input is `evidenceWindow` keys past it
    /// Guarded by the conversion lock (see `ConversionLock`), as everything the conversion runs
    nonisolated(unsafe) private static var windowCache: [String: WindowAnalysis?] = [:]

    /// The analyses as Japanese around every position where a Latin word could start or end: for each key, what the
    /// `evidenceWindow` keys before it say on their own as if a word started there (`before`), what the keys from it say
    /// as if one ended there (`after`), each as `evidence` has them, and the key's `context`: among those analyses, the
    /// one reading it in the longest word the dictionary knows (then the best valued), as `morphology` has it, with how
    /// far the key is from that analysis's position (0 to 11 after it, 12 to 23 before it). Where a Latin word really
    /// ends, the Japanese after it reads well on its own however badly the whole input reads (Finder|uindou is ウインドウ)
    /// Whether the windows still growing at the end of an input being typed are read: their readings change with each
    /// key, which can flip the words before them (an experiment: the nogrowing file in the model directory turns it off)
    /// Guarded by the conversion lock (see `ConversionLock`), as everything the conversion runs
    nonisolated(unsafe) static var growingWindows = true

    static func conditionedAnalyses(of input: TypedInput, analyzer: JapaneseAnalyzer) -> PositionAnalyses {
        let count = input.keys.count
        func step(_ value: Float, _ low: Float, _ high: Float) -> UInt32 {
            UInt32(max(low, min(high, value.rounded())) - low)
        }
        func window(_ range: Range<Int>, isComplete: Bool) -> WindowAnalysis? {
            let key = String(input.keys[range]).lowercased() + (isComplete ? "." : "")
            if let cached = Self.windowCache[key] {
                return cached
            }
            let text = Self.romajiText(of: input.elements[range], isComplete: isComplete)
            var analysis: WindowAnalysis?
            if let words = analyzer.analyze(text), !words.isEmpty, let piece = TypedInput(text) {
                analysis = WindowAnalysis(words: words, rows: Self.keyMorphology(of: piece, words: words))
            }
            if Self.windowCache.count >= 8192 {
                Self.windowCache.removeAll(keepingCapacity: true)
            }
            Self.windowCache[key] = analysis
            return analysis
        }
        func vector(_ words: [JapaneseAnalyzer.Word]?, last: Bool) -> [UInt32] {
            guard let words, let word = last ? words.last : words.first else {
                return [3, 0, 0, 0, 0, 0]
            }
            let characters = words.reduce(0) { $0 + $1.ruby.count }
            let total = words.reduce(Float(0)) { $0 + $1.value } / Float(max(characters, 1))
            let unknown = word.ruby == word.word && word.cid == CIDData.固有名詞.cid && word.mid == MIDData.一般.mid
                || word.ruby.contains(where: { $0.isASCII })
            return [2, UInt32(min(word.ruby.count, 6)), unknown ? 1 : 0, step(word.value / Float(max(word.ruby.count, 1)), -16, 0), UInt32(word.cid), step(total, -16, 0)]
        }
        var before = [[UInt32]](repeating: Self.unselectedEvidence, count: count)
        var after = [[UInt32]](repeating: Self.unselectedEvidence, count: count)
        var context = [[UInt32]](repeating: Self.noContext, count: count)
        func consider(_ rows: [[UInt32]], over window: Range<Int>, offset: (Int) -> UInt32) {
            // A complete window has a row for the convert key after its keys too
            let first = window.lowerBound
            for (index, row) in rows.prefix(window.count).enumerated() where row != Self.noMorphology {
                let key = first + index
                let best = context[key]
                // A word the dictionary knows over one it does not, then the longer, then the better valued
                let known = (row[4] == 0, best[4] == 0)
                let better = best == Self.noContext || known == (true, false)
                    || known.0 == known.1 && (row[1] > best[1] || row[1] == best[1] && row[2] > best[2])
                if better {
                    context[key] = row + [offset(key)]
                }
            }
        }
        for start in 0 ..< count {
            guard start > 0 else {
                before[start] = Self.edgeEvidence
                continue
            }
            let first = max(0, start - Self.evidenceWindow)
            let analysis = window(first ..< start, isComplete: true)
            before[start] = vector(analysis?.words, last: true)
            if let analysis {
                consider(analysis.rows, over: first ..< start) { 12 + UInt32(min(start - 1 - $0, 11)) }
            }
        }
        for end in 1 ..< max(count, 1) {
            let limit = min(count, end + Self.evidenceWindow)
            guard Self.growingWindows || input.isComplete || limit < count else {
                continue
            }
            let analysis = window(end ..< limit, isComplete: input.isComplete && limit == count)
            after[end] = vector(analysis?.words, last: false)
            if let analysis {
                consider(analysis.rows, over: end ..< limit) { UInt32($0 - end) }
            }
        }
        return PositionAnalyses(before: before, after: after, context: context)
    }

    /// What the second pass reads besides the first pass's shape: see `evidence(of:analyzer:starts:ends:morphology:)`
    struct Evidence {
        var before: [[UInt32]]
        var after: [[UInt32]]
        /// The morphology with the keys after each likely end read by the analysis from that end, so that the Japanese
        /// right after a Latin word is read on its own (uindou after Finder is ウインドウ, not でる|引導)
        var morphology: [[UInt32]]?
    }

    static func evidence(of input: TypedInput, analyzer: JapaneseAnalyzer, starts: [Int: Double], ends: [Int: Double], morphology: [[UInt32]]?) -> Evidence {
        let count = input.keys.count
        func step(_ value: Float, _ low: Float, _ high: Float) -> UInt32 {
            UInt32(max(low, min(high, value.rounded())) - low)
        }
        func analysis(_ range: Range<Int>, isComplete: Bool) -> (words: [JapaneseAnalyzer.Word]?, input: TypedInput?) {
            let text = Self.romajiText(of: input.elements[range], isComplete: isComplete)
            let key = String(input.keys[range]).lowercased() + (isComplete ? "." : "")
            if let cached = Self.evidenceCache[key] {
                return (cached, TypedInput(text))
            }
            let words = analyzer.analyze(text).flatMap { $0.isEmpty ? nil : $0 }
            if Self.evidenceCache.count >= 4096 {
                Self.evidenceCache.removeAll(keepingCapacity: true)
            }
            Self.evidenceCache[key] = words
            return (words, TypedInput(text))
        }
        func vector(_ words: [JapaneseAnalyzer.Word]?, last: Bool) -> [UInt32] {
            guard let words, let word = last ? words.last : words.first else {
                return [3, 0, 0, 0, 0, 0]
            }
            let characters = words.reduce(0) { $0 + $1.ruby.count }
            let total = words.reduce(Float(0)) { $0 + $1.value } / Float(max(characters, 1))
            let unknown = word.ruby == word.word && word.cid == CIDData.固有名詞.cid && word.mid == MIDData.一般.mid
                || word.ruby.contains(where: { $0.isASCII })
            return [2, UInt32(min(word.ruby.count, 6)), unknown ? 1 : 0, step(word.value / Float(max(word.ruby.count, 1)), -16, 0), UInt32(word.cid), step(total, -16, 0)]
        }
        var result = Evidence(before: [[UInt32]](repeating: Self.unselectedEvidence, count: count), after: [[UInt32]](repeating: Self.unselectedEvidence, count: count), morphology: morphology)
        for start in starts.keys where start < count {
            result.before[start] = start == 0 ? Self.edgeEvidence : vector(analysis(max(0, start - Self.evidenceWindow) ..< start, isComplete: true).words, last: true)
        }
        // The likelier an end, the later its analysis is written over the keys after it, so that it wins where the
        // windows overlap
        for (end, _) in ends.sorted(by: { $0.value < $1.value }) where end > 0 && end < count {
            let limit = min(count, end + Self.evidenceWindow)
            let (words, piece) = analysis(end ..< limit, isComplete: input.isComplete && limit == count)
            result.after[end] = vector(words, last: false)
            guard result.morphology != nil, let words, let piece else {
                continue
            }
            let rows = Self.keyMorphology(of: piece, words: words)
            for key in end ..< limit where key - end < rows.count {
                result.morphology?[key] = rows[key - end]
            }
        }
        return result
    }

    /// For each key: the length of the longest word of `lexicon` that starts at it, of the longest that ends with it,
    /// whether a word written with a capital inside starts at it (iPhone for iPhone or iphone), and whether it is inside
    /// one. Words of 2 to 12 letters, or `throughHyphens`, up to `maxWordLength` keys with hyphens between letters
    /// (e-mail is one word)
    static func lexicon(of keys: [Character], in lexicon: ScriptLexicon, throughHyphens: Bool = false) -> [[UInt8]] {
        var result = keys.map { _ in [UInt8](repeating: 0, count: 4) }
        for start in keys.indices where keys[start].isASCII && keys[start].isLetter {
            var end = start + 1
            while end <= min(keys.count, start + (throughHyphens ? Self.maxWordLength : 12)), Self.continuesWord(keys, at: end - 1, start: start, throughHyphens: throughHyphens) {
                defer { end += 1 }
                guard end - start >= 2 else {
                    continue
                }
                guard let spelling = lexicon.spelling(of: String(keys[start ..< end])) else {
                    continue
                }
                let length = UInt8(end - start)
                result[start][0] = max(result[start][0], length)
                result[end - 1][1] = max(result[end - 1][1], length)
                if spelling.dropFirst().contains(where: \.isUppercase) {
                    result[start][2] = 1
                    for index in start + 1 ..< end {
                        result[index][3] = 1
                    }
                }
            }
        }
        return result
    }

    /// Whether the key at `index` can be part of a Latin word that starts at `start`: a letter, or, `throughHyphens`, a
    /// hyphen between letters (the - of e-mail and built-in), so words joined by hyphens are one word
    static func continuesWord(_ keys: [Character], at index: Int, start: Int, throughHyphens: Bool) -> Bool {
        let key = keys[index]
        if key.isASCII && key.isLetter {
            return true
        }
        return throughHyphens && key == "-" && index > start && index + 1 < keys.count
            && keys[index - 1].isASCII && keys[index - 1].isLetter && keys[index + 1].isASCII && keys[index + 1].isLetter
    }

    /// For each key, what is known about the keys from it as one Latin word, for each length from 1 up to
    /// `maxWordLength` while the keys are letters, or hyphens between letters `throughHyphens` (none for a key that is
    /// not a letter), in one byte. The top 2 bits
    /// tell whether `lexicon` knows the word (1), written with a capital inside (2: github is GitHub); the lower 6 how
    /// much more Latin than romaji it reads for each character, by the character models, in quarters from -8 (32 is
    /// even). A word reads with its start and end: pig reads as a Latin word, butahapig does not
    static func words(of keys: [Character], models: CharacterModels?, lexicon: ScriptLexicon?, throughHyphens: Bool = false) -> [[UInt8]] {
        keys.indices.map { start in
            var result: [UInt8] = []
            let order = models?.latin.order ?? 1
            var history = Substring(String(repeating: "^", count: order - 1))
            var latin = 0.0
            var romaji = 0.0
            for end in start + 1 ... min(keys.count, start + Self.maxWordLength) {
                let key = keys[end - 1]
                guard Self.continuesWord(keys, at: end - 1, start: start, throughHyphens: throughHyphens) else {
                    break
                }
                var value: UInt8 = 32
                if let models {
                    let character = Character(key.lowercased())
                    latin += models.latin.logProbability(of: character, after: history)
                    romaji += models.romaji.logProbability(of: character, after: history)
                    history = Substring(String(history + String(character)).suffix(order - 1))
                    let difference = latin + models.latin.logProbability(of: "$", after: history) - romaji - models.romaji.logProbability(of: "$", after: history)
                    value = UInt8(max(0, min(63, (difference / Double(end - start + 1) * 4).rounded() + 32)))
                }
                if let spelling = lexicon?.knownSpelling(of: String(keys[start ..< end])) {
                    value |= (spelling.dropFirst().contains(where: \.isUppercase) ? 2 : 1) << 6
                }
                result.append(value)
            }
            return result
        }
    }

    /// For each key and each length of `words`, what the dictionary has for the kana of those keys (see
    /// `JapaneseAnalyzer.words(reading:)`), when they are a word of the lexicon of 3 letters or more typed in lower case
    /// that reads as whole kana (an n before the next key read as ん, as in token|wo): 0 when not looked up, else 64,
    /// plus 32 when a particle or an auxiliary reads so (made is まで), plus how rare the likeliest noun is (its value
    /// negated, 1 to 31; 0 for none). token reads as 都県, a rare word, and is likely the Latin word; sake reads as 酒,
    /// a common one
    static func readings(of input: TypedInput, words: [[UInt8]], analyzer: JapaneseAnalyzer) -> [[UInt8]] {
        words.enumerated().map { start, lengths in
            lengths.enumerated().map { offset, value -> UInt8 in
                let end = start + offset + 1
                guard offset >= 2, value >> 6 != 0, input.keys[start ..< end].allSatisfy({ $0.isASCII && $0.isLowercase }),
                      let kana = input.kana(of: start ..< end) else {
                    return 0
                }
                let words = analyzer.words(reading: kana)
                let rarity = words.noun.map { UInt8(max(1, min(31, (-$0.value).rounded()))) } ?? 0
                return 64 | (words.functionWord ? 32 : 0) | rarity
            }
        }
    }

    /// For each key, whether it is a letter romaji leaves unread for good: the letter stays in the kana of the whole
    /// input although keys come after it (the p of こーひーまpー1 for ko-hi-map-1, the g of ぶたはぴgです). Romaji only
    /// leaves the letters still being typed at the end, so a letter left inside says the keys around it are not romaji
    static func stranded(of input: TypedInput) -> [Bool] {
        let whole = input.prefixKana.last ?? ""
        return input.keys.indices.map { index in
            let upTo = input.prefixKana[index + 1]
            guard index < input.keys.count - 1 || input.isComplete, input.keys[index].isASCII, input.keys[index].isLetter,
                  let last = upTo.last, last.isASCII, last.isLetter, whole.hasPrefix(upTo) else {
                return false
            }
            return true
        }
    }

    // A flat list of feature templates, some only when the shape has what they read; splitting it would not make it
    // simpler, so disable the lint
    // swiftlint:disable cyclomatic_complexity
    /// For each key, the indices of its features among `dimension` (a power of 2). `trace` is told the template of each
    /// feature (key, template, index), to see what the score of a key is made of
    static func extract(keys: [Character], shape: KeyShape, dimension: Int, trace: ((Int, UInt32, Int) -> Void)? = nil) -> [[Int]] {
        let count = keys.count
        let boundary = shape.boundary
        let pending = shape.pending
        let codes = keys.map { UInt32($0.lowercased().unicodeScalars.first?.value ?? 0) }
        let cases = keys.map { key -> UInt32 in
            if key.isUppercase { 1 } else if key.isLetter { 0 } else if key.isNumber { 2 } else { 3 }
        }
        func code(_ index: Int) -> UInt32 {
            index < 0 ? 1 : index >= count ? 2 : codes[index] &+ 16
        }
        func caseAt(_ index: Int) -> UInt32 {
            index < 0 || index >= count ? 4 : cases[index]
        }
        func bit(_ value: Bool) -> UInt32 {
            value ? 1 : 0
        }
        var result: [[Int]] = []
        result.reserveCapacity(count)
        for index in 0 ..< count {
            var features: [Int] = []
            features.reserveCapacity(40)
            func add(_ template: UInt32, _ a: UInt32 = 0, _ b: UInt32 = 0, _ c: UInt32 = 0, _ d: UInt32 = 0, _ e: UInt32 = 0) {
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                for value in [template, a, b, c, d, e] {
                    hash = (hash ^ UInt64(value)) &* 0x0000_0100_0000_01b3
                }
                let feature = Int(truncatingIfNeeded: hash ^ (hash >> 29)) & (dimension - 1)
                features.append(feature)
                trace?(index, template, feature)
            }
            add(1)
            for offset in -3 ... 3 {
                add(2, UInt32(bitPattern: Int32(offset)), code(index + offset))
            }
            for offset in -2 ... 1 {
                add(3, UInt32(bitPattern: Int32(offset)), code(index + offset), code(index + offset + 1))
            }
            for offset in -2 ... 0 {
                add(4, UInt32(bitPattern: Int32(offset)), code(index + offset), code(index + offset + 1), code(index + offset + 2))
            }
            for offset in -3 ... 0 {
                add(5, UInt32(bitPattern: Int32(offset)), code(index + offset), code(index + offset + 1), code(index + offset + 2), code(index + offset + 3))
            }
            for offset in -2 ... 2 {
                add(6, UInt32(bitPattern: Int32(offset)), caseAt(index + offset))
            }
            add(7, caseAt(index - 2), caseAt(index - 1), caseAt(index), caseAt(index + 1), caseAt(index + 2))
            add(8, bit(boundary[index]))
            add(9, bit(boundary[index + 1]))
            add(10, bit(pending[index]))
            add(11, bit(index > 0 && pending[index - 1]))
            add(12, bit(boundary[index]), code(index))
            add(13, bit(pending[index]), code(index - 1), code(index))
            add(14, bit(index == 0))
            add(15, bit(index == count - 1))
            add(16, bit(index == count - 1 && !shape.isComplete))
            add(17, caseAt(index - 1), caseAt(index), bit(boundary[index]))
            add(18, code(index), caseAt(index))
            add(19, bit(boundary[index]), bit(pending[index]), caseAt(index))
            if let stranded = shape.stranded {
                // A letter romaji leaves unread for good (see `stranded(of:)`), and what follows it (map- in map-1)
                add(162, bit(stranded[index]))
                add(163, bit(stranded[index]), code(index + 1))
                add(164, bit(stranded[index]), bit(index > 0 && stranded[index - 1]), caseAt(index))
            }
            if let scores = shape.modelScores?[index] {
                func value(_ score: Int8) -> UInt32 {
                    UInt32(bitPattern: Int32(score))
                }
                add(20, value(scores[0]))
                add(21, value(scores[1]))
                add(22, value(scores[2]))
                add(23, value(scores[3]))
                add(24, value(scores[1]), value(scores[2]))
                add(25, value(scores[0]), caseAt(index), bit(boundary[index]))
                add(26, value(scores[3]), code(index + 1))
            }
            if let morphology = shape.morphology?[index] {
                if morphology != Self.noMorphology {
                    add(30, morphology[0])
                    add(31, morphology[1])
                    add(32, morphology[2])
                    add(33, morphology[3])
                    add(34, morphology[4])
                    add(35, morphology[5])
                    add(36, morphology[6])
                    add(37, morphology[0], morphology[4])
                    add(38, morphology[2], morphology[4], caseAt(index))
                    add(39, morphology[3], morphology[0])
                    add(40, morphology[5], morphology[1], morphology[0])
                } else {
                    add(30, 99)
                }
            }
            if let lexicon = shape.lexicon?[index] {
                let startsWord = UInt32(lexicon[0])
                let endsWord = UInt32(lexicon[1])
                add(50, startsWord)
                add(51, endsWord)
                add(52, UInt32(lexicon[2]), UInt32(lexicon[3]))
                add(53, startsWord, caseAt(index))
                add(54, endsWord, code(index + 1))
                add(55, startsWord, bit(boundary[index]))
                add(56, UInt32(index > 0 ? shape.lexicon![index - 1][1] : 0), startsWord)
                // A known Latin word ending just before a key where a word of the Japanese reading starts (hello|sekai)
                if let morphology = shape.morphology?[index], morphology != Self.noMorphology {
                    let endsBefore = UInt32(index > 0 ? shape.lexicon![index - 1][1] : 0)
                    add(57, endsBefore, morphology[0], morphology[4])
                    add(58, startsWord, morphology[0], morphology[5])
                    add(59, endsBefore, morphology[1], morphology[2])
                    add(60, UInt32(lexicon[3]), morphology[4], caseAt(index))
                }
            }
            if let context = shape.context?[index] {
                // The best reading of the key among the analyses from each position where a Latin word could end or
                // start (see `conditionedAnalyses`): a long word of the dictionary over the key says the keys around it
                // are Japanese however the whole input reads, and how far that position is says where the Latin word
                // would end
                let morphology = shape.morphology?[index] ?? Self.noMorphology
                add(133, context[0])
                add(134, context[1])
                add(135, context[2])
                add(136, context[3])
                add(137, context[4])
                add(138, context[5])
                add(139, context[6])
                add(140, context[7])
                add(141, context[0], context[4], context[7])
                add(142, context[2], context[4], caseAt(index))
                add(143, context[1], context[7])
                add(144, bit(context[1] > morphology[1]), context[4], morphology[4])
                add(145, context[1], context[5], context[0])
                add(146, context[3], context[0])
                if index > 0, let previous = shape.context?[index - 1] {
                    add(147, previous[1], previous[7], context[0])
                }
                if index + 1 < count, let next = shape.context?[index + 1] {
                    add(148, next[0], next[7], context[1])
                }
            }
            result.append(features)
        }
        return result
    }
    // swiftlint:enable cyclomatic_complexity
}

extension ScriptTaggerFeatures {
    /// For each key and each length a Latin word from it can have (see `words(of:models:lexicon:)`), the indices of the
    /// features of that word among `dimension` (a power of 2): `words[start][length - 1]`. `trace` is told the template
    /// of each feature (start, length, template, index)
    static func wordFeatures(keys: [Character], shape: KeyShape, dimension: Int, trace: ((Int, Int, UInt32, Int) -> Void)? = nil) -> [[[Int]]] {
        let count = keys.count
        let codes = keys.map { UInt32($0.lowercased().unicodeScalars.first?.value ?? 0) }
        func code(_ index: Int) -> UInt32 {
            index < 0 ? 1 : index >= count ? 2 : codes[index] &+ 16
        }
        func caseAt(_ index: Int) -> UInt32 {
            index < 0 || index >= count ? 4 : keys[index].isUppercase ? 1 : keys[index].isLetter ? 0 : keys[index].isNumber ? 2 : 3
        }
        func bit(_ value: Bool) -> UInt32 {
            value ? 1 : 0
        }
        // startsBefore[k]: the keys before k where a word of the analysis as Japanese starts; functionWordsBefore[k], where
        // a particle or an auxiliary starts (the converter's parts of speech 147...554: は, を, です)
        var startsBefore = [0]
        var functionWordsBefore = [0]
        for index in 0 ..< count {
            let analysis = shape.morphology.map { $0[index] } ?? Self.noMorphology
            let starts = analysis != Self.noMorphology && analysis[0] == 1
            startsBefore.append(startsBefore[index] + (starts ? 1 : 0))
            functionWordsBefore.append(functionWordsBefore[index] + (starts && 147 ... 554 ~= analysis[3] ? 1 : 0))
        }
        return shape.words.enumerated().map { start, lengths in
            lengths.enumerated().map { offset, value in
                let length = offset + 1
                let end = start + length
                var features: [Int] = []
                features.reserveCapacity(20)
                func add(_ template: UInt32, _ a: UInt32 = 0, _ b: UInt32 = 0, _ c: UInt32 = 0, _ d: UInt32 = 0) {
                    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                    for value in [template, a, b, c, d] {
                        hash = (hash ^ UInt64(value)) &* 0x0000_0100_0000_01b3
                    }
                    let feature = Int(truncatingIfNeeded: hash ^ (hash >> 29)) & (dimension - 1)
                    features.append(feature)
                    trace?(start, length, template, feature)
                }
                let known = UInt32(value >> 6)
                let reading = UInt32(value & 63)
                let size = UInt32(min(length, 12))
                let word = keys[start ..< end]
                // A capital at the start, one inside, all capitals
                let spelling = bit(word.first!.isUppercase) | bit(word.dropFirst().contains(where: \.isUppercase)) << 1 | bit(word.allSatisfy(\.isUppercase)) << 2
                add(100, size)
                add(101, known, size)
                add(102, known, spelling)
                add(103, reading)
                add(104, reading, size)
                add(105, reading, known)
                add(106, spelling, size)
                // Whether the word reads as whole romaji on its own (hoteru), or leaves letters (pig)
                add(107, bit(shape.boundary[start] && shape.boundary[end]), known, size)
                add(108, code(start - 1), caseAt(start))
                add(109, code(end), code(end + 1))
                add(110, code(end), known)
                add(111, bit(start == 0), spelling, known)
                add(112, bit(end == count), bit(shape.isComplete), size)
                add(113, code(start), code(start + 1), size)
                add(114, code(end - 2), code(end - 1))
                add(115, bit(shape.pending[end - 1]), bit(shape.boundary[end]), known)
                if let morphology = shape.morphology {
                    // What the analysis as Japanese says where the word starts and right after it: a word of the reading
                    // starting after it (hello|sekai), or the word lining up with one of the reading (anime is アニメ)
                    let first = morphology[start]
                    let after = end < count ? morphology[end] : Self.noMorphology
                    add(116, after[0], after[4], known)
                    add(117, first[0], after == Self.noMorphology ? 2 : after[0], first[5], known)
                    add(118, first[3], spelling)
                    add(119, after[3], known)
                    // The word is exactly one word of the reading (anime is アニメ, Ogura is 小倉), how common that word
                    // is, and what it is written in
                    let single = first[0] == 1 && (end == count || after[0] == 1) && startsBefore[end] - startsBefore[start + 1] == 0
                    add(120, bit(single) | spelling << 1, first[2], first[5], known)
                    add(121, bit(single), first[3], known)
                    // Words of the reading starting inside the word, and whether one is a particle or an auxiliary: a
                    // name typed with a capital is one word (Ogura is 小倉), not a sentence (Sakehasake is 酒は酒)
                    let inside = startsBefore[end] - startsBefore[start + 1]
                    add(122, UInt32(min(inside, 3)), bit(functionWordsBefore[end] - functionWordsBefore[start + 1] > 0), spelling, known)
                }
                if let readings = shape.readings, readings[start].indices.contains(offset), readings[start][offset] != 0 {
                    // What the dictionary has for the kana of the keys (see `readings(of:words:analyzer:)`): whether a
                    // particle or an auxiliary reads so, and how rare the likeliest noun is (0 for none)
                    let found = readings[start][offset]
                    let kind = UInt32(found >> 5 & 1)
                    let rarity = UInt32(found & 31)
                    add(150, kind, rarity)
                    add(151, kind, rarity, known)
                    add(152, kind, rarity / 2, size)
                    add(153, kind, rarity / 2, reading / 4)
                }
                if word.contains("-") {
                    // Words joined by hyphens (e-mail, built-in): how many, whether the lexicon knows the whole, and
                    // whether a part is a single letter (e-mail, x-ray)
                    let hyphens = UInt32(min(2, word.filter { $0 == "-" }.count))
                    let singleLetterPart = word.split(separator: "-").contains { $0.count == 1 }
                    add(165, hyphens, known)
                    add(166, hyphens, bit(singleLetterPart), spelling)
                    add(167, hyphens, reading / 8)
                }
                if let stranded = shape.stranded {
                    // Letters romaji leaves unread inside the word (see `stranded(of:)`)
                    let count = UInt32(min(3, stranded[start ..< end].filter { $0 }.count))
                    add(159, count, known)
                    add(160, count, bit(end == shape.words.count))
                }
                if let before = shape.before, let after = shape.after {
                    // The second pass: how the Japanese before the word and after it read on their own, when the first
                    // pass found the word likely (see `evidence`): a word of the reading right after (Web|pe-ji is Web
                    // and ページ), one the dictionary does not know (Webp|e-ji leaves e-ji), and how well each side reads
                    let left = before[start]
                    let right = end == count ? Self.edgeEvidence : after[end]
                    add(125, right[0], right[1], right[2], known)
                    add(126, right[0], right[4], known)
                    add(127, right[0], right[3], right[5], spelling)
                    add(128, left[0], left[1], left[2], known)
                    add(129, left[0], left[4], known)
                    add(130, left[0], left[3], right[0], right[3])
                    add(131, right[0], right[1], right[2], size)
                    add(132, left[0], left[5], right[5], known)
                }
                return features
            }
        }
    }
}

/// Words the tagger knows as Latin words, with how each is written when it has a capital inside (github is GitHub).
/// Read from lexicon.tsv (word<TAB>spelling), so the tagger learns and runs with the same words, unlike the system spell
/// checker, which depends on the macOS version and what the user taught it
struct ScriptLexicon: Sendable {
    private let spellings: [String: String]

    init(contentsOf url: URL) throws {
        var spellings: [String: String] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if parts.count == 2 {
                spellings[String(parts[0])] = String(parts[1])
            }
        }
        self.spellings = spellings
    }

    /// How a known word is written, whatever the capitals typed
    func knownSpelling(of typed: String) -> String? {
        self.spellings[typed.lowercased()]
    }

    /// How `typed` is written if it is a known word: the capitals typed are kept, and a known spelling adds its own
    /// (iphone and iPhone are iPhone)
    func spelling(of typed: String) -> String? {
        guard let spelling = self.spellings[typed.lowercased()] else {
            return nil
        }
        return String(zip(typed, spelling).map { $0.isUppercase || $1.isUppercase ? Character($0.uppercased()) : $0 })
    }
}

/// The weights of the tagger
struct ScriptTaggerModel: Sendable {
    static let tagCount = ScriptTag.allCases.count
    /// Number of feature indices the features are hashed into
    let dimension: Int
    /// For each feature index of a key, one weight for each tag
    var weights: [Float]
    /// For each feature index of a Latin word as a whole, its weight
    var wordWeights: [Float]
    /// Scores of a tag after a tag, and of the first tag
    var transitions: [Float]
    var starts: [Float]

    init(dimension: Int) {
        self.dimension = dimension
        self.weights = [Float](repeating: 0, count: dimension * Self.tagCount)
        self.wordWeights = [Float](repeating: 0, count: dimension)
        self.transitions = [Float](repeating: 0, count: Self.tagCount * Self.tagCount)
        self.starts = [Float](repeating: 0, count: Self.tagCount)
    }

    private static let magic: UInt32 = 0x4F47_5433  // OGT3

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let floats = data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
        let header = data.withUnsafeBytes { buffer in
            (buffer.load(fromByteOffset: 0, as: UInt32.self), buffer.load(fromByteOffset: 4, as: UInt32.self))
        }
        let tags = Self.tagCount
        let dimension = Int(header.1)
        let weightsStart = 2 + tags + tags * tags
        guard header.0 == Self.magic, header.1.nonzeroBitCount == 1, floats.count == weightsStart + dimension * (tags + 1) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.dimension = dimension
        self.starts = Array(floats[2 ..< 2 + tags])
        self.transitions = Array(floats[2 + tags ..< weightsStart])
        self.weights = Array(floats[weightsStart ..< weightsStart + dimension * tags])
        self.wordWeights = Array(floats[(weightsStart + dimension * tags)...])
    }

    func write(to url: URL) throws {
        var data = Data()
        withUnsafeBytes(of: Self.magic) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(self.dimension)) { data.append(contentsOf: $0) }
        for array in [self.starts, self.transitions, self.weights, self.wordWeights] {
            array.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }

    /// What the tagger reads about an input: the features of each key, and of each run of keys as one Latin word
    /// (`words[start][length - 1]`)
    struct Features {
        var keys: [[Int]]
        var words: [[[Int]]]
        /// The convert key was pressed after the keys
        var isComplete = true
        /// For each key, whether it is a capital (a word with one was typed with Shift on purpose)
        var capitals: [Bool] = []
    }

    func features(keys: [Character], shape: ScriptTaggerFeatures.KeyShape) -> Features {
        Features(
            keys: ScriptTaggerFeatures.extract(keys: keys, shape: shape, dimension: self.dimension),
            words: ScriptTaggerFeatures.wordFeatures(keys: keys, shape: shape, dimension: self.dimension),
            isComplete: shape.isComplete,
            capitals: keys.map(\.isUppercase)
        )
    }

    /// The scores of every way to read the input, with the costs of `decoding` on its Latin words
    func lattice(_ features: Features, decoding: ScriptTaggerDecoding = .init()) -> ScriptTaggerLattice {
        let count = features.keys.count
        // capitalsBefore[k]: the capitals among the keys before k
        var capitalsBefore = [0]
        for index in 0 ..< count {
            capitalsBefore.append(capitalsBefore[index] + (features.capitals.indices.contains(index) && features.capitals[index] ? 1 : 0))
        }
        return ScriptTaggerLattice(
            emissions: features.keys.map { indices in
                (0 ..< Self.tagCount).map { tag in indices.reduce(0.0) { $0 + Double(self.weights[$1 * Self.tagCount + tag]) } }
            },
            words: features.words.enumerated().map { start, lengths in
                lengths.enumerated().map { offset, indices in
                    indices.reduce(0.0) { $0 + Double(self.wordWeights[$1]) }
                        - Double(decoding.cost(withCapital: capitalsBefore[start + offset + 1] > capitalsBefore[start], endingAt: start + offset + 1, count: count, isComplete: features.isComplete))
                }
            },
            transitions: self.transitions.map(Double.init),
            starts: self.starts.map(Double.init)
        )
    }

    /// The best tags for the keys
    func tags(_ features: Features, decoding: ScriptTaggerDecoding = .init()) -> [ScriptTag] {
        self.lattice(features, decoding: decoding).best()
    }

    /// For each key, the probability of each tag given all the keys
    func marginals(_ features: Features, decoding: ScriptTaggerDecoding = .init()) -> [[Float]] {
        let lattice = self.lattice(features, decoding: decoding)
        return lattice.posteriors(lattice.sums()).keys.map { $0.map(Float.init) }
    }
}

/// Costs on Latin words when the tagger decides, set on held-out sentences after training.
/// The training samples have far more Latin words than what people type, so the tagger needs a word to be likelier than
/// it learned before showing it: less so for a word typed with a capital (Apple, iPad), which Shift says is meant, and
/// more so for a word still being typed, which the next keys may turn into romaji
struct ScriptTaggerDecoding: Sendable {
    /// Cost of a Latin word typed in lower case
    var wordCost: Float = 0
    /// Cost of a Latin word typed with a capital in it
    var capitalCost: Float = 0
    /// More cost for a Latin word that reaches the end of input still being typed
    var typingCost: Float = 0
    /// The cost of a Latin word typed in lower case when Zenzai checks whether the Japanese reading is natural (see
    /// `SegmentsManager.keepingNaturalJapanese`), if the model has one: the check keeps natural Japanese, so the cost can
    /// be lower and let more words read badly as Japanese be Latin (tokenを送ってください)
    var checkedWordCost: Float?
    /// The cost of a Latin word typed in lower case that is still being typed, when it differs from the word cost: it
    /// reaches the end of input, or only letters romaji has not read yet follow it (`TypedInput.typingFrom`). Zenzai
    /// checks only words with whole kana after them, so such a word keeps the cost it had without the check (one in
    /// yorosikuoneg is not shown as letters before the check can tell it is お願い)
    var typingWordCost: Float?

    init(wordCost: Float = 0, capitalCost: Float = 0, typingCost: Float = 0) {
        self.wordCost = wordCost
        self.capitalCost = capitalCost
        self.typingCost = typingCost
    }

    /// Reads decoding.tsv (name<TAB>value lines)
    init(contentsOf url: URL) throws {
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2, let value = Float(parts[1]) else {
                continue
            }
            switch parts[0] {
            case "word": self.wordCost = value
            case "capital": self.capitalCost = value
            case "typing": self.typingCost = value
            case "checkedWord": self.checkedWordCost = value
            default: break
            }
        }
    }

    func write(to url: URL) throws {
        try "word\t\(self.wordCost)\ncapital\t\(self.capitalCost)\ntyping\t\(self.typingCost)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    /// The costs when Zenzai checks the Japanese readings: the checked word cost in place of the word cost, but for
    /// words still being typed
    var checked: ScriptTaggerDecoding {
        var checked = self
        checked.wordCost = self.checkedWordCost ?? self.wordCost
        checked.typingWordCost = self.wordCost
        return checked
    }

    /// The cost of a Latin word that ends before the key at `end` of `count` keys
    /// - Parameter typingFrom: Where the keys romaji has not read yet start at the end (`TypedInput.typingFrom`), for
    ///   the typing word cost; the end of input when not given
    func cost(withCapital: Bool, endingAt end: Int, count: Int, isComplete: Bool, typingFrom: Int? = nil) -> Float {
        let atEnd = end == count && !isComplete
        if withCapital {
            return self.capitalCost + (atEnd ? self.typingCost : 0)
        }
        if let typingWordCost, !isComplete, end >= (typingFrom ?? count) {
            return typingWordCost + (atEnd ? self.typingCost : 0)
        }
        return self.wordCost + (atEnd ? self.typingCost : 0)
    }

    /// Word scores (`words[start][length - 1]`) with the costs taken off, for keys of which `capitals` are capitals
    func applied(to words: [[Double]], capitals: [Bool], isComplete: Bool, typingFrom: Int? = nil) -> [[Double]] {
        var capitalsBefore = [0]
        for capital in capitals {
            capitalsBefore.append(capitalsBefore.last! + (capital ? 1 : 0))
        }
        return words.enumerated().map { start, lengths in
            lengths.enumerated().map { offset, score in
                let end = start + offset + 1
                return score - Double(self.cost(withCapital: capitalsBefore[end] > capitalsBefore[start], endingAt: end, count: capitals.count, isComplete: isComplete, typingFrom: typingFrom))
            }
        }
    }
}

/// What scores every way to read an input: the linear model (`ScriptTaggerModel`) or the neural one
/// (`NeuralScriptScorer`)
protocol ScriptScorer: Sendable {
    func lattice(keys: [Character], shape: ScriptTaggerFeatures.KeyShape) -> ScriptTaggerLattice
}

extension ScriptTaggerModel: ScriptScorer {
    func lattice(keys: [Character], shape: ScriptTaggerFeatures.KeyShape) -> ScriptTaggerLattice {
        self.lattice(self.features(keys: keys, shape: shape))
    }
}

/// The scores of every way to split an input into romaji keys and Latin words (a semi-Markov lattice), in log space.
/// Each key is romaji on its own (J), or part of a Latin word of letters only, of up to `maxWordLength` keys, whose
/// first key is B and the others I. A word scores as a whole, by its keys, and by the transitions between them
struct ScriptTaggerLattice {
    private static let (romaji, begin, inside) = (ScriptTag.japanese.rawValue, ScriptTag.latinBegin.rawValue, ScriptTag.latinInside.rawValue)
    /// Score of each tag for each key
    let emissions: [[Double]]
    /// `words[start][length - 1]`: the score of the keys from `start` as one Latin word, besides the scores of its keys.
    /// A key has as many lengths as letters run from it, up to `maxWordLength`
    let words: [[Double]]
    let transitions: [Double]
    let starts: [Double]
    /// `insideBefore[k]`: the sum of the I scores of the keys before k
    private let insideBefore: [Double]

    init(emissions: [[Double]], words: [[Double]], transitions: [Double], starts: [Double]) {
        self.emissions = emissions
        self.words = words
        self.transitions = transitions
        self.starts = starts
        var sums = [0.0]
        for scores in emissions {
            sums.append(sums.last! + scores[Self.inside])
        }
        self.insideBefore = sums
    }

    var count: Int {
        self.emissions.count
    }

    /// The lattice with the costs of `decoding` taken off its Latin words, for keys of which `capitals` are capitals
    func applying(_ decoding: ScriptTaggerDecoding, capitals: [Bool], isComplete: Bool, typingFrom: Int? = nil) -> ScriptTaggerLattice {
        ScriptTaggerLattice(
            emissions: self.emissions,
            words: decoding.applied(to: self.words, capitals: capitals, isComplete: isComplete, typingFrom: typingFrom),
            transitions: self.transitions,
            starts: self.starts
        )
    }

    private func transition(_ from: Int, _ to: Int) -> Double {
        self.transitions[from * ScriptTaggerModel.tagCount + to]
    }

    /// The score of the word of `length` keys from `start`: the word, its keys, and the transitions inside it
    func wordScore(_ start: Int, _ length: Int) -> Double {
        var score = self.emissions[start][Self.begin] + self.words[start][length - 1]
        if length >= 2 {
            score += self.insideBefore[start + length] - self.insideBefore[start + 1] + self.transition(Self.begin, Self.inside)
                + Double(length - 2) * self.transition(Self.inside, Self.inside)
        }
        return score
    }

    /// The tag of the last key of a word
    static func lastTag(ofWordOf length: Int) -> Int {
        length == 1 ? Self.begin : Self.inside
    }

    private static func logSumExp(_ a: Double, _ b: Double) -> Double {
        let maximum = max(a, b)
        guard maximum > -.infinity else {
            return -.infinity
        }
        return maximum + log(exp(a - maximum) + exp(b - maximum))
    }

    /// The sums over all ways to read the keys (forward-backward)
    struct Sums {
        /// `forward[k][tag]`: all ways to read the keys before k whose last key has `tag`
        var forward: [[Double]]
        /// `backward[k][tag]`: all ways to read the keys from k on, after a key with `tag`
        var backward: [[Double]]
        /// For each key: all ways to read the keys before it and go on to it as romaji, or as the start of a word
        var enterRomaji: [Double]
        var enterWord: [Double]
        /// For each key: all ways to read it as romaji and the keys after it, or a word from it and the keys after it
        var leaveRomaji: [Double]
        var leaveWord: [Double]
        var logZ: Double
    }

    func sums() -> Sums {
        let count = self.count
        let tags = ScriptTaggerModel.tagCount
        var forward = [[Double]](repeating: [Double](repeating: -.infinity, count: tags), count: count + 1)
        var enterRomaji = [Double](repeating: -.infinity, count: count)
        var enterWord = [Double](repeating: -.infinity, count: count)
        for end in stride(from: 1, through: count, by: 1) {
            let position = end - 1
            if position == 0 {
                enterRomaji[0] = self.starts[Self.romaji]
                enterWord[0] = self.starts[Self.begin]
            } else {
                for from in 0 ..< tags {
                    enterRomaji[position] = Self.logSumExp(enterRomaji[position], forward[position][from] + self.transition(from, Self.romaji))
                    enterWord[position] = Self.logSumExp(enterWord[position], forward[position][from] + self.transition(from, Self.begin))
                }
            }
            forward[end][Self.romaji] = enterRomaji[position] + self.emissions[position][Self.romaji]
            for length in stride(from: 1, through: min(end, ScriptTaggerFeatures.maxWordLength), by: 1) where self.words[end - length].count >= length {
                let tag = Self.lastTag(ofWordOf: length)
                forward[end][tag] = Self.logSumExp(forward[end][tag], enterWord[end - length] + self.wordScore(end - length, length))
            }
        }
        var backward = [[Double]](repeating: [Double](repeating: 0, count: tags), count: count + 1)
        var leaveRomaji = [Double](repeating: -.infinity, count: count)
        var leaveWord = [Double](repeating: -.infinity, count: count)
        for start in stride(from: count - 1, through: 0, by: -1) {
            leaveRomaji[start] = self.emissions[start][Self.romaji] + backward[start + 1][Self.romaji]
            for length in stride(from: 1, through: self.words[start].count, by: 1) {
                leaveWord[start] = Self.logSumExp(leaveWord[start], self.wordScore(start, length) + backward[start + length][Self.lastTag(ofWordOf: length)])
            }
            for tag in 0 ..< tags {
                backward[start][tag] = Self.logSumExp(self.transition(tag, Self.romaji) + leaveRomaji[start], self.transition(tag, Self.begin) + leaveWord[start])
            }
        }
        let logZ = count == 0 ? 0 : Self.logSumExp(self.starts[Self.romaji] + leaveRomaji[0], self.starts[Self.begin] + leaveWord[0])
        return Sums(forward: forward, backward: backward, enterRomaji: enterRomaji, enterWord: enterWord, leaveRomaji: leaveRomaji, leaveWord: leaveWord, logZ: logZ)
    }

    /// The probability of each tag for each key, and of each word (`words[start][length - 1]`)
    func posteriors(_ sums: Sums) -> (keys: [[Double]], words: [[Double]]) {
        let count = self.count
        var keys = [[Double]](repeating: [Double](repeating: 0, count: ScriptTaggerModel.tagCount), count: count)
        var words = self.words.map { [Double](repeating: 0, count: $0.count) }
        // Where the words that keys are inside of start and end
        var inside = [Double](repeating: 0, count: count + 1)
        for start in 0 ..< count {
            keys[start][Self.romaji] = exp(sums.enterRomaji[start] + sums.leaveRomaji[start] - sums.logZ)
            for length in stride(from: 1, through: self.words[start].count, by: 1) {
                let probability = exp(sums.enterWord[start] + self.wordScore(start, length) + sums.backward[start + length][Self.lastTag(ofWordOf: length)] - sums.logZ)
                words[start][length - 1] = probability
                keys[start][Self.begin] += probability
                if length >= 2 {
                    inside[start + 1] += probability
                    inside[start + length] -= probability
                }
            }
        }
        var running = 0.0
        for index in 0 ..< count {
            running += inside[index]
            keys[index][Self.inside] = running
        }
        return (keys, words)
    }

    /// The expected number of each transition and of each first tag, from the probabilities of the words
    func expectedTransitions(_ sums: Sums, words: [[Double]]) -> (transitions: [Double], starts: [Double]) {
        let tags = ScriptTaggerModel.tagCount
        var transitions = [Double](repeating: 0, count: tags * tags)
        var starts = [Double](repeating: 0, count: tags)
        guard self.count > 0 else {
            return (transitions, starts)
        }
        starts[Self.romaji] = exp(self.starts[Self.romaji] + sums.leaveRomaji[0] - sums.logZ)
        starts[Self.begin] = exp(self.starts[Self.begin] + sums.leaveWord[0] - sums.logZ)
        for position in 1 ..< self.count {
            for from in 0 ..< tags where sums.forward[position][from] > -.infinity {
                transitions[from * tags + Self.romaji] += exp(sums.forward[position][from] + self.transition(from, Self.romaji) + sums.leaveRomaji[position] - sums.logZ)
                transitions[from * tags + Self.begin] += exp(sums.forward[position][from] + self.transition(from, Self.begin) + sums.leaveWord[position] - sums.logZ)
            }
        }
        for lengths in words {
            for (offset, probability) in lengths.enumerated() where offset >= 1 {
                transitions[Self.begin * tags + Self.inside] += probability
                transitions[Self.inside * tags + Self.inside] += probability * Double(offset - 1)
            }
        }
        return (transitions, starts)
    }

    /// The best way to read the keys (Viterbi): the tag of each key
    func best() -> [ScriptTag] {
        let count = self.count
        let tags = ScriptTaggerModel.tagCount
        guard count > 0 else {
            return []
        }
        var scores = [[Double]](repeating: [Double](repeating: -.infinity, count: tags), count: count + 1)
        // For each end and tag of the last key: where the last piece starts, and the tag of the key before it
        var back = [[(start: Int, previous: Int)]](repeating: [(start: Int, previous: Int)](repeating: (0, 0), count: tags), count: count + 1)
        func entering(_ position: Int, _ tag: Int) -> (score: Double, from: Int) {
            guard position > 0 else {
                return (self.starts[tag], 0)
            }
            var best = (score: -Double.infinity, from: 0)
            for from in 0 ..< tags where scores[position][from] + self.transition(from, tag) > best.score {
                best = (scores[position][from] + self.transition(from, tag), from)
            }
            return best
        }
        for end in 1 ... count {
            let romaji = entering(end - 1, Self.romaji)
            scores[end][Self.romaji] = romaji.score + self.emissions[end - 1][Self.romaji]
            back[end][Self.romaji] = (end - 1, romaji.from)
            for length in stride(from: 1, through: min(end, ScriptTaggerFeatures.maxWordLength), by: 1) where self.words[end - length].count >= length {
                let start = end - length
                let into = entering(start, Self.begin)
                let score = into.score + self.wordScore(start, length)
                let tag = Self.lastTag(ofWordOf: length)
                if score > scores[end][tag] {
                    scores[end][tag] = score
                    back[end][tag] = (start, into.from)
                }
            }
        }
        var result = [ScriptTag](repeating: .japanese, count: count)
        var end = count
        var tag = (0 ..< tags).max { scores[count][$0] < scores[count][$1] }!
        while end > 0 {
            let (start, previous) = back[end][tag]
            if tag != Self.romaji {
                result[start] = .latinBegin
                for index in start + 1 ..< end {
                    result[index] = .latinInside
                }
            }
            end = start
            tag = previous
        }
        return result
    }
}

/// The identification layer by the learned tagger
struct TaggerScriptIdentifier: ScriptIdentifier {
    let scorer: any ScriptScorer
    let decoding: ScriptTaggerDecoding
    let characterModels: ScriptTaggerFeatures.CharacterModels?
    /// Analyzes the input as Japanese, when the model was trained with that analysis
    let analyzer: JapaneseAnalyzer?
    /// Analyzes the keys around likely boundaries for the second pass, in its own session, so the analysis of the whole
    /// input goes on from one key to the next
    let evidenceAnalyzer: JapaneseAnalyzer?
    /// The words the model was trained to look the letters up in, if any
    let lexicon: ScriptLexicon?
    /// Looks up the dictionary's words for the kana of words of the lexicon typed, when the model reads them (the
    /// readings file in its directory)
    let readingWords: JapaneseAnalyzer?
    /// Whether the model reads the letters romaji leaves unread (the stranded file in its directory)
    let readsStranded: Bool
    /// Whether the model reads words joined by hyphens as one word (the hyphens file in its directory)
    let readsHyphens: Bool
    /// The model of the second pass (the stage2 directory), which also reads the analyses of the Japanese on each side
    /// of the Latin words the first pass finds likely (see `ScriptTaggerFeatures.evidence`), and its decoding costs
    let secondPass: (scorer: any ScriptScorer, decoding: ScriptTaggerDecoding)?
    /// Whether the model reads the analyses around every position (the evidence file in its directory; see
    /// `ScriptTaggerFeatures.conditionedAnalyses`)
    let readsEvidence: Bool

    /// Reads the model (neural.bin, or else tagger.bin), and romaji.tsv, latin.tsv, and decoding.tsv when they are there,
    /// from `directory`, once for each directory. With `converter`, the input is also analyzed as Japanese, for a model
    /// trained with that analysis. With `naturalnessChecked`, Zenzai checks the Japanese readings of the words the layer
    /// finds Latin, and the decoding costs for that are used (`ScriptTaggerDecoding.checked`)
    init(modelDirectory directory: URL, converter: KanaKanjiConverter? = nil, naturalnessChecked: Bool = false) throws {
        self.analyzer = converter.map { JapaneseAnalyzer(converter: $0) }
        self.readingWords = FileManager.default.fileExists(atPath: directory.appendingPathComponent("readings").path) ? self.analyzer : nil
        self.readsStranded = FileManager.default.fileExists(atPath: directory.appendingPathComponent("stranded").path)
        self.readsHyphens = FileManager.default.fileExists(atPath: directory.appendingPathComponent("hyphens").path)
        self.evidenceAnalyzer = converter.map { JapaneseAnalyzer(converter: $0, fast: true) }
        self.readsEvidence = FileManager.default.fileExists(atPath: directory.appendingPathComponent("evidence").path)
        self.evidenceGate = (try? String(contentsOf: directory.appendingPathComponent("gate"), encoding: .utf8))
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? Self.defaultEvidenceGate
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("nogrowing").path) {
            ScriptTaggerFeatures.growingWindows = false
        }
        let decoding = (try? ScriptTaggerDecoding(contentsOf: directory.appendingPathComponent("decoding.tsv"))) ?? .init()
        self.decoding = naturalnessChecked ? decoding.checked : decoding
        self.lexicon = FileManager.default.fileExists(atPath: directory.appendingPathComponent("lexicon").path)
            ? Self.lexicon(in: directory)
            : nil
        if let loaded = Self.loaded[directory] {
            (self.scorer, self.characterModels, self.secondPass) = (loaded.scorer, loaded.characterModels, loaded.secondPass)
        } else {
            self.scorer = try Self.scorer(in: directory)
            self.characterModels = try? ScriptTaggerFeatures.CharacterModels(directory: directory)
            let stage2 = directory.appendingPathComponent("stage2", isDirectory: true)
            self.secondPass = FileManager.default.fileExists(atPath: stage2.path)
                ? (try Self.scorer(in: stage2), (try? ScriptTaggerDecoding(contentsOf: stage2.appendingPathComponent("decoding.tsv"))) ?? self.decoding)
                : nil
            Self.loaded[directory] = Loaded(scorer: self.scorer, characterModels: self.characterModels, secondPass: self.secondPass)
        }
    }

    /// What a model directory holds, read once per process
    private struct Loaded {
        var scorer: any ScriptScorer
        var characterModels: ScriptTaggerFeatures.CharacterModels?
        var secondPass: (scorer: any ScriptScorer, decoding: ScriptTaggerDecoding)?
    }

    /// The decoding costs of the pass whose lattice decides
    var finalDecoding: ScriptTaggerDecoding {
        self.secondPass?.decoding ?? self.decoding
    }

    /// Where the first pass's lattice (with its decoding costs) has a Latin word likely enough to analyze the Japanese on
    /// its sides for the second pass: the starts and the ends of the words with a probability of `threshold` or more,
    /// at most `limit` words, the likeliest first
    nonisolated static func boundaries(of lattice: ScriptTaggerLattice, threshold: Double = 0.03, limit: Int = 6) -> (starts: [Int: Double], ends: [Int: Double]) {
        let probabilities = lattice.posteriors(lattice.sums()).words
        var candidates: [(probability: Double, word: Range<Int>)] = []
        for (start, lengths) in probabilities.enumerated() {
            for (offset, probability) in lengths.enumerated() where probability >= threshold {
                candidates.append((probability, start ..< start + offset + 1))
            }
        }
        let chosen = candidates.sorted { $0.probability > $1.probability }.prefix(limit)
        // Each boundary with the probability of the likeliest word it bounds
        var starts: [Int: Double] = [:]
        var ends: [Int: Double] = [:]
        for candidate in chosen {
            starts[candidate.word.lowerBound] = max(starts[candidate.word.lowerBound] ?? 0, candidate.probability)
            ends[candidate.word.upperBound] = max(ends[candidate.word.upperBound] ?? 0, candidate.probability)
        }
        return (starts, ends)
    }

    /// What the model reads about `input`'s keys, without the second pass's evidence or the analyses around every
    /// position (see `rawLattice(for:shape:)`)
    func shape(_ input: TypedInput) -> ScriptTaggerFeatures.KeyShape {
        .init(input, models: self.characterModels, analyzer: self.analyzer, lexicon: self.lexicon, readingWords: self.readingWords, stranded: self.readsStranded, hyphens: self.readsHyphens)
    }

    /// How likely a key has to be in a Latin word, by the model without the analyses around every position, for the
    /// model to read them: they cost an analysis for each of the last `evidenceWindow` positions at each key typed, which
    /// typing Japanese does not need. The gate file in the model directory sets it (0 reads them always)
    static let defaultEvidenceGate = 0.01
    let evidenceGate: Double

    /// `shape` with the analyses conditioned on the boundaries this model's first pass finds likely, for a second pass
    /// (this model's, or one being trained on this model's first pass)
    func conditionedShape(_ input: TypedInput, shape: ScriptTaggerFeatures.KeyShape) -> ScriptTaggerFeatures.KeyShape {
        guard let analyzer = self.evidenceAnalyzer else {
            return shape
        }
        let first = self.scorer.lattice(keys: input.keys, shape: shape).applying(self.decoding, capitals: input.keys.map(\.isUppercase), isComplete: input.isComplete, typingFrom: input.typingFrom)
        let (starts, ends) = Self.boundaries(of: first)
        let evidence = ScriptTaggerFeatures.evidence(of: input, analyzer: analyzer, starts: starts, ends: ends, morphology: shape.morphology)
        var conditioned = shape
        conditioned.before = evidence.before
        conditioned.after = evidence.after
        conditioned.morphology = evidence.morphology
        return conditioned
    }

    /// The lattice that decides the tags of `input`, before the decoding costs: the second pass's when there is one, from
    /// the first pass's likely boundaries, otherwise the first's
    func rawLattice(for input: TypedInput, shape: ScriptTaggerFeatures.KeyShape) -> ScriptTaggerLattice {
        guard let secondPass, self.analyzer != nil else {
            let lattice = self.scorer.lattice(keys: input.keys, shape: shape)
            // A model reading the analyses around every position gets them once a Latin word is plausible somewhere
            guard self.readsEvidence, let evidenceAnalyzer, shape.context == nil, !input.keys.isEmpty,
                  self.evidenceGate <= 0 || lattice.posteriors(lattice.sums()).keys.contains(where: { $0[1] + $0[2] >= self.evidenceGate }) else {
                return lattice
            }
            var evident = shape
            let analyses = ScriptTaggerFeatures.conditionedAnalyses(of: input, analyzer: evidenceAnalyzer)
            (evident.before, evident.after, evident.context) = (analyses.before, analyses.after, analyses.context)
            return self.scorer.lattice(keys: input.keys, shape: evident)
        }
        return secondPass.scorer.lattice(keys: input.keys, shape: self.conditionedShape(input, shape: shape))
    }

    func rawLattice(for input: TypedInput) -> ScriptTaggerLattice {
        self.rawLattice(for: input, shape: self.shape(input))
    }

    /// The model in `directory`: the linear one in tagger.bin, the neural one in neural.bin, or the neural one on top of
    /// the linear one when neural.bin says it learned so
    /// The networks in `directory` (neural.bin, and neural-*.bin for an ensemble, whose scores are averaged) on their own,
    /// or added to the linear model when they were trained on top of it; the linear model alone when there is none
    nonisolated static func scorer(in directory: URL) throws -> any ScriptScorer {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0 == "neural.bin" || $0.hasPrefix("neural-") && $0.hasSuffix(".bin") }
            .sorted()
        guard !names.isEmpty else {
            return try ScriptTaggerModel(contentsOf: directory.appendingPathComponent("tagger.bin"))
        }
        let networks = try names.map { try NeuralScriptScorer(contentsOf: directory.appendingPathComponent($0)) }
        let network: any ScriptScorer = networks.count == 1
            ? networks[0]
            : CombinedScriptScorer(scorers: networks, weights: networks.map { _ in 1 / Double(networks.count) })
        guard networks.contains(where: \.isOnLinearModel) else {
            return network
        }
        return CombinedScriptScorer(scorers: [try ScriptTaggerModel(contentsOf: directory.appendingPathComponent("tagger.bin")), network])
    }

    nonisolated(unsafe) private static var loaded: [URL: Loaded] = [:]
    nonisolated(unsafe) private static var loadedLexicons: [URL: ScriptLexicon] = [:]

    /// lexicon.tsv in `directory`, read once
    private static func lexicon(in directory: URL) -> ScriptLexicon? {
        if let lexicon = Self.loadedLexicons[directory] {
            return lexicon
        }
        let lexicon = try? ScriptLexicon(contentsOf: directory.appendingPathComponent("lexicon.tsv"))
        Self.loadedLexicons[directory] = lexicon
        return lexicon
    }

    func segment(_ input: TypedInput) -> ScriptSegmentation {
        let lattice = self.rawLattice(for: input).applying(self.finalDecoding, capitals: input.keys.map(\.isUppercase), isComplete: input.isComplete, typingFrom: input.typingFrom)
        let tags = lattice.best()
        var words: [LatinInputGuess.Span] = []
        var start: Int?
        for index in 0 ... tags.count {
            let tag = index < tags.count ? tags[index] : .japanese
            if tag != .latinInside, let begin = start {
                words.append(.init(word: self.writing(of: String(input.keys[begin ..< index])), keys: begin ..< index))
                start = nil
            }
            if tag == .latinBegin {
                start = index
            }
        }
        let romajiCapitals = tags.indices.filter { tags[$0] == .japanese && input.keys[$0].isASCII && input.keys[$0].isUppercase }
        let posteriors = lattice.posteriors(lattice.sums())
        var uncertain = self.uncertainWords(in: input, tags: tags, posteriors: posteriors)
        words.removeAll { word in uncertain.contains { $0.keys == word.keys } }
        var shorter = self.shorterWords(of: words, in: input, posteriors: posteriors.words)
        var longer = self.longerWords(of: words, in: input, tags: tags, posteriors: posteriors.words)
        var possible = self.possibleWords(in: input, tags: tags, posteriors: posteriors.words, uncertain: uncertain)
        if let clauseEnd = input.clauseEnd {
            // The end of the clause being converted cuts a Latin word it falls in, as the rules do: the letters on each
            // side stay letters (win|dows), rather than the model reading what is left of the word again
            words = words.flatMap { $0.split(at: clauseEnd) }
            uncertain.removeAll { $0.keys.lowerBound < clauseEnd && clauseEnd < $0.keys.upperBound }
            shorter.removeAll { $0.word.lowerBound < clauseEnd && clauseEnd < $0.word.upperBound }
            longer.removeAll { $0.word.lowerBound < clauseEnd && clauseEnd < $0.longer.keys.upperBound }
            possible.removeAll { $0.word.keys.lowerBound < clauseEnd && clauseEnd < $0.word.keys.upperBound }
        }
        return ScriptSegmentation(latinWords: words, romajiCapitals: romajiCapitals, uncertainWords: uncertain, shorterWords: shorter, longerWords: longer, possibleWords: possible)
    }

    /// How the letters `typed` are written: only a known spelling with a capital inside changes them (iphone is iPhone)
    private func writing(of typed: String) -> String {
        guard let known = self.lexicon?.spelling(of: typed), known.dropFirst().contains(where: \.isUppercase) else {
            return typed
        }
        return known
    }

    /// How likely a shorter word has to be for the converter to see it (see `ScriptSegmentation.shorterWords`)
    static let shorterWordThreshold = 0.01
    /// At most this many shorter words for each word, the likeliest
    static let shorterWordLimit = 2

    /// Where each of `words` may end earlier (see `ScriptSegmentation.shorterWords`): at a word the lexicon knows (Win,
    /// sign-in; not T-sha in T-shatsu: Zenzai cannot tell letters from kana after a word it does not know), or at one
    /// started with a capital, which the converter keeps when it is a name its dictionary knows (Osaka in Osakashi), from
    /// the same start, likely enough by `posteriors` (`ScriptTaggerLattice.posteriors`), with the keys left over to the
    /// word's end reading as romaji on their own, as the converter reads them after the shorter word (Mac|hakaku). Or
    /// where a word may start one key later, its first n being the ん of the kana before it (ん+map in sakuhinmap)
    private func shorterWords(of words: [LatinInputGuess.Span], in input: TypedInput, posteriors: [[Double]]) -> [ScriptSegmentation.ShorterWord] {
        var shorter: [ScriptSegmentation.ShorterWord] = []
        for word in words where word.keys.count >= 3 {
            let start = word.keys.lowerBound
            var candidates: [ScriptSegmentation.ShorterWord] = []
            for end in start + 2 ..< word.keys.upperBound where end - start - 1 < posteriors[start].count {
                let probability = posteriors[start][end - start - 1]
                let typed = String(input.keys[start ..< end])
                let known = self.knows(typed)
                guard probability >= Self.shorterWordThreshold, known || input.keys[start].isUppercase,
                      input.readsAsKana(end ..< word.keys.upperBound) else {
                    continue
                }
                candidates.append(.init(word: word.keys, shorter: .init(word: self.writing(of: typed), keys: start ..< end), probability: probability, known: known))
            }
            // The word without its first n, when that n closes the kana before it as ん (ん+map for sakuhinmap, read as
            // さくひ+nmap): a word the lexicon knows, likely enough from there
            let end = word.keys.upperBound
            if input.keys[start] == "n", start > 0, input.prefixKana[start + 1].last == "n", end - start - 2 < posteriors[start + 1].count {
                let probability = posteriors[start + 1][end - start - 2]
                let typed = String(input.keys[start + 1 ..< end])
                if probability >= Self.shorterWordThreshold, self.knows(typed) {
                    candidates.append(.init(word: word.keys, shorter: .init(word: self.writing(of: typed), keys: start + 1 ..< end), probability: probability))
                }
            }
            shorter += candidates.sorted { $0.probability > $1.probability }.prefix(Self.shorterWordLimit)
        }
        return shorter
    }

    /// At most this many longer words for each word, the likeliest
    static let longerWordLimit = 2

    /// Where each of `words` may end later (see `ScriptSegmentation.longerWords`): at a word the lexicon knows (Finder
    /// for Find in Finderuindou), from the same start, likely enough by `posteriors` (as for a shorter word), over
    /// lower-case letters the model read as romaji (`tags`) that romaji has read
    private func longerWords(of words: [LatinInputGuess.Span], in input: TypedInput, tags: [ScriptTag], posteriors: [[Double]]) -> [ScriptSegmentation.LongerWord] {
        var longer: [ScriptSegmentation.LongerWord] = []
        for word in words where word.keys.count >= 2 {
            let start = word.keys.lowerBound
            let last = min(input.typingFrom, start + posteriors[start].count)
            guard last > word.keys.upperBound else {
                continue
            }
            var candidates: [ScriptSegmentation.LongerWord] = []
            for end in word.keys.upperBound + 1 ... last {
                let key = input.keys[end - 1]
                guard tags[end - 1] == .japanese, key.isASCII, key.isLetter, key.isLowercase else {
                    break
                }
                let probability = posteriors[start][end - start - 1]
                let typed = String(input.keys[start ..< end])
                guard probability >= Self.shorterWordThreshold, self.knows(typed) else {
                    continue
                }
                candidates.append(.init(word: word.keys, longer: .init(word: self.writing(of: typed), keys: start ..< end), probability: probability))
            }
            longer += candidates.sorted { $0.probability > $1.probability }.prefix(Self.longerWordLimit)
        }
        return longer
    }

    /// Whether the lexicon knows `typed`, or each of its parts joined by hyphens, of two letters or more (sign-in; not
    /// T-sha)
    private func knows(_ typed: String) -> Bool {
        if self.lexicon?.spelling(of: typed) != nil {
            return true
        }
        let parts = typed.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count > 1 && parts.allSatisfy { $0.count >= 2 && self.lexicon?.spelling(of: String($0)) != nil }
    }

    /// How likely a word typed in lower case that the model reads as Japanese has to be for the converter to check it as
    /// letters (see `ScriptSegmentation.possibleWords`)
    static let possibleWordThreshold = 0.001
    /// At most this many such words, the likeliest
    static let possibleWordLimit = 2

    /// The words that the model reads as Japanese though the lexicon knows them (see `ScriptSegmentation.possibleWords`):
    /// likely enough by `posteriors`, of three letters or more, reading as Japanese in standard romaji, and with no letter
    /// left unread after them: kana read after them, since what follows is what makes a reading unnatural (のでを), or
    /// the end of the input, where what comes before has to tell (not while a consonant after them is still unread:
    /// homet is not yet 褒めて). A word that runs to the end of the input with its last letters unread (the m of zoom)
    /// is one too, by the kana its read part makes (ゾオ): the word is whole, and its reading up to there can be compared
    private func possibleWords(
        in input: TypedInput, tags: [ScriptTag], posteriors: [[Double]], uncertain: [ScriptSegmentation.UncertainWord]
    ) -> [ScriptSegmentation.PossibleWord] {
        var possible: [ScriptSegmentation.PossibleWord] = []
        for (start, lengths) in posteriors.enumerated() {
            for (offset, rawProbability) in lengths.enumerated() {
                let keys = start ..< start + offset + 1
                // The costs that keep a word still being typed off the best path (see `ScriptTaggerDecoding.typingCost`)
                // come off here: Zenzai's comparison is what makes letters at the end of the input safe, so a word there
                // is checked by its odds without them
                let probability = self.probabilityWithoutTypingCosts(rawProbability, keys: keys, input: input)
                let typed = String(input.keys[keys])
                guard probability >= Self.possibleWordThreshold, keys.count >= 3,
                      keys.upperBound <= input.typingFrom || keys.upperBound == input.keys.count, start + 2 <= input.typingFrom else {
                    continue
                }
                // The keys romaji has read, which read as kana: all of them, or those before the unread end of the input
                let read = keys.upperBound <= input.typingFrom ? keys : start ..< input.typingFrom
                guard keys.allSatisfy({ tags[$0] == .japanese }),
                      !uncertain.contains(where: { $0.keys.overlaps(keys) }),
                      typed.allSatisfy({ $0.isASCII && $0.isLetter && $0.isLowercase }), StandardRomaji.spells(input.keys[read]),
                      input.kana(of: read) != nil, self.lexicon?.spelling(of: typed) != nil else {
                    continue
                }
                possible.append(.init(word: .init(word: self.writing(of: typed), keys: keys), probability: probability))
            }
        }
        return Array(possible.sorted { $0.probability > $1.probability }.prefix(Self.possibleWordLimit))
    }

    /// `probability` of the word at `keys` with the decoding costs of a word still being typed taken off its odds (see
    /// `ScriptTaggerDecoding.cost`): the same when the word is not at the end of the input
    private func probabilityWithoutTypingCosts(_ probability: Double, keys: Range<Int>, input: TypedInput) -> Double {
        let decoding = self.finalDecoding
        let count = input.keys.count
        let extra = decoding.cost(withCapital: false, endingAt: keys.upperBound, count: count, isComplete: input.isComplete, typingFrom: input.typingFrom)
            - decoding.cost(withCapital: false, endingAt: keys.upperBound, count: count, isComplete: true)
        guard extra > 0, probability < 1 else {
            return probability
        }
        let odds = probability / (1 - probability) * exp(Double(extra))
        return odds / (1 + odds)
    }

    /// How sure the model has to be, either way, about a word typed in lower case that reads as Japanese for it to
    /// decide the word here; otherwise the converter decides (see `ScriptSegmentation.uncertainWords`)
    static let certainty = 0.95
    /// At most this many words are left to the converter, the likeliest
    static let uncertainWordLimit = 6

    /// The words the model is not sure about by `posteriors` (of the lattice with its decoding costs applied, see
    /// `ScriptTaggerLattice.posteriors`), typed in lower case and reading as Japanese in standard romaji (not cafe: c
    /// without h is typed as the word on purpose, so the model's own reading stands, as for a word typed with a capital).
    /// A word typed with a capital that the model reads as romaji all the same (`tags`; the T of Tokyotonisumu, read as
    /// と+kyoto) is one too when the lexicon knows it: the converter weighs it against the words it reads instead. The
    /// lexicon's spelling goes with the letters when it knows one (API for api)
    private func uncertainWords(in input: TypedInput, tags: [ScriptTag], posteriors: (keys: [[Double]], words: [[Double]])) -> [ScriptSegmentation.UncertainWord] {
        var uncertain: [ScriptSegmentation.UncertainWord] = []
        for (start, lengths) in posteriors.words.enumerated() {
            for (offset, probability) in lengths.enumerated() where probability > 1 - Self.certainty {
                let keys = start ..< start + offset + 1
                // Unsure between this word and romaji, not between ways to cut Latin letters (hello or hellose): the keys
                // read as romaji together are at most as likely as the one least likely to be romaji
                let romaji = keys.map { posteriors.keys[$0][ScriptTag.japanese.rawValue] }.min() ?? 0
                let typed = String(input.keys[keys])
                let withCapital = input.keys[start].isUppercase
                guard romaji > 1 - Self.certainty, typed.allSatisfy({ $0.isASCII && $0.isLetter }), typed.dropFirst().allSatisfy(\.isLowercase),
                      !withCapital || tags[start] == .japanese && self.lexicon?.spelling(of: typed) != nil,
                      StandardRomaji.spells(typed.lowercased()), input.kana(ofUncertain: keys) != nil else {
                    continue
                }
                let known = self.lexicon?.spelling(of: typed)
                uncertain.append(.init(word: typed, spelling: known == typed ? nil : known, keys: keys, probability: probability, romajiProbability: romaji))
            }
        }
        return Array(uncertain.sorted { $0.probability > $1.probability }.prefix(Self.uncertainWordLimit))
    }
}
