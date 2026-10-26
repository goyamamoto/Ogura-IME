@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

// The end of the input: once no key will come (Enter, the convert key, typing stopped), the letters romaji has not read
// at the end are read as they will stay, so a Latin word that runs into them is identified whole (iPad, not IPA + d),
// as a trailing n becomes ん (see `SegmentsManager.finishTrailingLetters`, `TypedInput.isComplete`). Japanese that ends in such letters stays
// Japanese (かくd). Reading the input as finished changes nothing but the case of the letters the input ends with (the
// conversion is the same; see `SegmentsManager.writingLastWord`), and what Enter commits is what is shown.

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let models = EvaluationModels(repository: repository, environment: [:])

/// An identification layer that reads the last word in two steps, as for iPad: while the input is being typed
/// and its last letter unread, the word stops before it (and is written as the lexicon spells the shorter word); once the
/// input reads as complete (`TypedInput.readsAsComplete`: no key will follow), the word runs over that letter
private struct WholeOnlyWhenFinished: ScriptIdentifier {
    /// The keys of the word, the spelling written for it whole, and the spelling of the shorter word
    var keys: String
    var whole: String
    var shorter: String
    func segment(_ input: TypedInput) -> ScriptSegmentation {
        guard String(input.keys).hasSuffix(self.keys) else {
            return ScriptSegmentation()
        }
        let start = input.keys.count - self.keys.count
        if !input.readsAsComplete, input.typingFrom < input.keys.count {
            return ScriptSegmentation(latinWords: [.init(word: self.shorter, keys: start ..< input.typingFrom)])
        }
        return ScriptSegmentation(latinWords: [.init(word: self.whole, keys: start ..< input.keys.count)])
    }
}

@MainActor
private final class EndHost: InputSessionHost {
    var inserted: [String] = []
    var markedText = ""
    func insertText(_ text: String) { self.inserted.append(text) }
    func updateMarkedText(_ markedText: SegmentsManager.MarkedText) { self.markedText = markedText.map(\.content).joined() }
    func switchInputMode(_ language: InputLanguage) {}
    func candidateRow(forNumberKey number: Int) -> Int { number - 1 }
    func leftSideContext(maxCount: Int) -> String? { "" }
    func rightSideContext(maxCount: Int) -> String? { nil }
}

/// A session with live conversion, with Zenzai when `zenzai`, identifying by `identifier` or else by the bundled model
@MainActor
private struct Typing {
    let session: InputSession
    let host = EndHost()
    let pauses = TypingPauses()

    init(zenzai: Bool, identifier: (any ScriptIdentifier)? = nil, learned: Bool = true, finishes: Bool = true) {
        var context = SegmentsManager.Context(
            useZenzai: zenzai,
            resourcesDirectoryURL: models.resourcesDirectoryURL,
            liveConversionEnabled: true,
            learnedScriptIdentification: learned,
            scriptModelDirectoryURL: repository.appendingPathComponent("Ogura/Resources/ScriptModel", isDirectory: true),
            zenzaiWeightURL: models.zenzaiWeightURL,
            supplementaryDictionaryURL: models.supplementaryDictionaryURL
        )
        context.writesLastWordAsFinished = finishes
        let manager = SegmentsManager(
            kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
            applicationDirectoryURL: freshTestLearningDirectory(),
            personalizationDirectoryURL: nil,
            context: context
        )
        manager.scriptIdentifierOverride = identifier
        self.session = InputSession(segmentsManager: manager, settingsProvider: {
            InputSession.Settings(liveConversionEnabled: true, keyBindingStyle: .msIME, inputStyle: .mapped(id: .defaultRomanToKana), typeHalfWidthSymbols: true)
        }, typingPauseScheduler: self.pauses.scheduler)
        self.session.host = self.host
    }

