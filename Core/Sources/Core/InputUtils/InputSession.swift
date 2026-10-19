import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Operations that the input session asks of the host (such as IMKInputController).
/// Tests replace it with an implementation that records the calls.
@MainActor
public protocol InputSessionHost: AnyObject {
    /// Insert committed text at the cursor
    func insertText(_ text: String)
    /// Update the marked text. An empty value clears the marked text
    func updateMarkedText(_ markedText: SegmentsManager.MarkedText)
    /// Apply the input mode (Japanese / English) on the host side
    func switchInputMode(_ language: InputLanguage)
    /// Row of the candidate chosen with a number key. Takes the candidate window's current page into account
    func candidateRow(forNumberKey number: Int) -> Int
    /// Context to the left and right of the cursor (read to improve conversion accuracy; never stored)
    func leftSideContext(maxCount: Int) -> String?
    func rightSideContext(maxCount: Int) -> String?
    /// The conversion made in the background after a key changed what is shown, after the marked text was updated: the
    /// host redraws what it draws from the session (the candidate window, for example)
    func conversionDidUpdate()
}

extension InputSessionHost {
    public func conversionDidUpdate() {}
}

/// Input session that does not depend on IMK.
///
/// Receives key events, drives the `InputState` state machine and `SegmentsManager`,
/// and reports the results (inserted text, marked text, input mode changes) to `InputSessionHost`.
/// Showing the candidate window and the prediction window is the host's job. The host reads `candidateWindow` and
/// `predictionCandidates` and draws them.
@MainActor
public final class InputSession {
    /// Settings that control the session. In production they come from `Config`; tests pass fixed values.
    public struct Settings: Sendable {
        public var liveConversionEnabled: Bool
        public var keyBindingStyle: Config.KeyBindingStyle.Value
        public var inputStyle: InputStyle
        /// Keys that trigger "continue writing"
        public var continuationKeys: ContinuationKeys
        /// Symbol keys make half-width symbols (% rather than ％): Config.TypeHalfWidthSymbols
        public var typeHalfWidthSymbols: Bool

        public init(liveConversionEnabled: Bool, keyBindingStyle: Config.KeyBindingStyle.Value, inputStyle: InputStyle, continuationKeys: ContinuationKeys = .all, typeHalfWidthSymbols: Bool = false) {
            self.liveConversionEnabled = liveConversionEnabled
            self.keyBindingStyle = keyBindingStyle
            self.inputStyle = inputStyle
            self.continuationKeys = continuationKeys
            self.typeHalfWidthSymbols = typeHalfWidthSymbols
        }

        public static var current: Settings {
            Settings(
                liveConversionEnabled: Config.LiveConversion().value,
                keyBindingStyle: Config.KeyBindingStyle().value,
                inputStyle: Config.InputStyle().value.converterInputStyle,
                continuationKeys: .current,
                typeHalfWidthSymbols: Config.TypeHalfWidthSymbols().value
            )
        }
    }

    public let segmentsManager: SegmentsManager
    public private(set) var inputState: InputState = .none
    public private(set) var inputLanguage: InputLanguage = .japanese
    public weak var host: (any InputSessionHost)?

    private let settingsProvider: @MainActor () -> Settings
    private let now: @MainActor () -> TimeInterval
    /// Runs the thorough conversion once typing stops (see `scheduleThoroughConversion`)
    private let typingPauseScheduler: DebouncedActionScheduler
    /// How long typing has to stop for the thorough conversion to be shown: longer than the time between keys while
    /// typing, so that it runs when the input is likely to be committed
    static let thoroughConversionDelay: TimeInterval = 0.2
    /// The clock of `KeyEventCore.timestamp`
    private let uptime: @MainActor () -> TimeInterval
    /// When the thorough conversion was last shown, by `uptime`, until the next event
    private var thoroughConversionShownAt: TimeInterval?
    /// How long after the thorough conversion is shown it can be seen: the app draws it on its next frame
    static let thoroughConversionVisibleAfter: TimeInterval = 0.05

    // Detects a double tap of the 英数 (Eisu) key
    private var lastKey: (time: TimeInterval, code: UInt16) = (0, 0)
    private static let doubleTapInterval: TimeInterval = 0.5
    private static let eisuKeyCode: UInt16 = 102

    // MARK: - Continue writing (implemented in InputSession+Continuation.swift)

