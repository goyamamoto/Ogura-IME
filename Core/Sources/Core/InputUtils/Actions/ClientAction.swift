import KanaKanjiConverterModule

public enum ClientAction {
    case `consume`
    case `fallthrough`
    case showCandidateWindow
    case hideCandidateWindow
    case appendToMarkedText(String)
    case appendPieceToMarkedText([InputPiece])

    /// Command that inserts text without going through marked text. Only valid when InputState is none
    case insertWithoutMarkedText(String)
    case removeLastMarkedText
    /// Command that deletes one character of marked text to the right of the cursor (forward)
    case removeForwardMarkedText

    case commitMarkedText
    /// Commit the selected candidate, and commit the remaining segments with their top candidates (Enter in MS-IME)
    case commitAllCandidates
    /// Cancel the conversion and go back to typing hiragana (BackSpace after conversion in MS-IME)
    case cancelConversion
    /// Command that edits the selection range with Shift+Left/Right
    case editSegment(Int)

    /// Command that enters previewing
    case enterFirstCandidatePreviewMode

    /// Command that enters `.selecting` when Space is pressed
    case enterCandidateSelectionMode
    case submitSelectedCandidate
    case selectNextCandidate
    case selectPrevCandidate
    case selectNumberCandidate(Int)

    case selectInputLanguage(InputLanguage)
    case commitMarkedTextAndSelectInputLanguage(InputLanguage)

    /// Commit the marked text, then type more input
    case commitMarkedTextAndAppendToMarkedText(String)
    case commitMarkedTextAndAppendPieceToMarkedText([InputPiece])

    /// Reset learning
    case forgetMemory

    // Conversion with Fn keys
    case submitKatakanaCandidate
    case submitHiraganaCandidate
    case submitHankakuKatakanaCandidate
    case submitFullWidthRomanCandidate
    case submitHalfWidthRomanCandidate

    // Accept a prediction candidate
    case acceptPredictionCandidate

    // Unicode Input (Shift+Ctrl+U)
    case enterUnicodeInputMode
    case appendToUnicodeInput(String)
    case removeLastUnicodeInput
    case submitUnicodeInput(String)
    case cancelUnicodeInput
    case submitSelectedCandidateAndEnterUnicodeInputMode

    case stopComposition

    /// Ask the on-device model to continue the text to the left of the cursor
    case requestContinuation
    /// Commit the marked text first, then continue writing
    case commitMarkedTextAndRequestContinuation
}

public enum ClientActionCallback {
    case `fallthrough`
    case transition(InputState)
    ///
    case basedOnBackspace(ifIsEmpty: InputState, ifIsNotEmpty: InputState)
    case basedOnSubmitCandidate(ifIsEmpty: InputState, ifIsNotEmpty: InputState)
}