    func type(_ keys: String) {
        for character in keys {
            let text = String(character)
            _ = self.session.handle(KeyEventCore(modifierFlags: character.isUppercase ? [.shift] : [], characters: text, charactersIgnoringModifiers: text.lowercased(), keyCode: 0))
        }
    }

    func enter() -> String {
        _ = self.session.handle(KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 0x24))
        return self.host.inserted.joined()
    }

    func convert() {
        _ = self.session.handle(KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49))
    }
}

/// A word of the matrix whose last letter romaji leaves unread: the keys typed, the word written whole, and the shorter
/// word's spelling (as the lexicon writes it)
private struct EndingWord {
    let keys: String
    let whole: String
    let shorter: String
    var identifier: WholeOnlyWhenFinished {
        WholeOnlyWhenFinished(keys: String(self.keys.suffix(self.whole.count)), whole: self.whole, shorter: self.shorter)
    }
}

private let latinWords = [
    EndingWord(keys: "iPad", whole: "iPad", shorter: "IPA"),
    EndingWord(keys: "kyouhaiPad", whole: "iPad", shorter: "IPA"),
    EndingWord(keys: "zoom", whole: "zoom", shorter: "ZOO"),
    EndingWord(keys: "Mac", whole: "Mac", shorter: "MA")
]

@MainActor
@Test("入力の終わりの英単語（最後の字がまだローマ字として読まれていない）: Enter はその語を終わりまで読んで確定する（iPad、IPAd ではない）。Zenzai なし", arguments: latinWords.indices)
func enterFinishesTheLastLatinWord(row: Int) {
    let word = latinWords[row]
    let typing = Typing(zenzai: false, identifier: word.identifier)
    typing.type(word.keys)
    let committed = typing.enter()
    #expect(committed.hasSuffix(word.whole), "\(word.keys) → \(committed)")
    #expect(typing.host.markedText.isEmpty)
}

@MainActor
@Test("入力の終わりの英単語: 打鍵が止まると、終わりまで読んだ形を表示し、Enter はそれを確定する（Zenzai あり）", .enabled(if: models.hasZenzai), arguments: latinWords.indices)
func pauseShowsTheLastLatinWordWhole(row: Int) {
    let word = latinWords[row]
    let typing = Typing(zenzai: true, identifier: word.identifier)
    typing.type(word.keys)
    typing.pauses.pause()
    let shown = typing.host.markedText
    #expect(shown.hasSuffix(word.whole), "\(word.keys): shown \(shown)")
    #expect(typing.enter() == shown)
}

@MainActor
@Test("入力の終わりの英単語: 変換キーでも同じ（最初の候補がその語、Enter で確定）", arguments: latinWords.indices)
func convertKeyFinishesTheLastLatinWord(row: Int) {
    let word = latinWords[row]
    let typing = Typing(zenzai: false, identifier: word.identifier)
    typing.type(word.keys)
    typing.convert()
    #expect(typing.host.markedText.hasSuffix(word.whole), "\(word.keys): \(typing.host.markedText)")
    #expect(typing.enter().hasSuffix(word.whole))
}

/// Japanese whose last letter romaji leaves unread: the letter stays a letter, the rest stays Japanese
private let japanese = ["kakud", "shitet", "arimasuk", "nihongot"]

@MainActor
@Test("入力の終わりの日本語（最後の字がまだ読まれていない）: Enter で終わりまで読んでも日本語のまま、最後の字は字のまま（同梱の識別器、Zenzai なし）", arguments: japanese)
func enterKeepsTheLastJapaneseJapanese(keys: String) {
    let typing = Typing(zenzai: false)
    typing.type(keys)
    let shown = typing.host.markedText
    let committed = typing.enter()
    #expect(!committed.hasPrefix(String(keys.prefix(3))), "\(keys) → \(committed)")
    #expect(committed.last == keys.last, "\(keys) → \(committed)")
    #expect(committed == shown, "\(keys): shown \(shown), committed \(committed)")
}

