import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Morphological analysis of the input read as Japanese romaji, by the converter's dictionary and connection costs (its
/// lattice), without Zenzai. The script tagger reads how well each key fits a Japanese word: hoteru reads as one known
/// word (ホテル), while apocalypse leaves letters no word covers. It converts, so it runs where the conversion runs (see
/// `ConversionLock`)
final class JapaneseAnalyzer {
    /// A word of the best reading of the input as Japanese
    struct Word {
        /// Its reading, one character for each character of the input's kana
        var ruby: String
        var word: String
        /// Its part of speech
        var cid: Int
        var mid: Int
        var value: Float
    }

    private let converter: KanaKanjiConverter
    private let sessionID: KanaKanjiConverter.ConversionSessionID
    private let options: ConvertRequestOptions
    /// The session and options for looking up the words of one reading (see `words(reading:)`), made at the first
    /// look-up
    private var readingSessionID: KanaKanjiConverter.ConversionSessionID?
    private let readingOptions: ConvertRequestOptions
    /// The words found for each reading so far
    private var readingWords: [String: ReadingWords] = [:]

    /// What the dictionary has for exactly one reading on its own (see `words(reading:)`)
    struct ReadingWords {
        /// The likeliest noun
        var noun: Word?
        /// Whether a particle or an auxiliary reads so (ので, まで)
        var functionWord: Bool
    }

    /// With `fast`, only the best reading is kept while converting and typos are not corrected: for many short pieces
    /// of input (see `ScriptTaggerFeatures.conditionedAnalyses`)
    init(converter: KanaKanjiConverter, fast: Bool = false) {
        self.converter = converter
        // Its own session, so analyzing does not disturb the conversion of the input
        self.sessionID = converter.createSession()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ogura-analyzer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.options = ConvertRequestOptions(
            N_best: fast ? 1 : 10,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            learningType: .nothing,
            memoryDirectoryURL: directory,
            sharedContainerURL: directory,
            textReplacer: .empty,
            specialCandidateProviders: [],
            typoCorrectionMode: fast ? .disabled : .automatic,
            metadata: nil
        )
        self.readingOptions = ConvertRequestOptions(
            N_best: 30,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            learningType: .nothing,
            memoryDirectoryURL: directory,
            sharedContainerURL: directory,
            textReplacer: .empty,
            specialCandidateProviders: [],
            typoCorrectionMode: .disabled,
            metadata: nil
        )
    }

    /// What the dictionary has for exactly `reading` (hiragana) on its own: its likeliest noun (とけん is 都県, a rare
    /// word, while さけ is 酒, a common one) and whether a particle or an auxiliary reads so. Not the reading filled in
    /// as kana or letters, nor forms of verbs (咲け), which make almost any reading look like Japanese. Looked up once
    /// for each reading
    func words(reading: String) -> ReadingWords {
        if let found = self.readingWords[reading] {
            return found
        }
        let sessionID = self.readingSessionID ?? self.converter.createSession()
        self.readingSessionID = sessionID
        var text = ComposingText()
        text.insertAtCursorPosition(reading, inputStyle: .direct)
        let result = try? self.converter.withSession(sessionID) {
            self.converter.requestCandidates(text, options: self.readingOptions)
        }
        let katakana = reading.toKatakana()
        let elements = (result?.mainResults ?? [])
            .compactMap { $0.data.count == 1 && $0.data[0].ruby == katakana ? $0.data[0] : nil }
            .filter { element in
                // Not the reading itself filled in as a name, nor letters (the Latin word, or a temporary entry)
                !(element.word == element.ruby && element.lcid == CIDData.固有名詞.cid && element.mid == MIDData.一般.mid)
                    && !element.word.contains(where: { $0.isASCII && $0.isLetter })
            }
        // The converter's nouns (its content words have these parts of speech besides verbs and adjectives)
        let noun = elements
            .filter { (1281 ..< 1297).contains($0.lcid) || (1306 ..< 1310).contains($0.lcid) }
            .max { $0.value() < $1.value() }
            .map { Word(ruby: $0.ruby, word: $0.word, cid: $0.lcid, mid: $0.mid, value: $0.value()) }
        let words = ReadingWords(noun: noun, functionWord: elements.contains { 147 ... 554 ~= $0.lcid })
        self.readingWords[reading] = words
        return words
    }

    /// The words of the best reading of `text` as Japanese, or nil when no candidate covers all of it
    func analyze(_ text: ComposingText) -> [Word]? {
        guard !text.isEmpty else {
            return []
        }
        let result = try? self.converter.withSession(self.sessionID) {
            self.converter.requestCandidates(text, options: self.options)
        }
        let katakana = text.convertTarget.toKatakana()
        guard let best = result?.mainResults.first(where: { $0.data.map(\.ruby).joined() == katakana }) else {
            return nil
        }
        return best.data.map { Word(ruby: $0.ruby, word: $0.word, cid: $0.lcid, mid: $0.mid, value: $0.value()) }
    }
}