    /// The continuation currently shown. nil means nothing is shown
    public internal(set) var continuation: Continuation?
    /// Model that writes the continuation. nil means the feature is off
    public var continuationProvider: (any ContinuationProvider)?
    var continuationTask: Task<Void, Never>?
    var continuationGeneration = 0
    /// The context the shown continuation was written for. Asking again while it is shown reuses it (see `requestContinuation`)
    var continuationContext: String?

    /// - Parameters:
    ///   - typingPauseScheduler: Runs work once typing stops; tests pass one that runs it when they say typing stopped.
    ///   - uptime: The clock of the keys' timestamps (`KeyEventCore.timestamp`).
    public init(
        segmentsManager: SegmentsManager,
        settingsProvider: @escaping @MainActor () -> Settings = { .current },
        now: @escaping @MainActor () -> TimeInterval = { Date().timeIntervalSince1970 },
        typingPauseScheduler: DebouncedActionScheduler = DebouncedActionScheduler(),
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.segmentsManager = segmentsManager
        self.settingsProvider = settingsProvider
        self.now = now
        self.typingPauseScheduler = typingPauseScheduler
        self.uptime = uptime
        self.segmentsManager.delegate = self
    }

    // MARK: - Reading state for display

    public var markedText: SegmentsManager.MarkedText {
        let markedText = self.segmentsManager.getCurrentMarkedText(inputState: self.inputState)
        if let continuation = self.continuation {
            return markedText.appendingGhost(continuation.displayText)
        }
        return markedText
    }

    public var candidateWindow: SegmentsManager.CandidateWindow {
        self.segmentsManager.getCurrentCandidateWindow(inputState: self.inputState)
    }

    public var predictionCandidates: [SegmentsManager.PredictionCandidate] {
        guard self.inputState == .composing else {
            return []
        }
        return self.segmentsManager.requestPredictionCandidates()
    }

    // MARK: - Lifecycle

    public func activate() {
        self.segmentsManager.activate()
    }

    public func deactivate() {
        self.cancelContinuation()
        self.typingPauseScheduler.cancel()
        self.segmentsManager.callOffThoroughConversion()
        ConversionLock.withLock {
            self.segmentsManager.deactivate(flushLearningData: false)
        }
        self.inputState = .none
    }

    // MARK: - Events from the host

    /// Handle a key event. Returns true if the IME consumed it, false if it should go to the app.
    public func handle(_ event: KeyEventCore) -> Bool {
        defer {
            self.scheduleThoroughConversion()
        }
        // A key made up without a time (0, as some tools post them) is taken as pressed now
        if let pressed = event.timestamp, pressed > 0, let shownAt = self.thoroughConversionShownAt,
           pressed < shownAt + Self.thoroughConversionVisibleAfter, self.inputState == .composing,
           self.segmentsManager.putBackConversionBeforeThorough() {
            // The key was pressed while the thorough conversion was being made, before it could be seen (the main thread
            // was busy with it): the key is for the conversion the user saw
            self.host?.updateMarkedText(self.markedText)
        }
        self.thoroughConversionShownAt = nil
        let settings = self.settingsProvider()
        let userAction = UserAction.getUserAction(
            eventCore: event,
            inputLanguage: self.inputLanguage,
            typeHalfWidthSymbols: settings.typeHalfWidthSymbols,
            keyBindingStyle: settings.keyBindingStyle,
            continuationKeys: settings.continuationKeys
        )

        // If a continuation is shown, first handle accepting or discarding it
        if let handled = self.handleContinuationKey(userAction: userAction) {
            return handled
        }

        // Double tap of the 英数 (Eisu) key: commit the current input as half-width alphanumerics and switch to English mode
        if event.keyCode == Self.eisuKeyCode, self.checkAndUpdateDoubleTap(keyCode: event.keyCode), !self.segmentsManager.isEmpty {
            self.withSettledConversion {
                _ = self.handleClientAction(.submitHalfWidthRomanCandidate, callback: .transition(.none), settings: settings)
                self.switchInputLanguage(.english)
            }
            return true
        }

        let (clientAction, callback) = self.inputState.event(
            eventCore: event,
            userAction: userAction,
            inputLanguage: self.inputLanguage,
            liveConversionEnabled: settings.liveConversionEnabled,
            keyBindingStyle: settings.keyBindingStyle
        )
        if Self.typesIntoInput(clientAction), self.segmentsManager.convertsTypingInBackground {
            if self.pausesTyping() {
                // Taken and dropped: the conversion is too far behind (a key held down)
                return true
            }
            // Shown at once; the conversion of the input comes from the background (see `segmentsManagerDidUpdateDisplay`)
            return self.handleClientAction(clientAction, callback: callback, settings: settings)
        }
        return self.withSettledConversion {
            let handled = self.handleClientAction(clientAction, callback: callback, settings: settings)
            if Self.typesIntoInput(clientAction) {
                // Converted here: the start of a long input is committed now (in the background, when its conversion comes)
                self.commitLongInputHead()
            }
            return handled
        }
    }

