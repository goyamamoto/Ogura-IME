@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// What the tagger reads about the dictionary's likeliest word for the kana of the keys in `range` of `keys` typed in
/// romaji (see `ScriptTaggerFeatures.readings`)
@MainActor
private func reading(_ keys: String, _ range: Range<Int>, analyzer: JapaneseAnalyzer) throws -> UInt8 {
    var text = ComposingText()
    for key in keys {
        text.insertAtCursorPosition([.init(piece: .key(intention: KeyMap.h2zMap(key), input: key, modifiers: []), inputStyle: .mapped(id: .defaultRomanToKana))])
    }
    let input = try #require(TypedInput(text))
    let lexicon = try ScriptLexicon(contentsOf: repository.appendingPathComponent("Ogura/Resources/ScriptModel/lexicon.tsv"))
    let words = ScriptTaggerFeatures.words(of: input.keys, models: nil, lexicon: lexicon)
    return ScriptTaggerFeatures.readings(of: input, words: words, analyzer: analyzer)[range.lowerBound][range.count - 1]
}

@MainActor
@Test("英単語の綴りをかなで読んだ語がどれだけよく使われるかを読む（token の都県は珍しく、sake の酒はよく使う）")
func readingWordsTellHowCommonTheJapaneseWordIs() throws {
    let analyzer = JapaneseAnalyzer(converter: KanaKanjiConverter.withDefaultDictionary())
    let token = try reading("tokenwookuttekudasai", 0 ..< 5, analyzer: analyzer)
    let sake = try reading("sakewonomu", 0 ..< 4, analyzer: analyzer)
    // Both have a noun (都県, 酒), the rarer the larger
    #expect(token & 31 != 0 && sake & 31 != 0, "\(token) \(sake)")
    #expect(token & 31 > sake & 31, "\(token) \(sake)")
    // made reads as まで, a particle
    #expect(try reading("kokomadekite", 4 ..< 8, analyzer: analyzer) & 32 != 0)
    // Words typed with a capital are not looked up: the capital tells already
    #expect(try reading("Tokenwookuttekudasai", 0 ..< 5, analyzer: analyzer) == 0)
}

/// The input of `keys` typed in romaji
private func typedInput(_ keys: String) throws -> TypedInput {
    var text = ComposingText()
    for key in keys {
        text.insertAtCursorPosition([.init(piece: .key(intention: KeyMap.h2zMap(key), input: key, modifiers: []), inputStyle: .mapped(id: .defaultRomanToKana))])
    }
    return try #require(TypedInput(text))
}

@Test("ローマ字が読み残す文字を見つける（ko-hi-map-1 の p）。打っている途中の最後の文字は数えない")
func strandedLettersAreTheOnesRomajiLeavesUnread() throws {
    let stranded = ScriptTaggerFeatures.stranded(of: try typedInput("ko-hi-map-1"))
    #expect(stranded.indices.filter { stranded[$0] } == [8])
    #expect(!ScriptTaggerFeatures.stranded(of: try typedInput("ko-hi-map")).contains(true))
    #expect(!ScriptTaggerFeatures.stranded(of: try typedInput("tokenwookuttekudasai")).contains(true))
}

@Test("英単語のあとのキーは、それだけでローマ字として読む（Machakaku の hakaku は はかく。入力全体では まちゃかく と読むので途中から切れない）")
func keysAfterAWordReadAsRomajiOnTheirOwn() throws {
    let input = try typedInput("Machakakuchou")
    #expect(input.kana(of: 3 ..< 9) == nil)
    #expect(input.readsAsKana(3 ..< 9))
    #expect(try typedInput("sign-inshite").readsAsKana(7 ..< 10))
    // A consonant left over is not kana; a last n is the ん it becomes
    #expect(!input.readsAsKana(3 ..< 6))
    #expect(try typedInput("Winnoken").readsAsKana(3 ..< 8))
}
