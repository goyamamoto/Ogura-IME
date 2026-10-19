import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

// The identification layer: which parts of romaji input are Latin words (English, names, code) rather than Japanese.
// `SegmentsManager` asks it about the input and turns its answer into what the converter sees.
// See docs/latin-identification.md.

/// The keys of the input, as the identification layer reads them
struct TypedInput {
    /// The keys typed. The convert key's separator is not a key
    var keys: [Character] = []
    /// The input element of each key
    var elements: [ComposingText.InputElement] = []
    /// Where each key is in the input it was read from
    var elementIndices: [Int] = []
    /// `prefixKana[i]` is the conversion of the first `i` keys
    var prefixKana = [""]
    /// The convert key was pressed, so the input is complete
    var isComplete = false
    /// The key that the clause being converted ends before, when Shift+← / → moved its end into the input: no Latin
    /// word runs across it, so moving the end into a Latin word splits it there (Sake|hasake)
    var clauseEnd: Int?

    /// Nil when a piece of the input is not a key. `clauseEnd` is the element of the input the clause being converted
    /// ends before, when its end was moved (see `SegmentsManager.clauseEnd`); without it, the cursor of the input says
    init?(_ composingText: ComposingText, clauseEnd: Int? = nil) {
        var prefix = ComposingText()
        for (index, element) in composingText.input.enumerated() {
            if case .compositionSeparator = element.piece {
                continue
            }
            guard let key = [element.piece].inputString(preferIntention: false).first else {
                return nil
            }
            self.keys.append(key)
            self.elements.append(element)
            self.elementIndices.append(index)
            prefix.insertAtCursorPosition([element])
            self.prefixKana.append(prefix.convertTarget)
        }
        self.isComplete = composingText.input.last?.piece == .compositionSeparator
        if let elementsBeforeEnd = clauseEnd ?? (composingText.isAtEndIndex ? nil : composingText.prefixToCursorPosition().input.count) {
            self.clauseEnd = self.elementIndices.filter { $0 < elementsBeforeEnd }.count
        }
        if self.isComplete {
            // The end of the input turns a trailing n into ん (かいぜn is かいぜん), so the n is not a letter left over
            self.prefixKana[self.prefixKana.count - 1] = composingText.convertTarget
        }
    }

    /// The first of the keys at the end that romaji has not read yet (the g of yorosikuoneg): a Latin word ending there
    /// or after is still being typed, since nothing after it reads as kana yet. The number of keys when the input is
    /// complete or every key is read
    var typingFrom: Int {
        guard !self.isComplete, let whole = self.prefixKana.last else {
            return self.keys.count
        }
        return self.keys.count - whole.reversed().prefix { $0.isASCII && $0.isLetter }.count
    }

    /// The kana the keys in `range` make within the input, when they start and end where kana does (an n left on its
    /// own before them counts as the ん it becomes); nil when a letter is left over (cぃck) or the range cuts a kana. A
    /// capital typed out of habit is a letter here (Tおきょ for Tokyo): see `kanaReadAlone`
    func kana(of range: Range<Int>) -> String? {
        guard let whole = self.prefixKana.last, range.upperBound <= self.keys.count else {
            return nil
        }
        func matches(_ prefix: String) -> Bool {
            whole.hasPrefix(prefix) || prefix.last == "n" && whole.hasPrefix(prefix.dropLast() + "ん")
        }
        let (before, upTo) = (self.prefixKana[range.lowerBound], self.prefixKana[range.upperBound])
        guard matches(before), matches(upTo) else {
            return nil
        }
        let kana = whole.dropFirst(before.count).prefix(upTo.count - before.count)
        guard !kana.isEmpty, !kana.contains(where: \.isASCII) else {
            return nil
        }
        return String(kana)
    }

    /// Whether the keys in `range`, read as romaji on their own, make kana with no letter left over (a last n counts as
    /// the ん it becomes): as the converter reads them after a word written as letters, which may differ from how they
    /// read within the input (hakaku after Mac is はかく, though machakaku reads まちゃかく)
    func readsAsKana(_ range: Range<Int>) -> Bool {
        self.kanaReadAlone(of: range) != nil
    }