    /// Commits the start of a long input on its own, as it is shown, up to a good place before the characters kept to
    /// correct (see `SegmentsManager.longInputHead`)
    private func commitLongInputHead() {
        guard self.inputState == .composing, self.continuation == nil, let head = self.segmentsManager.longInputHead() else {
            return
        }
        let leftSideContext = self.segmentsManager.getCleanLeftSideContext(maxCount: 30) ?? ""
        self.host?.insertText(head.text)
        ConversionLock.withLock {
            self.segmentsManager.commitLongInputHead(head, leftSideContext: leftSideContext)
        }
        self.thoroughConversionShownAt = nil
        self.host?.updateMarkedText(self.markedText)
    }

    /// Keys typed far faster than they convert for long (a key held down, repeating) would leave the conversion ever further
    /// behind, the input growing and each conversion of it taking longer. Once this many characters of the reading show
    /// unconverted (see `SegmentsManager.unconvertedCharacterCount`), the keys that type are dropped until the conversion
    /// catches up to fewer than `typingResumesBelow`; the other keys work as ever
    static let typingPausesAt = 16
    static let typingResumesBelow = 4
    /// Typing is paused (see `typingPausesAt`)
    private var typingPaused = false

    /// Whether the key that types is dropped (see `typingPausesAt`)
    private func pausesTyping() -> Bool {
        let unconverted = self.segmentsManager.unconvertedCharacterCount
        if self.typingPaused, unconverted < Self.typingResumesBelow {
            self.typingPaused = false
        } else if !self.typingPaused, unconverted >= Self.typingPausesAt {
            self.typingPaused = true
        }
        return self.typingPaused
    }

    /// Whether the action only types into the input, which can be shown before it is converted
    private static func typesIntoInput(_ action: ClientAction) -> Bool {
        switch action {
        case .appendToMarkedText, .appendPieceToMarkedText:
            true
        default:
            false
        }
    }

    /// Runs `body` with the conversion of the input as it is now, nothing converting in the background meanwhile (see
    /// `SegmentsManager.settleConversion`): what a key does with the conversion, it does with that of what was typed
    private func withSettledConversion<Result>(_ body: () -> Result) -> Result {
        self.segmentsManager.callOffThoroughConversion()
        return ConversionLock.withLock {
            self.segmentsManager.settleConversion()
            return body()
        }
    }

    /// Called when the OS asks to commit the marked text (a click or a focus change)
    public func commitComposition() {
        defer {
            self.scheduleThoroughConversion()
        }
        self.withSettledConversion {
            self.commitCompositionSettled()
        }
    }

    private func commitCompositionSettled() {
        self.cancelContinuation()
        // In Unicode input mode, only reset the state and return.
        // The IME cannot remove marked text that the OS has already committed.
        if case .unicodeInput = self.inputState {
            self.inputState = .none
            return
        }
        if self.segmentsManager.isEmpty {
            return
        }
        let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
        self.host?.insertText(text)
        self.inputState = .none
        self.host?.updateMarkedText(self.markedText)
    }

    /// Called when the input mode is changed from the menu bar or a shortcut
    public func inputModeDidChange(to language: InputLanguage) {
        defer {
            self.scheduleThoroughConversion()
        }
        self.withSettledConversion {
            self.inputModeDidChangeSettled(to: language)
        }
    }

    private func inputModeDidChangeSettled(to language: InputLanguage) {
        switch language {
        case .english:
            // Switch to English input and keep the marked text, shown as it will be committed (the reading)
            if self.inputLanguage == .japanese {
                self.inputLanguage = .english
                self.segmentsManager.stopJapaneseInput()
                self.host?.updateMarkedText(self.markedText)
            }
        case .japanese:
            if self.inputLanguage == .english {
                self.inputLanguage = .japanese
                let (clientAction, callback) = self.inputState.event(
                    eventCore: .init(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 0x00),
                    userAction: .かな,
                    inputLanguage: self.inputLanguage,
                    liveConversionEnabled: false
                )
                _ = self.handleClientAction(clientAction, callback: callback, settings: self.settingsProvider())
            }
        }
    }

