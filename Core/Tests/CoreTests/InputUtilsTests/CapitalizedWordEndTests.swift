/// Words typed with a capital, with the bundled model and Zenzai. Where such a word ends: the model reads names typed
/// with a capital (Kanagawa, Ogawa), so a word followed by romaji that looks like a name's end (Winnogawa) reads as one
/// name; Zenzai then prefers the shorter word with the rest as Japanese (see `ScriptSegmentation.shorterWords`). And
/// what follows a name: Zenzai converts around it, with the Japanese name the dictionary knows for it as its context
/// (see `SegmentsManager.contextWord`)
@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let resourcesDirectory = repository.appendingPathComponent("Ogura/Resources/gguf", isDirectory: true)
private let hasZenzaiWeights = ((try? FileManager.default.attributesOfItem(
    atPath: resourcesDirectory.appendingPathComponent("ggml-model-Q5_K_M.gguf").path
)[.size] as? Int) ?? 0) > 1_000_000

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
        applicationDirectoryURL: testLearningDirectory,
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
@Test("大文字から打った語の終わりは、残りを日本語に読む方が自然ならそこまで（Winの側、Fanの中身）。名前はそのまま（Shinagawa、Inoueさん）", .enabled(if: hasZenzaiWeights))
func capitalizedWordEndsBeforeNaturalJapanese() {
    #expect(committed("suittihaWinnogawaniarimasu") == "スイッチはWinの側にあります")
    #expect(committed("Fannonakamiwomiru") == "Fanの中身を見る")
    #expect(committed("Shinagawaniikimasu") == "Shinagawaに行きます")
    #expect(committed("Inouesannniaimashita") == "Inoueさんに会いました")
}

@MainActor
@Test("英字で打った名前のあとは、辞書にある日本語の名前を文脈にして変換する（Osaka市、Kanagawa県、橋はOsaka市）", .enabled(if: hasZenzaiWeights))
func nameInLettersIsContextForWhatFollows() {
    #expect(committed("Osakashiniikimasu") == "Osaka市に行きます")
    #expect(committed("Kanagawakennnisunde") == "Kanagawa県に住んで")
    #expect(committed("Tokyoekideoriru") == "Tokyo駅で降りる")
    #expect(committed("watashihaOsakashiniikimasu") == "私はOsaka市に行きます")
    #expect(committed("hashihaOsakashiniarimasu") == "橋はOsaka市にあります")
    #expect(committed("ashitaKyoutoshiniikimasu") == "明日Kyouto市に行きます")
    // A name is not cut short where its first part is a name too (Yoko)
    #expect(committed("watashihaYokohamanisundeimasu") == "私はYokohamaに住んでいます")
    #expect(committed("Pythonnyuumonwoyomu") == "Python入門を読む")
    #expect(committed("kyouhaGitHubnipushsita") == "今日はGitHubにpushした")
}
