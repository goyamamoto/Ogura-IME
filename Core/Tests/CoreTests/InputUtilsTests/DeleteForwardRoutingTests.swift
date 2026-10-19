import Core
import Testing

/// Regression test for #355: during conversion, fn+Delete (keyCode 0x75) was passed through to the app, so the display and the internal state got out of sync.
private let forwardDeleteEvent = KeyEventCore(
    modifierFlags: [],
    characters: "\u{F728}",
    charactersIgnoringModifiers: "\u{F728}",
    keyCode: 0x75
)

@Test func testForwardDeleteKeyIsRecognizedAsDeleteForward() {
    for language in [InputLanguage.japanese, .english] {
        let action = UserAction.getUserAction(eventCore: forwardDeleteEvent, inputLanguage: language, typeBackSlash: false)
        guard case .deleteForward = action else {
            Issue.record("Expected keyCode 0x75 to be .deleteForward in \(language), got \(action)")
            return
        }
    }
}

@Test func testForwardDeleteFallsThroughWhenNotComposing() {
    let (action, callback) = InputState.none.event(
        eventCore: forwardDeleteEvent,
        userAction: .deleteForward,
        inputLanguage: .japanese,
        liveConversionEnabled: false
    )
    guard case .fallthrough = action, case .fallthrough = callback else {
        Issue.record("Expected forward delete in none state to fall through, got \(action), \(callback)")
        return
    }
}

@Test func testForwardDeleteIsHandledByIMEWhileComposing() {
    let (action, callback) = InputState.composing.event(
        eventCore: forwardDeleteEvent,
        userAction: .deleteForward,
        inputLanguage: .japanese,
        liveConversionEnabled: false
    )
    guard case .removeForwardMarkedText = action,
          case .basedOnBackspace(ifIsEmpty: .none, ifIsNotEmpty: .composing) = callback else {
        Issue.record("Expected forward delete in composing state to delete forward, got \(action), \(callback)")
        return
    }
}

@Test func testForwardDeleteIsConsumedInCandidateStates() {
    for state in [InputState.previewing, .selecting, .unicodeInput("")] {
        let (action, callback) = state.event(
            eventCore: forwardDeleteEvent,
            userAction: .deleteForward,
            inputLanguage: .japanese,
            liveConversionEnabled: false
        )
        guard case .consume = action, case .fallthrough = callback else {
            Issue.record("Expected forward delete to be consumed in \(state), got \(action), \(callback)")
            return
        }
    }
}