@MainActor
@Test("入力の終わりの n は今までどおり ん（動きませn → 動きません）", arguments: ["ugokimasen", "ikimasen"])
func enterStillFinishesTheTrailingN(keys: String) {
    // The last n is unread while typing (せn) and becomes ん at Enter
    let typing = Typing(zenzai: false)
    typing.type(keys)
    #expect(typing.enter().hasSuffix("せん"))
}

@MainActor
@Test("同梱の識別器で: iPhone,iPad と iPad は、最後に Enter でも iPad（IPAd にならない）", arguments: ["iPhone,iPad", "iPad", "kyouhaiPad"])
func bundledIdentifierFinishesIPad(keys: String) {
    let typing = Typing(zenzai: false)
    typing.type(keys)
    #expect(typing.enter().hasSuffix("iPad"))
}

/// Japanese typed partway through a word: the letter romaji has not read stays a letter and stays out of the readings
/// the checks compare (褒めt is not homet: a stray t after kana reads like more of a Latin word), and the rest stays
/// Japanese, at Enter and once typing stops
private let halfTypedJapanese = ["kodomowohomet", "tabet", "kakud", "shitet"]

/// The letters of `text` that are not kana or kanji: Japanese typed partway through keeps only its last letter
private func asciiLetters(_ text: String) -> String {
    String(text.filter { $0.isASCII && $0.isLetter })
}

@MainActor
@Test("途中まで打った日本語（Zenzai あり）: Enter でも、打鍵が止まってからでも、最後の字だけが字のまま（子供を褒めt、homet にならない）", .enabled(if: models.hasZenzai), arguments: halfTypedJapanese)
func halfTypedJapaneseStaysJapaneseWithZenzai(keys: String) {
    let atEnter = Typing(zenzai: true)
    atEnter.type(keys)
    let committed = atEnter.enter()
    #expect(asciiLetters(committed) == String(keys.last ?? " "), "\(keys) → \(committed)")
    let afterPause = Typing(zenzai: true)
    afterPause.type(keys)
    afterPause.pauses.pause()
    let shown = afterPause.host.markedText
    #expect(asciiLetters(shown) == String(keys.last ?? " "), "\(keys): shown \(shown)")
    #expect(afterPause.enter() == shown)
}

@MainActor
@Test("途中まで打った日本語（規則の識別、学習した識別層を使わない）: Enter で最後の字まで英単語にしない（食べt、たbet ではない）", arguments: ["tabet", "kodomowohomet", "suget"])
func halfTypedJapaneseStaysJapaneseWithTheRules(keys: String) {
    let typing = Typing(zenzai: false, learned: false)
    typing.type(keys)
    let shown = typing.host.markedText
    let committed = typing.enter()
    #expect(asciiLetters(committed) == String(keys.last ?? " "), "\(keys) → \(committed)")
    #expect(committed == shown, "\(keys): shown \(shown), committed \(committed)")
}

@MainActor
@Test("入力の終わりの n（Zenzai あり）: 打鍵が止まってから Enter でも ん（動きません）", .enabled(if: models.hasZenzai), arguments: ["ugokimasen", "ikimasen"])
func trailingNAfterThePause(keys: String) {
    let typing = Typing(zenzai: true)
    typing.type(keys)
    typing.pauses.pause()
    let committed = typing.enter()
    #expect(!committed.hasSuffix("n"), "\(keys) → \(committed)")
}

/// Rows of the rule not handled yet (kept with what they do now):
/// - Shift+← / → while composing picks clauses from the input converted as it was being typed, and Enter commits them:
///   the word typed last is still cut before its unread letter (below).
/// - A long input whose start is committed once typing stops (`SegmentsManager.commitLongInputHead`) converts the rest
///   again as being typed, until typing stops once more.
@MainActor
@Test("未対応: Shift+← で文節を選んでから Enter すると、最後の英単語は打ちかけのまま切れる（今の動き。直れば known issue が外れる）")
func clausesPickedWithShiftArrowAreNotFinishedYet() {
    let word = latinWords[0]
    let typing = Typing(zenzai: false, identifier: word.identifier)
    typing.type(word.keys)
    _ = typing.session.handle(KeyEventCore(modifierFlags: [.shift], characters: nil, charactersIgnoringModifiers: nil, keyCode: 123))
    let committed = typing.enter()
    withKnownIssue("Shift+← / → からの文節は、入力を終わったものとして読み直していない") {
        #expect(committed.hasSuffix(word.whole), "\(word.keys) → \(committed)")
    }
}

