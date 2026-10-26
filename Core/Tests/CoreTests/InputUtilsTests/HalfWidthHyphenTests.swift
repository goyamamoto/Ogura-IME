@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A hyphen typed after a Latin word or a digit is -, not the long vowel mark ー, whether symbols are typed in half width
/// or not
@MainActor
private final class RecordingHost: InputSessionHost {
    var inserted: [String] = []
    var markedText = ""
    func insertText(_ text: String) { self.inserted.append(text) }
    func updateMarkedText(_ markedText: SegmentsManager.MarkedText) { self.markedText = markedText.map(\.content).joined() }
    func switchInputMode(_ language: InputLanguage) {}
    func candidateRow(forNumberKey number: Int) -> Int { number - 1 }
    func leftSideContext(maxCount: Int) -> String? { "" }
    func rightSideContext(maxCount: Int) -> String? { nil }
}

/// What typing `keys` and Enter commits, without Zenzai, with the rules telling Latin words
@MainActor
private func committed(_ keys: String, halfWidthSymbols: Bool, learned: Bool = false) -> String {
    let manager = SegmentsManager(
        kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
        applicationDirectoryURL: freshTestLearningDirectory(),
        personalizationDirectoryURL: nil,
        context: .init(
            useZenzai: false,
            liveConversionEnabled: true,
            learnedScriptIdentification: learned,
            scriptModelDirectoryURL: repository.appendingPathComponent("Ogura/Resources/ScriptModel", isDirectory: true)
        )
    )
    let session = InputSession(segmentsManager: manager, settingsProvider: {
        InputSession.Settings(liveConversionEnabled: true, keyBindingStyle: .msIME, inputStyle: .mapped(id: .defaultRomanToKana), typeHalfWidthSymbols: halfWidthSymbols)
    })
    let host = RecordingHost()
    session.host = host
    for character in keys {
        let text = String(character)
        _ = session.handle(KeyEventCore(modifierFlags: character.isUppercase ? [.shift] : [], characters: text, charactersIgnoringModifiers: text.lowercased(), keyCode: 0))
    }
    _ = session.handle(KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 0x24))
    return host.inserted.joined()
}

@MainActor
@Test("英単語や数字の後のハイフンは、記号を半角で入力する設定でなくても半角（UTF-8、COVID-19、3-2-1、iPhone-から、us-west-1）", arguments: [true, false])
func hyphenAfterLatinWordOrDigitIsHalfWidth(halfWidthSymbols: Bool) {
    #expect(committed("UTF-8", halfWidthSymbols: halfWidthSymbols) == "UTF-8")
    #expect(committed("COVID-19", halfWidthSymbols: halfWidthSymbols) == "COVID-19")
    #expect(committed("3-2-1", halfWidthSymbols: halfWidthSymbols) == "3-2-1")
    // After a word the identification layer tells as Latin (the model knows iPhone; the rules read it as 異Phoね)
    #expect(committed("iPhone-kara", halfWidthSymbols: halfWidthSymbols, learned: true) == "iPhone-から")
    #expect(committed("us-west-1nidepuroishita", halfWidthSymbols: halfWidthSymbols, learned: true).hasPrefix("us-west-1に"))
}

@MainActor
@Test("かなの後の - は長音のまま（コーヒー）", arguments: [true, false])
func hyphenAfterKanaIsTheLongVowelMark(halfWidthSymbols: Bool) {
    #expect(committed("ko-hi-wonomu", halfWidthSymbols: halfWidthSymbols).hasPrefix("コーヒー"))
}
