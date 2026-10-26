@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

/// Words joined by hyphens (e-mail, built-in) read as one Latin word, when the model reads them so (the hyphens file in
/// its directory)
private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let resourcesDirectory = repository.appendingPathComponent("Ogura/Resources/gguf", isDirectory: true)
private let hasZenzaiWeights = ((try? FileManager.default.attributesOfItem(
    atPath: resourcesDirectory.appendingPathComponent("ggml-model-Q5_K_M.gguf").path
)[.size] as? Int) ?? 0) > 1_000_000

@Test("ハイフンでつないだ語は、一つの英単語の候補になる（e-mail）。ハイフンで終わる候補や、語の外のハイフンは含めない")
func wordCandidatesGoThroughHyphensBetweenLetters() {
    let keys = Array("e-mailwo-")
    let through = ScriptTaggerFeatures.words(of: keys, models: nil, lexicon: nil, throughHyphens: true)
    let letters = ScriptTaggerFeatures.words(of: keys, models: nil, lexicon: nil)
    // From e: e, e-, e-m, ..., e-mailwo (the last - has no letter after it)
    #expect(through[0].count == 8)
    #expect(letters[0].count == 1)
    #expect(!ScriptTaggerFeatures.continuesWord(keys, at: 1, start: 1, throughHyphens: true))
    #expect(!ScriptTaggerFeatures.continuesWord(keys, at: 8, start: 2, throughHyphens: true))
}

/// What typing `keys` and Enter commits, with Zenzai and the bundled model
@MainActor
private func committed(_ keys: String) -> String {
    final class Host: InputSessionHost {
        var inserted: [String] = []
        func insertText(_ text: String) { self.inserted.append(text) }
        func updateMarkedText(_ markedText: SegmentsManager.MarkedText) {}
        func switchInputMode(_ language: InputLanguage) {}
        func candidateRow(forNumberKey number: Int) -> Int { number - 1 }
        func leftSideContext(maxCount: Int) -> String? { "" }
        func rightSideContext(maxCount: Int) -> String? { nil }
    }
    let manager = SegmentsManager(
        kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
        applicationDirectoryURL: freshTestLearningDirectory(),
        personalizationDirectoryURL: nil,
        context: .init(
            useZenzai: true,
            resourcesDirectoryURL: resourcesDirectory,
            liveConversionEnabled: true,
            learnedScriptIdentification: true,
            scriptModelDirectoryURL: repository.appendingPathComponent("Ogura/Resources/ScriptModel", isDirectory: true)
        )
    )
    let session = InputSession(segmentsManager: manager, settingsProvider: {
        InputSession.Settings(liveConversionEnabled: true, keyBindingStyle: .msIME, inputStyle: .mapped(id: .defaultRomanToKana))
    })
    let host = Host()
    session.host = host
    for character in keys {
        let text = String(character)
        _ = session.handle(KeyEventCore(modifierFlags: character.isUppercase ? [.shift] : [], characters: text, charactersIgnoringModifiers: text.lowercased(), keyCode: 0))
    }
    _ = session.handle(KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 0x24))
    return host.inserted.joined()
}

@MainActor
@Test("ハイフンでつないだ英単語は英字のまま、ハイフンも打ったまま（e-mail、built-in）。長音の えー は日本語のまま", .enabled(if: hasZenzaiWeights))
func hyphenatedWordsStayLatin() {
    #expect(committed("e-mailwookuru") == "e-mailを送る")
    #expect(committed("built-inkannsuu").hasPrefix("built-in"))
    // tone is an English word too, but えーとね is the natural reading
    #expect(committed("e-tone") == "えーとね")
    #expect(committed("ko-hi-wonomu").hasPrefix("コーヒー"))
}

@MainActor
@Test("英単語二つをつないだ語は、文末まで打っても英字のまま（us-west）。英字とカタカナで書く語は、英字のあとをローマ字で読む（T-shatu は Tシャツ）", .enabled(if: hasZenzaiWeights))
func joinedWordsAndLetteredLoanwords() {
    #expect(committed("us-westhadoudesuka") == "us-westはどうですか")
    // The - is the long vowel mark here: half-width symbols are off
    let shirt = committed("T-shatuwokiteodekakeshimasu")
    #expect(shirt.hasPrefix("T") && shirt.hasSuffix("シャツを着てお出かけします"))
    #expect(committed("Uta-nnshitekaeru") == "Uターンして帰る")
}

@MainActor
@Test("言語や国のコードから始まるハイフンでつないだ語は、コードまで英字（eu-east、en-US）。英単語が後ろのローマ字まで取り込んでも、日本語の方がずっと自然ならそこで終わる（sign-inして）", .enabled(if: hasZenzaiWeights))
func codesAndWordEndsAroundHyphens() {
    #expect(committed("depuroisakihaeu-eastdesu") == "デプロイ先はeu-eastです")
    #expect(committed("gengohaen-USnisetteisuru") == "言語はen-USに設定する")
    #expect(committed("sign-inshitekudasai") == "sign-inしてください")
    #expect(committed("de-tawohozonsuru") == "データを保存する")
}

@MainActor
@Test("入力の終わりの英単語も、前の日本語から見て英字の方が自然なら英字で確定する（今日の会議はzoom）", .enabled(if: hasZenzaiWeights))
func latinWordAtTheEndIsCommittedAsLetters() {
    #expect(committed("kyounokaigihazoom") == "今日の会議はzoom")
    #expect(committed("yamanomine") == "山の峰" || committed("yamanomine") == "山ノ峰")
}
