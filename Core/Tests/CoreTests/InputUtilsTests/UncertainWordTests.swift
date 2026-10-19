@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

/// Words the identification layer leaves to the converter (`ScriptSegmentation.uncertainWords`), words it is sure of, and
/// Latin letters the converter writes for kana, through Zenzai. These tests run when the Zenzai weights are in the
/// repository (not an LFS pointer).
private let resourcesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Ogura/Resources/gguf", isDirectory: true)
private let hasZenzaiWeights = ((try? FileManager.default.attributesOfItem(
    atPath: resourcesDirectory.appendingPathComponent("ggml-model-Q5_K_M.gguf").path
)[.size] as? Int) ?? 0) > 1_000_000

/// An identification layer with a fixed answer
private struct FixedScriptIdentifier: ScriptIdentifier {
    var segmentation: ScriptSegmentation
    func segment(_ input: TypedInput) -> ScriptSegmentation {
        self.segmentation
    }
}

/// An identification layer that grows surer of a word typed first once more follows (token once を送って follows):
/// unlikely while fewer than `sureFrom` keys are typed, `sure` after
private struct GrowingScriptIdentifier: ScriptIdentifier {
    var word = "token"
    var sureFrom = 12
    var sure = 0.5
    func segment(_ input: TypedInput) -> ScriptSegmentation {
        guard input.keys.count >= self.word.count else {
            return ScriptSegmentation()
        }
        let probability = input.keys.count < self.sureFrom ? 0.08 : self.sure
        return ScriptSegmentation(uncertainWords: [.init(word: self.word, spelling: nil, keys: 0 ..< self.word.count, probability: probability, romajiProbability: 1 - probability)])
    }
}

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

/// A session converting with Zenzai (unless not `zenzai`) and live conversion; the identification layer is `identifier`
/// or answers `segmentation` when given, else it is the bundled model, or the rules when not `learned`
@MainActor
private func makeSession(segmentation: ScriptSegmentation? = nil, identifier: (any ScriptIdentifier)? = nil, learned: Bool = true, zenzai: Bool = true) -> (InputSession, RecordingHost) {
    let manager = SegmentsManager(
        kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
        applicationDirectoryURL: freshTestLearningDirectory(),
        personalizationDirectoryURL: nil,
        context: .init(
            useZenzai: zenzai,
            resourcesDirectoryURL: resourcesDirectory,
            liveConversionEnabled: true,
            learnedScriptIdentification: learned,
            scriptModelDirectoryURL: resourcesDirectory.deletingLastPathComponent().appendingPathComponent("ScriptModel", isDirectory: true)
        )
    )
    if let identifier {
        manager.scriptIdentifierOverride = identifier
    } else if let segmentation {
        manager.scriptIdentifierOverride = FixedScriptIdentifier(segmentation: segmentation)
    }
    let session = InputSession(segmentsManager: manager, settingsProvider: {
        InputSession.Settings(liveConversionEnabled: true, keyBindingStyle: .msIME, inputStyle: .mapped(id: .defaultRomanToKana))
    })
    let host = RecordingHost()
    session.host = host
    return (session, host)
}

@MainActor
private func type(_ keys: String, into session: InputSession) {
    for character in keys {
        let text = String(character)
        _ = session.handle(KeyEventCore(modifierFlags: character.isUppercase ? [.shift] : [], characters: text, charactersIgnoringModifiers: text.lowercased(), keyCode: 0))
    }
}

private let enter = KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 0x24)

@MainActor
@Test("変換エンジンが英字の方を選ぶ迷う語は、Zenzai を通しても英字のまま（mode）", .enabled(if: hasZenzaiWeights))
func uncertainWordWrittenByConverterSurvivesZenzai() {
    // mode at even odds: the letters cost 12, less than any word for もで, and もでが変わる is no likelier to Zenzai
    let mode = ScriptSegmentation.UncertainWord(word: "mode", spelling: nil, keys: 0 ..< 4, probability: 0.5, romajiProbability: 0.5)
    let (session, host) = makeSession(segmentation: ScriptSegmentation(uncertainWords: [mode]))
    type("modegakawaru", into: session)
    #expect(host.markedText.hasPrefix("mode"), "\(host.markedText)")
    #expect(session.handle(enter))
    #expect(host.inserted.joined().hasPrefix("mode"), "\(host.inserted)")
}

