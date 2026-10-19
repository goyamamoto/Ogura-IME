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

    public init(
        segmentsManager: SegmentsManager,
        settingsProvider: @escaping @MainActor () -> Settings = { .current },
        now: @escaping @MainActor () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.segmentsManager = segmentsManager
        self.settingsProvider = settingsProvider
        self.now = now
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
        self.segmentsManager.deactivate(flushLearningData: false)
        self.inputState = .none
    }

    // MARK: - Events from the host

    /// Handle a key event. Returns true if the IME consumed it, false if it should go to the app.
    public func handle(_ event: KeyEventCore) -> Bool {
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
            _ = self.handleClientAction(.submitHalfWidthRomanCandidate, callback: .transition(.none), settings: settings)
            self.switchInputLanguage(.english)
            return true
        }

        let (clientAction, callback) = self.inputState.event(
            eventCore: event,
            userAction: userAction,
            inputLanguage: self.inputLanguage,
            liveConversionEnabled: settings.liveConversionEnabled,
            keyBindingStyle: settings.keyBindingStyle
        )
        return self.handleClientAction(clientAction, callback: callback, settings: settings)
    }

    /// Called when the OS asks to commit the marked text (a click or a focus change)
    public func commitComposition() {
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
        switch language {
        case .english:
            // Switch to English input and keep the marked text
            if self.inputLanguage == .japanese {
                self.inputLanguage = .english
                self.segmentsManager.stopJapaneseInput()
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

    /// A candidate was committed in the candidate window (by a click, for example)
    public func submitCandidateFromWindow() {
        self.submitSelectedCandidate()
        self.inputState = self.segmentsManager.isEmpty ? .none : .previewing
        self.host?.updateMarkedText(self.markedText)
    }

    /// The selected row in the candidate window changed
    public func selectCandidateRow(_ row: Int) {
        self.segmentsManager.requestSelectingRow(row)
        self.inputState = .selecting
        self.host?.updateMarkedText(self.markedText)
    }

    // MARK: - Internal processing

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
        let cleanLeftSideContext = self.segmentsManager.getCleanLeftSideContext(maxCount: 30)
        self.host?.insertText(candidate.text)
        self.segmentsManager.prefixCandidateCommited(candidate, leftSideContext: cleanLeftSideContext ?? "")
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
            self.submitSelectedCandidate()
            if !self.segmentsManager.isEmpty {
                // Commit the remaining segments with their top candidates
                let text = self.segmentsManager.commitMarkedText(inputState: .previewing)
                self.host?.insertText(text)
            }
        case .cancelConversion:
            self.segmentsManager.cancelConversion()
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
            self.submitCandidate(self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) {
                $0.toHiragana()
            })
        case .submitKatakanaCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) {
                $0.toKatakana()
            })
        case .submitHankakuKatakanaCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) {
                $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false)!
            })
        case .submitFullWidthRomanCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRomanCandidate(inputState: self.inputState) {
                $0.applyingTransform(.fullwidthToHalfwidth, reverse: true)!
            })
        case .submitHalfWidthRomanCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRomanCandidate(inputState: self.inputState) {
                $0.applyingTransform(.fullwidthToHalfwidth, reverse: false)!
            })
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
        }

        self.host?.updateMarkedText(self.markedText)
        return true
    }
}

extension InputSession: SegmentManagerDelegate {
    public func getLeftSideContext(maxCount: Int) -> String? {
        self.host?.leftSideContext(maxCount: maxCount)
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