    /// A candidate was chosen in the candidate window (by a click, for example). With MS-IME key bindings it is chosen
    /// for the clause and the next clause follows, as with a number key; otherwise it is committed
    public func submitCandidateFromWindow() {
        defer {
            self.scheduleThoroughConversion()
        }
        self.withSettledConversion {
            if self.settingsProvider().keyBindingStyle == .msIME, self.inputState == .selecting {
                self.segmentsManager.moveClauseFocus(count: 1)
            } else {
                self.submitSelectedCandidate()
                self.inputState = self.segmentsManager.isEmpty ? .none : .previewing
            }
            self.host?.updateMarkedText(self.markedText)
        }
    }

    /// The selected row in the candidate window changed
    public func selectCandidateRow(_ row: Int) {
        defer {
            self.scheduleThoroughConversion()
        }
        self.withSettledConversion {
            self.segmentsManager.requestSelectingRow(row)
            self.inputState = .selecting
            self.host?.updateMarkedText(self.markedText)
        }
    }

    // MARK: - Internal processing

    /// Shows the thorough conversion once typing stops (see `SegmentsManager.showThoroughConversion`), so that Enter
    /// commits it as it is shown. Called after each event: a key typed before then puts it off, and anything that leaves
    /// the live conversion cancels it
    private func scheduleThoroughConversion() {
        guard self.inputState == .composing, self.segmentsManager.canShowThoroughConversion else {
            self.typingPauseScheduler.cancel()
            return
        }
        self.typingPauseScheduler.schedule(after: Self.thoroughConversionDelay) { [weak self] in
            guard let self, self.inputState == .composing else {
                return
            }
            // Made in the background when the conversions are, and shown when it comes (see `segmentsManagerDidUpdateDisplay`)
            if self.segmentsManager.requestThoroughConversionInBackground() {
                return
            }
            ConversionLock.withLock {
                if self.segmentsManager.showThoroughConversion() {
                    self.host?.updateMarkedText(self.markedText)
                    self.thoroughConversionShownAt = self.uptime()
                }
                // Whether or not it changed what is shown, the start of a long input is committed in its form
                self.commitLongInputHead()
            }
        }
    }

    private func checkAndUpdateDoubleTap(keyCode: UInt16) -> Bool {
        let now = self.now()
        let isDouble = (self.lastKey.code == keyCode) && (now - self.lastKey.time < Self.doubleTapInterval)
        self.lastKey = (time: now, code: keyCode)
        return isDouble
    }

    private func switchInputLanguage(_ language: InputLanguage) {
        self.inputLanguage = language
        self.host?.switchInputMode(language)
        if language == .english {
            self.segmentsManager.stopJapaneseInput()
        }
    }

    private func submitCandidate(_ candidate: Candidate) {
        // Get the context before inserting
        let cleanLeftSideContext = self.segmentsManager.getCleanLeftSideContext(maxCount: 30) ?? ""
        // The clauses moved past with → come before it
        let earlierClauses = self.segmentsManager.takeEarlierClauses()
        self.host?.insertText(earlierClauses + candidate.text)
        self.segmentsManager.prefixCandidateCommited(candidate, leftSideContext: cleanLeftSideContext + earlierClauses)
    }