    /// The kana of the keys of a word left to the converter (see `ScriptSegmentation.uncertainWords`): within the
    /// input, or read on their own in lower case when the word starts with a capital, which the converter sees in lower
    /// case (see `ScriptSegmentation.romajiCapitals`)
    func kana(ofUncertain range: Range<Int>) -> String? {
        self.kana(of: range) ?? (self.keys[range.lowerBound].isUppercase ? self.kanaReadAlone(of: range) : nil)
    }

    /// The kana the keys in `range` make read as romaji on their own, in lower case (ときょ for Tokyo, read as a
    /// capital typed out of habit, see `ScriptSegmentation.romajiCapitals`), with no letter left over (a last n counts as
    /// the ん it becomes); nil when a letter is left over
    func kanaReadAlone(of range: Range<Int>) -> String? {
        var text = ComposingText()
        for offset in range {
            let key = Character(self.keys[offset].lowercased())
            text.insertAtCursorPosition([.init(piece: .key(intention: nil, input: key, modifiers: []), inputStyle: self.elements[offset].inputStyle)])
        }
        let lastN = text.convertTarget.hasSuffix("n")
        let kana = lastN ? String(text.convertTarget.dropLast()) : text.convertTarget
        guard !kana.isEmpty, !kana.contains(where: \.isASCII) else {
            return nil
        }
        return lastN ? kana + "ん" : kana
    }
}

/// Which parts of the input are Latin words: the identification layer's answer
struct ScriptSegmentation {
    /// Latin words whose extent is decided, with the spelling to write
    var latinWords: [LatinInputGuess.Span] = []
    /// Capitals that start a Latin word whose end is left to the converter (O in korehaOguradesu): read as romaji
    /// again, the word can end anywhere the converter finds natural (Ogura|です)
    var openCapitals: [Int] = []
    /// Capitals that are romaji all the same (K in Kyouhaiitenkidesu, typed at the start out of habit): the converter
    /// sees them in lower case, so they make kana
    var romajiCapitals: [Int] = []
    /// Words typed in lower case that read as Japanese too, in standard romaji, which the identification layer is not
    /// sure about (token in tokenwohakkousuru; not cafe, typed as the word on purpose), and words it knows typed with a
    /// capital it reads as romaji all the same (Tokyo in Tokyotonisumu, read as と+kyoto): the converter reads their keys
    /// as romaji and gets the letters as a temporary dictionary entry priced by the probability, so its own dictionary
    /// and connection costs decide between the two readings (token rather than 都県, but 酒 rather than sake)
    var uncertainWords: [UncertainWord] = []
    /// Where a Latin word may end earlier than decided (Win in Winnogawa, read as one name since names are typed so;
    /// sign-in in sign-inshite), when the keys left over read as romaji, or start one key later, its first n being the
    /// ん of the kana before it (map in sakuhinmap): the converter can prefer the shorter word with the rest as Japanese
    /// (Winの側, sign-inして, 作品map, see `SegmentsManager.keepingNaturalJapanese`)
    var shorterWords: [ShorterWord] = []
    /// Where a Latin word may end later than decided, at a word the lexicon knows (Finder for Find in Finderuindou, read
    /// as Find+えるいんどう when the model finds the two ends about as likely): the converter can prefer the longer word
    /// when the input is clearly likelier so (Finderウインドウ rather than Find得る引導, see
    /// `SegmentsManager.keepingNaturalJapanese`)
    var longerWords: [LongerWord] = []
    /// Words typed in lower case that the identification layer reads as Japanese though it knows them as Latin words
    /// (node in nodewokidousuru, read as ので; zoom at the end of kyounokaigihazoom, its m still unread): the converter
    /// writes them as letters when their Japanese reading is clearly unnatural (see `SegmentsManager.keepingNaturalJapanese`)
    var possibleWords: [PossibleWord] = []

