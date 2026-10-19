import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import NaturalLanguage
import OSLog

public final class SegmentsManager {
    private static let textReplacer = TextReplacer.withDefaultEmojiDictionary()

    public init(
        kanaKanjiConverter: KanaKanjiConverter,
        applicationDirectoryURL: URL,
        personalizationDirectoryURL: URL?,
        context: Context = Context()
    ) {
        self.kanaKanjiConverter = kanaKanjiConverter
        self.conversionSessionID = kanaKanjiConverter.createSession()
        self.plainConversionSessionID = kanaKanjiConverter.createSession()
        self.lookupSessionID = kanaKanjiConverter.createSession()
        self.headSessionID = kanaKanjiConverter.createSession()
        self.applicationDirectoryURL = applicationDirectoryURL
        self.personalizationDirectoryURL = personalizationDirectoryURL
        self.context = context
    }

    /// What the converter learns from a committed conversion while Zenzai is on. The converter learns each word for its
    /// reading, wherever it comes, which can override what Zenzai reads from the context (納める learned from 税金を納める
    /// beats 治める in 国を治める). In homophoneLearningEvaluation (100 pairs of sentences sharing a reading, the first
    /// committed, then the second typed), learning words made 13 of the second sentences wrong when the first was committed
    /// whole and 32 clause by clause; phrases 3 and 34; corrections none, and a candidate picked is learned all the same
    public enum ZenzaiLearning: Sendable {
        /// Each word, as the converter does without Zenzai
        case words
        /// The committed text as one phrase (see `learnedAsOnePhrase`)
        case phrases
        /// Only what the user changed (another candidate, or the clause moved), as one phrase: Zenzai converts what was
        /// accepted the same way again from the context
        case corrections
    }

    /// Type for injecting settings, for example in tests. It does not expose the settings outside.
    public struct Context {
        public init() {}
        public init(
            useZenzai: Bool,
            resourcesDirectoryURL: URL? = nil,
            liveConversionEnabled: Bool? = nil,
            uppercaseStartsAlphabetInput: Bool? = nil,
            learnedScriptIdentification: Bool? = nil,
            scriptModelDirectoryURL: URL? = nil,
            convertsAsTheConverterDoes: Bool = false,
            zenzaiWeightURL: URL? = nil,
            zenzaiLearning: ZenzaiLearning? = nil,
            typeHalfWidthSymbols: Bool? = nil
        ) {
            self.useZenzai = useZenzai
            self.resourcesDirectoryURL = resourcesDirectoryURL
            self.liveConversionEnabled = liveConversionEnabled
            self.uppercaseStartsAlphabetInput = uppercaseStartsAlphabetInput
            self.learnedScriptIdentification = learnedScriptIdentification
            self.scriptModelDirectoryURL = scriptModelDirectoryURL
            self.convertsAsTheConverterDoes = convertsAsTheConverterDoes
            self.zenzaiWeightURL = zenzaiWeightURL
            if let zenzaiLearning {
                self.zenzaiLearning = zenzaiLearning
            }
            self.typeHalfWidthSymbols = typeHalfWidthSymbols
        }

        var useZenzai: Bool = true
        /// The candidates are the converter's own, without what Ogura does on top of it (Latin words, letters written
        /// for kana, the first clause): for comparing the two (see HomophoneEvaluation)
        var convertsAsTheConverterDoes = false
        /// Zenzai's weights, in place of the ones in the resources: for comparing models (see HomophoneEvaluation)
        var zenzaiWeightURL: URL?
        /// What the converter learns from what is committed while Zenzai is on (see `ZenzaiLearning`)
        var zenzaiLearning: ZenzaiLearning = .corrections
        var resourcesDirectoryURL: URL?
        /// If nil, follow the setting (Config.LiveConversion)
        var liveConversionEnabled: Bool?
        /// If nil, follow the setting (Config.UppercaseStartsAlphabetInput)
        var uppercaseStartsAlphabetInput: Bool?
        /// Whether the learned identification layer tells Latin words from romaji rather than the rules. If nil, follow
        /// the setting (Config.LearnedScriptIdentification)
        var learnedScriptIdentification: Bool?
        /// Where the learned identification layer is (tagger.bin, with the files it reads; see `TaggerScriptIdentifier`).
        /// If nil, the one in the resources (ScriptModel)
        var scriptModelDirectoryURL: URL?
        /// Whether symbols are typed in half width, which makes a hyphen after a Latin word or a digit half width too
        /// (see `halfWidthHyphens`). If nil, follow the setting (Config.TypeHalfWidthSymbols)
        var typeHalfWidthSymbols: Bool?
    }

    public weak var delegate: (any SegmentManagerDelegate)?
    private let kanaKanjiConverter: KanaKanjiConverter
    private let conversionSessionID: KanaKanjiConverter.ConversionSessionID
    /// The session of conversions without Zenzai while Zenzai is on (see `withConverter`)
    private let plainConversionSessionID: KanaKanjiConverter.ConversionSessionID
    /// For conversions on the side that must not disturb the input's (see `japaneseName`)
    private let lookupSessionID: KanaKanjiConverter.ConversionSessionID
    /// For the input before a Latin word converted around (see `contextWord`)
    private let headSessionID: KanaKanjiConverter.ConversionSessionID
    /// The temporary dictionary entries each session (plain or not) last converted with, for the sessions that decide
    /// by them (see `startingOverForChangedEntries`)
    private var sessionEntries: [Bool: [PricedEntry]] = [:]

    /// A dictionary entry with its value, which the equality of `DicdataElement` leaves out
    private struct PricedEntry: Equatable {
        var element: DicdataElement
        var value: PValue
    }

    deinit {
        self.kanaKanjiConverter.removeSession(self.conversionSessionID)
        self.kanaKanjiConverter.removeSession(self.plainConversionSessionID)
        self.kanaKanjiConverter.removeSession(self.lookupSessionID)
        self.kanaKanjiConverter.removeSession(self.headSessionID)
    }

    /// The conversion sessions of this object: the input's, and the ones on the side
    private enum Session {
        /// The input, with Zenzai when it is on
        case input
        /// The input without Zenzai while Zenzai is on: the converter's cache of an input made with Zenzai is not for
        /// converting it again without
        case plain
        /// Readings looked up on the side (see `japaneseName`)
        case lookup
        /// The input before a Latin word converted around (see `contextWord`)
        case head
    }

    /// Dictionaries and models are shared. Conversion state is kept separate for each input session, and for each kind
    /// of conversion of this object (see `Session`)
    @MainActor
    private func withConverter<Result>(_ session: Session = .input, _ operation: (KanaKanjiConverter) -> Result) -> Result {
        let sessionID = switch session {
        case .input: self.conversionSessionID
        case .plain: self.plainConversionSessionID
        case .lookup: self.lookupSessionID
        case .head: self.headSessionID
        }
        do {
            return try self.kanaKanjiConverter.withSession(sessionID) {
                operation(self.kanaKanjiConverter)
            }
        } catch {
            // Only this object's own deinit destroys this session.
            preconditionFailure("SegmentsManager lost its conversion session: \(error)")
        }
    }
    private let applicationDirectoryURL: URL
    private let personalizationDirectoryURL: URL?
    private let context: Context

    private var composingText: ComposingText = ComposingText()
    private var lastInputStyle: InputStyle = .direct

    private var liveConversionEnabled: Bool {
        self.context.liveConversionEnabled ?? Config.LiveConversion().value
    }
    private var zenzaiPersonalizationLevel: Config.ZenzaiPersonalizationLevel.Value {
        Config.ZenzaiPersonalizationLevel().value
    }
    private var rawCandidates: ConversionResult?

    private var selectionIndex: Int?
    private var didExperienceSegmentEdition = false
    private var lastOperation: Operation = .other
    private var shouldShowCandidateWindow = false

    private var isShowingAdditionalCandidates = false

    /// The input started with an uppercase letter, so this word is being typed in Latin letters as is (no romaji-to-kana conversion)
    public private(set) var isAlphabetWordInput = false
    private var additionalCandidates: [CandidatePresentation] = []
    /// The letters as typed, offered when the input converted for selection does not look like Japanese (see `LatinInputGuess`)
    private var latinCandidate: (candidate: Candidate, rank: Int)?
    /// The last conversion had Latin words in the input (see `latinWordsConversionText`)
    private var hasLatinWords = false
    /// The input as the converter saw it at the last conversion, Latin words as letters (see `latinWordsConversionText`):
    /// what is left after the clause being converted is shown from it, so a Latin word there shows as typed (windows,
    /// not うぃんどws)
    private var latinWordsInput: ComposingText?
    /// Tells which parts of the input are Latin words (see `ScriptIdentifier`): the learned identification layer when the
    /// setting chooses it and its model is there, else the rules. Read at each use, so the setting applies at once
    @MainActor private var scriptIdentifier: any ScriptIdentifier {
        if let identifier = self.scriptIdentifierOverride {
            return identifier
        }
        if self.context.learnedScriptIdentification ?? Config.LearnedScriptIdentification().value, let identifier = self.learnedScriptIdentifier {
            return identifier
        }
        return RuleBasedScriptIdentifier()
    }
    /// An identification layer tests set in place of the rules and the model
    var scriptIdentifierOverride: (any ScriptIdentifier)?
    /// The learned identification layer, read the first time it is used (the model itself is read once per process)
    @MainActor private lazy var learnedScriptIdentifier: TaggerScriptIdentifier? = {
        let directory = self.context.scriptModelDirectoryURL ?? self.resourcesDirectoryURL.appendingPathComponent("ScriptModel", isDirectory: true)
        let analyze = FileManager.default.fileExists(atPath: directory.appendingPathComponent("analyze").path)
        return try? TaggerScriptIdentifier(modelDirectory: directory, converter: analyze ? self.kanaKanjiConverter : nil, naturalnessChecked: self.context.useZenzai)
    }()
    private var showingAdditionalCandidateCount = 0
    private var isFixingAdditionalCandidateTop = false

    public struct PredictionCandidate: Sendable, Equatable {
        public var displayText: String
        public var appendText: String
        public var deleteCount: Int = 0
    }

    public func makeCandidatePresentations(_ candidates: [Candidate]) -> [CandidatePresentation] {
        let additionalPresentations = self.additionalCandidatePresentationsForSelectionIndex
        return candidates.indices.map { index in
            if index < additionalPresentations.count {
                return .init(candidate: candidates[index], displayContext: additionalPresentations[index].displayContext)
            }
            return .init(candidate: candidates[index])
        }
    }

    private lazy var zenzaiPersonalizationMode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode? = self.getZenzaiPersonalizationMode()

    private func getZenzaiPersonalizationMode() -> ConvertRequestOptions.ZenzaiMode.PersonalizationMode? {
        let alpha = self.zenzaiPersonalizationLevel.alpha
        // Personalization is off.
        if alpha == 0 {
            return nil
        }
        guard let personalizationDirectoryURL else {
            return nil
        }

        let base = self.resourcesDirectoryURL.appendingPathComponent("lm", isDirectory: false).path
        let personal = personalizationDirectoryURL.path + "/lm"
        // check personal lm existence
        guard [
            FileManager.default.fileExists(atPath: personal + "_c_abc.marisa"),
            FileManager.default.fileExists(atPath: personal + "_r_xbx.marisa"),
            FileManager.default.fileExists(atPath: personal + "_u_abx.marisa"),
            FileManager.default.fileExists(atPath: personal + "_u_xbc.marisa")
        ].allSatisfy(\.self) else {
            self.appendDebugMessage("❌ Seems like there is missing marisa file for prefix \(personal)")
            return nil
        }

        return .init(baseNgramLanguageModel: base, personalNgramLanguageModel: personal, alpha: alpha)
    }

    private enum Operation: Sendable {
        case insert
        case delete
        case editSegment
        case cancelConversion
        case other
    }

    /// Maximum number of characters of surrounding context read from the host app. Only this range is read, to improve conversion accuracy; it is never stored.
    enum ContextLength {
        static let conversion = 30
    }

    private static let logger = Logger(subsystem: "org.if0.inputmethod.ogura", category: "SegmentsManager")

    public func appendDebugMessage(_ string: String) {
        Self.logger.debug("\(string, privacy: .private)")
    }