    /// Commits the input, or the selected clause, in the form of the function key (F6 hiragana … F10 half-width letters)
    private func submitFunctionCandidate(_ function: UserAction.Function) {
        let candidate = switch function {
        case .six:
            self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) { $0.toHiragana() }
        case .seven:
            self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) { $0.toKatakana() }
        case .eight:
            self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) {
                $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false)!
            }
        case .nine:
            self.segmentsManager.getModifiedRomanCandidate(inputState: self.inputState) {
                $0.applyingTransform(.fullwidthToHalfwidth, reverse: true)!
            }
        case .ten:
            self.segmentsManager.getModifiedRomanCandidate(inputState: self.inputState) {
                $0.applyingTransform(.fullwidthToHalfwidth, reverse: false)!
            }
        }
        self.submitCandidate(candidate)
    }

    private func submitSelectedCandidate() {
        if let candidate = self.segmentsManager.selectedCandidate {
            self.submitCandidate(candidate)
            self.segmentsManager.requestResettingSelection()
        }
    }

    private func commitMarkedText() {
        let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
        self.host?.insertText(text)
    }

    /// In English mode, use .direct to type the text as is, without romaji conversion
    private func effectiveInputStyle(_ settings: Settings) -> InputStyle {
        self.inputLanguage == .english ? .direct : settings.inputStyle
    }

    // This kind of code can only get complex, so disable the lint
    // swiftlint:disable:next cyclomatic_complexity
    private func handleClientAction(_ clientAction: ClientAction, callback: ClientActionCallback, settings: Settings) -> Bool {
        switch clientAction {
        case .showCandidateWindow:
            self.segmentsManager.requestSetCandidateWindowState(visible: true)
        case .hideCandidateWindow:
            self.segmentsManager.requestSetCandidateWindowState(visible: false)
        case .enterFirstCandidatePreviewMode:
            self.segmentsManager.insertCompositionSeparator(inputStyle: settings.inputStyle, skipUpdate: false)
            self.segmentsManager.requestSetCandidateWindowState(visible: false)
        case .enterCandidateSelectionMode:
            self.segmentsManager.insertCompositionSeparator(inputStyle: settings.inputStyle, skipUpdate: true)
            self.segmentsManager.update(requestRichCandidates: true)
        case .appendToMarkedText(let string):
            self.segmentsManager.insertAtCursorPosition(string, inputStyle: self.effectiveInputStyle(settings))
        case .appendPieceToMarkedText(let pieces):
            self.segmentsManager.insertAtCursorPosition(pieces: pieces, inputStyle: self.effectiveInputStyle(settings))
        case .insertWithoutMarkedText(let string):
            self.host?.insertText(string)
        case .editSegment(let count):
            self.segmentsManager.editSegment(count: count)
        case .moveCursor(let count):
            self.segmentsManager.moveCursor(count: count)
        case .commitMarkedText:
            self.commitMarkedText()
        case .commitMarkedTextAndAppendToMarkedText(let string):
            self.commitMarkedText()
            self.segmentsManager.insertAtCursorPosition(string, inputStyle: self.effectiveInputStyle(settings))
        case .commitMarkedTextAndAppendPieceToMarkedText(let pieces):
            self.commitMarkedText()
            self.segmentsManager.insertAtCursorPosition(pieces: pieces, inputStyle: self.effectiveInputStyle(settings))
        case .submitSelectedCandidate:
            self.submitSelectedCandidate()
        case .commitAllCandidates:
            // The clauses as shown, the ones moved past with → first
            self.host?.insertText(self.segmentsManager.commitClauses())
        case .moveClauseFocus(let count):
            if self.inputState == .previewing {
                // The clauses of the conversion shown
                self.segmentsManager.update(requestRichCandidates: true)
            }
            self.segmentsManager.moveClauseFocus(count: count)
        case .selectNumberCandidateAndMoveToNextClause(let num):
            let row = self.host?.candidateRow(forNumberKey: num) ?? (num - 1)
            self.segmentsManager.requestSelectingRow(row)
            self.segmentsManager.moveClauseFocus(count: 1)
        case .cancelConversion:
            self.segmentsManager.cancelConversion()
        case .cancelConversionOrStopComposition:
            if self.segmentsManager.hasReturnedToReading {
                self.segmentsManager.stopComposition()
            } else {
                self.segmentsManager.cancelConversion()
            }
        case .removeLastMarkedText:
            self.segmentsManager.deleteBackwardFromCursorPosition()
            self.segmentsManager.requestResettingSelection()
        case .removeForwardMarkedText:
            self.segmentsManager.deleteForwardFromCursorPosition()
            self.segmentsManager.requestResettingSelection()
        case .selectPrevCandidate:
            self.segmentsManager.requestSelectingPrevCandidate()
        case .selectNextCandidate:
            self.segmentsManager.requestSelectingNextCandidate()
        case .selectNumberCandidate(let num):
            let row = self.host?.candidateRow(forNumberKey: num) ?? (num - 1)
            self.segmentsManager.requestSelectingRow(row)
            self.submitSelectedCandidate()
            self.segmentsManager.requestResettingSelection()
        case .submitHiraganaCandidate:
            self.submitFunctionCandidate(.six)
        case .submitKatakanaCandidate:
            self.submitFunctionCandidate(.seven)
        case .submitHankakuKatakanaCandidate:
            self.submitFunctionCandidate(.eight)
        case .submitFullWidthRomanCandidate:
            self.submitFunctionCandidate(.nine)
        case .submitHalfWidthRomanCandidate:
            self.submitFunctionCandidate(.ten)
        case .applyFunction(let function):
            if self.segmentsManager.isAlphabetWordInput {
                // Letters typed as a word on purpose (see `isAlphabetWordInput`) are committed in the form, as before
                self.submitFunctionCandidate(function)
            } else {
                self.segmentsManager.applyFunction(function, toWholeInput: self.inputState != .selecting)
            }
        case .stopComposition:
            self.segmentsManager.stopComposition()
        case .forgetMemory:
            self.segmentsManager.forgetMemory()
        case .selectInputLanguage(let language):
            self.switchInputLanguage(language)
        case .commitMarkedTextAndSelectInputLanguage(let language):
            self.commitMarkedText()
            self.switchInputLanguage(language)
        case .acceptPredictionCandidate:
            self.segmentsManager.acceptPredictionCandidate()
        case .requestContinuation:
            self.requestContinuation()
        case .commitMarkedTextAndRequestContinuation:
            self.commitMarkedText()
            self.requestContinuation()
        case .enterUnicodeInputMode, .appendToUnicodeInput, .removeLastUnicodeInput, .cancelUnicodeInput:
            // The state transition and the marked text update happen through the callback and the markedText redraw
            break
        case .submitUnicodeInput(let codePoint):
            if let scalar = UInt32(codePoint, radix: 16), let unicodeScalar = Unicode.Scalar(scalar) {
                self.host?.insertText(String(Character(unicodeScalar)))
            }
        case .submitSelectedCandidateAndEnterUnicodeInputMode:
            self.submitSelectedCandidate()
            // If text remains, commit it as hiragana
            if !self.segmentsManager.isEmpty {
                self.host?.insertText(self.segmentsManager.convertTarget)
                self.segmentsManager.stopComposition()
            }
        case .consume:
            break
        case .fallthrough:
            return false
        }

        switch callback {
        case .fallthrough:
            break
        case .transition(let inputState):
            if inputState == .none {
                self.switchInputLanguage(self.inputLanguage)
            }
            self.inputState = inputState
        case .basedOnBackspace(let ifIsEmpty, let ifIsNotEmpty), .basedOnSubmitCandidate(let ifIsEmpty, let ifIsNotEmpty):
            self.inputState = self.segmentsManager.isEmpty ? ifIsEmpty : ifIsNotEmpty
        case .basedOnRemainingInput(let ifIsEmpty, let ifIsNotEmpty):
            let inputState = self.segmentsManager.isEmpty ? ifIsEmpty : ifIsNotEmpty
            if inputState == .none {
                self.switchInputLanguage(self.inputLanguage)
            }
            self.inputState = inputState
        }

        self.host?.updateMarkedText(self.markedText)
        return true
    }
}