    struct ShorterWord: Equatable {
        /// The keys of the word as decided
        var word: Range<Int>
        /// The shorter word, from the same start or one key later, with the spelling to write
        var shorter: LatinInputGuess.Span
        /// The probability that the keys are the shorter word
        var probability: Double
        /// The lexicon knows the shorter word; otherwise it starts with a capital and may be a name (Osaka in Osakashi)
        var known = true
    }

    struct LongerWord: Equatable {
        /// The keys of the word as decided
        var word: Range<Int>
        /// The longer word, from the same start, with the spelling to write
        var longer: LatinInputGuess.Span
        /// The probability that the keys are the longer word
        var probability: Double
    }

    struct PossibleWord: Equatable {
        var word: LatinInputGuess.Span
        /// The probability that the keys are this Latin word
        var probability: Double
    }

    struct UncertainWord: Equatable {
        /// The letters as typed
        var word: String
        /// The spelling the lexicon knows for them when it differs (API for api)
        var spelling: String?
        var keys: Range<Int>
        /// The probability that the keys are this Latin word
        var probability: Double
        /// The probability that the keys are romaji instead: at most that of the key least likely to be romaji
        var romajiProbability: Double
    }

    var isEmpty: Bool {
        self.latinWords.isEmpty && self.openCapitals.isEmpty && self.romajiCapitals.isEmpty && self.uncertainWords.isEmpty
            && self.possibleWords.isEmpty
    }
}

/// The identification layer: tells which parts of the typed keys are Latin words. It runs where the conversion runs,
/// on whichever thread holds the conversion lock (see `ConversionLock`)
protocol ScriptIdentifier {
    func segment(_ input: TypedInput) -> ScriptSegmentation
}

/// The identification layer as rules, built up one case at a time. It asks the spell checker, so it runs on the main
/// thread (see `LatinInputGuess.systemKnownWordOnMainThread`)
struct RuleBasedScriptIdentifier: ScriptIdentifier {
    func segment(_ input: TypedInput) -> ScriptSegmentation {
        let keys = input.keys
        var words = LatinInputGuess.latinSpans(
            keys: keys,
            prefixKana: input.prefixKana,
            isComplete: input.isComplete,
            endsWell: { Self.latinWordEndsWell(at: $0, in: input) },
            knownWord: LatinInputGuess.systemKnownWordOnMainThread
        )
        words += LatinInputGuess.capitalRuns(keys: keys).filter { run in !words.contains { $0.keys.overlaps(run.keys) } }
        words += Self.unknownCapitalizedWords(in: input, knownWords: words)
        if let clauseEnd = input.clauseEnd {
            words = words.flatMap { $0.split(at: clauseEnd) }
        }
        let kana = input.prefixKana.last ?? ""
        // A capital at the very start counts too, unless it started English input (Config.UppercaseStartsAlphabetInput),
        // and so does one at the start of what is left after the first clause is committed (Oguradesu after これは)
        let openCapitals = keys.indices.filter { index in
            keys[index].isASCII && keys[index].isUppercase && kana.hasPrefix(input.prefixKana[index])
                && !words.contains { $0.keys.contains(index) } && Self.startsKana(in: input, from: index)
        }
        return ScriptSegmentation(latinWords: words, openCapitals: openCapitals)
    }

    /// How the Japanese after a word typed in Latin letters usually starts: particles, the copula, and する
    nonisolated static let wordsAfterLatinWord = ["は", "が", "を", "に", "で", "と", "の", "も", "へ", "や", "か", "よ", "ね", "だ", "な", "し", "す", "さ", "って", "から", "まで", "より"]

    /// Whether `rest`, the conversion of what follows a word typed in Latin letters, lets the word end there. Letters
    /// not yet made into kana do not tell yet
    nonisolated static func followsLatinWord(_ rest: String) -> Bool {
        // A symbol, a digit, or a space also ends a word (Ctrl before ＋)
        rest.allSatisfy(\.isASCII) || rest.first.map { !$0.isLetter } == true || Self.wordsAfterLatinWord.contains { word in
            // Not when a small kana follows: すぉ in swotukai is not the す of する
            rest.hasPrefix(word) && !(rest.dropFirst(word.count).first.map { "ぁぃぅぇぉゃゅょ".contains($0) } ?? false)
        }
    }

