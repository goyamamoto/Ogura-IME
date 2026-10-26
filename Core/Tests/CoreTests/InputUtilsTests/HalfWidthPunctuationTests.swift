@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A period or a comma between letters or digits is written in half width (Node.js, 1.1, 1,000, iPhone,iPad); at the end
/// of a sentence and next to kana they stay 。 and 、
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

/// What typing `keys` and Enter commits, without Zenzai, with the learned identification layer
@MainActor
private func committed(_ keys: String) -> String {
    let manager = SegmentsManager(
        kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
        applicationDirectoryURL: freshTestLearningDirectory(),
        personalizationDirectoryURL: nil,
        context: .init(
            useZenzai: false,
            liveConversionEnabled: true,
            learnedScriptIdentification: true,
            scriptModelDirectoryURL: repository.appendingPathComponent("Ogura/Resources/ScriptModel", isDirectory: true)
        )
    )
    let session = InputSession(segmentsManager: manager, settingsProvider: {
        InputSession.Settings(liveConversionEnabled: true, keyBindingStyle: .msIME, inputStyle: .mapped(id: .defaultRomanToKana), typeHalfWidthSymbols: true)
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
@Test("数字や英字の間のピリオドは半角（1.1、3.14、v2.0.3、index.html）")
func periodBetweenLettersOrDigitsIsHalfWidth() {
    #expect(committed("ba-jon1.1") == "バージョン1.1")
    #expect(committed("3.14") == "3.14")
    #expect(committed("v2.0.3") == "v2.0.3")
    // The word after the dot is written as typed, not as the lexicon spells it (HTML)
    #expect(committed("index.htmlwohiraku").hasPrefix("index.html"))
}

@MainActor
@Test("英字や数字の間のカンマは半角（1,000、3,4、iPhone,iPad）。かなの隣は読点のまま")
func commaBetweenLettersOrDigitsIsHalfWidth() {
    #expect(committed("1,000en").hasPrefix("1,000"))
    #expect(committed("1,000,000") == "1,000,000")
    #expect(committed("3,4ko").hasPrefix("3,4"))
    #expect(committed("iPhone,iPad") == "iPhone,iPad")
    #expect(committed("kyouha,iitenki").contains("、"))
}

@MainActor
@Test("文末のピリオドは句点のまま（会議はzoom。、バージョン1。）")
func periodAtTheEndIsTheJapaneseFullStop() {
    #expect(committed("kaigihazoom.").hasSuffix("zoom。"))
    #expect(committed("ba-jon1.").hasSuffix("1。"))
    #expect(committed("1.kyouha").hasPrefix("1。"))
}

@Test("ピリオドとカンマを半角にする位置")
func halfWidthPunctuationPositions() throws {
    func marks(_ keys: String, latin: [Range<Int>] = []) throws -> [String] {
        var text = ComposingText()
        for key in keys {
            text.insertAtCursorPosition([.init(piece: .key(intention: nil, input: key, modifiers: []), inputStyle: .mapped(id: .defaultRomanToKana))])
        }
        let input = try #require(TypedInput(text))
        let words = latin.map { LatinInputGuess.Span(word: String(Array(keys)[$0]), keys: $0) }
        return SegmentsManager.halfWidthPunctuation(in: input, latinWords: words).map { "\($0.index)\($0.mark)" }
    }
    #expect(try marks("Node.js", latin: [0 ..< 4, 5 ..< 7]) == ["4."])
    #expect(try marks("Node.", latin: [0 ..< 4]).isEmpty)
    #expect(try marks("Node.wo", latin: [0 ..< 4]).isEmpty)
    #expect(try marks("12,345") == ["2,"])
    #expect(try marks("12,34") == ["2,"])
    #expect(try marks("iPhone,iPad", latin: [0 ..< 6, 7 ..< 11]) == ["6,"])
    #expect(try marks("iPhone,wo", latin: [0 ..< 6]).isEmpty)
}

@MainActor
@Test("ドットを含む名前は一つの英単語（Node.js、README.md、Chart.js）。後ろのローマ字と混ざらない")
func dottedNamesAreOneWord() {
    #expect(committed("Node.jswotsukaimasu").hasPrefix("Node.js"))
    #expect(committed("README.mdwoyomu").hasPrefix("README.md"))
    #expect(committed("Chart.jswotsukau").hasPrefix("Chart.js"))
    #expect(committed("korehaREADME.mddesu").contains("README.md"))
}