    private func zenzaiMode(
        leftSideContext: String?,
        rightSideContext: String?,
        requestRichCandidates: Bool
    ) -> ConvertRequestOptions.ZenzaiMode {
        if !self.context.useZenzai {
            return .off
        }
        return .on(
            weight: self.context.zenzaiWeightURL ?? self.resourcesDirectoryURL.appendingPathComponent("ggml-model-Q5_K_M.gguf", isDirectory: false),
            inferenceLimit: Config.ZenzaiInferenceLimit().value,
            requestRichCandidates: requestRichCandidates,
            personalizationMode: self.zenzaiPersonalizationMode,
            versionDependentMode: .v3(
                .init(
                    profile: Config.ZenzaiProfile().value,
                    leftSideContext: leftSideContext,
                    rightSideContext: rightSideContext,
                    enableAlignmentSeparator: true,
                    )
            )
        )
    }

    private var resourcesDirectoryURL: URL {
        if let resourcesDirectoryURL = self.context.resourcesDirectoryURL {
            return resourcesDirectoryURL
        }
        if let resourceURL = Bundle.main.resourceURL {
            return resourceURL
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    }

    private var metadata: ConvertRequestOptions.Metadata {
        if let tag = PackageMetadata.gitTag {
            .init(versionString: "Ogura (\(tag))")
        } else if let commit = PackageMetadata.gitCommit {
            .init(versionString: "Ogura (\(commit.prefix(7)))")
        } else {
            .init(versionString: "Ogura (unknown version)")
        }
    }

    private func options(
        leftSideContext: String?,
        rightSideContext: String?,
        requestRichCandidates: Bool,
        requireJapanesePrediction: ConvertRequestOptions.PredictionMode,
        requireEnglishPrediction: ConvertRequestOptions.PredictionMode,
        zenzai: Bool = true
    ) -> ConvertRequestOptions {
        .init(
            requireJapanesePrediction: requireJapanesePrediction,
            requireEnglishPrediction: requireEnglishPrediction,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            fullWidthRomanCandidate: true,
            learningType: Config.Learning().value.learningType,
            memoryDirectoryURL: self.memoryDirectoryURL,
            sharedContainerURL: CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: self.memoryDirectoryURL),
            textReplacer: Self.textReplacer,
            specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
            zenzaiMode: zenzai ? self.zenzaiMode(
                leftSideContext: leftSideContext,
                rightSideContext: rightSideContext,
                requestRichCandidates: requestRichCandidates
            ) : .off,
            experimentalZenzaiPredictiveInput: true,
            typoCorrectionMode: .automatic,
            metadata: self.metadata
        )
    }

    public var memoryDirectoryURL: URL {
        self.applicationDirectoryURL
    }

    @MainActor
    public func activate() {
        self.shouldShowCandidateWindow = false
        self.lastInputStyle = .direct
        self.zenzaiPersonalizationMode = self.getZenzaiPersonalizationMode()
    }