@MainActor
@Test("辞書の語がよく当たる迷う語は日本語のまま（sake は 酒）", .enabled(if: hasZenzaiWeights))
func uncertainWordReadWellAsJapaneseStaysJapanese() {
    let sake = ScriptSegmentation.UncertainWord(word: "sake", spelling: nil, keys: 0 ..< 4, probability: 0.5, romajiProbability: 0.5)
    let (session, host) = makeSession(segmentation: ScriptSegmentation(uncertainWords: [sake]))
    type("sakehasakedesu", into: session)
    #expect(!host.markedText.hasPrefix("sake"), "\(host.markedText)")
    #expect(session.handle(enter))
    #expect(!host.inserted.joined().contains("sake"), "\(host.inserted)")
}

@MainActor
@Test("学習版が確信する英単語は、Zenzai を通しても英字のまま（hello）", .enabled(if: hasZenzaiWeights))
func certainLatinWordSurvivesZenzai() {
    // hello is Latin for sure, though the model spreads the word's end over hello and hellose
    let (session, host) = makeSession()
    type("hellosekai", into: session)
    #expect(session.handle(enter))
    #expect(host.inserted.joined() == "hello世界", "\(host.inserted)")
}

@MainActor
@Test("Zenzai が打っていない英字で書いた変換を退けたら、かな書きではなく変換エンジンの変換に戻る（no-to は note ではなく ノート）", .enabled(if: hasZenzaiWeights))
func untypedLettersFallBackToTheConverterNotToKana() {
    // Zenzai writes note for no-to; the candidates it leaves are the katakana and hiragana readings
    let (session, host) = makeSession()
    type("onrainkaigideno-towokyouyuushimasu", into: session)
    #expect(session.handle(enter))
    let inserted = host.inserted.joined()
    #expect(inserted == "オンライン会議でノートを共有します", "\(inserted)")
}

@MainActor
@Test("辞書が英字で書くカタカナ語は読みのまま書き、文全体をカタカナにしない（uindouzu は Windows ではなく ウインドウズ）", .enabled(if: hasZenzaiWeights))
func lettersTheDictionaryWritesForKanaAreWrittenAsTheReading() {
    for learned in [true, false] {
        let (session, host) = makeSession(learned: learned)
        type("tatoebawindowstokakebauindouzuninaranaidesu", into: session)
        #expect(session.handle(enter))
        #expect(host.inserted.joined() == "例えばwindowsと書けばウインドウズにならないです", "\(learned ? "learned" : "rules"): \(host.inserted)")
    }
}

@MainActor
@Test("迷う語が打つうちに確からしくなったら、変換エンジンは新しい値で決め直す（Zenzai あり）", .enabled(if: hasZenzaiWeights))
func uncertainWordIsDecidedByItsLatestPriceWithZenzai() {
    // The converter keeps the nodes of the input it has converted: with the price name had when なめ was typed, a word
    // for なめ would stay. Not token: Zenzai keeps とけんを送って Japanese, as it is when in doubt
    let (session, host) = makeSession(identifier: GrowingScriptIdentifier(word: "name", sureFrom: 9, sure: 0.9))
    type("namewokaeru", into: session)
    #expect(session.handle(enter))
    #expect(host.inserted.joined() == "nameを変える")
}

@MainActor
@Test("迷う語が打つうちに確からしくなったら、変換エンジンは新しい値で決め直す（Zenzai なし）")
func uncertainWordIsDecidedByItsLatestPriceWithoutZenzai() {
    let (session, host) = makeSession(identifier: GrowingScriptIdentifier(), zenzai: false)
    type("tokenwookuttekudasai", into: session)
    #expect(session.handle(enter))
    #expect(host.inserted.joined() == "tokenを送ってください")
}