/// What typing `keys` commits with the last word written as finished and without (`Context.writesLastWordAsFinished`),
/// Enter right after the last key or once typing stopped (with Zenzai)
@MainActor
private func committedBothWays(_ keys: String, pause: Bool) -> (finished: String, asTyped: String) {
    func commit(finishes: Bool) -> String {
        let typing = Typing(zenzai: true, finishes: finishes)
        typing.type(keys)
        if pause {
            typing.pauses.pause()
        }
        return typing.enter()
    }
    return (commit(finishes: true), commit(finishes: false))
}

/// Sentences whose kana before the last letters must stay when the input is read as finished (logoうt, not logo雨t):
/// they commit the same either way
private let kanaKeptRows = ["konosesshonkaralogout", "Royha,outsidedesatsueishitautsukushiisnapshot", "konoYuanbao,tomodachitonopartydetabetandakedo,hontounimuch"]

@MainActor
@Test("入力を終わったものとして読んでも、かなと漢字は変わらない（止まってから Enter、すぐ Enter）", .enabled(if: models.hasZenzai), arguments: kanaKeptRows)
func finishingNeverChangesTheKana(keys: String) {
    for pause in [true, false] {
        let both = committedBothWays(keys, pause: pause)
        #expect(both.finished == both.asTyped, "\(keys) (pause \(pause)): \(both.asTyped) → \(both.finished)")
    }
}

/// Inputs that reading as finished changes at most in the case of the letters they end with
private let caseFixedRows = ["iPad", "kyouhaiPad", "zoom", "Mac", "gmt", "cd", "10kb", "tabet", "kodomowohomet"]

@MainActor
@Test("入力を終わったものとして読んで変わるのは、最後の英字の大文字小文字だけ（IPAd → iPad、GMt → GMT、10kb → 10KB）。ほかの字は変わらない", .enabled(if: models.hasZenzai), arguments: caseFixedRows)
func finishingChangesOnlyTheCaseOfTheLastLetters(keys: String) {
    for pause in [true, false] {
        let both = committedBothWays(keys, pause: pause)
        #expect(both.finished.lowercased() == both.asTyped.lowercased(), "\(keys) (pause \(pause)): \(both.asTyped) → \(both.finished)")
        #expect(both.finished.count == both.asTyped.count)
    }
}

@MainActor
@Test("文字列の上の決まり: 最後の英字の並びが、識別器の書き方と大文字小文字を除いて同じ時だけ置き換える")
func writingLastWordReplacesOnlyTheCase() {
    #expect(SegmentsManager.writingLastWord(of: "今日はIPAd", as: "iPad") == "今日はiPad")
    #expect(SegmentsManager.writingLastWord(of: "10kb", as: "10KB") == "10KB")
    #expect(SegmentsManager.writingLastWord(of: "GMt", as: "GMT") == "GMT")
    // Different letters, or kana before the last letter: nothing changes
    #expect(SegmentsManager.writingLastWord(of: "食べt", as: "bet") == "食べt")
    #expect(SegmentsManager.writingLastWord(of: "子供を褒めt", as: "homet") == "子供を褒めt")
    #expect(SegmentsManager.writingLastWord(of: "このセッションからlogoうt", as: "logout") == "このセッションからlogoうt")
    #expect(SegmentsManager.writingLastWord(of: "IPAd", as: nil) == "IPAd")
}
