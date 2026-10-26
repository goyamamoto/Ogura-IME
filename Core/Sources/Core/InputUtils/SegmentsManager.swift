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
        self.sessionState = SessionState()
        self.ownsSessions = true
    }

    /// The twin of `main` (see `twin`): the same converter, sessions, settings and identification layer
    private init(twinOf main: SegmentsManager) {
        self.kanaKanjiConverter = main.kanaKanjiConverter
        self.conversionSessionID = main.conversionSessionID
        self.plainConversionSessionID = main.plainConversionSessionID
        self.lookupSessionID = main.lookupSessionID
        self.headSessionID = main.headSessionID
        self.applicationDirectoryURL = main.applicationDirectoryURL
        self.personalizationDirectoryURL = main.personalizationDirectoryURL
        self.context = main.context
        self.sessionState = main.sessionState
        self.ownsSessions = false
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
            useZenzai: Bool = true,
            resourcesDirectoryURL: URL? = nil,
            liveConversionEnabled: Bool? = nil,
            uppercaseStartsAlphabetInput: Bool? = nil,
            learnedScriptIdentification: Bool? = nil,
            scriptModelDirectoryURL: URL? = nil,
            convertsAsTheConverterDoes: Bool = false,
            zenzaiWeightURL: URL? = nil,
            supplementaryDictionaryURL: URL? = nil,
            zenzaiCheckWeightURL: URL? = nil,
            zenzaiSecondOpinion: Bool = true,
            zenzaiSecondOpinionWeight: Float? = nil,
            zenzaiSecondOpinionThreshold: Float? = nil,
            zenzaiLearning: ZenzaiLearning? = nil,
            clauseCandidatesOnly: Bool? = nil,
            readingJudge: (any ReadingJudge)? = nil,
            judgeWeights: JudgeWeights? = nil,
            conversionScheduler: (any ConversionScheduler)? = nil
        ) {
            self.useZenzai = useZenzai
            self.resourcesDirectoryURL = resourcesDirectoryURL
            self.liveConversionEnabled = liveConversionEnabled
            self.uppercaseStartsAlphabetInput = uppercaseStartsAlphabetInput
            self.learnedScriptIdentification = learnedScriptIdentification
            self.scriptModelDirectoryURL = scriptModelDirectoryURL
            self.convertsAsTheConverterDoes = convertsAsTheConverterDoes
            self.zenzaiWeightURL = zenzaiWeightURL
            self.supplementaryDictionaryURL = supplementaryDictionaryURL
            self.zenzaiCheckWeightURL = zenzaiCheckWeightURL
            self.zenzaiSecondOpinion = zenzaiSecondOpinion
            self.zenzaiSecondOpinionWeight = zenzaiSecondOpinionWeight
            self.zenzaiSecondOpinionThreshold = zenzaiSecondOpinionThreshold
            if let zenzaiLearning {
                self.zenzaiLearning = zenzaiLearning
            }
            self.clauseCandidatesOnly = clauseCandidatesOnly
            self.readingJudge = readingJudge
            if let judgeWeights {
                self.judgeWeights = judgeWeights
            }
            self.conversionScheduler = conversionScheduler
        }

        var useZenzai: Bool = true
        /// The candidates are the converter's own, without what Ogura does on top of it (Latin words, letters written
        /// for kana, the first clause): for comparing the two
        var convertsAsTheConverterDoes = false
        /// The weights Zenzai converts with, in place of the model chosen (see `SegmentsManager.zenzaiWeightURL`): for
        /// comparing models
        var zenzaiWeightURL: URL?
        /// The dictionary supplementing the converter's with words it lacks (`supplement.louds` and the files with it;
        /// see Tools/build_supplement_dictionary.sh), in place of the one in the resources (Dictionary/supplement)
        var supplementaryDictionaryURL: URL?
        /// The weights the naturalness checks score readings with, in place of zenz-v3.2-small's (see
        /// `SegmentsManager.zenzaiCheckWeightURL`): for comparing models
        var zenzaiCheckWeightURL: URL?
        /// Whether the checks' model scores the candidates too in the thorough conversion (see
        /// `SegmentsManager.zenzaiSecondOpinion`)
        var zenzaiSecondOpinion = true
        /// How much it counts and from what preference it is heard, in place of `SegmentsManager.secondOpinionWeight` and
        /// `secondOpinionThreshold`: for comparing them
        var zenzaiSecondOpinionWeight: Float?
        var zenzaiSecondOpinionThreshold: Float?
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
        /// Whether the candidates listed for a clause are those for its reading, as in MS-IME (see `clauseCandidates`).
        /// If nil, so when the key bindings are MS-IME's (Config.KeyBindingStyle)
        var clauseCandidatesOnly: Bool?
        /// A model trained to tell the reading meant from the others, which scores each reading the naturalness checks
        /// compare with Zenzai's score of it (see `keepingNaturalJapanese`). If nil, or while it gives no score, Zenzai
        /// alone
        var readingJudge: (any ReadingJudge)?
        /// How the naturalness checks weigh Zenzai's score of a reading against the judge's (see `readingJudge`)
        var judgeWeights = JudgeWeights()
        /// Where the conversions made while typing run, off the main thread (see `convertsInBackground`). If nil, each key
        /// is converted before it is shown, as the evaluations and most tests have it
        var conversionScheduler: (any ConversionScheduler)?
    }

    /// How the naturalness checks weigh the difference between two readings by Zenzai against the difference by the
    /// reading judge (see `Context.readingJudge`), in Zenzai's units: half each, the judge's differences running about
    /// 1.09 of Zenzai's (13.0 against 11.9). On 1,800 pairs of readings of the same keys, Zenzai alone tells the right
    /// one from the wrong one where Ogura goes wrong at AUC 0.83 and where one word is read the other way round at 0.99;
    /// the judge alone 0.92 and 0.99; half each 0.91 and 0.995, keeping the most Latin words with at most 2% of Japanese
    /// turned into letters
    public struct JudgeWeights: Sendable {
        public var zenzai: Float = 0.5
        public var judge: Float = 0.457
        /// Where Zenzai finds a word likelier read one way and the judge the other way, each by at least this once
        /// weighed, the word is read as Japanese: this is a Japanese input method, and when the two disagree with such
        /// confidence both readings make sense (rate against ラテ: Zenzai prefers ラテ by 4.6 and the judge rate by
        /// 3.6, a rate being as likely a thing to write about as a latte), so the Japanese one is the one to write.
        /// The other reading is offered. Nil never. Not where the readings differ by where a word ends: there the shorter
        /// reading is part of the word read as kana (Endのテ for EndNote). Nor while the word is unfinished at the end
        /// of the input (bug against ぶg)
        public var confidentDisagreement: Float? = 3
        public init(zenzai: Float = 0.5, judge: Float = 0.457, confidentDisagreement: Float? = 3) {
            self.zenzai = zenzai
            self.judge = judge
            self.confidentDisagreement = confidentDisagreement
        }
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
    /// What goes with the sessions, shared with the twin (see `twin`)
    private final class SessionState {
        /// The temporary dictionary entries each session (plain or not) last converted with, for the sessions that
        /// decide by them (see `startingOverForChangedEntries`)
        var entries: [Bool: [PricedEntry]] = [:]
        /// The Japanese names of Latin words looked up (see `japaneseName`), by word: the same word is asked about at each
        /// key typed after it
        var japaneseNames: [String: String?] = [:]
    }
    private let sessionState: SessionState
    /// Whether the sessions are this object's, to remove with it: the twin's are its main object's
    private let ownsSessions: Bool

    /// A dictionary entry with its value, which the equality of `DicdataElement` leaves out
    private struct PricedEntry: Equatable {
        var element: DicdataElement
        var value: PValue
    }

    deinit {
        guard self.ownsSessions else {
            return
        }
        ConversionLock.withLock {
            self.kanaKanjiConverter.removeSession(self.conversionSessionID)
            self.kanaKanjiConverter.removeSession(self.plainConversionSessionID)
            self.kanaKanjiConverter.removeSession(self.lookupSessionID)
            self.kanaKanjiConverter.removeSession(self.headSessionID)
        }
    }

    /// The conversion sessions of this object: the input's, and the ones on the side
    private enum Session: CaseIterable {
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
    private func withConverter<Result>(_ session: Session = .input, _ operation: (KanaKanjiConverter) -> Result) -> Result {
        let sessionID = self.sessionCopies?[session] ?? self.sessionID(of: session)
        do {
            return try self.kanaKanjiConverter.withSession(sessionID) {
                operation(self.kanaKanjiConverter)
            }
        } catch {
            // Only this object's own deinit destroys this session.
            preconditionFailure("SegmentsManager lost its conversion session: \(error)")
        }
    }

    private func sessionID(of session: Session) -> KanaKanjiConverter.ConversionSessionID {
        switch session {
        case .input: self.conversionSessionID
        case .plain: self.plainConversionSessionID
        case .lookup: self.lookupSessionID
        case .head: self.headSessionID
        }
    }

    /// Copies of the sessions that conversions go to while `inSessionCopies` runs
    private var sessionCopies: [Session: KanaKanjiConverter.ConversionSessionID]?

    /// Runs `body` with each conversion session replaced by a copy of itself, dropped afterwards: what is converted there
    /// (the thorough conversion) leaves the sessions as they were, so the conversion while typing goes on from its own
    /// state at the next key, whatever was shown. The sessions that convert without Zenzai start empty instead: a copy
    /// shares the lattice's nodes, and the converter on its own links new nodes into them where the input is shorter
    /// than the one it last converted, while Zenzai resets them before each search
    private func inSessionCopies<Result>(_ body: () -> Result) -> Result {
        var copies: [Session: KanaKanjiConverter.ConversionSessionID] = [:]
        for session in Session.allCases {
            switch session {
            case .input, .head:
                do {
                    copies[session] = try self.kanaKanjiConverter.copySession(self.sessionID(of: session))
                } catch {
                    preconditionFailure("SegmentsManager lost its conversion session: \(error)")
                }
            case .plain, .lookup:
                copies[session] = self.kanaKanjiConverter.createSession()
            }
        }
        let sessionEntries = self.sessionState.entries
        self.sessionCopies = copies
        defer {
            self.sessionCopies = nil
            self.sessionState.entries = sessionEntries
            for copy in copies.values {
                self.kanaKanjiConverter.removeSession(copy)
            }
        }
        return body()
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
    /// The element of the input the clause being converted ends before, when Shift+← / → moved its end into the input
    /// (see `editSegment`); nil while the clause runs to the end. The end moves by the kana the converter reads, which
    /// after a Latin word can differ from the kana of the input as typed (after Yamamotosan the converter reads にあいます
    /// for niaimasu, while the input as typed reads さんい, so the end of the word is no boundary of its kana), so the
    /// element is kept apart from the cursor of `composingText`, which stands at the kana boundary at or before it (see
    /// `moveClauseEnd`)
    private var clauseEnd: Int?
    private var lastOperation: Operation = .other
    /// The input is shown as its reading and edited there (← / → or Esc while typing, see `moveCursor`), until it is
    /// converted (Space) or committed: what is typed or deleted applies at the caret, which stands before element
    /// `readingCaret` of the input, or at the end when nil. The caret moves by the characters of the reading as the
    /// converter reads it (see `readingText`), which after a Latin word can differ from the kana of the input as typed
    /// (see `clauseEnd`), so it is kept as an element and the edits are made on the elements. The composing text's own
    /// cursor stays at the end, where the conversion and the clause editing (Shift+← / →) expect it
    private var isEditingReading = false
    private var readingCaret: Int?
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
    /// The best conversion of the whole of the input being converted, kept while the end of the clause moves inside it:
    /// the input after the clause is shown from it (see `restText`)
    private var wholeConversion: Candidate?
    /// Texts of the candidates offered besides the clause's own, the other reading of an uncertain word (see
    /// `offering`): they stay in the clause's list whatever they cover
    private var offeredTexts: Set<String> = []
    /// The converter's own candidates for the reading of the clause being converted (see `alternativesForClause`)
    private var clauseAlternatives: [Candidate] = []
    /// What became of the thorough conversion of the input as it stands (see `showThoroughConversion`)
    private var thoroughConversion: ThoroughConversion = .notRun
    /// The conversion the thorough one took the place of on the screen, while it is shown (see
    /// `putBackConversionBeforeThorough`)
    private var conversionBeforeThorough: ConversionState?
    /// The last conversion is the converter's own, as Zenzai wrote letters that were not typed (see `updateRawCandidate`)
    private var zenzaiWroteUntypedLetters = false
    /// The clauses before the one being converted, moved past with → (see `moveClauseFocus`), the nearest last
    private var earlierClauses: [EarlierClause] = []
    /// The clauses after the one being converted that ← moved back from, the nearest last
    private var laterClauses: [LaterClause] = []

    /// Whether the candidates listed for a clause are those for its reading, as in MS-IME (see `clauseCandidates`)
    private var clauseCandidatesOnly: Bool {
        !self.context.convertsAsTheConverterDoes && (self.context.clauseCandidatesOnly ?? (Config.KeyBindingStyle().value == .msIME))
    }

    /// The conversion of the input being converted, as a whole: saved for each clause moved past, to come back to it
    private struct ConversionState {
        var composingText: ComposingText
        var rawCandidates: ConversionResult?
        var wholeConversion: Candidate?
        var selectionIndex: Int?
        var didExperienceSegmentEdition: Bool
        var clauseEnd: Int?
        var lastOperation: Operation
        var latinWordsInput: ComposingText?
        var hasLatinWords: Bool
        var latinCandidate: (candidate: Candidate, rank: Int)?
        var offeredTexts: Set<String>
        var clauseAlternatives: [Candidate]
        var isShowingAdditionalCandidates: Bool
        var additionalCandidates: [CandidatePresentation]
        var showingAdditionalCandidateCount: Int
        var isFixingAdditionalCandidateTop: Bool
        var thoroughConversion: ThoroughConversion
    }

    /// The thorough conversion of the input as it stands, run once typing stops (see `showThoroughConversion`)
    private enum ThoroughConversion {
        /// Not run since the input last changed
        case notRun
        /// Shown in place of the conversion made while typing
        case shown
        /// Run, and the conversion made while typing stood (see `writesLettersNotIn`)
        case declined
    }

    /// A clause moved past with → (see `moveClauseFocus`)
    private struct EarlierClause {
        /// The candidate chosen for the clause
        var candidate: Candidate
        /// Whether the user chose it (see `prefixCandidateCommited`)
        var corrected: Bool
        /// The conversion the clause was chosen in, to come back to with ←
        var state: ConversionState
    }

    /// A clause ← moved back from (see `moveClauseFocus`)
    private struct LaterClause {
        var candidate: Candidate?
        var corrected: Bool
        var state: ConversionState
        /// What the clause showed
        var text: String
        /// What the input after the clause showed
        var rest: String
    }

    private var conversionState: ConversionState {
        get {
            ConversionState(
                composingText: self.composingText,
                rawCandidates: self.rawCandidates,
                wholeConversion: self.wholeConversion,
                selectionIndex: self.selectionIndex,
                didExperienceSegmentEdition: self.didExperienceSegmentEdition,
                clauseEnd: self.clauseEnd,
                lastOperation: self.lastOperation,
                latinWordsInput: self.latinWordsInput,
                hasLatinWords: self.hasLatinWords,
                latinCandidate: self.latinCandidate,
                offeredTexts: self.offeredTexts,
                clauseAlternatives: self.clauseAlternatives,
                isShowingAdditionalCandidates: self.isShowingAdditionalCandidates,
                additionalCandidates: self.additionalCandidates,
                showingAdditionalCandidateCount: self.showingAdditionalCandidateCount,
                isFixingAdditionalCandidateTop: self.isFixingAdditionalCandidateTop,
                thoroughConversion: self.thoroughConversion
            )
        }
        set {
            self.composingText = newValue.composingText
            self.rawCandidates = newValue.rawCandidates
            self.wholeConversion = newValue.wholeConversion
            self.selectionIndex = newValue.selectionIndex
            self.didExperienceSegmentEdition = newValue.didExperienceSegmentEdition
            self.clauseEnd = newValue.clauseEnd
            self.lastOperation = newValue.lastOperation
            self.latinWordsInput = newValue.latinWordsInput
            self.hasLatinWords = newValue.hasLatinWords
            self.latinCandidate = newValue.latinCandidate
            self.offeredTexts = newValue.offeredTexts
            self.clauseAlternatives = newValue.clauseAlternatives
            self.isShowingAdditionalCandidates = newValue.isShowingAdditionalCandidates
            self.additionalCandidates = newValue.additionalCandidates
            self.showingAdditionalCandidateCount = newValue.showingAdditionalCandidateCount
            self.isFixingAdditionalCandidateTop = newValue.isFixingAdditionalCandidateTop
            self.thoroughConversion = newValue.thoroughConversion
        }
    }
    /// Tells which parts of the input are Latin words (see `ScriptIdentifier`): the learned identification layer when the
    /// setting chooses it and its model is there, else the rules. Read at each use, so the setting applies at once
    private var scriptIdentifier: any ScriptIdentifier {
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
    private var learnedScriptIdentifier: TaggerScriptIdentifier? {
        if let read = self.readLearnedScriptIdentifier {
            return read
        }
        let directory = self.context.scriptModelDirectoryURL ?? self.resourcesDirectoryURL.appendingPathComponent("ScriptModel", isDirectory: true)
        let analyze = FileManager.default.fileExists(atPath: directory.appendingPathComponent("analyze").path)
        let identifier = try? TaggerScriptIdentifier(modelDirectory: directory, converter: analyze ? self.kanaKanjiConverter : nil, naturalnessChecked: self.context.useZenzai)
        self.readLearnedScriptIdentifier = .some(identifier)
        return identifier
    }
    /// The learned identification layer once it was read, nil inside when it could not be. The twin gets it from its main
    /// object (see `twin`), so the two go on with the same analyses of the input
    private var readLearnedScriptIdentifier: TaggerScriptIdentifier??

    /// Whether the identification layer in use can tell Latin words off the main thread, as the conversion in the
    /// background needs (see `convertsInBackground`): the learned one once it is read, which the first conversion does;
    /// the rules ask the spell checker, which is the main thread's
    private var identifiesAnywhere: Bool {
        if let identifier = self.scriptIdentifierOverride {
            return !(identifier is RuleBasedScriptIdentifier)
        }
        guard Config.LatinCandidateForNonJapaneseInput().value else {
            return true
        }
        guard self.context.learnedScriptIdentification ?? Config.LearnedScriptIdentification().value,
              case .some(.some) = self.readLearnedScriptIdentifier else {
            return false
        }
        return true
    }
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
        requestRichCandidates: Bool,
        thorough: Bool = false
    ) -> ConvertRequestOptions.ZenzaiMode {
        if !self.context.useZenzai {
            return .off
        }
        return .on(
            weight: self.zenzaiWeightURL,
            inferenceLimit: Config.ZenzaiInferenceLimit().value,
            requestRichCandidates: requestRichCandidates,
            thorough: thorough,
            secondOpinion: thorough ? self.zenzaiSecondOpinion : nil,
            personalizationMode: self.zenzaiPersonalizationMode,
            versionDependentMode: .v3(
                .init(
                    profile: Config.ZenzaiProfile().value,
                    leftSideContext: leftSideContext,
                    rightSideContext: rightSideContext,
                    enableAlignmentSeparator: true,
                    )
            ),
            cancellation: thorough ? self.thoroughCancellation : nil
        )
    }

    /// The weights Zenzai converts with: the model chosen (Config.ZenzaiModel), or zenz-v3.2-small when the resources
    /// have no genmai
    private var zenzaiWeightURL: URL {
        if let zenzaiWeightURL = self.context.zenzaiWeightURL {
            return zenzaiWeightURL
        }
        if Config.ZenzaiModel().value == .genmai, let genmaiWeightURL = self.genmaiWeightURL {
            return genmaiWeightURL
        }
        return self.zenzWeightURL
    }

    /// The weights the naturalness checks score readings with (see `keepingNaturalJapanese`): zenz-v3.2-small, whichever
    /// model converts. The checks' margins and the reading judge's weights were set by its scores; with genmai's, the
    /// checks read more English words as romaji (名前はナメ for name: 64 decisions between letters and kana wrong in
    /// 5,520 sentences against 54), and each key took a little longer (median 6.4 ms against 6.0)
    private var zenzaiCheckWeightURL: URL {
        self.context.zenzaiCheckWeightURL ?? self.zenzWeightURL
    }

    /// When another model converts (genmai), the model the checks score readings with scores the candidates too in the
    /// thorough conversion (see `ConvertRequestOptions.ZenzaiMode.SecondOpinion`): where the two disagree and the smaller
    /// model is sure, the candidate both find probable is right more often than the conversion model's own choice (AJIMEE
    /// 183 → 186 with genmai, no homophone of 77 lost); where it is only somewhat surer it is wrong more often, so it is
    /// not heard
    private var zenzaiSecondOpinion: ConvertRequestOptions.ZenzaiMode.SecondOpinion? {
        guard self.context.zenzaiSecondOpinion, self.zenzaiCheckWeightURL != self.zenzaiWeightURL else {
            return nil
        }
        return .init(
            weightURL: self.zenzaiCheckWeightURL,
            weight: self.context.zenzaiSecondOpinionWeight ?? Self.secondOpinionWeight,
            threshold: self.context.zenzaiSecondOpinionThreshold ?? Self.secondOpinionThreshold
        )
    }

    /// How much the second model's log-probability counts against the conversion model's, and by how much (in
    /// log-probability) it must prefer a candidate to the conversion model's choice to be heard at all: chosen on
    /// AJIMEE-Bench and the homophone set, checked on the Aozora and Latin sentences. The threshold matters more than the
    /// weight: with it, weights from 0.25 to 2 gave the same results
    public static let secondOpinionWeight: Float = 0.5
    public static let secondOpinionThreshold: Float = 4

    private var zenzWeightURL: URL {
        self.resourcesDirectoryURL.appendingPathComponent("ggml-model-Q5_K_M.gguf", isDirectory: false)
    }

    /// genmai's weights, when the resources have them (see Tools/build_genmai_gguf.sh)
    private lazy var genmaiWeightURL: URL? = {
        let url = self.resourcesDirectoryURL.appendingPathComponent("genmai/ggml-model-Q5_K_M.gguf", isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

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
        zenzai: Bool = true,
        thorough: Bool = false
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
                requestRichCandidates: requestRichCandidates,
                thorough: thorough
            ) : .off,
            experimentalZenzaiPredictiveInput: true,
            typoCorrectionMode: .automatic,
            supplementaryDictionaryURL: self.supplementaryDictionaryURL,
            metadata: self.metadata
        )
    }

    /// The dictionary supplementing the converter's (see `Context.supplementaryDictionaryURL`): the one given, else the
    /// bundled one when there is one
    private var supplementaryDictionaryURL: URL? {
        if let url = self.context.supplementaryDictionaryURL {
            return url
        }
        let bundled = self.resourcesDirectoryURL.appendingPathComponent("Dictionary/supplement", isDirectory: true)
        return FileManager.default.fileExists(atPath: bundled.appendingPathComponent("supplement.louds", isDirectory: false).path) ? bundled : nil
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
    private func stopConversion() {
        self.withConverter { $0.stopComposition() }
        self.withConverter(.plain) { $0.stopComposition() }
        self.sessionState.entries = [:]
    }

    /// Starts the conversion in the session over when the temporary dictionary entries differ from those it last
    /// converted with. The converter keeps the nodes of the part of the input it has converted, priced as they were
    /// when it made them; an uncertain word's entry changes its price as the identification layer reads more keys
    /// (token gets likelier once を送って follows), and with the old nodes the session would go on deciding by the price
    /// the word had when its kana was first typed
    private func startingOverForChangedEntries(_ entries: [DicdataElement], plain: Bool, converter: KanaKanjiConverter) {
        let priced = entries.map { PricedEntry(element: $0, value: $0.value()) }
        guard self.sessionState.entries[plain] != priced else {
            return
        }
        converter.stopComposition()
        self.sessionState.entries[plain] = priced
    }

    @MainActor
    public func deactivate(flushLearningData: Bool = true) {
        self.dropBackgroundConversion()
        self.stopConversion()
        if flushLearningData {
            self.withConverter { $0.commitUpdateLearningData() }
        }
        self.rawCandidates = nil
        self.latinWordsInput = nil
        self.forgetClauses()
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.composingText.stopComposition()
        self.clauseEnd = nil
        self.isEditingReading = false
        self.readingCaret = nil
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.lastInputStyle = .direct
        self.isAlphabetWordInput = false
    }

    @MainActor
    /// Stop this input
    public func stopComposition() {
        self.dropBackgroundConversion()
        self.composingText.stopComposition()
        self.clauseEnd = nil
        self.isEditingReading = false
        self.readingCaret = nil
        self.stopConversion()
        self.rawCandidates = nil
        self.latinWordsInput = nil
        self.forgetClauses()
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.lastInputStyle = .direct
        self.isAlphabetWordInput = false
    }

    /// Drops what the clauses kept (see `moveClauseFocus`) when the input ends
    private func forgetClauses() {
        self.earlierClauses = []
        self.laterClauses = []
        self.wholeConversion = nil
        self.offeredTexts = []
        self.clauseAlternatives = []
    }

    @MainActor
    /// Stop Japanese input itself
    public func stopJapaneseInput() {
        self.leaveClauses()
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
        // Converting converts the whole reading, wherever the caret was
        self.isEditingReading = false
        self.readingCaret = nil
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: inputStyle)])
        self.lastOperation = .insert
        if !skipUpdate {
            self.updateRawCandidate()
        }
    }

    @MainActor
    public func insertAtCursorPosition(_ string: String, inputStyle: InputStyle) {
        self.leaveClauses()
        self.lastInputStyle = inputStyle
        self.insertAtReadingCaret(string.map { .init(piece: .character($0), inputStyle: inputStyle) })
        self.lastOperation = .insert
        // When live conversion is off, show the candidate window
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.convertAfterTyping()
    }

    @MainActor
    public func insertAtCursorPosition(pieces: [InputPiece], inputStyle: InputStyle) {
        self.leaveClauses()
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
        self.insertAtReadingCaret(pieces.map { .init(piece: $0, inputStyle: inputStyle) })
        self.lastOperation = .insert
        // When live conversion is off, show the candidate window
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.convertAfterTyping()
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
        // The clauses after this one are read again once it ends elsewhere
        self.laterClauses = []
        // The clause end is edited now, not the reading
        self.isEditingReading = false
        self.readingCaret = nil
        // The end moves by the kana of the input as the converter reads it (see `clauseEnd`), from the end of the
        // candidate chosen when one is, else from where it is
        var text = self.composingText
        if let latinWordsInput, latinWordsInput.input.count == text.input.count {
            text = latinWordsInput
        }
        var end = self.clauseEnd
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            let (base, rest) = self.remaining(after: candidates[selectionIndex])
            end = rest.isEmpty ? nil : base.input.count - rest.input.count
        }
        _ = text.moveCursorFromCursorPosition(count: Self.surfaceIndex(of: end, in: text) - text.convertTargetCursorPosition)
        if count > 0, text.isAtEndIndex, !self.didExperienceSegmentEdition {
            // If the end is at the right end, move it to just after the left end
            _ = text.moveCursorFromCursorPosition(count: -text.convertTargetCursorPosition + count)
        } else {
            // Otherwise, move it
            _ = text.moveCursorFromCursorPosition(count: count)
        }
        if text.isAtStartIndex {
            // If it is at the start, move one step right
            _ = text.moveCursorFromCursorPosition(count: 1)
        }
        self.moveClauseEnd(to: text.isAtEndIndex ? nil : text.prefixToCursorPosition().input.count)
        self.lastOperation = .editSegment
        self.didExperienceSegmentEdition = true
        self.shouldShowCandidateWindow = true
        self.selectionIndex = nil
        self.updateRawCandidate()
    }

    /// The character of `text` that element `end` of its input ends before, or the end of the text when nil
    private static func surfaceIndex(of end: Int?, in text: ComposingText) -> Int {
        guard let end else {
            return text.convertTarget.count
        }
        if let index = text.inputIndexToSurfaceIndexMap()[end] {
            return index
        }
        var rest = text
        rest.prefixComplete(composingCount: .inputCount(end))
        return text.convertTarget.count - rest.convertTarget.count
    }

    /// Moves the end of the clause being converted to before element `end` of the input, or to the end of the input when
    /// nil (see `clauseEnd`). The cursor of the input as typed goes to the kana boundary at or before the element
    private func moveClauseEnd(to end: Int?) {
        let text = self.composingText
        guard let end, text.input[min(end, text.input.count)...].contains(where: { $0.piece != .compositionSeparator }) else {
            _ = self.composingText.moveCursorFromCursorPosition(count: text.convertTarget.count - text.convertTargetCursorPosition)
            self.clauseEnd = nil
            return
        }
        let boundaries = text.inputIndexToSurfaceIndexMap()
        let surface = (0 ... end).reversed().lazy.compactMap { boundaries[$0] }.first ?? 0
        _ = self.composingText.moveCursorFromCursorPosition(count: surface - text.convertTargetCursorPosition)
        self.clauseEnd = end
    }

    @MainActor
    public func deleteBackwardFromCursorPosition(count: Int = 1) {
        self.leaveClauses()
        if self.isEditingReading, let caret = self.readingCaret {
            // The characters of the reading before the caret inside it
            self.deleteAtReadingCaret(before: caret, count: count)
            self.lastOperation = .delete
            self.shouldShowCandidateWindow = !self.liveConversionEnabled
            self.updateRawCandidate()
            return
        }
        if !self.composingText.isAtEndIndex {
            // Move it to the right end
            self.moveClauseEnd(to: nil)
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
        self.leaveClauses()
        if self.isEditingReading, let caret = self.readingCaret {
            // The characters of the reading after the caret inside it; the caret keeps its place
            self.deleteAtReadingCaret(after: caret, count: count)
            self.lastOperation = .delete
            self.shouldShowCandidateWindow = !self.liveConversionEnabled
            self.updateRawCandidate()
            return
        }
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
        self.leaveClauses()
        self.moveClauseEnd(to: nil)
        self.didExperienceSegmentEdition = false
        // The reading stays, and can be edited, until the input is converted or committed (MS-IME)
        self.isEditingReading = true
        self.readingCaret = nil
        self.lastOperation = .cancelConversion
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.updateRawCandidate()
    }

    /// Move the caret inside the reading by `count` characters (← / → while typing, MS-IME): what live conversion shows
    /// goes back to its reading first (see `cancelConversion`), and what is typed or deleted next applies at the caret.
    /// The caret stays inside the reading; moving it past either end does nothing more
    @MainActor
    public func moveCursor(count: Int) {
        if !self.isEditingReading {
            self.cancelConversion()
        }
        var text = self.readingText
        _ = text.moveCursorFromCursorPosition(count: Self.surfaceIndex(of: self.readingCaret, in: text) - text.convertTargetCursorPosition)
        _ = text.moveCursorFromCursorPosition(count: count)
        guard !text.isAtEndIndex else {
            self.readingCaret = nil
            return
        }
        let surface = text.convertTargetCursorPosition
        let boundaries = Self.boundaries(of: text)
        if let boundary = boundaries.first(where: { $0.surface == surface }) {
            self.readingCaret = boundary.element
            return
        }
        // Inside a kana made of several keys (ょ of きょ, from k, y, o): the keys become the characters they make, so
        // the caret can stand between them
        guard let start = boundaries.last(where: { $0.surface < surface }), let end = boundaries.first(where: { $0.surface > surface }),
              self.fixKana(elements: start.element ..< end.element, characters: start.surface ..< end.surface, of: text) else {
            return
        }
        self.readingCaret = start.element + surface - start.surface
        self.updateRawCandidate()
    }

    /// The input as the converter reads it, whose characters the caret inside the reading moves by: with its Latin
    /// words as letters when it has any (see `latinWordsInput`), else the input as typed
    private var readingText: ComposingText {
        if let latinWordsInput, latinWordsInput.input.count == self.composingText.input.count {
            return latinWordsInput
        }
        return self.composingText
    }

    /// The boundaries between the elements of `text` where its characters begin and end, by element: the keys of a kana
    /// (k, y, o for きょ) have none between them
    private static func boundaries(of text: ComposingText) -> [(element: Int, surface: Int)] {
        text.inputIndexToSurfaceIndexMap().map { (element: $0.key, surface: $0.value) }.sorted { $0.element < $1.element }
    }

    /// The style of a character of the input fixed as it is: what `ComposingText` gives the characters it fixes around
    /// its own cursor (its `frozen`)
    private static let fixed = InputStyle.mapped(id: .empty)

    /// Makes the elements of the input in `elements`, which make the characters in `characters` of `text` (the input as
    /// the converter reads it), those characters as they are (see `fixed`), so they are read with nothing typed around
    /// them. Not when they are letters (a Latin word, or a key romaji has not read yet), which stay keys. False when
    /// nothing changed
    private func fixKana(elements: Range<Int>, characters: Range<Int>, of text: ComposingText) -> Bool {
        let input = self.composingText.input
        guard elements.upperBound <= input.count, characters.upperBound <= text.convertTarget.count else {
            return false
        }
        let made = Array(text.convertTarget)[characters]
        guard made.contains(where: { !$0.isASCII }), input[elements].contains(where: { $0.inputStyle != Self.fixed }) else {
            return false
        }
        var fixed = input
        fixed.replaceSubrange(elements, with: made.map { .init(piece: .character($0), inputStyle: Self.fixed) })
        self.replaceInput(with: fixed)
        return true
    }

    /// Puts `elements` into the input at the caret inside the reading when it stands inside it (see `readingCaret`),
    /// else at the end. The kana after the caret stays as it is: its keys are fixed as the characters they make, so
    /// what is typed is not read with them (k before あ is not か)
    private func insertAtReadingCaret(_ elements: [ComposingText.InputElement]) {
        guard self.isEditingReading, let caret = self.readingCaret, caret < self.composingText.input.count else {
            self.composingText.insertAtCursorPosition(elements)
            return
        }
        let reading = self.readingText
        let boundaries = Self.boundaries(of: reading)
        if let here = boundaries.first(where: { $0.element == caret }), let next = boundaries.first(where: { $0.element > caret }) {
            _ = self.fixKana(elements: caret ..< next.element, characters: here.surface ..< next.surface, of: reading)
        }
        var input = self.composingText.input
        input.insert(contentsOf: elements, at: caret)
        self.replaceInput(with: input)
        self.readingCaret = caret + elements.count
    }

    /// Deletes `count` characters of the reading before the caret inside it: each is the keys of a character of the
    /// reading as the converter reads it (the letters of a Latin word one by one)
    @MainActor private func deleteAtReadingCaret(before caret: Int, count: Int) {
        let boundaries = Self.boundaries(of: self.readingText)
        var start = caret
        for _ in 0 ..< count {
            guard let previous = boundaries.last(where: { $0.element < start }) else {
                break
            }
            start = previous.element
        }
        var input = self.composingText.input
        guard start < caret, caret <= input.count else {
            return
        }
        input.removeSubrange(start ..< caret)
        self.replaceInput(with: input)
        self.readingCaret = start
    }

    /// Deletes `count` characters of the reading after the caret inside it; the caret keeps its place
    @MainActor private func deleteAtReadingCaret(after caret: Int, count: Int) {
        let boundaries = Self.boundaries(of: self.readingText)
        var end = caret
        for _ in 0 ..< count {
            guard let next = boundaries.first(where: { $0.element > end }) else {
                break
            }
            end = next.element
        }
        var input = self.composingText.input
        guard caret < end, caret < input.count else {
            return
        }
        input.removeSubrange(caret ..< min(end, input.count))
        self.replaceInput(with: input)
        self.readingCaret = caret < input.count ? caret : nil
    }

    /// Makes the input `input`, read from the start again, with the cursor at its end
    private func replaceInput(with input: [ComposingText.InputElement]) {
        var text = ComposingText()
        text.insertAtCursorPosition(input)
        self.composingText = text
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
        rawCandidates = self.clauseCandidates(rawCandidates)
        return self.isShowingAdditionalCandidates
            ? self.additionalCandidatesForSelectionIndex + rawCandidates
            : rawCandidates
    }

    /// The input left after `candidate`, with the input it is counted in: the one the converter saw when the candidate
    /// counts keys (see `latinWordsInput`), else the input itself
    private func remaining(after candidate: Candidate) -> (base: ComposingText, rest: ComposingText) {
        var base = self.composingText
        if case .inputCount = candidate.composingCount, let latinWordsInput, latinWordsInput.input.count == self.composingText.input.count {
            base = latinWordsInput
        }
        var rest = base
        rest.prefixComplete(composingCount: candidate.composingCount)
        return (base, rest)
    }

    /// How much of the input `candidate` covers, in characters of the reading
    private func length(of candidate: Candidate) -> Int {
        let (base, rest) = self.remaining(after: candidate)
        return base.convertTarget.count - rest.convertTarget.count
    }

    /// `candidates` as the list for the clause being converted, the first of them. The converter adds the kana and
    /// letter forms of the whole input to any conversion (キョウハイイテンキデスネ), and the letters as typed are offered
    /// for the whole input too (korehawindowsdesu, see `latinCandidate`): they are for the whole input, so they go when
    /// the clause is less than it, or one press of Space would turn the whole input into katakana. When candidates are
    /// listed clause by clause (MS-IME), the list keeps the candidates that cover the clause and the ones offered besides
    /// (see `offeredTexts`), and the converter's own for the clause's reading follow them (see `alternativesForClause`)
    private func clauseCandidates(_ candidates: [Candidate]) -> [Candidate] {
        guard let first = candidates.first else {
            return candidates
        }
        let clauseLength = self.length(of: first)
        var kept = candidates
        if !self.remaining(after: first).rest.isEmpty {
            kept = candidates.filter { candidate in
                let (_, rest) = self.remaining(after: candidate)
                let wholeForm = rest.isEmpty && candidate.data.count == 1
                    && candidate.data[0].lcid == CIDData.固有名詞.cid && candidate.data[0].mid == MIDData.一般.mid
                return !wholeForm
            }
        }
        guard self.clauseCandidatesOnly else {
            return kept
        }
        kept = kept.filter { self.length(of: $0) == clauseLength || self.offeredTexts.contains($0.text) }
        let seen = Set(kept.map(\.text))
        return kept + self.clauseAlternatives.filter { !seen.contains($0.text) && self.length(of: $0) == clauseLength }
    }

    /// The converter's own candidates for the reading of the clause being converted (京は, 教は, きょうは for 今日は), to
    /// list after those the conversion gave: a clause listed on its own has every conversion of its reading, as in
    /// MS-IME. None when the clause is the whole input, whose candidates the conversion lists
    private func alternativesForClause() -> [Candidate] {
        guard let first = self.candidates?.first else {
            return []
        }
        let (base, rest) = self.remaining(after: first)
        guard !rest.isEmpty else {
            return []
        }
        var prefix = base
        _ = prefix.moveCursorFromCursorPosition(count: base.convertTarget.count - rest.convertTarget.count - prefix.convertTargetCursorPosition)
        prefix = prefix.prefixToCursorPosition()
        guard !prefix.isEmpty else {
            return []
        }
        let result = self.withConverter(.lookup) { converter in
            converter.requestCandidates(
                prefix,
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
        return result.mainResults.compactMap { candidate in
            guard prefix.isWholeComposingText(composingCount: candidate.composingCount) else {
                return nil
            }
            var candidate = candidate
            // Counted in keys, as the candidates are when the converter saw the Latin words as letters
            candidate.composingCount = .inputCount(prefix.input.count)
            return candidate
        }
    }

    /// What the input after `candidate`, the clause being converted, shows: the clauses after it in the best conversion
    /// of the whole input (see `wholeConversion`), as in MS-IME; the reading where the clause ends inside one of its
    /// words; the whole reading when there is no such conversion
    private func restText(after candidate: Candidate) -> String {
        self.restWords(after: candidate)?.map(\.word).joined() ?? self.remaining(after: candidate).rest.convertTarget
    }

    /// The words that the input after `candidate`, the clause being converted, shows (see `restText`), so that → can keep
    /// them as they are (see `moveToNextClause`). Nil when the rest shows the reading
    private func restWords(after candidate: Candidate) -> [DicdataElement]? {
        let (base, rest) = self.remaining(after: candidate)
        let reading = rest.convertTarget
        guard !reading.isEmpty, let whole = self.wholeConversion, whole.text == whole.data.map(\.word).joined() else {
            return nil
        }
        // The clause is the start of the conversion: the rest is its other words
        if whole.data.count > candidate.data.count, whole.data.prefix(candidate.data.count).elementsEqual(candidate.data) {
            return Array(whole.data.dropFirst(candidate.data.count))
        }
        // The words of the conversion laid over the reading: each takes as many characters as its own reading. A word
        // the clause cuts into shows what is left of it when the part cut off is written as read (の改善 cut after の),
        // else as read. What is left is a word of its own here, not learned
        let lengths = whole.data.map { $0.ruby.count }
        guard lengths.reduce(0, +) == base.convertTarget.count else {
            return nil
        }
        let consumed = base.convertTarget.count - reading.count
        var words: [DicdataElement] = []
        var offset = 0
        for (element, length) in zip(whole.data, lengths) {
            if offset >= consumed {
                words.append(element)
            } else if offset + length > consumed {
                let cut = consumed - offset
                let left = element.word.hasPrefix(element.ruby.prefix(cut).toHiragana())
                    ? String(element.word.dropFirst(cut))
                    : String(reading.prefix(length - cut))
                words.append(DicdataElement(
                    word: left,
                    ruby: String(element.ruby.dropFirst(cut)),
                    cid: element.rcid,
                    mid: element.mid,
                    value: element.value(),
                    metadata: .isNotLearningTarget
                ))
            }
            offset += length
        }
        return words
    }

    /// What the input after `candidate`, the clause being converted, shows: the clauses ← moved back from as they were
    /// (see `moveClauseFocus`), else the rest of the best conversion (see `restText`)
    private func textAfterClause(_ candidate: Candidate) -> String {
        guard let farthest = self.laterClauses.first else {
            return self.restText(after: candidate)
        }
        return self.laterClauses.reversed().map(\.text).joined() + farthest.rest
    }

    /// Moves the clause being converted by `count`: → to the next clause and ← back, as in MS-IME, keeping what was
    /// chosen for the clauses passed. They are committed together (see `commitClauses`). Past the last clause, or
    /// before the first, nothing moves
    @MainActor
    public func moveClauseFocus(count: Int) {
        if count > 0 {
            for _ in 0 ..< count {
                self.moveToNextClause()
            }
        } else {
            for _ in 0 ..< -count {
                self.moveToPreviousClause()
            }
        }
        self.shouldShowCandidateWindow = true
    }

    /// The function key last applied and what it showed (see `applyFunction`), to go on cycling on the next press
    private struct FunctionPress {
        var function: UserAction.Function
        var text: String
        var presses: Int
    }
    private var lastFunction: FunctionPress?

    /// Shows the clause being converted, or the whole input, in the form of the function key (F6 hiragana, F7
    /// katakana, F8 half-width katakana, F9 full-width letters, F10 half-width letters) without committing it, as in
    /// MS-IME: → moves on and Enter commits the clauses as shown. Pressed again, the form cycles as in MS-IME: the kana
    /// forms turn back one character at a time from the end (トウキョウ, トウキョう, トウキょう), and the letters go
    /// through as typed, upper case and capitalized
    @MainActor
    public func applyFunction(_ function: UserAction.Function, toWholeInput: Bool) {
        if toWholeInput {
            // The whole input as the one clause
            self.leaveClauses()
            self.moveClauseEnd(to: nil)
            self.didExperienceSegmentEdition = false
            self.isEditingReading = false
            self.readingCaret = nil
            self.selectionIndex = nil
        }
        let reading: String
        let keys: String
        let composingCount: ComposingCount
        if !toWholeInput, let chosen = self.chosenCandidate {
            // The reading with Latin words kept as typed (see `latinWordsInput`), and the keys as typed
            let (base, rest) = self.remaining(after: chosen.candidate)
            reading = String(base.convertTarget.prefix(base.convertTarget.count - rest.convertTarget.count))
            keys = self.composingText.input.prefix(base.input.count - rest.input.count).map(\.piece).inputString(preferIntention: false)
            composingCount = chosen.candidate.composingCount
        } else {
            reading = self.composingText.convertTarget
            keys = self.composingText.input.map(\.piece).inputString(preferIntention: false)
            composingCount = .inputCount(self.composingText.input.count)
        }
        let presses = if let last = self.lastFunction, last.function == function, self.selectedCandidate?.text == last.text {
            last.presses + 1
        } else {
            0
        }
        let text = Self.functionForm(function, reading: reading, keys: keys, presses: presses)
        // Not learned: a form asked for with a key is not a choice among conversions, and learned with its reading it
        // would come first for that reading from then on. The word itself is marked, so that it stays out of the
        // learning however the clauses around it are learned (as a phrase with them, as the word before the next one)
        let candidate = Candidate(
            text: text,
            value: 0,
            composingCount: composingCount,
            lastMid: MIDData.一般.mid,
            data: [DicdataElement(word: text, ruby: reading.toKatakana(), cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: 0, metadata: .isNotLearningTarget)],
            isLearningTarget: false
        )
        // Listed first, as the candidate chosen, in place of the other forms a candidate list offers
        self.additionalCandidates = [CandidatePresentation(candidate: candidate)]
        self.isShowingAdditionalCandidates = true
        self.showingAdditionalCandidateCount = 1
        self.isFixingAdditionalCandidateTop = false
        self.selectionIndex = 0
        self.lastFunction = FunctionPress(function: function, text: text, presses: presses)
        // The list closes until Space asks for it again
        self.shouldShowCandidateWindow = false
    }

    /// The form of the function key for `reading` (the kana forms) or `keys` (the letter forms), at the `presses`-th
    /// press in a row (see `applyFunction`)
    private static func functionForm(_ function: UserAction.Function, reading: String, keys: String, presses: Int) -> String {
        // The last `presses` characters in the other form, from none around again
        func mixed(_ main: (String) -> String, _ tail: (String) -> String) -> String {
            let back = reading.isEmpty ? 0 : presses % reading.count
            return main(String(reading.prefix(reading.count - back))) + tail(String(reading.suffix(back)))
        }
        switch function {
        case .six:
            return mixed({ $0.toHiragana() }, { $0.toKatakana() })
        case .seven:
            return mixed({ $0.toKatakana() }, { $0.toHiragana() })
        case .eight:
            return mixed({ $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? $0 }, { $0.toHiragana() })
        case .nine, .ten:
            let letters = switch presses % 3 {
            case 1: keys.uppercased()
            case 2: keys.prefix(1).uppercased() + keys.dropFirst().lowercased()
            default: keys
            }
            return letters.applyingTransform(.fullwidthToHalfwidth, reverse: function == .nine) ?? letters
        }
    }

    /// The candidate chosen for the clause being converted, and whether the user chose it (see `prefixCandidateCommited`)
    private var chosenCandidate: (candidate: Candidate, corrected: Bool)? {
        guard let candidate = self.selectedCandidate ?? self.candidates?.first else {
            return nil
        }
        return (candidate, (self.selectionIndex ?? 0) > 0 || self.didExperienceSegmentEdition)
    }

    @MainActor private func moveToNextClause() {
        guard let chosen = self.chosenCandidate else {
            return
        }
        let (_, rest) = self.remaining(after: chosen.candidate)
        guard !rest.isEmpty else {
            return
        }
        self.selectionIndex = self.selectionIndex ?? 0
        self.earlierClauses.append(EarlierClause(candidate: chosen.candidate, corrected: chosen.corrected, state: self.conversionState))
        if let later = self.laterClauses.last, later.state.composingText.input.count == rest.input.count {
            // The clause ← moved back from, as it was
            self.laterClauses.removeLast()
            self.conversionState = later.state
            self.stopConversion()
            return
        }
        self.laterClauses = []
        // What the rest shows stays as it is: → moves the clause, as in MS-IME (see `updateRawCandidate`)
        let shownRest = self.restWords(after: chosen.candidate)
        // The clauses moved past are context for the rest, as committed text would be. A Latin word that stands for a
        // Japanese name is context as the name (大阪 for Osaka), as when the whole input was converted (see `contextWord`)
        let leftSideContext = (self.getCleanLeftSideContext(maxCount: ContextLength.conversion) ?? "")
            + self.earlierClauses.map { self.japaneseName(of: $0.candidate.text) ?? $0.candidate.text }.joined()
        self.withConverter { $0.setCompletedData(chosen.candidate) }
        self.composingText.prefixComplete(composingCount: chosen.candidate.composingCount)
        self.moveClauseEnd(to: nil)
        self.didExperienceSegmentEdition = false
        self.selectionIndex = nil
        self.updateRawCandidate(requestRichCandidates: true, forcedLeftSideContext: leftSideContext)
        if let shownRest {
            self.keepFirst(shownRest, readingAs: rest)
        }
    }

    /// Puts `words`, what the input left after a clause moved past showed, first among its conversions, and their first
    /// clause first as the clause now converted, so that → leaves what is shown as it was, as in MS-IME. The conversion
    /// made again with the clauses passed as the context gives the other candidates. `seen` is that input as it was read
    /// for showing the words, with its Latin words as letters (see `latinWordsInput`): the words keep it, though the
    /// conversion made again may read the Latin words otherwise
    @MainActor private func keepFirst(_ words: [DicdataElement], readingAs seen: ComposingText) {
        guard var rawCandidates = self.rawCandidates, let last = words.last, seen.input.count == self.composingText.input.count,
              words.map(\.ruby).joined() == seen.convertTarget.toKatakana() else {
            return
        }
        let rest = Candidate(
            text: words.map(\.word).joined(),
            value: words.reduce(0) { $0 + $1.value() },
            composingCount: .inputCount(self.composingText.input.count),
            lastMid: last.mid,
            data: words
        )
        rawCandidates.mainResults.removeAll { $0.text == rest.text }
        rawCandidates.mainResults.insert(rest, at: 0)
        if let clause = Self.firstClause(of: rest), clause.text != rest.text {
            // The clause counts the converter's characters; where they are not those of the input, it counts keys
            var counted = clause
            if seen.convertTarget != self.composingText.convertTarget {
                var prefix = seen
                _ = prefix.moveCursorFromCursorPosition(count: clause.data.reduce(0) { $0 + $1.ruby.count } - prefix.convertTargetCursorPosition)
                counted.composingCount = .inputCount(prefix.prefixToCursorPosition().input.count)
            }
            rawCandidates.firstClauseResults.removeAll { $0.text == counted.text }
            rawCandidates.firstClauseResults.insert(counted, at: 0)
        } else {
            // The rest is one clause, converted as a whole
            rawCandidates.firstClauseResults = []
        }
        self.rawCandidates = rawCandidates
        if seen.convertTarget != self.composingText.convertTarget {
            // What is left after the clause is shown from the input as it was read (see `restText`)
            self.latinWordsInput = seen
            self.hasLatinWords = true
        }
        self.keepWholeConversion()
        if self.clauseCandidatesOnly {
            self.clauseAlternatives = self.alternativesForClause()
        }
    }

    @MainActor private func moveToPreviousClause() {
        guard let earlier = self.earlierClauses.popLast() else {
            return
        }
        let chosen = self.chosenCandidate
        self.laterClauses.append(LaterClause(
            candidate: chosen?.candidate,
            corrected: chosen?.corrected ?? false,
            state: self.conversionState,
            text: chosen?.candidate.text ?? self.composingText.convertTarget,
            rest: chosen.map { self.restText(after: $0.candidate) } ?? ""
        ))
        self.conversionState = earlier.state
        self.stopConversion()
    }

    /// Commits the clauses as shown: the ones moved past, the one being converted and the ones after it (see
    /// `moveClauseFocus`). Returns the text to insert, having learned what the user chose
    @MainActor
    public func commitClauses() -> String {
        var text = self.earlierClauses.map(\.candidate.text).joined()
        for clause in self.earlierClauses {
            self.learn(clause.candidate, corrected: clause.corrected)
        }
        if let chosen = self.chosenCandidate {
            let after = self.textAfterClause(chosen.candidate)
            if self.laterClauses.isEmpty, !chosen.corrected, let whole = self.wholeConversion, chosen.candidate.text + after == whole.text {
                // The conversion committed as it came learns as one (see `learnedAsOnePhrase`)
                self.learn(whole, corrected: false)
            } else {
                self.learn(chosen.candidate, corrected: chosen.corrected)
                for clause in self.laterClauses.reversed() {
                    if let candidate = clause.candidate {
                        self.learn(candidate, corrected: clause.corrected)
                    }
                }
            }
            text += chosen.candidate.text + after
        } else {
            text += self.composingText.convertTarget
        }
        self.stopComposition()
        return text
    }

    /// Commits the clauses moved past (see `moveClauseFocus`) before the clause being converted is committed on its
    /// own: returns their text, to insert before it, having learned what the user chose
    @MainActor
    public func takeEarlierClauses() -> String {
        let text = self.earlierClauses.map(\.candidate.text).joined()
        for clause in self.earlierClauses {
            self.learn(clause.candidate, corrected: clause.corrected)
        }
        self.earlierClauses = []
        return text
    }

    /// Back from the clauses moved past (see `moveClauseFocus`) to the conversion of the whole input, before the
    /// conversion is cancelled or the input changes
    @MainActor private func leaveClauses() {
        self.laterClauses = []
        guard let first = self.earlierClauses.first else {
            return
        }
        self.earlierClauses = []
        self.conversionState = first.state
        self.stopConversion()
    }

    /// Learns `candidate`, committed; `corrected` when the user chose it over the first candidate (see
    /// `prefixCandidateCommited`)
    @MainActor private func learn(_ candidate: Candidate, corrected: Bool) {
        self.withConverter { $0.setCompletedData(candidate) }
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
    private func latinWordsConversionText(otherReading: Bool = false, contexts: ConversionContexts) -> LatinWordsConversion? {
        guard Config.LatinCandidateForNonJapaneseInput().value,
              self.composingText.input.allSatisfy({ $0.inputStyle != .direct }),
              self.composingText.input.last?.piece != .compositionSeparator || self.composingText.input.count > 1,
              let input = TypedInput(self.composingText, clauseEnd: self.clauseEnd) else {
            return nil
        }
        var segmentation = self.scriptIdentifier.segment(input)
        guard !segmentation.isEmpty || self.hasHalfWidthMarks(in: input) else {
            return nil
        }
        if self.context.useZenzai, !segmentation.uncertainWords.isEmpty {
            // Zenzai cannot write letters for a kana reading, and once it rejects a candidate made from a temporary entry
            // the converter reads the input again without the entries (へっぉ世界 for hello世界). So the converter decides
            // the uncertain words by its own scores first, and Zenzai sees the ones it writes as letters typed as is
            let written = self.wordsWrittenByConverter(self.conversion(of: input, segmentation: segmentation), uncertain: segmentation.uncertainWords, input: input, leftSideContext: contexts.appLeft)
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
            let natural = self.keepingNaturalJapanese(segmentation, input: input, leftSideContext: contexts.appLeft ?? "")
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
        if segmentation.isEmpty, conversion.otherReading == nil, !self.hasHalfWidthMarks(in: input) {
            return nil
        }
        return conversion
    }

    /// Whether a Latin word could be meant as Japanese: typed in lower case (hyphens read as ー: e-tone is えーとね),
    /// spelled in standard romaji, and read as kana from start to end, or to the end of the kana its last letter
    /// starts, when the keys after it go with that letter (noter in hahanoteryouri is のてりょ with yo, sup in
    /// yakusokuwosuppokashita すっぽ with po). Keys that spell Japanese in standard romaji are Japanese when in doubt;
    /// code (not kode), or a word started with Shift, is typed as the word on purpose
    private static func couldBeJapanese(_ word: LatinInputGuess.Span, input: TypedInput) -> Bool {
        guard word.word.count >= 2, word.word.allSatisfy({ $0.isASCII && $0.isLowercase || $0 == "-" }) else {
            return false
        }
        let (start, last) = (word.keys.lowerBound, min(word.keys.upperBound + Self.kanaOverrun, input.typingFrom))
        // A word running into the keys romaji has not read yet is still being typed
        guard last >= word.keys.upperBound else {
            return false
        }
        return (word.keys.upperBound ... last).contains { end in
            let keys = input.keys[start ..< end]
            return keys.allSatisfy({ $0.isASCII && $0.isLowercase || $0 == "-" }) && StandardRomaji.spells(keys) && input.kana(of: start ..< end) != nil
        }
    }

    /// How many keys after a Latin word the kana its last letter starts may take (ryo, っぽ as ppo, っち as cchi)
    private static let kanaOverrun = 3

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
    /// is read as decided, so it ends earlier only when the Japanese after the shorter word is likelier: Winの側 for
    /// Winnogawa and Fanの中身 for Fannonakami are 9 to 12 likelier, Web上 for Webue (read as one word) 1.5, while Pi for
    /// Pinn (ん), still being typed, is within 1. Shorter words the lexicon does not know are not offered (T-sha for
    /// T-shatsu), so the margin need not keep them out
    static let shorterWordMargin: Float = 1

    /// The same as `shorterWordMargin` when the shorter word is a name the converter's dictionary knows (Osaka, 大阪; see
    /// `japaneseName`). Zenzai finds a suffix after such a name likelier only by a little (Osaka市 for Osakashi, 0.5 to
    /// 3; Kanagawa県 8), and a name cut short clearly unlikelier (Yoko|hama, Ino|ue, Hokkai|dou: 6 or more), so the
    /// name ends wherever Zenzai finds the rest likelier read as romaji
    static let shorterNameMargin: Float = 0

    /// How much likelier, in natural log, Zenzai must find the input with a Latin word read on over the kana after it
    /// (see `ScriptSegmentation.longerWords`) than as decided for the word to end there. Kana become letters, so the
    /// longer word has to be clearly likelier, as for a word that could be Japanese (`naturalJapaneseMargin`):
    /// Finderウインドウ for Find+えるいんどう (Find得る引導) is about 25 likelier
    static let longerWordMargin: Float = 3

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
    /// context; with a reading judge (see `Context.readingJudge`), the judge scores each reading too
    private func keepingNaturalJapanese(_ segmentation: ScriptSegmentation, input: TypedInput, leftSideContext: String) -> NaturalReading {
        let weight = self.zenzaiCheckWeightURL
        // The letters romaji has not read yet at the end: they read like more of a Latin word (Sakeハsakeデs, homet for
        // 褒めt, タカイmineニn), so the readings are compared without them, also when a Latin word runs to the end of the
        // input over them (zoom at the end as zoo against ゾオ: both readings are cut alike)
        let unread = input.keys.count - input.typingFrom
        // The scores of the readings compared, by reading: the checks compare the same reading with several others
        var scores: [String: ReadingScore?] = [:]
        /// The reading with `words` as letters, up to the key `upTo` when given: where a word may end is compared up to
        /// the next Latin word after it (see `nextWord`), since the letters of that word and what follows them tell
        /// the two ends apart less the longer the input runs (Web上の against Webueの differs by 1.5 before Keynote, and
        /// by nothing by the end of …Keynoteを使用してください). Whether a word is Japanese is compared over the whole
        /// input: the words after it keep made and site Latin (madeのは、多くのcases; site上でkeep). As Zenzai compares
        /// it, without the letters romaji has not read at the end, and as typed, with them (see `score`)
        func reading(_ words: [LatinInputGuess.Span], upTo: Int?) -> (compared: String, typed: String) {
            var reading = segmentation
            reading.latinWords = words
            let conversion = self.conversion(of: input, segmentation: reading).text
            if let upTo, upTo < input.keys.count {
                var prefix = ComposingText()
                prefix.insertAtCursorPosition(Array(conversion.input.prefix(input.elementIndices[upTo])))
                return (prefix.convertTarget, prefix.convertTarget)
            }
            let text = conversion.convertTarget
            if unread > 0, text.suffix(unread).allSatisfy({ $0.isASCII && $0.isLetter }) {
                return (String(text.dropLast(unread)), text)
            }
            return (text, text)
        }
        /// Zenzai's score of the reading with `words` as letters (see `reading`), and the reading judge's when there is
        /// one (see `Context.readingJudge`): of the reading as typed, with the letters romaji has not read at the end,
        /// when `judgingTyped`, else of the reading compared, without them
        func score(_ words: [LatinInputGuess.Span], upTo: Int? = nil, judgingTyped: Bool) -> ReadingScore? {
            let (compared, typed) = reading(words, upTo: upTo)
            let judged = judgingTyped ? typed : compared
            let key = compared + "\u{0}" + judged
            if let score = scores[key] {
                return score
            }
            var score = self.withConverter { $0.zenzaiInputLogProbability(compared.toKatakana(), leftSideContext: leftSideContext, modelURL: weight) }
                .map { ReadingScore(zenzai: $0, complete: compared == typed) }
            // Without the judge's score (while it is still loading, or when it fails), Zenzai's alone
            if let judge = self.context.readingJudge, score != nil {
                score?.judge = judge.scores(of: [judged])?.first
            }
            scores[key] = score
            return score
        }
        /// How the reading with the Latin words `other` compares with the one with `words`, the reading as it is, up to
        /// the key `upTo` when given: how much likelier whichever has more letters is (see `preference(_:over:differing:)`).
        /// The reading as it is is scored first. Nil when either cannot be scored
        func preference(of other: [LatinInputGuess.Span], against words: [LatinInputGuess.Span], differing: ReadingDifference, upTo: Int? = nil) -> ReadingPreference? {
            // The judge has learned that letters left over after kana are wrong, so it sees the letters romaji has not
            // read at the end when a Latin word of either reading runs over them (zoom at the end is zoom against ぞおm,
            // while zoo against ぞお is ぞお). When they belong to what comes after the words compared, it does not: they
            // would sway it from key to key, the kana reading alone carrying letters left over at one key and neither
            // reading at the next (とねはs against toneはs, then とねはす against toneはす)
            let judgingTyped = (words + other).contains { $0.keys.upperBound > input.typingFrom }
            guard let asIs = score(words, upTo: upTo, judgingTyped: judgingTyped), let changed = score(other, upTo: upTo, judgingTyped: judgingTyped) else {
                return nil
            }
            func letters(_ words: [LatinInputGuess.Span]) -> Int {
                words.reduce(0) { $0 + $1.keys.count }
            }
            return letters(other) > letters(words) ? self.preference(changed, over: asIs, differing: differing) : self.preference(asIs, over: changed, differing: differing)
        }
        var words = segmentation.latinWords
        var otherWords = segmentation.latinWords
        for word in segmentation.latinWords where Self.couldBeJapanese(word, input: input) {
            let others = words.filter { $0.keys != word.keys }
            if let asLetters = preference(of: others, against: words, differing: .word), asLetters.japanese || asLetters.letters < -Self.naturalJapaneseMargin {
                words = others
            } else {
                otherWords.removeAll { $0.keys == word.keys }
            }
        }
        let unnatural = Self.addingUnnaturalJapanese(segmentation.possibleWords, to: words) { preference(of: $1, against: $0, differing: .word) }
        words = unnatural.words
        otherWords = (otherWords + unnatural.offered).sorted { $0.keys.lowerBound < $1.keys.lowerBound }
        let ended = self.endingEarlier(segmentation, input: input, words: words, otherWords: otherWords) { preference(of: $1, against: $0, differing: .end, upTo: $2)?.letters }
        let extended = self.endingLater(segmentation, words: ended.words, otherWords: ended.otherWords) { preference(of: $1, against: $0, differing: .end, upTo: $2)?.letters }
        return NaturalReading(words: extended.words, otherWords: extended.otherWords)
    }

    /// The scores of a reading the naturalness checks compare: Zenzai's log-probability of it as input, and the reading
    /// judge's score when there is one (see `keepingNaturalJapanese`)
    private struct ReadingScore {
        var zenzai: Float
        var judge: Float?
        /// Whether the reading ends with what romaji has read: not when letters it has not read yet were left off for
        /// Zenzai (see `keepingNaturalJapanese`), the word at the end being unfinished
        var complete: Bool
    }

    /// What two readings of the same keys the naturalness checks compare differ by
    private enum ReadingDifference {
        /// A word read as letters against the same keys read as kana
        case word
        /// A word ending at different keys
        case end
    }

    /// How two readings of the same keys compare for the naturalness checks
    private struct ReadingPreference {
        /// How much likelier the reading with more letters is, in Zenzai's units
        var letters: Float
        /// Whether the word is to be read as Japanese since Zenzai and the judge disagree about it, each confidently (see
        /// `JudgeWeights.confidentDisagreement`)
        var japanese = false
    }

    /// How the reading scored `letters`, which has more letters, compares with the one scored `kana`: how much likelier
    /// it is, by Zenzai's difference alone without a judge, else by the differences weighed as `Context.judgeWeights`
    /// says, and whether Zenzai and the judge disagree about a word confidently
    private func preference(_ letters: ReadingScore, over kana: ReadingScore, differing: ReadingDifference) -> ReadingPreference {
        let zenzai = letters.zenzai - kana.zenzai
        guard let lettersJudge = letters.judge, let kanaJudge = kana.judge else {
            return ReadingPreference(letters: zenzai)
        }
        let weights = self.context.judgeWeights
        let byZenzai = weights.zenzai * zenzai
        let byJudge = weights.judge * (lettersJudge - kanaJudge)
        var preference = ReadingPreference(letters: (weights.zenzai * letters.zenzai + weights.judge * lettersJudge) - (weights.zenzai * kana.zenzai + weights.judge * kanaJudge))
        if differing == .word, letters.complete, kana.complete, let confident = weights.confidentDisagreement,
           (byZenzai > 0) != (byJudge > 0), abs(byZenzai) >= confident, abs(byJudge) >= confident {
            preference.japanese = true
        }
        return preference
    }

    /// `words` with each word ending at a longer word (see `ScriptSegmentation.longerWords`) where Zenzai finds the input
    /// clearly likelier so (Finderウインドウ for Find+えるいんどう), and `otherWords` with the likeliest longer word in
    /// place of each word that does not and has no shorter word offered, to offer. `preference` tells how much likelier
    /// the reading with the second Latin words, which has more letters, is than the one with the first, the reading as
    /// it is, up to a key when given
    private func endingLater(
        _ segmentation: ScriptSegmentation,
        words: [LatinInputGuess.Span],
        otherWords: [LatinInputGuess.Span],
        preference: ([LatinInputGuess.Span], [LatinInputGuess.Span], Int?) -> Float?
    ) -> (words: [LatinInputGuess.Span], otherWords: [LatinInputGuess.Span]) {
        var (words, otherWords) = (words, otherWords)
        for word in segmentation.latinWords {
            let longerWords = segmentation.longerWords.filter { longer in
                longer.word == word.keys && !words.contains { $0.keys != word.keys && $0.keys.overlaps(longer.longer.keys) }
            }
            guard !longerWords.isEmpty, let index = words.firstIndex(where: { $0.keys == word.keys }) else {
                continue
            }
            var best: (words: [LatinInputGuess.Span], preference: Float)?
            for longer in longerWords {
                var ended = words
                ended[index] = longer.longer
                let upTo = Self.nextWord(after: longer.longer.keys, in: ended)
                if let likelier = preference(words, ended, upTo), likelier > Self.longerWordMargin, likelier > (best?.preference ?? -.infinity) {
                    best = (ended, likelier)
                }
            }
            if let best {
                words = best.words
            } else if let likeliest = longerWords.max(by: { $0.probability < $1.probability }),
                      let otherIndex = otherWords.firstIndex(where: { $0.keys == word.keys }) {
                otherWords[otherIndex] = likeliest.longer
            }
        }
        return (words, otherWords)
    }

    /// Where the first of `words` after the keys `keys` with kana between starts, if any: the readings of the keys are
    /// compared up to there. A word right after the keys (dows after win, one word cut by the end of the clause being
    /// converted) is read with them: its letters tell the readings apart
    private static func nextWord(after keys: Range<Int>, in words: [LatinInputGuess.Span]) -> Int? {
        var end = keys.upperBound
        for word in words.sorted(by: { $0.keys.lowerBound < $1.keys.lowerBound }) where word.keys.lowerBound >= keys.upperBound {
            guard word.keys.lowerBound == end else {
                return word.keys.lowerBound
            }
            end = word.keys.upperBound
        }
        return nil
    }

    /// `words` with each word ending at a shorter word (see `ScriptSegmentation.shorterWords`) where Zenzai finds the keys
    /// left over clearly likelier read as romaji, and `otherWords` with the likeliest shorter word in place of each word
    /// that does not, to offer. Only keys that spell standard romaji are read as Japanese (see `couldBeJapanese`), and a
    /// shorter word the lexicon does not know only when it is a name the converter's dictionary knows (see
    /// `shorterNameMargin`). `preference` tells how much likelier the reading with the first Latin words, the reading as
    /// it is, which has more letters, is than the one with the second, up to a key when given
    private func endingEarlier(
        _ segmentation: ScriptSegmentation,
        input: TypedInput,
        words: [LatinInputGuess.Span],
        otherWords: [LatinInputGuess.Span],
        preference: ([LatinInputGuess.Span], [LatinInputGuess.Span], Int?) -> Float?
    ) -> (words: [LatinInputGuess.Span], otherWords: [LatinInputGuess.Span]) {
        var (words, otherWords) = (words, otherWords)
        for word in segmentation.latinWords {
            let shorterWords = segmentation.shorterWords.filter {
                $0.word == word.keys && StandardRomaji.spells(String(input.keys[$0.shorter.keys.upperBound ..< word.keys.upperBound]))
                    && ($0.known || self.japaneseName(of: $0.shorter.word) != nil)
            }
            let upTo = Self.nextWord(after: word.keys, in: words)
            guard !shorterWords.isEmpty, let index = words.firstIndex(where: { $0.keys == word.keys }) else {
                continue
            }
            var best: (words: [LatinInputGuess.Span], preference: Float)?
            for shorter in shorterWords {
                var ended = words
                ended[index] = shorter.shorter
                let margin = self.japaneseName(of: shorter.shorter.word) != nil ? Self.shorterNameMargin : Self.shorterWordMargin
                // The shorter word read is likelier by how much the word as it is is less likely
                if let likelier = preference(words, ended, upTo).map({ -$0 }), likelier > margin, likelier > (best?.preference ?? -.infinity) {
                    best = (ended, likelier)
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
    /// Japanese reading it does not find clearly more likely, to offer as letters. `preference` tells how the reading
    /// with the second Latin words, which has more letters, compares with the one with the first, the reading as it is
    private static func addingUnnaturalJapanese(
        _ possibleWords: [ScriptSegmentation.PossibleWord],
        to words: [LatinInputGuess.Span],
        preference: ([LatinInputGuess.Span], [LatinInputGuess.Span]) -> ReadingPreference?
    ) -> (words: [LatinInputGuess.Span], offered: [LatinInputGuess.Span]) {
        var words = words
        var offered: [LatinInputGuess.Span] = []
        for possible in possibleWords where !words.contains(where: { $0.keys.overlaps(possible.word.keys) }) {
            let added = (words + [possible.word]).sorted { $0.keys.lowerBound < $1.keys.lowerBound }
            guard let asLetters = preference(words, added) else {
                continue
            }
            if !asLetters.japanese, asLetters.letters > Self.unnaturalJapaneseMargin {
                words = added
            } else if asLetters.japanese || asLetters.letters > -Self.naturalJapaneseMargin {
                offered.append(possible.word)
            }
        }
        return (words, offered)
    }

    /// What the converter sees for `segmentation` of `input` (see `latinWordsConversionText`)
    private func conversion(of input: TypedInput, segmentation: ScriptSegmentation) -> LatinWordsConversion {
        var elements = self.composingText.input
        let punctuation = Self.halfWidthPunctuation(in: input, latinWords: segmentation.latinWords)
        for word in segmentation.latinWords {
            // A word after a dot written as a dot is a part of a name (index.html, Node.js, apple.com): as typed, not
            // in the spelling the lexicon knows the word by (HTML)
            let typed = String(input.keys[word.keys])
            let afterDot = punctuation.contains { $0.index == word.keys.lowerBound - 1 && $0.mark == "." }
            let spelling = afterDot && typed.lowercased() == word.word.lowercased() ? typed : word.word
            for (offset, character) in zip(word.keys, spelling) {
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
        for index in Self.halfWidthHyphens(in: input, latinWords: segmentation.latinWords) {
            elements[input.elementIndices[index]] = .init(piece: .character("-"), inputStyle: .direct)
        }
        for (index, mark) in punctuation {
            elements[input.elementIndices[index]] = .init(piece: .character(mark), inputStyle: .direct)
        }
        // A capital read as romaji that a Latin word covers after all (the T of Tokyo, see `ScriptSegmentation.possibleWords`)
        // stays a letter
        for index in segmentation.openCapitals + segmentation.romajiCapitals where !segmentation.latinWords.contains(where: { $0.keys.contains(index) }) {
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
        if let end = self.clauseEnd {
            // The clause being converted ends at the same element (Shift+← / → move it, see `clauseEnd`)
            var prefix = ComposingText()
            prefix.insertAtCursorPosition(Array(elements.prefix(end)))
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

    /// Whether the input has a hyphen or a punctuation mark written in half width even without Latin words (3-2-1, 1.1)
    private func hasHalfWidthMarks(in input: TypedInput) -> Bool {
        !Self.halfWidthHyphens(in: input, latinWords: []).isEmpty || !Self.halfWidthPunctuation(in: input, latinWords: []).isEmpty
    }

    /// The punctuation keys written in half width: a period or a comma between letters written as letters or digits on
    /// both sides (Node.js, index.html, 1.1, v2.0.3, 1,000, iPhone,iPad). A period with kana or nothing after it ends
    /// a sentence (会議はzoom。) and stays 。 until a letter or digit follows it; a comma with kana on a side stays 、
    static func halfWidthPunctuation(in input: TypedInput, latinWords: [LatinInputGuess.Span]) -> [(index: Int, mark: Character)] {
        let keys = input.keys
        func isDigit(_ index: Int) -> Bool {
            keys.indices.contains(index) && keys[index].isASCII && keys[index].isNumber
        }
        func isWritten(_ index: Int) -> Bool {
            isDigit(index) || latinWords.contains { $0.keys.contains(index) }
        }
        var marks: [(index: Int, mark: Character)] = []
        for index in keys.indices.dropFirst() where (keys[index] == "." || keys[index] == ",") && isWritten(index - 1) && isWritten(index + 1) {
            marks.append((index, keys[index]))
        }
        return marks
    }

    /// The hyphens typed right after a Latin word or a digit (Wi-Fi, UTF-8, us-west-1, 3-2-1), and after such a hyphen:
    /// they are written as -, not ー, whether symbols are typed in half width or not, as periods between letters are. In
    /// romaji - is the long vowel mark, which only follows kana, so after letters written as letters or after digits it is
    /// a hyphen or a minus. Before digits after kana it can be either (気温は-5度, コーヒー1杯), and it stays ー
    static func halfWidthHyphens(in input: TypedInput, latinWords: [LatinInputGuess.Span]) -> [Int] {
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
    private func wordsWrittenByConverter(_ conversion: LatinWordsConversion, uncertain: [ScriptSegmentation.UncertainWord], input: TypedInput, leftSideContext: String?) -> [LatinInputGuess.Span] {
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
            guard let ruby = input.kana(ofUncertain: word.keys)?.toKatakana(),
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
            guard let kana = input.kana(ofUncertain: word.keys) else {
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
        written.data = zip(Self.wordsBefore(candidate), candidate.data).map { previous, element in
            guard Self.writesLettersForKana(element, afterNumber: previous?.last?.isNumber == true),
                  !allowed.contains(where: { $0.word == element.word && $0.ruby == element.ruby }) else {
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

    /// Whether `text` has a run of Latin letters that `shown` does not (case apart): a thorough conversion that writes
    /// letters where the conversion shown had Japanese. Letters right after a number are the unit the number was
    /// read with (50cm), as in `writesUntypedLetters`
    static func writesLettersNotIn(_ shown: String, _ text: String) -> Bool {
        let known = Set(Self.letterRuns(of: shown).map { $0.letters.lowercased() })
        return Self.letterRuns(of: text).contains { !$0.afterNumber && !known.contains($0.letters.lowercased()) }
    }

    /// Whether `text` has Latin letters that are not among the keys `typed`, whatever their case. Zenzai can write a word
    /// typed in romaji in English (note for no-to, hotel for hoteru), but Latin letters belong where the user typed them
    /// (GitHub for github). Letters right after a number are the unit or the size the number was read with (45km for
    /// よんじゅうごきろめーとる, 3GB, 4K), the way to write the number, so they do not count
    static func writesUntypedLetters(_ text: String, typed: String) -> Bool {
        let typed = typed.lowercased()
        return Self.letterRuns(of: text).contains { !$0.afterNumber && !typed.contains($0.letters.lowercased()) }
    }

    /// The runs of Latin letters in `text`, each with whether it comes right after a number (the first one after a number
    /// when `startingAfterNumber`)
    private static func letterRuns(of text: String, startingAfterNumber: Bool = false) -> [(letters: String, afterNumber: Bool)] {
        var runs: [(letters: String, afterNumber: Bool)] = []
        var previous: Character?
        var afterNumber = startingAfterNumber
        for character in text {
            if character.isASCII, character.isLetter {
                if let previous, previous.isASCII, previous.isLetter {
                    runs[runs.count - 1].letters.append(character)
                } else {
                    runs.append((String(character), afterNumber))
                }
            }
            afterNumber = character.isNumber
            previous = character
        }
        return runs
    }

    /// The word before each word of `candidate`, nil before the first
    private static func wordsBefore(_ candidate: Candidate) -> [String?] {
        [nil] + candidate.data.dropLast().map(\.word)
    }

    /// Whether `candidate` writes Latin letters the user did not type: by its text (see above), or by a word of its that
    /// writes letters for a kana reading (JAM for ジャム typed as jamu, which the text alone lets through when the keys
    /// happen to spell the letters: REDjamu). The entries in `allowed` are meant to do that (Ogura for オグラ)
    static func writesUntypedLetters(_ candidate: Candidate, typed: String, allowed: [DicdataElement] = []) -> Bool {
        Self.writesUntypedLetters(candidate.text, typed: typed) || zip(Self.wordsBefore(candidate), candidate.data).contains { previous, element in
            Self.writesLettersForKana(element, afterNumber: previous?.last?.isNumber == true)
                && !allowed.contains { $0.word == element.word && $0.ruby == element.ruby }
        }
    }

    /// Whether `element` writes Latin letters its reading does not have: it wrote them for kana (JAM for ジャム). Letters
    /// typed as they are, and a letter still being typed after kana (アイk), are in the reading, in full width. Letters
    /// right after a number, in the word (45km) or at its start when the word before ends with one (`afterNumber`: km
    /// after 45), are the unit the number was read with (see `writesUntypedLetters(_:typed:)`)
    private static func writesLettersForKana(_ element: DicdataElement, afterNumber: Bool = false) -> Bool {
        let reading = Set(element.ruby.lowercased().unicodeScalars.map(Self.narrowed))
        return Self.letterRuns(of: element.word, startingAfterNumber: afterNumber).contains { run in
            !run.afterNumber && run.letters.contains { character in
                !character.lowercased().unicodeScalars.allSatisfy { reading.contains($0) }
            }
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
    private func makeLatinCandidate(result: ConversionResult) -> (candidate: Candidate, rank: Int)? {
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
            knownWord: LatinInputGuess.systemKnownWordOnMainThread
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
    ///   - thorough: Converts as when typing stops (see `showThoroughConversion` and
    ///     `ConvertRequestOptions.ZenzaiMode.thorough`): Zenzai weighs the dictionary's own conversion and its other
    ///     readings against what it settled on while typing. Slower.
    ///
    /// - Note:
    ///   The context is read from the app here, on the main actor; the conversion itself takes it as it is (see
    ///   `updateRawCandidate(requestRichCandidates:contexts:thorough:)`), so that it can run off the main thread too.
    @MainActor private func updateRawCandidate(
        requestRichCandidates: Bool = false,
        forcedLeftSideContext: String? = nil,
        forcedRightSideContext: String? = nil,
        thorough: Bool = false
    ) {
        self.updateRawCandidate(
            requestRichCandidates: requestRichCandidates,
            contexts: self.conversionContexts(left: forcedLeftSideContext, right: forcedRightSideContext),
            thorough: thorough
        )
    }

    /// The text around the input that the conversion reads (see `ContextLength.conversion`)
    struct ConversionContexts: Sendable {
        /// What the conversion has on its left and right: the app's, or what is given in its place (the clauses committed
        /// before the input, for example)
        var left: String?
        var right: String?
        /// What the app has on the left, which the naturalness checks of Latin words read whatever the conversion is given
        var appLeft: String?
    }

    /// The context the app has around the input, or the one given in its place
    @MainActor func conversionContexts(left: String? = nil, right: String? = nil) -> ConversionContexts {
        let appLeft = self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        return ConversionContexts(
            left: left ?? appLeft,
            right: right ?? self.getCleanRightSideContext(maxCount: ContextLength.conversion),
            appLeft: appLeft
        )
    }

    /// Converts the input with `contexts` around it (see `updateRawCandidate(requestRichCandidates:forcedLeftSideContext:forcedRightSideContext:thorough:)`).
    /// It reads nothing from the app, so it runs on whichever thread holds the conversion lock (see `ConversionLock`)
    private func updateRawCandidate(
        requestRichCandidates: Bool = false,
        contexts: ConversionContexts,
        thorough: Bool = false
    ) {
        self.resetAdditionalCandidates()
        self.latinCandidate = nil
        self.offeredTexts = []
        self.clauseAlternatives = []
        self.thoroughConversion = thorough ? .shown : .notRun
        self.zenzaiWroteUntypedLetters = false
        if !thorough {
            self.conversionBeforeThorough = nil
        }
        // Not needed
        if composingText.isEmpty {
            self.rawCandidates = nil
            self.latinWordsInput = nil
            self.wholeConversion = nil
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

        let latinWordsText = self.context.convertsAsTheConverterDoes ? nil : self.latinWordsConversionText(otherReading: requestRichCandidates, contexts: contexts)
        self.withConverter { $0.importDynamicUserDictionary(latinWordsText?.entries ?? [], shortcuts: dynamicShortcuts) }

        let leftSideContext = contexts.left
        let rightSideContext = contexts.right
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
                        zenzai: zenzai,
                        thorough: thorough
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
            self.keepWholeConversion()
            return
        }
        var converted = result
        var candidates = counting(converted)
        if self.context.useZenzai, let first = candidates.mainResults.first, Self.writesUntypedLetters(first, typed: typed, allowed: allowed) {
            // Zenzai wrote a word typed in romaji in English (note for no-to). The candidates it leaves are the plain
            // kana readings of the input, so the converter's own conversion takes over
            converted = convert(zenzai: false)
            candidates = counting(converted)
            self.zenzaiWroteUntypedLetters = true
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
            self.offeredTexts = Set([other.firstClauseResults.first?.text, other.mainResults.first?.text].compactMap { $0 })
        }
        self.hasLatinWords = latinWordsText != nil
        self.latinWordsInput = latinWordsText?.text
        self.latinCandidate = self.makeLatinCandidate(result: result)
        self.keepWholeConversion()
        if self.clauseCandidatesOnly, requestRichCandidates || self.didExperienceSegmentEdition {
            self.clauseAlternatives = self.alternativesForClause()
        }
    }

    /// Keeps the best conversion of the whole input (see `wholeConversion`) when the input was converted as a whole:
    /// while the end of the clause is moved, the conversion is of the input up to it, and the one kept still shows the rest
    private func keepWholeConversion() {
        guard self.composingText.isAtEndIndex else {
            return
        }
        self.wholeConversion = self.rawCandidates?.mainResults.first { self.composingText.isWholeComposingText(composingCount: $0.composingCount) }
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

    /// How many of the o and u in a word typed with a capital are tried as long vowels (see `japaneseName`)
    static let longVowelsTried = 3

    /// The Japanese name that `word`, a Latin word typed with a capital, stands for in the converter's dictionary (大阪 for
    /// Osaka, 神奈川 for Kanagawa, 井上 for Inoue), or nil when it stands for none the dictionary knows (Python, Win). Zenzai
    /// does not know the names in letters: after Osaka it writes 氏 for し, after 大阪 市, and after Kanagawa it goes on
    /// in letters (Ken for けん). The keys read as kana, with each of the first `longVowelsTried` o and u also tried as the
    /// long vowel that Hepburn romaji drops (おおさか for osaka, とうきょう for tokyo); the converter on its own converts each
    /// reading, and the name is the likeliest proper noun that covers a whole reading
    private func japaneseName(of word: String) -> String? {
        if let cached = self.sessionState.japaneseNames[word] {
            return cached
        }
        let name = self.lookUpJapaneseName(of: word)
        if self.sessionState.japaneseNames.count >= 256 {
            self.sessionState.japaneseNames.removeAll()
        }
        self.sessionState.japaneseNames[word] = name
        return name
    }

    private func lookUpJapaneseName(of word: String) -> String? {
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
        if self.thoroughConversion == .shown {
            // The thorough conversion shown is converted for the clauses as it was, so that they are what was shown, and
            // in copies of the sessions as it was (see `showThoroughConversion`)
            let shown = self.composingDisplayText
            self.inSessionCopies {
                self.updateRawCandidate(requestRichCandidates: requestRichCandidates, thorough: true)
            }
            if self.thoroughConversionWritesLetters(notIn: shown) {
                self.updateRawCandidate(requestRichCandidates: requestRichCandidates)
            }
        } else {
            self.updateRawCandidate(requestRichCandidates: requestRichCandidates)
        }
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
        // Another candidate than the first, or a clause moved, is a choice the user made
        self.learn(candidate, corrected: (self.selectionIndex ?? 0) > 0 || self.didExperienceSegmentEdition)
        // The clauses after this one are read again after it
        self.laterClauses = []
        self.composingText.prefixComplete(composingCount: candidate.composingCount)

        if !self.composingText.isEmpty {
            // Move the cursor to the right end
            self.moveClauseEnd(to: nil)
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

    @MainActor
    public func requestSetCandidateWindowState(visible: Bool) {
        if !visible {
            // The candidates go with the clauses: back to the whole input
            self.leaveClauses()
        }
        self.shouldShowCandidateWindow = visible
    }

    @MainActor
    public func requestSelectingNextCandidate() {
        self.isFixingAdditionalCandidateTop = false
        self.selectionIndex = (self.selectionIndex ?? -1) + 1
        // The list shows again after a function key closed it (see `applyFunction`)
        self.shouldShowCandidateWindow = true
    }

    @MainActor
    public func requestSelectingPrevCandidate() {
        let selectionIndex = self.selectionIndex ?? 0
        self.shouldShowCandidateWindow = true

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
        self.lastFunction = nil
    }

    @MainActor
    public func commitMarkedText(inputState: InputState) -> String {
        if inputState == .selecting {
            // The clauses, as shown
            return self.commitClauses()
        }
        if inputState == .composing, self.finishTrailingN() {
            // What is shown is committed, the thorough conversion when typing stopped long enough for it. Only a trailing
            // n read as ん here changes the input, and it is converted again as typing that stops would have it
            _ = self.showThoroughConversion()
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
    /// after a delete, for example). Returns whether there was one
    @discardableResult
    @MainActor private func finishTrailingN() -> Bool {
        guard self.composingText.convertTarget.last == "n", !self.isAlphabetWordInput, self.lastInputStyle != .direct else {
            return false
        }
        // The separator ends the editing of the reading too; what is shown must stay as it is, so that what is committed is
        // what was shown
        let lastOperation = self.lastOperation
        let isEditingReading = self.isEditingReading
        let readingCaret = self.readingCaret
        self.insertCompositionSeparator(inputStyle: self.lastInputStyle)
        self.lastOperation = lastOperation
        self.isEditingReading = isEditingReading
        self.readingCaret = readingCaret
        return true
    }

    /// Whether the conversion shown while typing has yet to be converted thoroughly (see `showThoroughConversion`)
    var canShowThoroughConversion: Bool {
        // While the conversion of the input is being made in the background, it is known once it is there (see
        // `requestThoroughConversionInBackground`)
        self.context.useZenzai && (self.conversionPending || self.showsLiveConversion && self.thoroughConversion == .notRun)
    }

    /// Converts the input once more and shows the result in place of the conversion made while typing; the session asks
    /// for it once typing stops (see `InputSession`), and Enter commits what is shown. While typing, Zenzai follows the
    /// prefix it settled on key by key; here it weighs that against the dictionary's own conversion and its other readings
    /// of the whole input (see `ConvertRequestOptions.ZenzaiMode.thorough`). It converts in copies of the sessions, so
    /// the next key goes on from the conversion made while typing. Returns whether what is shown changed
    @MainActor func showThoroughConversion() -> Bool {
        guard self.canShowThoroughConversion else {
            return false
        }
        return self.showThoroughConversion(contexts: self.conversionContexts())
    }

    /// The thorough conversion with `contexts` around the input (see `showThoroughConversion()`), on whichever thread holds
    /// the conversion lock
    private func showThoroughConversion(contexts: ConversionContexts) -> Bool {
        guard self.canShowThoroughConversion else {
            return false
        }
        let shown = self.composingDisplayText
        let shownConversion = self.conversionState
        self.inSessionCopies {
            self.updateRawCandidate(contexts: contexts, thorough: true)
        }
        if self.thoroughConversionWritesLetters(notIn: shown) {
            self.conversionState = shownConversion
            self.thoroughConversion = .declined
            return false
        }
        self.conversionBeforeThorough = shownConversion
        return self.composingDisplayText != shown
    }

    /// Whether the thorough conversion just made writes letters: letters the conversion shown did not have are a reading
    /// written in romaji (heibee for 平兵衛), the worst error, and when Zenzai wrote letters that were not typed the
    /// converter's own conversion took its place. Either way the conversion shown stands
    private func thoroughConversionWritesLetters(notIn shown: String) -> Bool {
        self.zenzaiWroteUntypedLetters || Self.writesLettersNotIn(shown, self.composingDisplayText)
    }

    /// Puts back the conversion that the thorough one took the place of on the screen (see `showThoroughConversion`), for
    /// a key pressed before the thorough conversion could be seen: the key is for what the user saw. Returns whether
    /// there was one
    @MainActor func putBackConversionBeforeThorough() -> Bool {
        guard self.thoroughConversion == .shown, let conversion = self.conversionBeforeThorough else {
            return false
        }
        self.conversionState = conversion
        self.conversionBeforeThorough = nil
        return true
    }

    // MARK: - Converting in the background while typing

    /// Whether the key typed now is converted in the background (see `Context.conversionScheduler`), so that it can be
    /// shown at once: in live conversion, with an identification layer that can run off the main thread, and not while
    /// the reading is edited or the clauses moved past are kept (typing there converts with them)
    public var convertsTypingInBackground: Bool {
        self.convertsInBackground && !self.isEditingReading && self.earlierClauses.isEmpty && self.laterClauses.isEmpty
    }

    /// Whether the conversions made while typing, and the thorough one when typing stops, run in the background
    private var convertsInBackground: Bool {
        self.context.conversionScheduler != nil && self.liveConversionEnabled && self.identifiesAnywhere
    }

    /// Converts the input after a key typed: in the background when it can (see `convertsTypingInBackground`), the input
    /// showing at once from the conversion shown before (see `instantDisplayText`), else here
    @MainActor private func convertAfterTyping() {
        guard self.convertsTypingInBackground else {
            self.updateRawCandidate()
            return
        }
        self.inputVersion += 1
        self.conversionPending = true
        // A thorough conversion still being made is of the input before this key: its result would not be shown
        self.thoroughCancellation?.cancel()
        self.startBackgroundJob(thorough: false)
    }

    /// The input changed since its conversion was made: the conversion is being made in the background, and what is
    /// shown comes from the conversion shown before (see `instantDisplayText`)
    private var conversionPending = false
    /// Counts the changes of the input converted in the background, to tell the conversion of the input as it is now
    private var inputVersion = 0
    /// The background job not yet taken back, and the number of the last one started
    private var runningJob: Int?
    private var lastJob = 0
    /// The thorough conversion was asked for while the conversion of the input was still being made: it starts once
    /// that is there
    private var thoroughConversionWanted = false
    /// The conversion shown last while typing and the reading it is of: the input shows from it until the conversion of
    /// the input comes (see `instantDisplayText`)
    private var shownConversion: (reading: String, text: String)?
    /// What the background jobs left for the main thread
    private let backgroundJobs = BackgroundJobs()
    /// The text the next background job converts after, in place of the app's: the start of the input just committed
    /// on its own, which the app may not have yet (see `commitLongInputHead`)
    private var nextJobLeftContext: String?
    /// Calls off the thorough conversion being made in the background (see `callOffThoroughConversion`); the twin's is
    /// that of the job it runs
    private var thoroughCancellation: ConvertRequestOptions.ZenzaiMode.Cancellation?

    /// A copy of this object for the conversion thread: it shares the converter, the sessions, the settings and the
    /// identification layer, and each job hands it the state the conversion reads (see `ConversionSnapshot`), so the
    /// input can change here while it converts
    private lazy var twin = SegmentsManager(twinOf: self)

    /// What the conversion reads of the input and what it makes, handed to the twin and back
    private struct ConversionSnapshot {
        var conversion: ConversionState
        var isAlphabetWordInput: Bool
        var lastInputStyle: InputStyle
        var isEditingReading: Bool
        var readingCaret: Int?
        var shouldShowCandidateWindow: Bool
        var zenzaiWroteUntypedLetters: Bool
        var conversionBeforeThorough: ConversionState?
        var zenzaiPersonalizationMode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode?
        var readLearnedScriptIdentifier: TaggerScriptIdentifier??
        var scriptIdentifierOverride: (any ScriptIdentifier)?
    }

    private var conversionSnapshot: ConversionSnapshot {
        get {
            ConversionSnapshot(
                conversion: self.conversionState,
                isAlphabetWordInput: self.isAlphabetWordInput,
                lastInputStyle: self.lastInputStyle,
                isEditingReading: self.isEditingReading,
                readingCaret: self.readingCaret,
                shouldShowCandidateWindow: self.shouldShowCandidateWindow,
                zenzaiWroteUntypedLetters: self.zenzaiWroteUntypedLetters,
                conversionBeforeThorough: self.conversionBeforeThorough,
                zenzaiPersonalizationMode: self.zenzaiPersonalizationMode,
                readLearnedScriptIdentifier: self.readLearnedScriptIdentifier,
                scriptIdentifierOverride: self.scriptIdentifierOverride
            )
        }
        set {
            self.conversionState = newValue.conversion
            self.isAlphabetWordInput = newValue.isAlphabetWordInput
            self.lastInputStyle = newValue.lastInputStyle
            self.isEditingReading = newValue.isEditingReading
            self.readingCaret = newValue.readingCaret
            self.shouldShowCandidateWindow = newValue.shouldShowCandidateWindow
            self.zenzaiWroteUntypedLetters = newValue.zenzaiWroteUntypedLetters
            self.conversionBeforeThorough = newValue.conversionBeforeThorough
            self.zenzaiPersonalizationMode = newValue.zenzaiPersonalizationMode
            self.readLearnedScriptIdentifier = newValue.readLearnedScriptIdentifier
            self.scriptIdentifierOverride = newValue.scriptIdentifierOverride
        }
    }

    /// What a background job made: the conversion, with what the input showed from it
    private struct BackgroundOutcome {
        var job: Int
        var thorough: Bool
        /// The `inputVersion` of the input converted
        var version: Int
        var snapshot: ConversionSnapshot
        /// The reading converted and what it shows as
        var shown: (reading: String, text: String)
        /// Whether what is shown changed (the thorough conversion; see `showThoroughConversion`)
        var changed: Bool
        /// The thorough conversion was called off while it was made (see `callOffThoroughConversion`): it is not shown
        var calledOff: Bool
    }

    /// The jobs called off, and what the last job made, between the conversion thread and the main thread
    private final class BackgroundJobs: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled: Set<Int> = []
        private var outcome: BackgroundOutcome?

        func cancel(_ job: Int) {
            self.lock.withLock { _ = self.cancelled.insert(job) }
        }

        /// Whether `job` was called off; it is forgotten as it is asked
        func isCancelled(_ job: Int) -> Bool {
            self.lock.withLock { self.cancelled.remove(job) != nil }
        }

        func put(_ outcome: BackgroundOutcome) {
            self.lock.withLock { self.outcome = outcome }
        }

        func take() -> BackgroundOutcome? {
            self.lock.withLock {
                defer {
                    self.outcome = nil
                }
                return self.outcome
            }
        }
    }

    /// Starts converting the input in the background, the thorough conversion with `thorough`, unless a job is still
    /// there: one at a time, and when it is done the input as it is then is converted (see `takeBackgroundOutcome`), so
    /// keys typed faster than they convert are converted together
    @MainActor private func startBackgroundJob(thorough: Bool) {
        guard let scheduler = self.context.conversionScheduler, self.runningJob == nil else {
            return
        }
        self.lastJob += 1
        self.runningJob = self.lastJob
        let cancellation = thorough ? ConvertRequestOptions.ZenzaiMode.Cancellation() : nil
        self.thoroughCancellation = cancellation
        let job = Handed((id: self.lastJob, version: self.inputVersion, snapshot: self.conversionSnapshot, contexts: self.conversionContexts(left: self.nextJobLeftContext), cancellation: cancellation))
        self.nextJobLeftContext = nil
        let twin = Handed(self.twin)
        let jobs = self.backgroundJobs
        let manager = WeaklyHanded(self)
        scheduler.schedule({
            let job = job.value
            guard !jobs.isCancelled(job.id) else {
                return
            }
            let twin = twin.value
            twin.conversionSnapshot = job.snapshot
            twin.thoroughCancellation = job.cancellation
            defer {
                twin.thoroughCancellation = nil
            }
            var changed = true
            if thorough {
                changed = twin.showThoroughConversion(contexts: job.contexts)
            } else {
                twin.updateRawCandidate(contexts: job.contexts)
            }
            jobs.put(BackgroundOutcome(
                job: job.id,
                thorough: thorough,
                version: job.version,
                snapshot: twin.conversionSnapshot,
                shown: (twin.composingText.convertTarget, twin.composingDisplayText),
                changed: changed,
                calledOff: job.cancellation?.isCancelled ?? false
            ))
        }, then: {
            manager.value?.takeBackgroundOutcome()
        })
    }

    /// Takes what the background made, on the main thread: the conversion of the input as it is now takes the place of
    /// the instant display; one of an input typed on since is what the instant display goes on from. With `notifying`,
    /// the delegate hears that what the input shows changed
    @MainActor private func takeBackgroundOutcome(notifying: Bool = true) {
        guard let outcome = self.backgroundJobs.take() else {
            return
        }
        if outcome.job == self.runningJob {
            self.runningJob = nil
            self.thoroughCancellation = nil
        }
        let current = outcome.version == self.inputVersion
        if outcome.thorough {
            self.takeThoroughOutcome(outcome, notifying: notifying)
        } else if current, self.conversionPending {
            self.install(outcome.snapshot)
            self.conversionPending = false
            if notifying {
                self.delegate?.segmentsManagerDidUpdateDisplay(thoroughConversionShown: false)
            }
            if self.thoroughConversionWanted {
                self.thoroughConversionWanted = false
                self.requestThoroughConversionInBackground()
            }
        } else if !current {
            self.shownConversion = outcome.shown
            if notifying {
                self.delegate?.segmentsManagerDidUpdateDisplay(thoroughConversionShown: false)
            }
        }
        if self.conversionPending {
            self.startBackgroundJob(thorough: false)
        }
    }

    /// The thorough conversion a job made (see `takeBackgroundOutcome`): shown if nothing changed since it started
    @MainActor private func takeThoroughOutcome(_ outcome: BackgroundOutcome, notifying: Bool) {
        guard outcome.version == self.inputVersion, !outcome.calledOff, !self.conversionPending, self.thoroughConversion == .notRun else {
            return
        }
        self.install(outcome.snapshot)
        if notifying {
            self.delegate?.segmentsManagerDidUpdateDisplay(thoroughConversionShown: outcome.changed)
        }
    }

    /// The conversion a job made, for the input as it is here
    private func install(_ snapshot: ConversionSnapshot) {
        self.conversionState = snapshot.conversion
        self.zenzaiWroteUntypedLetters = snapshot.zenzaiWroteUntypedLetters
        self.conversionBeforeThorough = snapshot.conversionBeforeThorough
    }

    /// Asks for the thorough conversion once typing stops, made in the background (see `showThoroughConversion`): it
    /// starts once the conversion of the input is there, and the delegate hears when it is shown. Returns false when it
    /// is not made in the background, for the caller to make it
    @discardableResult
    @MainActor func requestThoroughConversionInBackground() -> Bool {
        guard self.convertsInBackground else {
            return false
        }
        if self.conversionPending || self.runningJob != nil {
            self.thoroughConversionWanted = true
        } else if self.canShowThoroughConversion {
            self.startBackgroundJob(thorough: true)
        }
        return true
    }

    /// Makes the conversion of the input as it is now the one there, for a key that needs it (Space, Enter, a delete, a
    /// clause moved): takes what the background made, and converts here what it has not. The caller holds the conversion
    /// lock, so nothing runs in the background meanwhile, and a job still waiting is called off. A thorough conversion
    /// not yet shown is dropped: the key is for what is shown
    @MainActor public func settleConversion() {
        if let outcome = self.backgroundJobs.take() {
            if outcome.job == self.runningJob {
                self.runningJob = nil
                self.thoroughCancellation = nil
            }
            if !outcome.thorough, outcome.version == self.inputVersion, self.conversionPending {
                self.install(outcome.snapshot)
                self.conversionPending = false
            }
        }
        if let job = self.runningJob {
            self.backgroundJobs.cancel(job)
            self.runningJob = nil
            self.thoroughCancellation = nil
        }
        self.thoroughConversionWanted = false
        if self.conversionPending {
            self.conversionPending = false
            self.updateRawCandidate()
        }
    }

    /// Calls off the thorough conversion being made in the background, before waiting for the conversion lock (see
    /// `settleConversion`): a key that needs the conversion is for what is shown, so the thorough conversion would be
    /// dropped, and it stops at its next inference instead of making the key wait for the rest. The conversion made while
    /// typing is not called off: the key needs it, and stopping it would leave the session as no full conversion leaves
    /// it
    @MainActor public func callOffThoroughConversion() {
        self.thoroughCancellation?.cancel()
    }

    /// Calls off what runs in the background for the input, when the input ends
    private func dropBackgroundConversion() {
        self.thoroughCancellation?.cancel()
        self.thoroughCancellation = nil
        self.nextJobLeftContext = nil
        if let job = self.runningJob {
            self.backgroundJobs.cancel(job)
            self.runningJob = nil
        }
        _ = self.backgroundJobs.take()
        self.conversionPending = false
        self.thoroughConversionWanted = false
        self.shownConversion = nil
    }

    /// How many characters of the reading the input shows unconverted while its conversion is being made: those typed
    /// since the reading of the conversion shown (see `instantDisplayText`). The session stops taking keys while there are
    /// too many (see `InputSession.pausesTyping`)
    public var unconvertedCharacterCount: Int {
        guard self.conversionPending else {
            return 0
        }
        let reading = self.composingText.convertTarget
        guard let shown = self.shownConversion else {
            return reading.count
        }
        return reading.count - zip(shown.reading, reading).prefix { $0 == $1 }.count
    }

    /// What the input shows while its conversion is being made: the conversion shown before, with the reading typed
    /// since it in place of the reading it was of from where the two part (今日h then a: 今日は, the h read with the a).
    /// When what was shown does not end in that old reading, the reading as it is (see `instantDisplay`)
    private var instantDisplayText: String {
        let reading = self.composingText.convertTarget
        guard reading.count > 1 else {
            return reading
        }
        return Self.instantDisplay(of: reading, after: self.shownConversion)
    }

    /// `reading` shown at once after `shown`, the conversion shown with the reading it is of (see `instantDisplayText`)
    static func instantDisplay(of reading: String, after shown: (reading: String, text: String)?) -> String {
        guard let shown else {
            return reading
        }
        let common = zip(shown.reading, reading).prefix { $0 == $1 }.count
        let oldTail = shown.reading.dropFirst(common)
        guard shown.text.hasSuffix(oldTail) else {
            return reading
        }
        return String(shown.text.dropLast(oldTail.count)) + reading.dropFirst(common)
    }

    // MARK: - Committing the start of a long input

    /// How many characters at the end of the reading are never committed on their own (see `longInputHead`): the user
    /// goes back to correct the conversion there
    public static let keptUncommitted = 60
    /// From how many characters of the reading its start is committed once typing stops and the thorough conversion is
    /// shown: up to the last sentence done before the characters kept, else the last comma. The longer the input, the
    /// longer each conversion of it: on an M1 (estimated from what each part of a conversion takes on an M5 Max), a key
    /// takes 63 ms in median at 40–59 characters, 130 ms at 80–99 and 430 ms at 120–139 (238, 487 and 936 ms at the slow
    /// 5%), and the thorough conversion 1.7 s at 155. Zenzai reads 512 tokens at most, the reading and its conversion
    /// together
    public static let committedAtPauseFrom = 80
    /// From how many characters the start is committed on any conversion of the input, without waiting for typing to stop
    /// (a sentence that goes on, a key held down): at the last sentence done before the characters kept, else the last
    /// comma, else between words
    public static let committedAnywhereFrom = 100
    private static let sentenceEnds: Set<Character> = ["。", "．", ".", "！", "!", "？", "?"]
    private static let commas: Set<Character> = ["、", "，", ","]
    private static let closingBrackets: Set<Character> = ["」", "』", "）", ")", "】", "］", "]", "〉", "》", "”", "’"]

    /// The start of a long input to commit on its own, as the input shows it: the conversion shown, up to the place where
    /// it is cut (see `committedAtPauseFrom` and `committedAnywhereFrom`). Nil when the input is not that long, has no
    /// place to cut, or does not show its own conversion as a whole (while its conversion is being made, while clauses
    /// or the reading are edited, letters typed as a word)
    @MainActor public func longInputHead() -> Candidate? {
        let readingCount = self.composingText.convertTarget.count
        guard readingCount >= Self.committedAtPauseFrom, !self.conversionPending, self.earlierClauses.isEmpty,
              self.laterClauses.isEmpty, !self.isEditingReading, !self.isAlphabetWordInput, self.clauseEnd == nil,
              self.showsLiveConversion, let whole = self.rawCandidates?.mainResults.first,
              self.composingText.isWholeComposingText(composingCount: whole.composingCount),
              whole.text == self.composingDisplayText, whole.text == whole.data.map(\.word).joined() else {
            return nil
        }
        let anywhere = readingCount >= Self.committedAnywhereFrom
        guard anywhere || self.thoroughConversion == .shown else {
            return nil
        }
        // The words laid over the reading the converter read (Latin words as letters), as for the clauses (see `restWords`)
        let base = self.latinWordsInput.flatMap { $0.input.count == self.composingText.input.count ? $0 : nil } ?? self.composingText
        let lengths = whole.data.map { $0.ruby.count }
        let total = base.convertTarget.count
        guard lengths.reduce(0, +) == total else {
            return nil
        }
        // The places between words: after a sentence done (its closing brackets with it), after a comma, or between two
        // words that are not the letters of one Latin word
        enum Place { case sentence, comma, word }
        struct Cut {
            /// The words before it, and the characters of the reading they take
            var words: Int
            var surface: Int
            var place: Place
        }
        func isLetter(_ character: Character?) -> Bool {
            character.map { $0.isASCII && $0.isLetter } ?? false
        }
        var places: [Cut] = []
        var surface = 0
        var text = ""
        for index in whole.data.indices.dropLast() {
            surface += lengths[index]
            text += whole.data[index].word
            let next = whole.data[index + 1].word.first
            if let next, Self.closingBrackets.contains(next) || Self.sentenceEnds.contains(next) || Self.commas.contains(next) {
                continue
            }
            let last = text.reversed().first { !Self.closingBrackets.contains($0) }
            let place: Place = if let last, Self.sentenceEnds.contains(last) {
                .sentence
            } else if let last, Self.commas.contains(last) {
                .comma
            } else {
                .word
            }
            if place == .word, isLetter(text.last), isLetter(next) {
                continue
            }
            places.append(Cut(words: index + 1, surface: surface, place: place))
        }
        let before = places.filter { total - $0.surface >= Self.keptUncommitted }
        let chosen = before.last { $0.place == .sentence } ?? before.last { $0.place == .comma }
            ?? (anywhere ? before.last { $0.place == .word } : nil)
        // The keys the cut comes after: a place where the reading of the keys before it ends
        guard let chosen, let keys = base.inputIndexToSurfaceIndexMap().filter({ $0.value == chosen.surface }).keys.max(), keys > 0 else {
            return nil
        }
        let data = Array(whole.data.prefix(chosen.words))
        return Candidate(
            text: data.map(\.word).joined(),
            value: data.reduce(0) { $0 + $1.value() },
            composingCount: .inputCount(keys),
            lastMid: data.last?.mid ?? MIDData.一般.mid,
            data: data
        )
    }

    /// Commits `head`, the start of the input (see `longInputHead`), which the caller inserts, and goes on with the rest:
    /// it shows as the conversion showed it, and converts after the text committed. `leftSideContext` is the text before
    /// the input, read before the head is inserted
    @MainActor public func commitLongInputHead(_ head: Candidate, leftSideContext: String) {
        let shown = self.composingDisplayText
        self.learn(head, corrected: false)
        self.composingText.prefixComplete(composingCount: head.composingCount)
        self.wholeConversion = nil
        self.selectionIndex = nil
        self.didExperienceSegmentEdition = false
        self.conversionBeforeThorough = nil
        self.thoroughConversion = .notRun
        self.shownConversion = (self.composingText.convertTarget, String(shown.dropFirst(head.text.count)))
        let left = leftSideContext + head.text
        if self.convertsTypingInBackground {
            self.inputVersion += 1
            self.conversionPending = true
            self.nextJobLeftContext = left
            self.startBackgroundJob(thorough: false)
        } else {
            self.updateRawCandidate(forcedLeftSideContext: left)
        }
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

    /// Whether the input has gone back to its reading by cancelling the conversion, with nothing typed or deleted
    /// since: Esc then clears the input, where otherwise it stops at the reading first, even when the reading looks
    /// the same as what live conversion showed (これはWindowsです)
    public var hasReturnedToReading: Bool {
        self.lastOperation == .cancelConversion || self.isEditingReading
    }

    /// What the input shows as while it is being typed
    private var composingDisplayText: String {
        if self.showsReading {
            // After a delete or a conversion cancel, always show hiragana, but keep Latin words as typed
            self.readingKeepingLatinWords ?? self.composingText.convertTarget
        } else if self.isAlphabetWordInput {
            // During English input, show the letters as typed
            self.composingText.convertTarget
        } else if self.conversionPending {
            // The conversion of the input is being made: at once from the one shown before
            self.instantDisplayText
        } else if self.showsLiveConversion, let firstCandidate = self.rawCandidates?.mainResults.first {
            // Otherwise, if live conversion is on
            firstCandidate.text
        } else {
            // Otherwise
            self.composingText.convertTarget
        }
    }

    /// Whether the reading is shown while composing (after a delete, a conversion cancel, or while the reading is edited)
    private var showsReading: Bool {
        self.lastOperation == .delete || self.lastOperation == .cancelConversion || self.isEditingReading
    }

    /// Whether the text shown while composing is the live conversion (the converter's first candidate), not the reading
    /// or the letters typed (see `composingDisplayText`)
    private var showsLiveConversion: Bool {
        !self.showsReading && !self.isAlphabetWordInput && self.liveConversionEnabled
            && self.composingText.convertTarget.count > 1 && self.rawCandidates?.mainResults.first != nil
    }

    /// What the input shows while it is being typed (see `composingDisplayText`), with the caret
    private func composingMarkedText() -> MarkedText {
        let text = self.composingDisplayText
        if !self.conversionPending {
            // What the instant display goes on from while the next keys convert
            self.shownConversion = (self.composingText.convertTarget, text)
        }
        // The caret inside the reading being edited, when it is not at the end
        var selectionRange = NSRange.notFound
        if self.isEditingReading, let caret = self.readingCaret {
            // The reading shown keeps the Latin words as typed, as the converter's text does (see `readingText`,
            // `readingKeepingLatinWords`): the caret is placed by the reading before it, or after it, whichever the
            // text shown shares
            let reading = self.readingText
            let surface = Self.surfaceIndex(of: caret, in: reading)
            let before = reading.convertTarget.prefix(surface)
            let after = reading.convertTarget.dropFirst(surface)
            let location = text.hasPrefix(before) ? before.count : text.hasSuffix(after) ? text.count - after.count : text.count
            selectionRange = NSRange(location: location, length: 0)
        }
        return MarkedText(text: [.init(content: text, focus: .none)], selectionRange: selectionRange)
    }

    public func getCurrentMarkedText(inputState: InputState) -> MarkedText {
        switch inputState {
        case .none, .attachDiacritic:
            return MarkedText(text: [], selectionRange: .notFound)
        case .composing:
            return self.composingMarkedText()
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
            // The clauses moved past (see `moveClauseFocus`), the clause being converted, and the input after it
            let earlier = self.earlierClauses.map(\.candidate.text).joined()
            if let candidates, !candidates.isEmpty {
                self.selectionIndex = min(self.selectionIndex ?? 0, candidates.count - 1)
                let selected = candidates[self.selectionIndex!]
                var text: [MarkedText.Element] = []
                if !earlier.isEmpty {
                    text.append(.init(content: earlier, focus: .unfocused))
                }
                text.append(.init(content: selected.text, focus: .focused))
                text.append(.init(content: self.textAfterClause(selected), focus: .unfocused))
                return MarkedText(text: text, selectionRange: NSRange(location: earlier.count + selected.text.count, length: 0))
            } else {
                return MarkedText(text: [.init(content: earlier + self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
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
    /// A conversion made in the background is there (see `SegmentsManager.convertsTypingInBackground`);
    /// `thoroughConversionShown` when it is the thorough conversion made once typing stopped, and it changed what is shown
    func segmentsManagerDidUpdateDisplay(thoroughConversionShown: Bool)
}

extension SegmentManagerDelegate {
    public func segmentsManagerDidUpdateDisplay(thoroughConversionShown: Bool) {}
}

private extension ComposingText {
    func isWholeComposingText(composingCount: ComposingCount) -> Bool {
        var c = self
        c.prefixComplete(composingCount: composingCount)
        return c.isEmpty
    }
}