/// An identification layer that finds one Latin word once its keys are typed
private struct OneLatinWord: ScriptIdentifier {
    var word: LatinInputGuess.Span
    func segment(_ input: TypedInput) -> ScriptSegmentation {
        input.keys.count >= self.word.keys.upperBound ? ScriptSegmentation(latinWords: [self.word]) : ScriptSegmentation()
    }
}

/// An identification layer that reads one Latin word typed with a capital once its keys are typed, and finds it may end
/// earlier (see `ScriptSegmentation.shorterWords`)
private struct OneCapitalizedWord: ScriptIdentifier {
    var word: LatinInputGuess.Span
    var shorter: LatinInputGuess.Span
    func segment(_ input: TypedInput) -> ScriptSegmentation {
        guard input.keys.count >= self.word.keys.upperBound else {
            return ScriptSegmentation()
        }
        return ScriptSegmentation(latinWords: [self.word], shorterWords: [.init(word: self.word.keys, shorter: self.shorter, probability: 0.05)])
    }
}

@MainActor
@Test("大文字から打った語は、短く終わった残りを日本語に読む方が自然ならそこで終わる（Winの側）。自然でなければ長いまま（Shinagawa）", .enabled(if: hasZenzaiWeights))
func capitalizedWordEndsWhereJapaneseIsNatural() {
    let (session, host) = makeSession(identifier: OneCapitalizedWord(word: .init(word: "Winnogawa", keys: 8 ..< 17), shorter: .init(word: "Win", keys: 8 ..< 11)))
    type("suittihaWinnogawaniarimasu", into: session)
    #expect(session.handle(enter))
    #expect(host.inserted.joined() == "スイッチはWinの側にあります")
    // Space offers the word as the layer read it, in the clause it starts
    let win = OneCapitalizedWord(word: .init(word: "Winnogawa", keys: 0 ..< 9), shorter: .init(word: "Win", keys: 0 ..< 3))
    let candidates = candidatesAfterSpace("Winnogawaniarimasu", identifier: win)
    #expect(candidates.first?.hasPrefix("Winの") == true, "\(candidates)")
    #expect(candidates.prefix(3).contains { $0.hasPrefix("Winnogawa") }, "\(candidates)")

    let shinagawa = OneCapitalizedWord(word: .init(word: "Shinagawa", keys: 0 ..< 9), shorter: .init(word: "Shinaga", keys: 0 ..< 7))
    let (longer, longerHost) = makeSession(identifier: shinagawa)
    type("Shinagawaniikimasu", into: longer)
    #expect(longer.handle(enter))
    #expect(longerHost.inserted.joined() == "Shinagawaに行きます")
}

@MainActor
@Test("英字にする小文字の語でも、日本語の読みがずっと自然なら日本語のまま（峰に登る）", .enabled(if: hasZenzaiWeights))
func naturalJapaneseReadingStaysJapanese() {
    let (session, host) = makeSession(identifier: OneLatinWord(word: .init(word: "mine", keys: 0 ..< 4)))
    type("mineninoboru", into: session)
    #expect(session.handle(enter))
    #expect(host.inserted.joined() == "峰に登る")
}

@MainActor
@Test("日本語の読みが不自然なら英字のまま（ドアをopenして）", .enabled(if: hasZenzaiWeights))
func unnaturalJapaneseReadingLeavesTheLatinWord() {
    let (session, host) = makeSession(identifier: OneLatinWord(word: .init(word: "open", keys: 5 ..< 9)))
    type("doawoopenshite", into: session)
    #expect(session.handle(enter))
    #expect(host.inserted.joined() == "ドアをopenして")
}

