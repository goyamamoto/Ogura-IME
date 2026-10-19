import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

/// With the setting on, when the user types an uppercase letter at the start of input, the word stays in Latin letters
/// (same behavior as MS-IME and Google Japanese Input).
@MainActor
private func makeManager(uppercaseStartsAlphabetInput: Bool = true) -> SegmentsManager {
    SegmentsManager(
        kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
        applicationDirectoryURL: freshTestLearningDirectory(),
        personalizationDirectoryURL: nil,
        context: .init(useZenzai: false, liveConversionEnabled: true, uppercaseStartsAlphabetInput: uppercaseStartsAlphabetInput)
    )
}

private func japanesePieces(_ text: String) -> [InputPiece] {
    text.map { .key(intention: KeyMap.h2zMap($0), input: $0, modifiers: []) }
}

@MainActor
@Test func testUppercaseAtStartKeepsWordAsAlphabet() {
    let manager = makeManager()
    manager.insertAtCursorPosition(pieces: japanesePieces("A"), inputStyle: .roman2kana)
    #expect(manager.isAlphabetWordInput)
    for character in "pple" {
        manager.insertAtCursorPosition(pieces: japanesePieces(String(character)), inputStyle: .roman2kana)
    }
    #expect(manager.convertTarget == "Apple")
    manager.update(requestRichCandidates: false)
    if case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting) {
        #expect(candidates.first?.text == "Apple")
    } else {
        Issue.record("Expected candidates for the alphabet word")
    }
    #expect(manager.commitMarkedText(inputState: .composing) == "Apple")
    #expect(!manager.isAlphabetWordInput, "確定後は通常のかな入力に戻る")
}

@MainActor
@Test func testLowercaseAtStartStillConvertsToKana() {
    let manager = makeManager()
    for character in "apple" {
        manager.insertAtCursorPosition(pieces: japanesePieces(String(character)), inputStyle: .roman2kana)
    }
    #expect(!manager.isAlphabetWordInput)
    #expect(manager.convertTarget == "あっpぇ")
}

@MainActor
@Test func testUppercaseInMiddleOfWordDoesNotSwitch() {
    let manager = makeManager()
    manager.insertAtCursorPosition(pieces: japanesePieces("ni"), inputStyle: .roman2kana)
    manager.insertAtCursorPosition(pieces: japanesePieces("H"), inputStyle: .roman2kana)
    #expect(!manager.isAlphabetWordInput)
}

@MainActor
@Test func testAlphabetWordEndsWhenDeletedToEmpty() {
    let manager = makeManager()
    manager.insertAtCursorPosition(pieces: japanesePieces("A"), inputStyle: .roman2kana)
    manager.deleteBackwardFromCursorPosition()
    #expect(!manager.isAlphabetWordInput)
    manager.insertAtCursorPosition(pieces: japanesePieces("ka"), inputStyle: .roman2kana)
    #expect(manager.convertTarget == "か")
}

@MainActor
@Test func testUppercaseAtStartStartsLatinWordWhenSettingIsOff() {
    // The default: a capital starts a Latin word, and typing goes back to kana after it
    let manager = makeManager(uppercaseStartsAlphabetInput: false)
    for character in "Ogurahaiidesu" {
        manager.insertAtCursorPosition(pieces: japanesePieces(String(character)), inputStyle: .roman2kana)
    }
    #expect(!manager.isAlphabetWordInput)
    #expect(manager.getCurrentMarkedText(inputState: .composing).map(\.content).joined() == "Oguraはいいです")
}