extension InputSession: SegmentManagerDelegate {
    public func getLeftSideContext(maxCount: Int) -> String? {
        self.host?.leftSideContext(maxCount: maxCount)
    }

    public func segmentsManagerDidUpdateDisplay(thoroughConversionShown: Bool) {
        guard self.inputState == .composing else {
            return
        }
        self.host?.updateMarkedText(self.markedText)
        if thoroughConversionShown {
            self.thoroughConversionShownAt = self.uptime()
        }
        self.commitLongInputHead()
        self.host?.conversionDidUpdate()
    }

    public func getRightSideContext(maxCount: Int) -> String? {
        self.host?.rightSideContext(maxCount: maxCount)
    }
}

extension Config.InputStyle.Value {
    /// Input method passed to the converter
    public var converterInputStyle: InputStyle {
        switch self {
        case .default:
            .mapped(id: .defaultRomanToKana)
        case .defaultAZIK:
            .mapped(id: .defaultAZIK)
        case .defaultKanaUS:
            .mapped(id: .defaultKanaUS)
        case .defaultKanaJIS:
            .mapped(id: .defaultKanaJIS)
        case .custom:
            if CustomInputTableStore.exists() {
                .mapped(id: .tableName(CustomInputTableStore.tableName))
            } else {
                .mapped(id: .defaultRomanToKana)
            }
        }
    }
}