/// The texts of the candidates Space shows for `keys`
@MainActor
private func candidatesAfterSpace(_ keys: String, identifier: any ScriptIdentifier) -> [String] {
    let (session, _) = makeSession(identifier: identifier)
    type(keys, into: session)
    _ = session.handle(KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49))
    guard case .selecting(let candidates, _) = session.segmentsManager.getCurrentCandidateWindow(inputState: session.inputState) else {
        return []
    }
    return candidates.map(\.text)
}

@MainActor
@Test("迷った語は、Space で反対の読みも候補に出る（英字にした語は日本語、日本語にした語は英字）", .enabled(if: hasZenzaiWeights))
func spaceOffersTheOtherReading() {
    // Kept Latin: the first clause read as romaji comes second
    let open = candidatesAfterSpace("doawoopenshite", identifier: OneLatinWord(word: .init(word: "open", keys: 5 ..< 9)))
    #expect(open.prefix(3).contains { $0.hasPrefix("ドアを") && $0 != "ドアを" && !$0.contains("open") }, "\(open)")
    // Kept Japanese by Zenzai: the word as typed comes second
    let mine = candidatesAfterSpace("mineninoboru", identifier: OneLatinWord(word: .init(word: "mine", keys: 0 ..< 4)))
    #expect(!(mine.first ?? "").contains("mine"), "\(mine)")
    #expect(mine.dropFirst().first?.hasPrefix("mine") == true, "\(mine)")
}

/// An identification layer that reads the keys of a word as Japanese, and finds they may be that Latin word once keys
/// follow it (see `ScriptSegmentation.possibleWords`)
private struct OnePossibleWord: ScriptIdentifier {
    var word: LatinInputGuess.Span
    func segment(_ input: TypedInput) -> ScriptSegmentation {
        guard input.keys.count > self.word.keys.upperBound else {
            return ScriptSegmentation()
        }
        return ScriptSegmentation(possibleWords: [.init(word: self.word, probability: 0.01)])
    }
}

@MainActor
@Test("日本語に読んだ語でも、日本語の読みが不自然で英単語の方がずっと自然なら英字にする（nodeを起動する）。自然なら日本語のまま（たけを切る）", .enabled(if: hasZenzaiWeights))
func unnaturalJapaneseReadingBecomesTheLatinWord() {
    let (session, host) = makeSession(identifier: OnePossibleWord(word: .init(word: "node", keys: 0 ..< 4)))
    type("nodewokidousuru", into: session)
    #expect(session.handle(enter))
    #expect(host.inserted.joined() == "nodeを起動する")
    let (japanese, japaneseHost) = makeSession(identifier: OnePossibleWord(word: .init(word: "take", keys: 0 ..< 4)))
    type("takewokiru", into: japanese)
    #expect(japanese.handle(enter))
    #expect(!japaneseHost.inserted.joined().contains("take") && japaneseHost.inserted.joined().hasSuffix("を切る"), "\(japaneseHost.inserted)")
}

@MainActor
@Test("迷う語を変換エンジンが日本語にしても、日本語の読みが自然とまでは言えなければ Space で英字も候補に出る（も出が変わる の次に modeが変わる）", .enabled(if: hasZenzaiWeights))
func spaceOffersLettersForUncertainJapanese() {
    let mode = ScriptSegmentation.UncertainWord(word: "mode", spelling: nil, keys: 0 ..< 4, probability: 0.15, romajiProbability: 0.85)
    let candidates = candidatesAfterSpace("modegakawaru", identifier: FixedScriptIdentifier(segmentation: ScriptSegmentation(uncertainWords: [mode])))
    #expect(candidates.prefix(2).contains { $0.hasPrefix("mode") }, "\(candidates)")
}

/// An identification layer that leaves one word to the converter once its keys are typed
private struct OneUncertainWord: ScriptIdentifier {
    var word: String
    var keys: Range<Int>
    var probability: Double
    func segment(_ input: TypedInput) -> ScriptSegmentation {
        guard input.keys.count >= self.keys.upperBound else {
            return ScriptSegmentation()
        }
        return ScriptSegmentation(uncertainWords: [.init(word: self.word, spelling: nil, keys: self.keys, probability: self.probability, romajiProbability: 1 - self.probability)])
    }
}