    @MainActor
    public func reloadUserDictionary() {
        self.withConverter { converter in
            converter.updateUserDictionaryURL(
                CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: self.memoryDirectoryURL),
                forceReload: true
            )
        }
    }

    @MainActor
    public func resetLearningData() {
        self.withConverter { $0.resetMemory() }
    }

    /// Ends the conversion of this input in both sessions, so the next input starts from nothing in each
    @MainActor
    private func stopConversion() {
        self.withConverter { $0.stopComposition() }
        self.withConverter(.plain) { $0.stopComposition() }
        self.sessionEntries = [:]
    }

    /// Starts the conversion in the session over when the temporary dictionary entries differ from those it last
    /// converted with. The converter keeps the nodes of the part of the input it has converted, priced as they were
    /// when it made them; an uncertain word's entry changes its price as the identification layer reads more keys
    /// (token gets likelier once を送って follows), and with the old nodes the session would go on deciding by the price
    /// the word had when its kana was first typed
    @MainActor
    private func startingOverForChangedEntries(_ entries: [DicdataElement], plain: Bool, converter: KanaKanjiConverter) {
        let priced = entries.map { PricedEntry(element: $0, value: $0.value()) }
        guard self.sessionEntries[plain] != priced else {
            return
        }
        converter.stopComposition()
        self.sessionEntries[plain] = priced
    }

    @MainActor
    public func deactivate(flushLearningData: Bool = true) {
        self.stopConversion()
        if flushLearningData {
            self.withConverter { $0.commitUpdateLearningData() }
        }
        self.rawCandidates = nil
        self.latinWordsInput = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.composingText.stopComposition()
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.lastInputStyle = .direct
        self.isAlphabetWordInput = false
    }

    @MainActor
    /// Stop this input
    public func stopComposition() {
        self.composingText.stopComposition()
        self.stopConversion()
        self.rawCandidates = nil
        self.latinWordsInput = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.lastInputStyle = .direct
        self.isAlphabetWordInput = false
    }

    @MainActor
    /// Stop Japanese input itself
    public func stopJapaneseInput() {
        self.rawCandidates = nil
        self.latinWordsInput = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.withConverter { $0.commitUpdateLearningData() }
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.lastInputStyle = .direct
        self.isAlphabetWordInput = false
    }

    /// Mark an input boundary when the convert key is pressed
    @MainActor
    public func insertCompositionSeparator(inputStyle: InputStyle, skipUpdate: Bool = false) {
        guard self.composingText.input.last?.piece != .compositionSeparator else {
            // Do nothing if the last element is already compositionSeparator
            return
        }
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: inputStyle)])
        self.lastOperation = .insert
        if !skipUpdate {
            self.updateRawCandidate()
        }
    }

    @MainActor
    public func insertAtCursorPosition(_ string: String, inputStyle: InputStyle) {
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition(string, inputStyle: inputStyle)
        self.lastOperation = .insert
        // When live conversion is off, show the candidate window
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    public func insertAtCursorPosition(pieces: [InputPiece], inputStyle: InputStyle) {
        var pieces = pieces
        var inputStyle = inputStyle
        // Without live conversion the input shows as typed and Enter commits it so (Aっpぇ for Apple), so a capital at
        // the start always keeps the input in Latin letters, as in MS-IME
        let uppercaseStartsAlphabetInput = self.context.uppercaseStartsAlphabetInput ?? Config.UppercaseStartsAlphabetInput().value
        if inputStyle != .direct, uppercaseStartsAlphabetInput || !self.liveConversionEnabled,
           Self.startsAlphabetWordInput(pieces: pieces, composingTextIsEmpty: self.composingText.isEmpty) {
            self.isAlphabetWordInput = true
        }
        if self.isAlphabetWordInput {
            // During English input, do not use intended characters (such as full-width); insert the typed characters as is
            inputStyle = .direct
            pieces = pieces.map { piece in
                if case .key(_, let input, _) = piece {
                    return .character(input)
                }
                return piece
            }
        }
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition(pieces.map { .init(piece: $0, inputStyle: inputStyle) })
        self.lastOperation = .insert
        // When live conversion is off, show the candidate window
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    /// When one ASCII uppercase letter is typed into empty input, treat the word as English input, like MS-IME and similar IMEs.
    static func startsAlphabetWordInput(pieces: [InputPiece], composingTextIsEmpty: Bool) -> Bool {
        guard composingTextIsEmpty, pieces.count == 1 else {
            return false
        }
        let input: Character = switch pieces[0] {
        case .character(let character): character
        case .key(_, let character, _): character
        case .compositionSeparator: " "
        }
        return input.isASCII && input.isUppercase
    }

    @MainActor
    public func editSegment(count: Int) {
        // If a prefix candidate is currently selected, first move the cursor to match it
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            var afterComposingText = self.composingText
            afterComposingText.prefixComplete(composingCount: candidates[selectionIndex].composingCount)
            let prefixCount = self.composingText.convertTarget.count - afterComposingText.convertTarget.count
            _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition + prefixCount)
        }
        if count > 0 {
            if self.composingText.isAtEndIndex && !self.didExperienceSegmentEdition {
                // If the cursor is at the right end, move it to just after the left end
                _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition + count)
            } else {
                // Otherwise, extend to the right
                _ = self.composingText.moveCursorFromCursorPosition(count: count)
            }
        } else {
            _ = self.composingText.moveCursorFromCursorPosition(count: count)
        }
        if self.composingText.isAtStartIndex {
            // If it is at the start, move one step right
            _ = self.composingText.moveCursorFromCursorPosition(count: 1)
        }
        self.lastOperation = .editSegment
        self.didExperienceSegmentEdition = true
        self.shouldShowCandidateWindow = true
        self.selectionIndex = nil
        self.updateRawCandidate()
    }

    @MainActor
    public func deleteBackwardFromCursorPosition(count: Int = 1) {
        if !self.composingText.isAtEndIndex {
            // Move it to the right end
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            // Also reset the segment editing state once
            self.didExperienceSegmentEdition = false
        }
        if count == 1, self.readingKeepingLatinWords?.last.map({ $0.isASCII && $0.isLetter }) == true {
            // A Latin word at the end loses its last letter, not the last kana its keys made (ぇ, from le, in Apple)
            var text = ComposingText()
            text.insertAtCursorPosition(Array(self.composingText.input.dropLast()))
            self.composingText = text
        } else {
            self.composingText.deleteBackwardFromCursorPosition(count: count)
        }
        self.lastOperation = .delete
        // When live conversion is off, show the candidate window
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    /// The reading of the input with its Latin words kept as typed (これはWindowsで rather than これはWいんどwsで), shown
    /// where the input is otherwise shown as kana: after a delete, for example. Nil when the input has no Latin words
    private var readingKeepingLatinWords: String? {
        guard self.hasLatinWords, let top = self.rawCandidates?.mainResults.first,
              self.composingText.isWholeComposingText(composingCount: top.composingCount) else {
            return nil
        }
        return top.data.map { element in
            element.word.allSatisfy(\.isASCII) ? element.word : element.ruby.toHiragana()
        }.joined()
    }

    /// Delete the character to the right of the cursor (forward). Used for fn+Delete and the Del key.
    /// Does nothing when the cursor is at the right end (the IME still consumes the event).
    @MainActor
    public func deleteForwardFromCursorPosition(count: Int = 1) {
        guard !self.composingText.isAtEndIndex else {
            return
        }
        self.composingText.deleteForwardFromCursorPosition(count: count)
        self.lastOperation = .delete
        // When live conversion is off, show the candidate window
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    /// Cancel the conversion and go back to a state where the user can keep typing hiragana (BackSpace after conversion in MS-IME).
    /// Also reset segment boundary edits and the cursor position.
    @MainActor
    public func cancelConversion() {
        if !self.composingText.isAtEndIndex {
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
        }
        self.didExperienceSegmentEdition = false
        self.lastOperation = .cancelConversion
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.updateRawCandidate()
    }

    @MainActor
    public func forgetMemory() {
        if let selectedCandidate {
            self.withConverter { $0.forgetMemory(selectedCandidate) }
            // It may have been learned as one phrase (see `learnedAsOnePhrase`)
            let phrase = Self.learnedAsOnePhrase(selectedCandidate)
            if self.context.useZenzai, phrase.data != selectedCandidate.data {
                self.withConverter { $0.forgetMemory(phrase) }
            }
            self.appendDebugMessage("\(#function): forget \(selectedCandidate.data.map {$0.word})")
        }
    }

    private var candidates: [Candidate]? {
        if self.isAlphabetWordInput {
            return self.alphabetWordCandidates + (self.rawCandidatesList ?? []).filter { candidate in
                !self.alphabetWordCandidates.contains { $0.text == candidate.text }
            }
        }
        guard var rawCandidates = self.rawCandidatesList else {
            return self.isShowingAdditionalCandidates
                ? self.additionalCandidatesForSelectionIndex
                : nil
        }
        if let latinCandidate, !self.didExperienceSegmentEdition {
            rawCandidates.removeAll { $0.text == latinCandidate.candidate.text }
            rawCandidates.insert(latinCandidate.candidate, at: min(latinCandidate.rank, rawCandidates.count))
        }
        return self.isShowingAdditionalCandidates
            ? self.additionalCandidatesForSelectionIndex + rawCandidates
            : rawCandidates
    }

    /// What the converter sees instead of the input when the input has Latin words in it (see `latinWordsConversionText`)
    struct LatinWordsConversion {
        var text: ComposingText
        /// Where the known Latin words are in `composingText.input`
        var words: [Range<Int>]
        /// Temporary dictionary entries for words that start with a capital but are not known words
        var capitalizedWords: [DicdataElement]
        /// Temporary dictionary entries for the words the identification layer leaves to the converter
        var uncertainWords: [DicdataElement] = []
        /// What the converter sees with the words in doubt read the other way, and where its Latin words are: Latin words
        /// that could be Japanese (see `couldBeJapanese`) read as romaji, and words read as Japanese that could be Latin
        /// written as letters. A word written as letters is not converted, and a word read as kana not written as typed,
        /// so the other reading is offered among the candidates this way (峰に向かう for mineに向かう, tokenを送って for
        /// と犬を送って). Nil when no word is in doubt, or when not asked for
        var otherReading: (text: ComposingText, words: [Range<Int>])?

        /// The entries that write letters the converter is meant to choose by its own scores
        var entries: [DicdataElement] {
            self.capitalizedWords + self.uncertainWords
        }
    }

    /// The input with its Latin words turned into what the converter should write. Nil when there are none.
    /// Which parts are Latin words is up to the identification layer (`ScriptIdentifier`); this turns its answer into
    /// what the converter sees:
    /// - A Latin word whose extent is decided (pig in butahapigdesu) becomes letters typed as is, the way Shift+letter
    ///   at the start types them, so the converter writes 豚はpigです rather than 豚はぴgです.
    /// - A capital that starts a word whose end is left to the converter (O in korehaOguradesu) is read as romaji again
    ///   (お), and each way the word could end (Og, Ogura, Oguradesu, ...) is offered as a temporary dictionary entry, so
    ///   the converter can write これはOguraです.
    /// - A capital that is romaji all the same (K in Kyouhaiitenkidesu) is read as romaji (き).
    /// Only what the converter sees changes: each key keeps its place, so candidates still count the same keys.
    @MainActor private func latinWordsConversionText(otherReading: Bool = false) -> LatinWordsConversion? {
        guard Config.LatinCandidateForNonJapaneseInput().value,
              self.composingText.input.allSatisfy({ $0.inputStyle != .direct }),
              self.composingText.input.last?.piece != .compositionSeparator || self.composingText.input.count > 1,
              let input = TypedInput(self.composingText) else {
            return nil
        }
        var segmentation = self.scriptIdentifier.segment(input)
        guard !segmentation.isEmpty || !self.halfWidthHyphens(in: input, latinWords: []).isEmpty else {
            return nil
        }
        if self.context.useZenzai, !segmentation.uncertainWords.isEmpty {
            // Zenzai cannot write letters for a kana reading, and once it rejects a candidate made from a temporary entry
            // the converter reads the input again without the entries (へっぉ世界 for hello世界). So the converter decides
            // the uncertain words by its own scores first, and Zenzai sees the ones it writes as letters typed as is
            let written = self.wordsWrittenByConverter(self.conversion(of: input, segmentation: segmentation), uncertain: segmentation.uncertainWords, input: input)
            segmentation.latinWords += written
            segmentation.uncertainWords.removeAll { word in written.contains { $0.keys == word.keys } }
        }
        // The Latin words of the other reading of the words in doubt: without Zenzai, the words that could be Japanese
        // read as kana
        var otherWords = segmentation.latinWords.filter { !Self.couldBeJapanese($0, input: input) }
        // Words the identification layer left to the converter that it did not write as letters: read as kana
        var leftAsKana: [LatinInputGuess.Span] = []
        if self.context.useZenzai {
            leftAsKana = segmentation.uncertainWords.map { LatinInputGuess.Span(word: $0.spelling ?? $0.word, keys: $0.keys) }
            // Zenzai checks them as it checks the words the identification layer reads as Japanese: the converter's
            // scores can prefer an unnatural reading (も出が変わる for modegakawaru)
            segmentation.possibleWords += segmentation.uncertainWords.filter { $0.keys.upperBound <= input.typingFrom }.map {
                .init(word: .init(word: $0.spelling ?? $0.word, keys: $0.keys), probability: $0.probability)
            }
            let natural = self.keepingNaturalJapanese(segmentation, input: input)
            segmentation.latinWords = natural.words
            otherWords = natural.otherWords
            leftAsKana.removeAll { word in natural.words.contains { $0.keys == word.keys } || otherWords.contains { $0.keys == word.keys } }
            // The rest stay kana: Zenzai would write them as letters from their temporary entries on its own (山のmine
            // for yamanomine), past the converter's scores and the checks
            segmentation.uncertainWords = []
        }
        segmentation.possibleWords = []
        var conversion = self.conversion(of: input, segmentation: segmentation)
        if otherReading, !leftAsKana.isEmpty || otherWords != segmentation.latinWords {
            var other = segmentation
            other.latinWords = otherWords + leftAsKana
            other.uncertainWords.removeAll { word in other.latinWords.contains { $0.keys == word.keys } }
            let reading = self.conversion(of: input, segmentation: other)
            conversion.otherReading = (reading.text, reading.words)
        }
        // Words checked as letters and left as Japanese, with nothing to offer either: the input as it is
        if segmentation.isEmpty, conversion.otherReading == nil, self.halfWidthHyphens(in: input, latinWords: []).isEmpty {
            return nil
        }
        return conversion
    }

    /// Whether a Latin word could be meant as Japanese: typed in lower case, spelled in standard romaji, and read as
    /// kana from start to end. Keys that spell Japanese in standard romaji are Japanese when in doubt; code (not kode),
    /// or a word started with Shift, is typed as the word on purpose
    private static func couldBeJapanese(_ word: LatinInputGuess.Span, input: TypedInput) -> Bool {
        word.word.count >= 2 && word.word.allSatisfy({ $0.isASCII && $0.isLowercase }) && StandardRomaji.spells(word.word)
            && input.kana(of: word.keys) != nil
    }

    /// How much likelier, in natural log, Zenzai must find the keys of a Latin word typed in lower case read as kana than
    /// as letters for them to stay Japanese (see `keepingNaturalJapanese`). Zenzai does not know what words mean: 峰に
    /// 向かう and と犬を送ってください score alike. Set so that when in doubt the words stay Japanese (峰に向かう, at the
    /// cost of と犬), since Space offers the other reading either way (see `LatinWordsConversion.otherReading`)
    static let naturalJapaneseMargin: Float = 3

    /// How much likelier, in natural log, Zenzai must find the keys of a word the identification layer reads as
    /// Japanese written as letters than read as kana for them to be letters (see `ScriptSegmentation.possibleWords`).
    /// The other way round from `naturalJapaneseMargin`: the letters win only when the Japanese reading is clearly the
    /// less natural one (nodeを起動する, not のでを起動する), so when in doubt the words stay Japanese
    static let unnaturalJapaneseMargin: Float = 0

    /// How much likelier, in natural log, Zenzai must find the keys left over after a shorter end of a Latin word (see
    /// `ScriptSegmentation.shorterWords`) read as romaji than as the word's letters for the word to end there. The word
    /// is read as decided, so it ends earlier only when the Japanese after the shorter word is clearly likelier: Winの側
    /// for Winnogawa and Fanの中身 for Fannonakami are 9 to 12 likelier, while T-sha for T-shatsu (ツ) or Pi for Pinn
    /// (ん), still being typed, are within 3
    static let shorterWordMargin: Float = 3

    /// The same as `shorterWordMargin` when the shorter word is a name the converter's dictionary knows (Osaka, 大阪; see
    /// `japaneseName`). Zenzai finds a suffix after such a name likelier only by a little (Osaka市 for Osakashi, 0.5 to
    /// 3; Kanagawa県 8), and a name cut short clearly unlikelier (Yoko|hama, Ino|ue, Hokkai|dou: 6 or more), so the
    /// name ends wherever Zenzai finds the rest likelier read as romaji
    static let shorterNameMargin: Float = 0

    /// What `keepingNaturalJapanese` leaves
    struct NaturalReading {
        /// The Latin words kept
        var words: [LatinInputGuess.Span]
        /// The Latin words of the other reading of the words in doubt, for the candidates (see
        /// `LatinWordsConversion.otherReading`): each word that could be Japanese the other way round, and each word
        /// typed with a capital that may end earlier at its other end
        var otherWords: [LatinInputGuess.Span]
    }

    /// The Latin words of `segmentation` but those that could be Japanese (see `couldBeJapanese`) whose keys Zenzai
    /// finds likelier read as romaji: in Japanese input, such keys are Japanese when in doubt, so a word stays Latin only
    /// when its romaji reading is not clearly likelier (ドアをopenして; 峰に向かう stays Japanese). A word ends earlier
    /// where the identification layer finds it plausible (see `ScriptSegmentation.shorterWords`) and Zenzai finds the
    /// keys left over likelier read as romaji (Winの側 for Winnogawa, read as one name; Macは拡張 for Machakaku). Zenzai
    /// scores how likely each reading of the input typed so far is, the word as letters and as kana, after the left
    /// context
    @MainActor private func keepingNaturalJapanese(_ segmentation: ScriptSegmentation, input: TypedInput) -> NaturalReading {
        let weight = self.context.zenzaiWeightURL ?? self.resourcesDirectoryURL.appendingPathComponent("ggml-model-Q5_K_M.gguf", isDirectory: false)
        let leftSideContext = self.getCleanLeftSideContext(maxCount: ContextLength.conversion) ?? ""
        // The letters romaji has not read yet at the end, after the Latin words: they read like more of a Latin word
        // (Sakeハsakeデs, homet for 褒めt, タカイmineニn), so the readings are compared without them
        let unread = input.keys.count - input.typingFrom
        func logProbability(_ words: [LatinInputGuess.Span]) -> Float? {
            var reading = segmentation
            reading.latinWords = words
            var text = self.conversion(of: input, segmentation: reading).text.convertTarget.toKatakana()
            if unread > 0, words.allSatisfy({ $0.keys.upperBound <= input.typingFrom }),
               text.suffix(unread).allSatisfy({ $0.isASCII && $0.isLetter }) {
                text = String(text.dropLast(unread))
            }
            return self.withConverter { $0.zenzaiInputLogProbability(text, leftSideContext: leftSideContext, modelURL: weight) }
        }
        var words = segmentation.latinWords
        var otherWords = segmentation.latinWords
        for word in segmentation.latinWords where Self.couldBeJapanese(word, input: input) {
            let others = words.filter { $0.keys != word.keys }
            if let asLetters = logProbability(words), let asKana = logProbability(others), asLetters - asKana < -Self.naturalJapaneseMargin {
                words = others
            } else {
                otherWords.removeAll { $0.keys == word.keys }
            }
        }
        let unnatural = Self.addingUnnaturalJapanese(segmentation.possibleWords, to: words) { logProbability($0) }
        words = unnatural.words
        otherWords = (otherWords + unnatural.offered).sorted { $0.keys.lowerBound < $1.keys.lowerBound }
        let ended = self.endingEarlier(segmentation, input: input, words: words, otherWords: otherWords) { logProbability($0) }
        return NaturalReading(words: ended.words, otherWords: ended.otherWords)
    }

    /// `words` with each word ending at a shorter word (see `ScriptSegmentation.shorterWords`) where Zenzai finds the keys
    /// left over clearly likelier read as romaji, and `otherWords` with the likeliest shorter word in place of each word
    /// that does not, to offer. Only keys that spell standard romaji are read as Japanese (see `couldBeJapanese`), and a
    /// shorter word the lexicon does not know only when it is a name the converter's dictionary knows (see
    /// `shorterNameMargin`). `logProbability` scores the reading with the given Latin words
    @MainActor private func endingEarlier(
        _ segmentation: ScriptSegmentation,
        input: TypedInput,
        words: [LatinInputGuess.Span],
        otherWords: [LatinInputGuess.Span],
        logProbability: ([LatinInputGuess.Span]) -> Float?
    ) -> (words: [LatinInputGuess.Span], otherWords: [LatinInputGuess.Span]) {
        var (words, otherWords) = (words, otherWords)
        for word in segmentation.latinWords {
            let shorterWords = segmentation.shorterWords.filter {
                $0.word == word.keys && StandardRomaji.spells(String(input.keys[$0.shorter.keys.upperBound ..< word.keys.upperBound]))
                    && ($0.known || self.japaneseName(of: $0.shorter.word) != nil)
            }
            guard !shorterWords.isEmpty, let index = words.firstIndex(where: { $0.keys == word.keys }), let asWord = logProbability(words) else {
                continue
            }
            var best: (words: [LatinInputGuess.Span], score: Float)?
            for shorter in shorterWords {
                var ended = words
                ended[index] = shorter.shorter
                let margin = self.japaneseName(of: shorter.shorter.word) != nil ? Self.shorterNameMargin : Self.shorterWordMargin
                if let score = logProbability(ended), score - asWord > margin, score > (best?.score ?? -.infinity) {
                    best = (ended, score)
                }
            }
            if let best {
                words = best.words
            } else if let likeliest = shorterWords.max(by: { $0.probability < $1.probability }),
                      let otherIndex = otherWords.firstIndex(where: { $0.keys == word.keys }) {
                otherWords[otherIndex] = likeliest.shorter
            }
        }
        return (words, otherWords)
    }

    /// `words` with the words read as Japanese that the identification layer knows as Latin words (see
    /// `ScriptSegmentation.possibleWords`) whose Japanese reading Zenzai finds clearly less likely, and the others whose
    /// Japanese reading it does not find clearly more likely, to offer as letters. `logProbability` scores the reading
    /// with the given Latin words
    @MainActor private static func addingUnnaturalJapanese(
        _ possibleWords: [ScriptSegmentation.PossibleWord],
        to words: [LatinInputGuess.Span],
        logProbability: ([LatinInputGuess.Span]) -> Float?
    ) -> (words: [LatinInputGuess.Span], offered: [LatinInputGuess.Span]) {
        var words = words
        var offered: [LatinInputGuess.Span] = []
        for possible in possibleWords where !words.contains(where: { $0.keys.overlaps(possible.word.keys) }) {
            let added = (words + [possible.word]).sorted { $0.keys.lowerBound < $1.keys.lowerBound }
            guard let asKana = logProbability(words), let asLetters = logProbability(added) else {
                continue
            }
            if asLetters - asKana > Self.unnaturalJapaneseMargin {
                words = added
            } else if asLetters - asKana > -Self.naturalJapaneseMargin {
                offered.append(possible.word)
            }
        }
        return (words, offered)
    }

    /// What the converter sees for `segmentation` of `input` (see `latinWordsConversionText`)
    @MainActor private func conversion(of input: TypedInput, segmentation: ScriptSegmentation) -> LatinWordsConversion {
        var elements = self.composingText.input
        for word in segmentation.latinWords {
            for (offset, character) in zip(word.keys, word.word) {
                elements[input.elementIndices[offset]] = .init(piece: .character(character), inputStyle: .direct)
            }
            // An n left on its own before the word is ん (アニメーショnGIF is アニメーションGIF), as a trailing n is at
            // the end of the input: the letters of the word no longer read it as romaji. Not when the n ends a Latin word
            // itself (win|dows, cut by the end of the clause)
            let start = word.keys.lowerBound
            if start > 0, input.keys[start - 1] == "n", input.prefixKana[start].last == "n",
               !segmentation.latinWords.contains(where: { $0.keys.contains(start - 1) }) {
                elements[input.elementIndices[start - 1]] = .init(piece: .character("ん"), inputStyle: .direct)
            }
        }
        for index in self.halfWidthHyphens(in: input, latinWords: segmentation.latinWords) {
            elements[input.elementIndices[index]] = .init(piece: .character("-"), inputStyle: .direct)
        }
        for index in segmentation.openCapitals + segmentation.romajiCapitals {
            let element = elements[input.elementIndices[index]]
            let lowercased = Character(input.keys[index].lowercased())
            elements[input.elementIndices[index]] = .init(piece: .key(intention: nil, input: lowercased, modifiers: []), inputStyle: element.inputStyle)
        }
        var text = ComposingText()
        // Conversion of each prefix of the keys as the converter sees them, to find where a capitalized word may end
        var convertedPrefixes = [""]
        for element in elements {
            text.insertAtCursorPosition([element])
            if case .compositionSeparator = element.piece {
                continue
            }
            convertedPrefixes.append(text.convertTarget)
        }
        if !self.composingText.isAtEndIndex {
            // Keep the cursor at the same key: the clause being converted ends there (Shift+← / → move it)
            let keysBeforeCursor = self.composingText.prefixToCursorPosition().input.count
            var prefix = ComposingText()
            prefix.insertAtCursorPosition(Array(elements.prefix(keysBeforeCursor)))
            _ = text.moveCursorFromCursorPosition(count: prefix.convertTarget.count - text.convertTargetCursorPosition)
        }
        return LatinWordsConversion(
            text: text,
            words: segmentation.latinWords.map { input.elementIndices[$0.keys.lowerBound] ..< input.elementIndices[$0.keys.upperBound - 1] + 1 },
            capitalizedWords: Self.capitalizedWordEntries(
                keys: input.keys,
                capitals: segmentation.openCapitals,
                knownWords: segmentation.latinWords,
                convertedPrefixes: convertedPrefixes
            ),
            uncertainWords: Self.uncertainWordEntries(input: input, words: segmentation.uncertainWords)
        )
    }

    /// The hyphens typed right after a Latin word or a digit (Wi-Fi, UTF-8, 3-2-1), and after such a hyphen, when
    /// symbols are typed in half width: they are written as -, not ー. In romaji - is the long vowel mark, which only
    /// follows kana, so after letters written as letters or after digits it is a hyphen or a minus. Before digits after
    /// kana it can be either (気温は-5度, コーヒー1杯), and it stays ー
    private func halfWidthHyphens(in input: TypedInput, latinWords: [LatinInputGuess.Span]) -> [Int] {
        guard self.context.typeHalfWidthSymbols ?? Config.TypeHalfWidthSymbols().value else {
            return []
        }
        var hyphens: [Int] = []
        for index in input.keys.indices.dropFirst() where input.keys[index] == "-" {
            let previous = index - 1
            let key = input.keys[previous]
            if key.isASCII && key.isNumber || latinWords.contains(where: { $0.keys.contains(previous) }) || hyphens.last == previous {
                hyphens.append(index)
            }
        }
        return hyphens
    }

    /// The words the identification layer left to the converter that the converter writes as letters by its own
    /// dictionary and connection costs, without Zenzai (token for とけん, but 酒 for さけ): the temporary entries of
    /// `conversion` offered, its best conversion of the whole input read for them
    @MainActor private func wordsWrittenByConverter(_ conversion: LatinWordsConversion, uncertain: [ScriptSegmentation.UncertainWord], input: TypedInput) -> [LatinInputGuess.Span] {
        let leftSideContext = self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        let result = self.withConverter(.plain) { converter in
            converter.importDynamicUserDictionary(conversion.entries)
            self.startingOverForChangedEntries(conversion.entries, plain: true, converter: converter)
            return converter.requestCandidates(
                conversion.text,
                options: self.options(
                    leftSideContext: leftSideContext,
                    rightSideContext: nil,
                    requestRichCandidates: false,
                    requireJapanesePrediction: .disabled,
                    requireEnglishPrediction: .disabled,
                    zenzai: false
                )
            )
        }
        let counted = Self.countingInputs(of: result, convertedFrom: conversion.text, words: conversion.words)
        guard let best = counted.mainResults.first(where: { self.composingText.isWholeComposingText(composingCount: $0.composingCount) }) else {
            return []
        }
        return uncertain.compactMap { word in
            guard let ruby = input.kana(of: word.keys)?.toKatakana(),
                  let written = best.data.first(where: { $0.ruby == ruby && ($0.word == word.word || $0.word == word.spelling) }) else {
                return nil
            }
            return LatinInputGuess.Span(word: written.word, keys: word.keys)
        }
    }

    /// Temporary dictionary entries for the words the identification layer is not sure about (see
    /// `ScriptSegmentation.uncertainWords`): the letters, for the kana their keys make, priced by the layer's odds of the
    /// word against romaji on the converter's scale. Even odds cost 12, like an uncommon word; each unit of log-odds moves
    /// that by 2, so a word at 0.9 beats most Japanese words for its reading and one at 0.1 only readings no word covers well
    private static func uncertainWordEntries(input: TypedInput, words: [ScriptSegmentation.UncertainWord]) -> [DicdataElement] {
        var entries: [DicdataElement] = []
        for word in words {
            guard let kana = input.kana(of: word.keys) else {
                continue
            }
            let odds = log(word.probability / word.romajiProbability)
            let value = PValue(max(-20, min(-5, -12 + 2 * odds)))
            entries.append(DicdataElement(word: word.word, ruby: kana.toKatakana(), cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value))
            if let spelling = word.spelling {
                // The known spelling, slightly preferred to the letters as typed (API for api)
                entries.append(DicdataElement(word: spelling, ruby: kana.toKatakana(), cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value + 0.5))
            }
        }
        return entries
    }

    /// Temporary dictionary entries for each way a word typed with a capital may end (O, Ogu, Ogura, Oguradesu, ...)
    /// - Parameters:
    ///   - capitals: Where the capitals are in `keys`
    ///   - knownWords: The known Latin words, which a capitalized word stops before
    ///   - convertedPrefixes: `convertedPrefixes[i]` is the conversion of the first `i` keys as the converter sees them
    private static func capitalizedWordEntries(keys: [Character], capitals: [Int], knownWords: [LatinInputGuess.Span], convertedPrefixes: [String]) -> [DicdataElement] {
        let converted = convertedPrefixes.last ?? ""
        var entries: [DicdataElement] = []
        for (position, start) in capitals.enumerated() where converted.hasPrefix(convertedPrefixes[start]) {
            // The word ends before the next capital or known word
            let limit = ([keys.count] + capitals[(position + 1)...] + knownWords.map(\.keys.lowerBound).filter { $0 > start }).min() ?? keys.count
            for end in start + 1 ... max(start + 1, limit) where end <= limit && converted.hasPrefix(convertedPrefixes[end])
                && convertedPrefixes[end].count >= convertedPrefixes[start].count {
                guard keys[start ..< end].allSatisfy({ $0.isASCII && $0.isLetter }) else {
                    break
                }
                let reading = converted.dropFirst(convertedPrefixes[start].count).prefix(convertedPrefixes[end].count - convertedPrefixes[start].count)
                // A reading with letters left over would not match the converter's dictionary search
                guard !reading.contains(where: \.isASCII) else {
                    continue
                }
                // A word typed in Latin letters is followed by a particle or the like in Japanese text (Ogura|は, Kyou|は);
                // ending it anywhere else splits it oddly (Kyo|う, where う reads as 雨)
                let endsWell = RuleBasedScriptIdentifier.followsLatinWord(String(converted.dropFirst(convertedPrefixes[end].count)))
                entries.append(DicdataElement(
                    word: String(keys[start ..< end]),
                    ruby: String(reading).toKatakana(),
                    cid: CIDData.固有名詞.cid,
                    mid: MIDData.一般.mid,
                    // Cheaper than any Japanese word for the same reading, the capital having been typed on purpose, and
                    // dearer the longer it runs, so the converter ends it before a particle (Ogura|です rather than
                    // Oguradesu) and does not take a whole Japanese sentence typed with a capital for one word
                    value: -2 * PValue(reading.count) - 0.5 * PValue(reading.count * reading.count) - (endsWell ? 0 : 4)
                ))
            }
        }
        return entries
    }

    /// Moves the best conversion that writes the capitalized words as typed to the top when the converter's own score
    /// puts it first. Zenzai ranks it low because the reading (オグラ) usually means a Japanese word, so without this it
    /// shows これは小倉です first
    static func promotingCapitalizedWords(_ result: ConversionResult, words: [DicdataElement], isWholeInput: (ComposingCount) -> Bool) -> ConversionResult {
        guard !words.isEmpty else {
            return result
        }
        var result = result
        // The best of them by the converter's own score, not the first Zenzai lists: that can be one long word for the
        // whole input (Kyouhaiitenkidesu) where Kyou|はいい天気です scores far better
        let index = result.mainResults.indices
            .filter { index in
                isWholeInput(result.mainResults[index].composingCount) && result.mainResults[index].data.contains { element in
                    words.contains { $0.word == element.word && $0.ruby == element.ruby }
                }
            }
            .max { result.mainResults[$0].value < result.mainResults[$1].value }
        // When the converter itself prefers Japanese (今日はいい天気です for Kyouhaiitenkidesu), leave it
        if let index, let top = result.mainResults.first, result.mainResults[index].value >= top.value {
            result.mainResults.insert(result.mainResults.remove(at: index), at: 0)
        }
        return result
    }

    /// Puts a conversion that writes only Latin letters the user typed first, when the first one writes letters that
    /// were not typed (see `writesUntypedLetters`); the other conversion stays among the candidates. When its words of
    /// the dictionary wrote the letters for kana (Windows for ウインドウズ typed as uindouzu), the same conversion with
    /// those words written as their readings goes first: every conversion can have such a word, and the only one left
    /// would be the whole input in katakana
    static func preferringTypedLetters(_ result: ConversionResult, typed: String, allowed: [DicdataElement] = [], isWholeInput: (ComposingCount) -> Bool) -> ConversionResult {
        guard let first = result.mainResults.first, Self.writesUntypedLetters(first, typed: typed, allowed: allowed) else {
            return result
        }
        var result = result
        if let written = Self.writingReadings(of: first, typed: typed, allowed: allowed) {
            if let index = result.mainResults.firstIndex(where: { $0.text == written.text && !Self.writesUntypedLetters($0, typed: typed, allowed: allowed) }) {
                result.mainResults.insert(result.mainResults.remove(at: index), at: 0)
            } else {
                result.mainResults.insert(written, at: 0)
            }
            return result
        }
        guard let index = result.mainResults.firstIndex(where: { candidate in
            isWholeInput(candidate.composingCount) == isWholeInput(first.composingCount) && !Self.writesUntypedLetters(candidate, typed: typed, allowed: allowed)
        }) else {
            return result
        }
        result.mainResults.insert(result.mainResults.remove(at: index), at: 0)
        return result
    }

    /// `candidate` with its words that write Latin letters for a kana reading (see `writesLettersForKana`) written as
    /// their readings, except the entries in `allowed`: 例えばwindowsと書けばWindowsに becomes 例えばwindowsと書けば
    /// ウインドウズに. Nil when it has no such word, or would still write letters that were not typed
    static func writingReadings(of candidate: Candidate, typed: String, allowed: [DicdataElement] = []) -> Candidate? {
        guard candidate.text == candidate.data.map(\.word).joined() else {
            return nil
        }
        var written = candidate
        written.data = candidate.data.map { element in
            guard Self.writesLettersForKana(element), !allowed.contains(where: { $0.word == element.word && $0.ruby == element.ruby }) else {
                return element
            }
            var element = element
            element.word = element.ruby
            return element
        }
        written.text = written.data.map(\.word).joined()
        guard written.text != candidate.text, !Self.writesUntypedLetters(written, typed: typed, allowed: allowed) else {
            return nil
        }
        return written
    }

    /// Whether `text` has Latin letters that are not among the keys `typed`, whatever their case. Zenzai can write a word
    /// typed in romaji in English (note for no-to, hotel for hoteru), but Latin letters belong where the user typed them
    /// (GitHub for github)
    static func writesUntypedLetters(_ text: String, typed: String) -> Bool {
        let typed = typed.lowercased()
        return text.split { !($0.isASCII && $0.isLetter) }.contains { !typed.contains($0.lowercased()) }
    }

    /// Whether `candidate` writes Latin letters the user did not type: by its text (see above), or by a word of its that
    /// writes letters for a kana reading (JAM for ジャム typed as jamu, which the text alone lets through when the keys
    /// happen to spell the letters: REDjamu). The entries in `allowed` are meant to do that (Ogura for オグラ)
    static func writesUntypedLetters(_ candidate: Candidate, typed: String, allowed: [DicdataElement] = []) -> Bool {
        Self.writesUntypedLetters(candidate.text, typed: typed) || candidate.data.contains { element in
            Self.writesLettersForKana(element) && !allowed.contains { $0.word == element.word && $0.ruby == element.ruby }
        }
    }

    /// Whether `element` writes Latin letters its reading does not have: it wrote them for kana (JAM for ジャム). Letters
    /// typed as they are, and a letter still being typed after kana (アイk), are in the reading, in full width
    private static func writesLettersForKana(_ element: DicdataElement) -> Bool {
        let reading = Set(element.ruby.lowercased().unicodeScalars.map(Self.narrowed))
        return element.word.contains { character in
            character.isASCII && character.isLetter && !character.lowercased().unicodeScalars.allSatisfy { reading.contains($0) }
        }
    }

    /// Full-width ASCII narrowed (ｋ is k)
    private static func narrowed(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        (0xFF01 ... 0xFF5E).contains(scalar.value) ? Unicode.Scalar(scalar.value - 0xFF01 + 0x21) ?? scalar : scalar
    }

    /// The first clauses for `converted`: the first clause of its best conversion (see `firstClause(of:)`), its words
    /// that write letters for kana written as their readings, then the converter's own first clauses. The converter orders
    /// those longest first, from several conversions, and one of them can be the whole of what is left (東京に行きます):
    /// committing that clause would commit everything. None when the best conversion is one clause, so the clause
    /// converted is the whole input
    static func firstClauses(of converted: ConversionResult, typed: String, allowed: [DicdataElement]) -> [Candidate] {
        guard let best = converted.mainResults.first, let clause = Self.firstClause(of: best) else {
            return converted.firstClauseResults
        }
        guard clause.text != best.text else {
            return []
        }
        var chosen = clause
        if Self.writesUntypedLetters(chosen, typed: typed, allowed: allowed) {
            chosen = Self.writingReadings(of: chosen, typed: typed, allowed: allowed) ?? chosen
        }
        return [chosen] + converted.firstClauseResults.filter { $0.text != chosen.text }
    }

    /// The first clause of `candidate`, by the converter's own rule for where a clause ends (a word that is not a
    /// function word after one that is not a prefix), applied to words. The converter's entries can be phrases (はいい
    /// for は and いい, に行き), whose part-of-speech ids at the two ends differ: each is cut where the system's tokenizer
    /// finds words, and the ids go to its first and last words (the words between count as content words unless written
    /// in hiragana). An entry with the same ids at both ends is one word, though the tokenizer may cut it (長さ). A Latin
    /// word counts as one word: the converter reads a word typed as letters as one word for each letter
    static func firstClause(of candidate: Candidate) -> Candidate? {
        guard candidate.text == candidate.data.map(\.word).joined(), !candidate.data.isEmpty else {
            return nil
        }
        // Each piece, as the converter's rule sees it, and the elements of the candidate it stands for
        var pieces: [(element: DicdataElement, data: [DicdataElement])] = []
        func isLetters(_ word: String) -> Bool {
            !word.isEmpty && word.allSatisfy { $0.isASCII && $0.isLetter }
        }
        for element in candidate.data {
            if isLetters(element.word), let last = pieces.last, isLetters(last.element.word) {
                let merged = DicdataElement(
                    word: last.element.word + element.word,
                    ruby: last.element.ruby + element.ruby,
                    lcid: last.element.lcid,
                    rcid: element.rcid,
                    mid: element.mid,
                    value: last.element.value() + element.value()
                )
                pieces[pieces.count - 1] = (merged, last.data + [element])
            } else {
                pieces.append((element, [element]))
            }
        }
        // Words of the text, as the system's tokenizer finds them
        let text = candidate.text
        var boundaries: Set<Int> = []
        let tagger = NLTagger(tagSchemes: [.tokenType])
        tagger.string = text
        tagger.setLanguage(.japanese, range: text.startIndex ..< text.endIndex)
        tagger.enumerateTags(in: text.startIndex ..< text.endIndex, unit: .word, scheme: .tokenType, options: []) { _, range in
            boundaries.insert(text.distance(from: text.startIndex, to: range.lowerBound))
            return true
        }
        var words: [(element: DicdataElement, data: [DicdataElement])] = []
        var offset = 0
        for piece in pieces {
            let count = piece.element.word.count
            let cuts = boundaries.filter { offset < $0 && $0 < offset + count }.sorted()
            offset += count
            guard !cuts.isEmpty, piece.data.count == 1, piece.element.lcid != piece.element.rcid,
                  let split = Self.splitting(piece.element, at: cuts.map { $0 - (offset - count) }) else {
                words.append(piece)
                continue
            }
            words += split.map { ($0, [$0]) }
        }
        let clause = Candidate.makePrefixClauseCandidate(data: words.map(\.element))
        let data = words.prefix(clause.data.count).flatMap(\.data)
        guard !data.isEmpty else {
            return nil
        }
        return Candidate(
            text: data.map(\.word).joined(),
            value: clause.value,
            composingCount: .surfaceCount(data.reduce(0) { $0 + $1.ruby.count }),
            lastMid: clause.lastMid,
            data: data
        )
    }

    /// `element` as words cut at `offsets` of its text, each with its reading. Only words in kana have a reading of their
    /// own, so the words from the first one not in kana to the last one stay together (の|使い方 of の使い方, though
    /// 使い and 方 are words). The first word takes the entry's left part-of-speech id and the last its right one; a
    /// word between is a content word unless it is in hiragana, then a function word. Nil when nothing is left to cut
    private static func splitting(_ element: DicdataElement, at offsets: [Int]) -> [DicdataElement]? {
        let characters = Array(element.word)
        let bounds = [0] + offsets + [characters.count]
        var surfaces = zip(bounds, bounds.dropFirst()).map { String(characters[$0 ..< $1]) }
        func isKana(_ text: String) -> Bool {
            text.unicodeScalars.allSatisfy { (0x3041 ... 0x309F).contains($0.value) || (0x30A0 ... 0x30FF).contains($0.value) }
        }
        if let first = surfaces.firstIndex(where: { !isKana($0) }), let last = surfaces.lastIndex(where: { !isKana($0) }), first < last {
            surfaces[first ... last] = [surfaces[first ... last].joined()]
        }
        guard surfaces.count > 1 else {
            return nil
        }
        let readings = surfaces.map { isKana($0) ? $0.toKatakana() : nil }
        let unknown = readings.indices.filter { readings[$0] == nil }
        var resolved = readings
        if let index = unknown.first {
            let before = readings[..<index].compactMap { $0 }.joined()
            let after = readings[(index + 1)...].compactMap { $0 }.joined()
            guard element.ruby.hasPrefix(before), element.ruby.hasSuffix(after), element.ruby.count > before.count + after.count else {
                return nil
            }
            resolved[index] = String(element.ruby.dropFirst(before.count).dropLast(after.count))
        }
        guard resolved.compactMap({ $0 }).joined() == element.ruby else {
            return nil
        }
        return surfaces.indices.map { index in
            let cid: Int
            if index == 0 {
                cid = element.lcid
            } else if index == surfaces.count - 1 {
                cid = element.rcid
            } else {
                cid = surfaces[index].unicodeScalars.allSatisfy { (0x3041 ... 0x309F).contains($0.value) } ? CIDData.助動詞デス基本形.cid : CIDData.一般名詞.cid
            }
            return DicdataElement(word: surfaces[index], ruby: resolved[index] ?? "", cid: cid, mid: element.mid, value: element.value() / PValue(surfaces.count))
        }
    }

    /// Makes candidates converted from `text` count keys rather than converted characters, which differ between `text`
    /// and the input it was made from (see `latinWordsConversionText`). Drops candidates that end inside one of the
    /// Latin `words` (h of hello): committing them would leave the rest of the word to be read as romaji again.
    static func countingInputs(of result: ConversionResult, convertedFrom text: ComposingText, words: [Range<Int>]) -> ConversionResult {
        func counted(_ candidates: [Candidate]) -> [Candidate] {
            candidates.compactMap { candidate in
                var candidate = candidate
                var rest = text
                rest.prefixComplete(composingCount: candidate.composingCount)
                let count = text.input.count - rest.input.count
                guard !words.contains(where: { $0.lowerBound < count && count < $0.upperBound }) else {
                    return nil
                }
                candidate.composingCount = .inputCount(count)
                return candidate
            }
        }
        var result = result
        result.mainResults = counted(result.mainResults)
        result.firstClauseResults = counted(result.firstClauseResults)
        result.predictionResults = counted(result.predictionResults)
        return result
    }

    /// Guesses, when the input is converted for selection, whether it was meant as Latin letters rather than Japanese
    @MainActor private func makeLatinCandidate(result: ConversionResult) -> (candidate: Candidate, rank: Int)? {
        guard Config.LatinCandidateForNonJapaneseInput().value, !self.isAlphabetWordInput,
              self.composingText.input.last?.piece == .compositionSeparator else {
            return nil
        }
        guard self.composingText.input.allSatisfy({ $0.inputStyle != .direct }) else {
            return nil
        }
        let input = self.composingText.input.map(\.piece).inputString(preferIntention: false)
        // A word for the whole reading. The plain kana fallbacks the converter adds for any input do not count
        let readingIsWord = (result.mainResults + result.firstClauseResults).contains { candidate in
            candidate.data.count == 1
                && self.composingText.isWholeComposingText(composingCount: candidate.composingCount)
                && !(candidate.data[0].lcid == CIDData.固有名詞.cid && candidate.data[0].mid == MIDData.一般.mid)
        }
        guard let guess = LatinInputGuess.guess(
            input: input,
            kana: self.composingText.convertTarget,
            readingIsWord: readingIsWord,
            knownWord: LatinInputGuess.systemKnownWord
        ) else {
            return nil
        }
        let candidate = Candidate(
            text: guess.text,
            value: 0,
            composingCount: .inputCount(self.composingText.input.count),
            lastMid: MIDData.一般.mid,
            data: [DicdataElement(word: guess.text, ruby: input, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: 0)]
        )
        return (candidate, guess.rank)
    }

    /// Candidates during English input: the letters as typed first, followed by full-width, lowercase, and uppercase variants.
    private var alphabetWordCandidates: [Candidate] {
        let inputString = self.composingText.input.map(\.piece).inputString(preferIntention: false)
        let transforms: [(String) -> String] = [
            { $0 },
            { $0.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? $0 },
            { $0.lowercased() },
            { $0.uppercased() }
        ]
        var seen: Set<String> = []
        return transforms.compactMap { transform in
            let text = transform(inputString)
            guard seen.insert(text).inserted else {
                return nil
            }
            return Candidate(
                text: text,
                value: 0,
                composingCount: .inputCount(self.composingText.input.count),
                lastMid: 0,
                data: [DicdataElement(word: text, ruby: inputString, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: 0)]
            )
        }
    }

    private var rawCandidatesList: [Candidate]? {
        guard let rawCandidates else {
            return nil
        }
        if !self.didExperienceSegmentEdition {
            let isWhole = { (candidate: Candidate) in self.composingText.isWholeComposingText(composingCount: candidate.composingCount) }
            // The first of the first clauses is the clause converted (see `firstClauses`). The converter's own first
            // clauses are longest first, so then any of them that is the whole input makes it the clause
            let wholeInput = self.context.convertsAsTheConverterDoes
                ? rawCandidates.firstClauseResults.contains(where: isWhole) : rawCandidates.firstClauseResults.first.map(isWhole) ?? true
            if wholeInput {
                // If firstClauseCandidate is the same size as mainResults, it is better to do nothing
                return rawCandidates.mainResults
            } else {
                // When the conversion range has not been edited
                let seenAsFirstClauseResults = rawCandidates.firstClauseResults.mapSet(transform: \.text)
                return rawCandidates.firstClauseResults + rawCandidates.mainResults.filter {
                    !seenAsFirstClauseResults.contains($0.text)
                }
            }
        } else {
            return rawCandidates.mainResults
        }
    }

    private var candidateOffsetByAdditionalCandidates: Int {
        self.isShowingAdditionalCandidates ? self.showingAdditionalCandidateCount : 0
    }

    private var additionalCandidatesForSelectionIndex: [Candidate] {
        self.additionalCandidatePresentationsForSelectionIndex.map(\.candidate)
    }

    private var additionalCandidatePresentationsForSelectionIndex: [CandidatePresentation] {
        guard self.isShowingAdditionalCandidates else {
            return []
        }
        guard self.candidateOffsetByAdditionalCandidates > 0 else {
            return []
        }
        return Array(self.additionalCandidates.suffix(self.candidateOffsetByAdditionalCandidates))
    }

    public var convertTarget: String {
        self.composingText.convertTarget
    }

    public var isEmpty: Bool {
        self.composingText.isEmpty
    }

    @MainActor
    public func getCleanLeftSideContext(maxCount: Int) -> String? {
        self.delegate?.getLeftSideContext(maxCount: maxCount).map {
            var last = $0.split(separator: "\n", omittingEmptySubsequences: false).last ?? $0[...]
            // Remove leading whitespace
            while last.first?.isWhitespace ?? false {
                last = last.dropFirst()
            }
            return String(last)
        }
    }

    @MainActor
    public func getCleanRightSideContext(maxCount: Int) -> String? {
        self.delegate?.getRightSideContext(maxCount: maxCount).map {
            var first = $0.split(separator: "\n", omittingEmptySubsequences: false).first ?? $0[...]
            // Remove trailing whitespace
            while first.last?.isWhitespace ?? false {
                first = first.dropLast()
            }
            return String(first)
        }
    }

    /// Updates the `self.rawCandidates` based on the current input context.
    ///
    /// This function is responsible for handling candidate conversion,
    /// taking into account partial confirmations and optionally fetching rich candidates.
    /// It also allows an override for the left-side context when necessary.
    ///
    /// - Parameters:
    ///   - requestRichCandidates: A Boolean flag indicating whether to fetch rich candidates (default is `false`). Generating rich candidates takes longer time.
    ///   - forcedLeftSideContext: An optional string that overrides the left-side context (default is `nil`).
    ///
    /// - Note:
    ///   This function is executed on the `@MainActor` to ensure UI consistency.
    @MainActor private func updateRawCandidate(
        requestRichCandidates: Bool = false,
        forcedLeftSideContext: String? = nil,
        forcedRightSideContext: String? = nil
    ) {
        self.resetAdditionalCandidates()
        self.latinCandidate = nil
        // Not needed
        if composingText.isEmpty {
            self.rawCandidates = nil
            self.latinWordsInput = nil
            self.isAlphabetWordInput = false
            self.stopConversion()
            return
        }
        /// Pre-register date and time conversions
        let dynamicShortcuts: [DicdataElement] =
            [
                ("M/d", -18, DateTemplateLiteral.CalendarType.western),
                ("yyyy/MM/dd", -18.1, .western),
                ("yyyy-MM-dd", -18.2, .western),
                ("M月d日（E）", -18.3, .western),
                ("yyyy年M月d日", -18.4, .western),
                ("Gyyyy年M月d日", -18.5, .japanese),
                ("E曜日", -18.6, .western)
            ].flatMap { (format, value: PValue, type) in
                [
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "-2", deltaUnit: 60 * 60 * 24).export(), ruby: "オトトイ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "-1", deltaUnit: 60 * 60 * 24).export(), ruby: "キノウ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "キョウ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "1", deltaUnit: 60 * 60 * 24).export(), ruby: "アシタ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "2", deltaUnit: 60 * 60 * 24).export(), ruby: "アサッテ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value)
                ]
            } + [
                // Month
                .init(word: DateTemplateLiteral(format: "MM月", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コンゲツ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                // Year
                .init(word: DateTemplateLiteral(format: "yyyy年", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コトシ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                .init(word: DateTemplateLiteral(format: "Gyyyy年", type: .japanese, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コトシ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.1),
                // Time
                .init(word: DateTemplateLiteral(format: "HH:mm", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                .init(word: DateTemplateLiteral(format: "HH時mm分", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.1),
                .init(word: DateTemplateLiteral(format: "aK時mm分", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.2)
            ]

        let latinWordsText = self.context.convertsAsTheConverterDoes ? nil : self.latinWordsConversionText(otherReading: requestRichCandidates)
        self.withConverter { $0.importDynamicUserDictionary(latinWordsText?.entries ?? [], shortcuts: dynamicShortcuts) }

        let leftSideContext = forcedLeftSideContext ?? self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        let rightSideContext = forcedRightSideContext ?? self.getCleanRightSideContext(maxCount: ContextLength.conversion)
        // Zenzai converts around the first Latin word, which is left context for it (see `contextWord`)
        let contextWord = self.context.useZenzai ? latinWordsText.flatMap { Self.contextWord(of: $0) } : nil
        let contextName = contextWord.flatMap { self.japaneseName(of: $0.word) }
        func convert(zenzai: Bool) -> ConversionResult {
            var text = latinWordsText?.text ?? self.composingText
            var leftSideContext = leftSideContext
            let withZenzai = zenzai && self.context.useZenzai
            // The word converted around, and the conversion of the input before it
            var around: (head: Candidate?, word: ContextWord)?
            if withZenzai, let contextWord {
                let start = contextWord.elements.lowerBound
                if start == 0 {
                    around = (nil, contextWord)
                } else if contextName != nil {
                    var before = ComposingText()
                    before.insertAtCursorPosition(Array(text.input[..<start]))
                    // The name is the right context of the head: 橋は before Osaka, where はしは alone reads otherwise
                    let head = self.withConverter(.head) { converter in
                        converter.requestCandidates(
                            before,
                            options: self.options(
                                leftSideContext: leftSideContext,
                                rightSideContext: contextName,
                                requestRichCandidates: false,
                                requireJapanesePrediction: .disabled,
                                requireEnglishPrediction: .disabled
                            )
                        ).mainResults.first
                    }
                    if let head {
                        around = (head, contextWord)
                    }
                }
            }
            if let around {
                text.prefixComplete(composingCount: .inputCount(around.word.elements.upperBound))
                leftSideContext = (leftSideContext ?? "") + (around.head?.text ?? "") + (contextName ?? around.word.word)
            }
            // Zenzai converts up to the cursor that Shift+← / → moved, and the converter on its own the whole input: in
            // place of Zenzai, it gets the part up to the cursor, or the clause would cover the whole input again
            let replacingZenzai = !zenzai && self.context.useZenzai
            return self.withConverter(replacingZenzai ? .plain : .input) { converter in
                // The sessions where the converter decides by the entries (Zenzai rejects candidates made from them)
                if !withZenzai {
                    self.startingOverForChangedEntries(latinWordsText?.entries ?? [], plain: replacingZenzai, converter: converter)
                }
                let result = converter.requestCandidates(
                    replacingZenzai && !text.isAtEndIndex ? text.prefixToCursorPosition() : text,
                    options: self.options(
                        leftSideContext: leftSideContext,
                        rightSideContext: rightSideContext,
                        requestRichCandidates: requestRichCandidates,
                        requireJapanesePrediction: Config.DebugPredictiveTyping().value ? .manualMix : .disabled,
                        requireEnglishPrediction: Config.DebugPredictiveTyping().value ? .manualMix : .disabled,
                        zenzai: zenzai
                    )
                )
                if let around {
                    return Self.joining(around.head, around.word, result)
                }
                return result
            }
        }
        let typed = self.composingText.input.map(\.piece).inputString(preferIntention: false)
        let allowed = latinWordsText?.entries ?? []
        func counting(_ result: ConversionResult) -> ConversionResult {
            guard let latinWordsText else {
                return result
            }
            let counted = Self.countingInputs(of: result, convertedFrom: latinWordsText.text, words: latinWordsText.words)
            return Self.promotingCapitalizedWords(counted, words: latinWordsText.entries) {
                self.composingText.isWholeComposingText(composingCount: $0)
            }
        }
        let result = convert(zenzai: true)
        if self.context.convertsAsTheConverterDoes {
            self.rawCandidates = result
            self.hasLatinWords = false
            self.latinWordsInput = nil
            self.latinCandidate = self.makeLatinCandidate(result: result)
            return
        }
        var converted = result
        var candidates = counting(converted)
        if self.context.useZenzai, let first = candidates.mainResults.first, Self.writesUntypedLetters(first, typed: typed, allowed: allowed) {
            // Zenzai wrote a word typed in romaji in English (note for no-to). The candidates it leaves are the plain
            // kana readings of the input, so the converter's own conversion takes over
            converted = convert(zenzai: false)
            candidates = counting(converted)
        }
        if requestRichCandidates {
            // The clauses are shown (Space, or a clause committed): the first one is that of the best conversion
            converted.firstClauseResults = Self.firstClauses(of: converted, typed: typed, allowed: allowed)
            candidates = counting(converted)
        }
        self.rawCandidates = Self.preferringTypedLetters(candidates, typed: typed, allowed: allowed) {
            self.composingText.isWholeComposingText(composingCount: $0)
        }
        if let otherReading = latinWordsText?.otherReading, let rawCandidates = self.rawCandidates {
            // The converter on its own converts the other reading: Zenzai would take the time of a second conversion, and
            // the reading is only offered
            let readTheOtherWay = self.withConverter(.plain) { converter in
                self.startingOverForChangedEntries(allowed, plain: true, converter: converter)
                return converter.requestCandidates(
                    otherReading.text.isAtEndIndex ? otherReading.text : otherReading.text.prefixToCursorPosition(),
                    options: self.options(
                        leftSideContext: leftSideContext,
                        rightSideContext: rightSideContext,
                        requestRichCandidates: true,
                        requireJapanesePrediction: .disabled,
                        requireEnglishPrediction: .disabled,
                        zenzai: false
                    )
                )
            }
            var other = readTheOtherWay
            other.firstClauseResults = Self.firstClauses(of: readTheOtherWay, typed: typed, allowed: allowed)
            other = Self.countingInputs(of: other, convertedFrom: otherReading.text, words: otherReading.words)
            self.rawCandidates = Self.offering(other, in: rawCandidates)
        }
        self.hasLatinWords = latinWordsText != nil
        self.latinWordsInput = latinWordsText?.text
        self.latinCandidate = self.makeLatinCandidate(result: result)
    }

    /// A Latin word typed as letters that Zenzai converts around (see `contextWord`)
    struct ContextWord: Equatable {
        var word: String
        /// The elements of the input the word takes
        var elements: Range<Int>
    }

    /// The first Latin word of the input of `conversion`, when keys to convert follow it before the cursor. Zenzai
    /// given letters in its input tends to copy the kana after them as they are (Osakaしにいきます for Osakashiniikimasu,
    /// above 市に行きます), to go on in letters (Ken for けん after Kanagawa), or to read the letters as a person's name
    /// (Osaka氏). So the input is converted around the word: the keys after it are the input, and the word, as the
    /// Japanese name it stands for when the dictionary knows one (see `japaneseName`), ends the left context, after the
    /// conversion of the keys before it. Zenzai then reads 市に行きます after Osaka as it does after 大阪. A word at the
    /// start of the input is converted around whether or not it is a name, since letters at the start are what Zenzai
    /// copies; a word in the middle only when it is a name, to leave the rest to one conversion. The candidates get the
    /// text before the word and the word back in front (see `joining`), so they still cover the whole input
    static func contextWord(of conversion: LatinWordsConversion) -> ContextWord? {
        // The cursor that Shift+← / → moved: a clause ending at or inside the word is converted as a whole
        let cursor = conversion.text.prefixToCursorPosition().input.count
        guard let range = conversion.words.first, range.upperBound < cursor else {
            return nil
        }
        let letters = conversion.text.input[range].compactMap { element -> Character? in
            if case .character(let character) = element.piece { character } else { nil }
        }
        var rest = conversion.text
        rest.prefixComplete(composingCount: .inputCount(range.upperBound))
        guard letters.count == range.count, !rest.prefixToCursorPosition().convertTarget.isEmpty else {
            return nil
        }
        return ContextWord(word: String(letters), elements: range)
    }

    /// The last Japanese name looked up (see `japaneseName`): the same word is asked about at each key typed after it
    /// The names `japaneseName` looked up, by word
    private var japaneseNames: [String: String?] = [:]

    /// How many of the o and u in a word typed with a capital are tried as long vowels (see `japaneseName`)
    static let longVowelsTried = 3

    /// The Japanese name that `word`, a Latin word typed with a capital, stands for in the converter's dictionary (大阪 for
    /// Osaka, 神奈川 for Kanagawa, 井上 for Inoue), or nil when it stands for none the dictionary knows (Python, Win). Zenzai
    /// does not know the names in letters: after Osaka it writes 氏 for し, after 大阪 市, and after Kanagawa it goes on
    /// in letters (Ken for けん). The keys read as kana, with each of the first `longVowelsTried` o and u also tried as the
    /// long vowel that Hepburn romaji drops (おおさか for osaka, とうきょう for tokyo); the converter on its own converts each
    /// reading, and the name is the likeliest proper noun that covers a whole reading
    @MainActor private func japaneseName(of word: String) -> String? {
        if let cached = self.japaneseNames[word] {
            return cached
        }
        let name = self.lookUpJapaneseName(of: word)
        if self.japaneseNames.count >= 256 {
            self.japaneseNames.removeAll()
        }
        self.japaneseNames[word] = name
        return name
    }

    @MainActor private func lookUpJapaneseName(of word: String) -> String? {
        guard let first = word.first, first.isUppercase, word.count >= 2,
              word.dropFirst().allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter }) else {
            return nil
        }
        let properNouns = CIDData.固有名詞.cid ... CIDData.地名一般.cid
        var best: (name: String, value: PValue)?
        for reading in self.readings(of: word.lowercased()) {
            var text = ComposingText()
            text.insertAtCursorPosition(reading, inputStyle: .direct)
            let result = self.withConverter(.lookup) { converter in
                converter.requestCandidates(
                    text,
                    options: self.options(
                        leftSideContext: nil,
                        rightSideContext: nil,
                        requestRichCandidates: false,
                        requireJapanesePrediction: .disabled,
                        requireEnglishPrediction: .disabled,
                        zenzai: false
                    )
                )
            }
            for candidate in result.mainResults where candidate.data.count == 1 && text.isWholeComposingText(composingCount: candidate.composingCount) {
                let entry = candidate.data[0]
                // The kana fallbacks the converter adds for any input are proper nouns in name only
                guard properNouns.contains(entry.lcid), !(entry.lcid == CIDData.固有名詞.cid && entry.mid == MIDData.一般.mid),
                      candidate.text != reading, candidate.text != reading.toKatakana(), candidate.text.contains(where: { !$0.isASCII }) else {
                    continue
                }
                if best == nil || candidate.value > best!.value {
                    best = (candidate.text, candidate.value)
                }
            }
        }
        return best?.name
    }

    /// The kana `romaji` reads as by the input's romaji table, with each of its first `longVowelsTried` o and u also read
    /// as the long vowel Hepburn romaji drops (おさか, おうさか and おおさか for osaka), in that order
    private func readings(of romaji: String) -> [String] {
        let inputStyle = self.composingText.input.first(where: { $0.inputStyle != .direct })?.inputStyle ?? .mapped(id: .defaultRomanToKana)
        var variants = [""]
        var varied = 0
        for key in romaji {
            var spellings = [String(key)]
            if varied < Self.longVowelsTried, let longVowels = ["o": ["ou", "oo"], "u": ["uu"]][String(key)] {
                spellings += longVowels
                varied += 1
            }
            variants = variants.flatMap { variant in spellings.map { variant + $0 } }
        }
        var readings: [String] = []
        for variant in variants {
            var text = ComposingText()
            for key in variant {
                text.insertAtCursorPosition([.init(piece: .key(intention: nil, input: key, modifiers: []), inputStyle: inputStyle)])
            }
            text.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: inputStyle)])
            let kana = text.convertTarget
            if !kana.isEmpty, !kana.contains(where: { $0.isASCII }), !readings.contains(kana) {
                readings.append(kana)
            }
        }
        return readings
    }

    /// `result`, converted from the input after `word`, with `head` (the conversion of the input before the word, if
    /// any) and the word written in front of each candidate, the word as letters typed as is (one entry per letter, as
    /// the converter reads such letters), and their keys counted (see `contextWord`)
    static func joining(_ head: Candidate?, _ word: ContextWord, _ result: ConversionResult) -> ConversionResult {
        let letters = word.word.map { letter in
            DicdataElement(word: String(letter), ruby: String(letter), cid: CIDData.固有名詞.cid, mid: MIDData.英単語.mid, value: -14)
        }
        var count: ComposingCount = .inputCount(word.elements.count)
        if let head {
            count = .composite(lhs: head.composingCount, rhs: count)
        }
        func joined(_ candidates: [Candidate]) -> [Candidate] {
            candidates.map { candidate in
                Candidate(
                    text: (head?.text ?? "") + word.word + candidate.text,
                    value: (head?.value ?? 0) + candidate.value,
                    composingCount: .composite(lhs: count, rhs: candidate.composingCount),
                    lastMid: candidate.lastMid,
                    data: (head?.data ?? []) + letters + candidate.data,
                    actions: candidate.actions,
                    inputable: candidate.inputable,
                    isLearningTarget: candidate.isLearningTarget
                )
            }
        }
        var result = result
        result.mainResults = joined(result.mainResults)
        result.firstClauseResults = joined(result.firstClauseResults)
        result.predictionResults = joined(result.predictionResults)
        result.englishPredictionResults = joined(result.englishPredictionResults)
        return result
    }

    /// `result` with the candidates of `alternative` offered: its first clause and its best conversion second in their
    /// lists, so one more press of Space reaches them, and the rest after the candidates of `result`
    static func offering(_ alternative: ConversionResult, in result: ConversionResult) -> ConversionResult {
        var result = result
        var seen = Set((result.firstClauseResults + result.mainResults).map(\.text))
        if let clause = alternative.firstClauseResults.first, seen.insert(clause.text).inserted {
            result.firstClauseResults.insert(clause, at: min(1, result.firstClauseResults.count))
        }
        if let best = alternative.mainResults.first, seen.insert(best.text).inserted {
            result.mainResults.insert(best, at: min(1, result.mainResults.count))
        }
        for candidate in alternative.firstClauseResults.dropFirst() + alternative.mainResults.dropFirst() where seen.insert(candidate.text).inserted {
            result.mainResults.append(candidate)
        }
        return result
    }

    @MainActor public func update(requestRichCandidates: Bool) {
        self.updateRawCandidate(requestRichCandidates: requestRichCandidates)
        self.shouldShowCandidateWindow = true
    }

    /// `candidate` as one phrase for learning: its words in one entry, with the left part-of-speech id of the first word
    /// and the right one of the last. The converter's learning raises a learned word for its reading wherever it comes
    /// (納める learned from 税金を納める then beats 治める in 国を治める), against what Zenzai reads from the context, and
    /// the more so while little is learned. Learned with the words around it, it comes back only with them. A candidate
    /// of one word is learned as it is
    static func learnedAsOnePhrase(_ candidate: Candidate) -> Candidate {
        guard candidate.data.count > 1, let first = candidate.data.first, let last = candidate.data.last,
              candidate.text == candidate.data.map(\.word).joined() else {
            return candidate
        }
        var phrase = candidate
        phrase.data = [
            DicdataElement(
                word: candidate.text,
                ruby: candidate.data.map(\.ruby).joined(),
                lcid: first.lcid,
                rcid: last.rcid,
                mid: last.mid,
                value: candidate.data.reduce(0) { $0 + $1.value() }
            )
        ]
        return phrase
    }

    /// - note: To stay consistent with the screen update, get the left context before calling this function and pass it as an argument
    @MainActor public func prefixCandidateCommited(_ candidate: Candidate, leftSideContext: String) {
        self.withConverter { $0.setCompletedData(candidate) }
        // Another candidate than the first, or a clause moved, is a choice the user made
        let corrected = (self.selectionIndex ?? 0) > 0 || self.didExperienceSegmentEdition
        switch self.context.useZenzai ? self.context.zenzaiLearning : .words {
        case .words:
            self.withConverter { $0.updateLearningData(candidate) }
        case .phrases:
            self.withConverter { $0.updateLearningData(Self.learnedAsOnePhrase(candidate)) }
        case .corrections where corrected:
            self.withConverter { $0.updateLearningData(Self.learnedAsOnePhrase(candidate)) }
        case .corrections:
            break
        }
        self.composingText.prefixComplete(composingCount: candidate.composingCount)

        if !self.composingText.isEmpty {
            // Move the cursor to the right end
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            self.didExperienceSegmentEdition = false
            self.shouldShowCandidateWindow = true
            self.selectionIndex = nil
            self.updateRawCandidate(requestRichCandidates: true, forcedLeftSideContext: leftSideContext + candidate.text)
        }
    }

    public enum CandidateWindow: Sendable {
        case hidden
        case composing([Candidate], selectionIndex: Int?)
        case selecting([Candidate], selectionIndex: Int?)
    }

    public func requestSetCandidateWindowState(visible: Bool) {
        self.shouldShowCandidateWindow = visible
    }

    @MainActor
    public func requestSelectingNextCandidate() {
        self.isFixingAdditionalCandidateTop = false
        self.selectionIndex = (self.selectionIndex ?? -1) + 1
    }

    @MainActor
    public func requestSelectingPrevCandidate() {
        let selectionIndex = self.selectionIndex ?? 0

        if self.isFixingAdditionalCandidateTop && self.isShowingAdditionalCandidates {
            if self.candidateOffsetByAdditionalCandidates < self.additionalCandidates.count {
                self.showingAdditionalCandidateCount += 1
            }
            self.selectionIndex = 0
            return
        }

        if selectionIndex == 0, !self.isShowingAdditionalCandidates {
            self.showAdditionalCandidatesIfNeeded()
            let additionalCount = self.candidateOffsetByAdditionalCandidates
            if additionalCount > 0 {
                self.isFixingAdditionalCandidateTop = true
                self.selectionIndex = 0
                return
            }
        }
        if selectionIndex == 0, self.isShowingAdditionalCandidates, self.candidateOffsetByAdditionalCandidates < self.additionalCandidates.count {
            self.isFixingAdditionalCandidateTop = true
            self.showingAdditionalCandidateCount += 1
            self.selectionIndex = 0
            return
        }
        self.selectionIndex = max(0, selectionIndex - 1)
    }

    public func requestSelectingRow(_ index: Int) {
        if self.isFixingAdditionalCandidateTop, index != 0 {
            self.isFixingAdditionalCandidateTop = false
        }
        self.selectionIndex = max(0, index)
    }

    public func stopSuggestionSelection() {
        self.selectionIndex = nil
    }

    public func requestResettingSelection() {
        self.selectionIndex = nil
        self.isFixingAdditionalCandidateTop = false
        self.resetAdditionalCandidates()
    }

    public var selectedCandidate: Candidate? {
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            return candidates[selectionIndex]
        }
        return nil
    }

    public func getCurrentCandidateWindow(inputState: InputState) -> CandidateWindow {
        switch inputState {
        case .none, .previewing, .attachDiacritic, .unicodeInput:
            return .hidden
        case .composing:
            if !self.liveConversionEnabled, let firstCandidate = self.candidates?.first {
                return .composing([firstCandidate], selectionIndex: 0)
            } else {
                return .hidden
            }
        case .selecting:
            if self.shouldShowCandidateWindow, let candidates, !candidates.isEmpty {
                self.selectionIndex = max(0, min(self.selectionIndex ?? 0, candidates.count - 1))
                return .selecting(candidates, selectionIndex: self.selectionIndex)
            } else {
                return .hidden
            }
        }
    }

    public struct MarkedText: Sendable, Equatable, Hashable, Sequence {
        public enum FocusState: Sendable, Equatable, Hashable {
            case focused
            case unfocused
            case none
            /// Show the suggestion ("continue writing") faintly
            case ghost
        }

        public struct Element: Sendable, Equatable, Hashable {
            public var content: String
            public var focus: FocusState
        }
        var text: [Element]

        public var selectionRange: NSRange

        public init(text: [Element], selectionRange: NSRange) {
            self.text = text
            self.selectionRange = selectionRange
        }

        public func makeIterator() -> Array<Element>.Iterator {
            text.makeIterator()
        }

        var isEmpty: Bool {
            self.text.isEmpty
        }
    }

    @MainActor
    public func getModifiedRubyCandidate(inputState: InputState, _ transform: (String) -> String) -> Candidate {
        let (ruby, composingCount): (String, ComposingCount) = switch inputState {
        case .selecting:
            if let selectedRuby = selectedCandidate?.data.map({ $0.ruby }).joined() {
                // Join all `ruby` values in `selectedCandidate.data` and return the result
                (selectedRuby, .surfaceCount(selectedRuby.count))
            } else {
                // With no selection, return convertTarget
                (self.convertTarget, .inputCount(self.composingText.input.count))
            }
        case .composing, .previewing, .none, .attachDiacritic, .unicodeInput:
            (self.convertTarget, .inputCount(self.composingText.input.count))
        }
        let candidateText = transform(ruby)
        return Candidate(
            text: candidateText,
            value: 0,
            composingCount: composingCount,
            lastMid: 0,
            data: [DicdataElement(
                word: candidateText,
                ruby: ruby,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )]
        )
    }

    @MainActor
    public func getModifiedRomanCandidate(inputState: InputState = .composing, _ transform: (String) -> String) -> Candidate {
        let targetInput: [ComposingText.InputElement]
        switch inputState {
        case .selecting:
            if let selectedCandidate {
                // The keys the selected clause covers (F10 on a clause, as in MS-IME)
                var rest = self.composingText
                rest.prefixComplete(composingCount: selectedCandidate.composingCount)
                targetInput = Array(self.composingText.input.prefix(self.composingText.input.count - rest.input.count))
            } else {
                targetInput = self.composingText.prefixToCursorPosition().input
            }
        case .composing, .previewing, .none, .attachDiacritic, .unicodeInput:
            targetInput = self.composingText.input
        }
        let inputString = targetInput.map(\.piece).inputString(preferIntention: false)
        let composingCount: ComposingCount = .inputCount(targetInput.count)
        let candidateText = transform(inputString)
        let candidate = Candidate(
            text: candidateText,
            value: 0,
            composingCount: composingCount,
            lastMid: 0,
            data: [DicdataElement(
                word: candidateText,
                ruby: inputString,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )]
        )
        return candidate
    }

    @MainActor
    private func createAdditionalCandidates() -> [CandidatePresentation] {
        let candidates: [(candidate: Candidate, annotationText: String?)] = [
            (self.getModifiedRomanCandidate(inputState: .selecting) { $0 }, "英数"),
            (self.getModifiedRomanCandidate(inputState: .selecting) { $0.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? $0 }, "全角英数"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? $0 }, "半角カナ"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toKatakana() }, "カタカナ"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toHiragana() }, "ひらがな")
        ]
        return candidates.map {
            .init(
                candidate: $0.candidate,
                displayContext: .init(annotationText: $0.annotationText)
            )
        }
    }

    @MainActor
    private func showAdditionalCandidatesIfNeeded() {
        if self.isShowingAdditionalCandidates {
            return
        }
        guard !self.convertTarget.isEmpty else {
            self.resetAdditionalCandidates()
            return
        }
        let candidates = self.createAdditionalCandidates()
        guard !candidates.isEmpty else {
            self.resetAdditionalCandidates()
            return
        }
        self.additionalCandidates = candidates
        self.isShowingAdditionalCandidates = true
        self.showingAdditionalCandidateCount = 1
    }

    private func resetAdditionalCandidates() {
        self.isShowingAdditionalCandidates = false
        self.additionalCandidates = []
        self.showingAdditionalCandidateCount = 0
        self.isFixingAdditionalCandidateTop = false
    }

    @MainActor
    public func commitMarkedText(inputState: InputState) -> String {
        if inputState == .composing {
            self.finishTrailingN()
        }
        let markedText = self.getCurrentMarkedText(inputState: inputState)
        let text = markedText.reduce(into: "") {$0.append(contentsOf: $1.content)}
        if let candidate = self.candidates?.first(where: {$0.text == text}) {
            self.prefixCandidateCommited(candidate, leftSideContext: "")
        }
        self.stopComposition()
        return text
    }

    /// A trailing n becomes ん when the input is committed as it is (動きませn → 動きません), as in MS-IME. The convert key
    /// already does this by marking the end of the input; do the same here, keeping how the input is shown (hiragana
    /// after a delete, for example)
    @MainActor private func finishTrailingN() {
        guard self.composingText.convertTarget.last == "n", !self.isAlphabetWordInput, self.lastInputStyle != .direct else {
            return
        }
        let lastOperation = self.lastOperation
        self.insertCompositionSeparator(inputStyle: self.lastInputStyle)
        self.lastOperation = lastOperation
    }

    public func requestPredictionCandidates() -> [PredictionCandidate] {
        guard let candidate = self.firstPredictionCandidate(),
              let prediction = Self.makePredictionCandidate(currentTarget: self.composingText.convertTarget, candidate: candidate) else {
            return []
        }
        return [prediction]
    }

    private func firstPredictionCandidate() -> Candidate? {
        guard Config.DebugPredictiveTyping().value else {
            return nil
        }

        let target = self.composingText.convertTarget
        guard !target.isEmpty else {
            return nil
        }

        guard let rawCandidates else {
            return nil
        }

        return rawCandidates.predictionResults.first {
            Self.makePredictionCandidate(currentTarget: target, candidate: $0) != nil
        }
    }

    static func makePredictionCandidate(
        currentTarget: String,
        candidate: Candidate
    ) -> PredictionCandidate? {
        var matchTarget = currentTarget
        var deleteCount = 0
        if let last = matchTarget.last,
           last.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) {
            matchTarget.removeLast()
            deleteCount = 1
        }
        guard matchTarget.count >= 2 else {
            return nil
        }

        let readingHiragana = candidate.data.map(\.ruby).joined().toHiragana()
        let matchTargetHiragana = matchTarget.toHiragana()
        guard readingHiragana.hasPrefix(matchTargetHiragana) else {
            return nil
        }
        guard matchTargetHiragana.count < readingHiragana.count else {
            return nil
        }

        let appendText = String(readingHiragana.dropFirst(matchTargetHiragana.count))
        guard !appendText.isEmpty else {
            return nil
        }

        return .init(displayText: candidate.text, appendText: appendText, deleteCount: deleteCount)
    }

    @MainActor
    public func acceptPredictionCandidate() {
        if let candidate = self.firstPredictionCandidate() {
            self.acceptPredictionCandidate(candidate)
        }
    }

    @MainActor
    func acceptPredictionCandidate(_ candidate: Candidate) {
        guard self.withConverter(.input, { $0.acceptPredictionCandidate(candidate, composingText: &self.composingText) }) else {
            return
        }
        self.lastInputStyle = .direct
        self.lastOperation = .insert
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    /// What the input shows as while it is being typed
    private var composingDisplayText: String {
        if self.lastOperation == .delete || self.lastOperation == .cancelConversion {
            // After a delete or a conversion cancel, always show hiragana, but keep Latin words as typed
            self.readingKeepingLatinWords ?? self.composingText.convertTarget
        } else if self.isAlphabetWordInput {
            // During English input, show the letters as typed
            self.composingText.convertTarget
        } else if self.liveConversionEnabled,
                  self.composingText.convertTarget.count > 1,
                  let firstCandidate = self.rawCandidates?.mainResults.first {
            // Otherwise, if live conversion is on
            firstCandidate.text
        } else {
            // Otherwise
            self.composingText.convertTarget
        }
    }

    public func getCurrentMarkedText(inputState: InputState) -> MarkedText {
        switch inputState {
        case .none, .attachDiacritic:
            return MarkedText(text: [], selectionRange: .notFound)
        case .composing:
            return MarkedText(text: [.init(content: self.composingDisplayText, focus: .none)], selectionRange: .notFound)
        case .previewing:
            if let latinCandidate, latinCandidate.rank == 0 {
                // The letters as typed come first in the candidate list, so the preview shows them too
                return MarkedText(text: [.init(content: latinCandidate.candidate.text, focus: .none)], selectionRange: .notFound)
            } else if let fullCandidate = self.rawCandidates?.mainResults.first,
                      self.composingText.isWholeComposingText(composingCount: fullCandidate.composingCount) {
                return MarkedText(text: [.init(content: fullCandidate.text, focus: .none)], selectionRange: .notFound)
            } else {
                return MarkedText(text: [.init(content: self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
            }
        case .selecting:
            if let candidates, !candidates.isEmpty {
                self.selectionIndex = min(self.selectionIndex ?? 0, candidates.count - 1)
                var afterComposingText = self.composingText
                // Counted in keys, the input the converter saw has its keys where the input has them
                if case .inputCount = candidates[self.selectionIndex!].composingCount, let latinWordsInput,
                   latinWordsInput.input.count == self.composingText.input.count {
                    afterComposingText = latinWordsInput
                }
                afterComposingText.prefixComplete(composingCount: candidates[self.selectionIndex!].composingCount)
                return MarkedText(
                    text: [
                        .init(content: candidates[self.selectionIndex!].text, focus: .focused),
                        .init(content: afterComposingText.convertTarget, focus: .unfocused)
                    ],
                    selectionRange: NSRange(location: candidates[self.selectionIndex!].text.count, length: 0)
                )
            } else {
                return MarkedText(text: [.init(content: self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
            }
        case .unicodeInput(let codePoint):
            // Unicode input mode: show "U+" followed by the code point
            let displayText = "U+" + codePoint
            return MarkedText(
                text: [.init(content: displayText, focus: .none)],
                selectionRange: NSRange(location: displayText.count, length: 0)
            )
        }
    }
}

@MainActor
public protocol SegmentManagerDelegate: AnyObject {
    func getLeftSideContext(maxCount: Int) -> String?
    func getRightSideContext(maxCount: Int) -> String?
}

private extension ComposingText {
    func isWholeComposingText(composingCount: ComposingCount) -> Bool {
        var c = self
        c.prefixComplete(composingCount: composingCount)
        return c.isEmpty
    }
}