    /// Whether the keys from a capital on, read as romaji, start with kana (Og makes お, Ct makes no kana). Only then can
    /// the converter be left to find where the word ends; otherwise the capital stays as typed rather than turning into
    /// a lower case letter
    private static func startsKana(in input: TypedInput, from index: Int) -> Bool {
        Self.romajiReading(of: index ..< min(index + 3, input.keys.count), in: input).first.map { !$0.isASCII } ?? false
    }

    /// The keys in `range` read as romaji on their own, the first one in lower case (a capital starts a word)
    private static func romajiReading(of range: Range<Int>, in input: TypedInput) -> String {
        var text = ComposingText()
        for offset in range {
            let key = offset == range.lowerBound ? Character(input.keys[offset].lowercased()) : input.keys[offset]
            text.insertAtCursorPosition([.init(piece: .key(intention: nil, input: key, modifiers: []), inputStyle: input.elements[offset].inputStyle)])
        }
        return text.convertTarget
    }

    /// Whether a word typed in Latin letters may end before the key at `end`: at the end, before a capital, or before
    /// what usually follows a word in Japanese. The keys after it are read on their own, since they may make kana
    /// together with its last key (dwo after iPad)
    private static func latinWordEndsWell(at end: Int, in input: TypedInput) -> Bool {
        guard end < input.keys.count, !input.keys[end].isUppercase else {
            return true
        }
        var rest = ComposingText()
        rest.insertAtCursorPosition(Array(input.elements[end...]))
        return Self.followsLatinWord(rest.convertTarget)
    }

    /// Words typed with a capital that are not known words and leave letters when read as romaji (Aptos reads あpとs),
    /// so neither a known spelling nor a kana reading can place them. Each runs from the capital to the first place
    /// where it has letters left over and may end (Aptos|を in Aptoswotukaimashou)
    private static func unknownCapitalizedWords(in input: TypedInput, knownWords: [LatinInputGuess.Span]) -> [LatinInputGuess.Span] {
        let keys = input.keys
        var words: [LatinInputGuess.Span] = []
        for start in keys.indices where keys[start].isASCII && keys[start].isUppercase
            && !knownWords.contains(where: { $0.keys.contains(start) }) && !words.contains(where: { $0.keys.contains(start) }) {
            for end in start + 3 ... max(start + 3, keys.count) where end <= keys.count {
                guard keys[start ..< end].allSatisfy({ $0.isASCII && $0.isLetter }),
                      !keys[start + 1 ..< end].contains(where: \.isUppercase),
                      !knownWords.contains(where: { $0.keys.overlaps(start ..< end) }) else {
                    break
                }
                var reading = Substring(Self.romajiReading(of: start ..< end, in: input))
                if !input.isComplete {
                    // Letters at the end may still become kana with the next key (Idej, then Ideju)
                    while reading.last.map({ $0.isASCII && $0.isLetter }) == true {
                        reading = reading.dropLast()
                    }
                } else if end == keys.count, reading.hasSuffix("n") {
                    // The end of the input turns a trailing n into ん
                    reading = reading.dropLast()
                }
                if reading.contains(where: { $0.isASCII && $0.isLetter }), Self.latinWordEndsWell(at: end, in: input) {
                    words.append(.init(word: String(keys[start ..< end]), keys: start ..< end))
                    break
                }
            }
        }
        return words
    }
}

extension LatinInputGuess.Span {
    /// The word as two words, before and from the key at `index`, when it runs across it
    func split(at index: Int) -> [Self] {
        guard self.keys.lowerBound < index, index < self.keys.upperBound else {
            return [self]
        }
        let offset = index - self.keys.lowerBound
        return [
            .init(word: String(self.word.prefix(offset)), keys: self.keys.lowerBound ..< index),
            .init(word: String(self.word.dropFirst(offset)), keys: index ..< self.keys.upperBound)
        ]
    }
}