@MainActor
@Test("打っている途中でも、日本語の読みが自然な語は英字で見せない（高い峰にn の mine、迷う語の 山の峰 の mine）", .enabled(if: hasZenzaiWeights))
func naturalJapaneseIsNotShownAsLettersWhileTyping() {
    // A consonant not read yet after the word reads like more of a Latin word: タカイmineニn
    let (session, host) = makeSession(identifier: OneLatinWord(word: .init(word: "mine", keys: 5 ..< 9)))
    for key in "takaimineninoboru" {
        type(String(key), into: session)
        #expect(!host.markedText.contains("mine"), "\(host.markedText)")
    }
    // Zenzai does not write a word the converter left as kana from its temporary entry
    let (uncertain, uncertainHost) = makeSession(identifier: OneUncertainWord(word: "mine", keys: 6 ..< 10, probability: 0.1))
    for key in "yamanominegamieru" {
        type(String(key), into: uncertain)
        #expect(!uncertainHost.markedText.contains("mine"), "\(uncertainHost.markedText)")
    }
}

/// An identification layer that answers `segmentation` once `from` keys are typed, and nothing before
private struct SegmentationFrom: ScriptIdentifier {
    var from: Int
    var segmentation: ScriptSegmentation
    func segment(_ input: TypedInput) -> ScriptSegmentation {
        input.keys.count >= self.from ? self.segmentation : ScriptSegmentation()
    }
}

@MainActor
@Test("入力の終わりで最後の子音がまだ読めていない語も、英単語として知っていれば読めたところまでで比べて英字にする（今日の会議はzoom）", .enabled(if: hasZenzaiWeights))
func latinWordAtTheEndWithAnUnreadConsonantIsChecked() {
    let zoom = ScriptSegmentation(possibleWords: [.init(word: .init(word: "zoom", keys: 13 ..< 17), probability: 0.3)])
    let (session, host) = makeSession(identifier: SegmentationFrom(from: 17, segmentation: zoom))
    type("kyounokaigihazoom", into: session)
    #expect(host.markedText == "今日の会議はzoom", "\(host.markedText)")
    #expect(session.handle(enter))
    #expect(host.inserted.joined() == "今日の会議はzoom")
}

@MainActor
@Test("英単語の終わりがかなの途中にあっても、そのかなの終わりまで読んで日本語がずっと自然なら日本語にする（母の手料理、すっぽかした）", .enabled(if: hasZenzaiWeights))
func latinWordEndingInsideAKanaIsChecked() {
    // The model read noter, whose r goes with the yo after it (のてりょ), and sup, whose p doubles the p after it (すっぽ)
    let noter = ScriptSegmentation(latinWords: [.init(word: "noter", keys: 4 ..< 9)])
    let (session, host) = makeSession(identifier: SegmentationFrom(from: 11, segmentation: noter))
    type("hahanoteryouriha,nandemoumakatta.", into: session)
    #expect(session.handle(enter))
    #expect(host.inserted.joined().contains("手料理"), "\(host.inserted.joined())")
    #expect(!host.inserted.joined().contains { $0.isASCII && $0.isLetter }, "\(host.inserted.joined())")

    let sup = ScriptSegmentation(latinWords: [.init(word: "sup", keys: 10 ..< 13)])
    let (supSession, supHost) = makeSession(identifier: SegmentationFrom(from: 15, segmentation: sup))
    type("yakusokuwosuppokashitakotowoayamatta.", into: supSession)
    #expect(supSession.handle(enter))
    #expect(!supHost.inserted.joined().contains { $0.isASCII && $0.isLetter }, "\(supHost.inserted.joined())")
}

@MainActor
@Test("ハイフンを含む語も、日本語の読みがずっと自然なら日本語のまま（えーとねどうですか）", .enabled(if: hasZenzaiWeights))
func hyphenatedLatinWordIsCheckedAgainstJapanese() {
    let (session, host) = makeSession(identifier: OneLatinWord(word: .init(word: "e-tone", keys: 0 ..< 6)))
    type("e-tonedoudesuka", into: session)
    #expect(session.handle(enter))
    #expect(host.inserted.joined() == "えーとねどうですか")
}

@MainActor
@Test("大文字をローマ字と読んだ語でも、その大文字から始まる英単語を知っていれば変換エンジンに任せ、変換エンジンが英字を選べば英字にする（Tokyo都に住む）", .enabled(if: hasZenzaiWeights))
func capitalReadAsRomajiIsLeftToTheConverter() {
    let tokyo = ScriptSegmentation(
        romajiCapitals: [0],
        uncertainWords: [.init(word: "Tokyo", spelling: nil, keys: 0 ..< 5, probability: 0.46, romajiProbability: 0.07)]
    )
    let (session, host) = makeSession(identifier: SegmentationFrom(from: 13, segmentation: tokyo))
    type("Tokyotonisumu", into: session)
    #expect(session.handle(enter))
    #expect(host.inserted.joined().hasPrefix("Tokyo") && host.inserted.joined().hasSuffix("に住む"), "\(host.inserted)")
}

@MainActor
@Test("英単語の頭の n が前のかなの ん なら、ん と英単語に分ける（作品mapを開く）", .enabled(if: hasZenzaiWeights))
func leadingNOfALatinWordCanCloseTheKanaBefore() {
    let nmap = ScriptSegmentation(
        latinWords: [.init(word: "nmap", keys: 6 ..< 10)],
        shorterWords: [.init(word: 6 ..< 10, shorter: .init(word: "map", keys: 7 ..< 10), probability: 0.3)]
    )
    let (session, host) = makeSession(identifier: SegmentationFrom(from: 10, segmentation: nmap))
    type("sakuhinmapwohiraku", into: session)
    #expect(session.handle(enter))
    #expect(host.inserted.joined() == "作品mapを開く")
}
@MainActor
@Test("大文字から打った語が後ろのかなを取り込んでも、短い語で切った方が少しでも自然ならそこで終わる（Web上のKeynote）", .enabled(if: hasZenzaiWeights))
func shorterWordWinsBySmallMargin() {
    // Zenzai finds Web上の likelier than Webueの by about 1.5 after 共同作業をするには、
    let webue = ScriptSegmentation(
        latinWords: [.init(word: "Webue", keys: 24 ..< 29), .init(word: "Keynote", keys: 31 ..< 38)],
        shorterWords: [.init(word: 24 ..< 29, shorter: .init(word: "Web", keys: 24 ..< 27), probability: 0.39)]
    )
    let (session, host) = makeSession(identifier: SegmentationFrom(from: 38, segmentation: webue))
    type("kyoudousagyouwosuruniha,WebuenoKeynotewotsukau", into: session)
    #expect(session.handle(enter))
    #expect(host.inserted.joined() == "共同作業をするには、Web上のKeynoteを使う")
}

@MainActor
@Test("語をもっと長く読む区切り方が辞書にある語で、Zenzai がそちらをはっきり自然と見れば、語はそこまで続く（Finderウインドウ）", .enabled(if: hasZenzaiWeights))
func longerWordWinsWhenClearlyLikelier() {
    // The model read Find and left eruindou as kana (得る引導) while finding Finder about as likely
    let finder = ScriptSegmentation(
        latinWords: [.init(word: "Find", keys: 30 ..< 34)],
        longerWords: [.init(word: 30 ..< 34, longer: .init(word: "Finder", keys: 30 ..< 36), probability: 0.33)]
    )
    let (session, host) = makeSession(identifier: SegmentationFrom(from: 36, segmentation: finder))
    type("shindangakanryousuruto,kekkagaFinderuindounihyoujisaremasu.", into: session)
    #expect(session.handle(enter))
    #expect(host.inserted.joined() == "診断が完了すると、結果がFinderウインドウに表示されます。")
}
