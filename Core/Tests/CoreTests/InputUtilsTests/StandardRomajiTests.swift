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

@Test("標準的なローマ字（ヘボン式、訓令式、日本式、外来語の書き方）と、理由のある IME の綴り（jy-）で書ける語と、書けない語を見分ける（綴りの目録の、迷ったら日本語のもの）")
func standardRomajiSpellsJapanese() {
    for word in ["mine", "token", "konnichiha", "konnnichiha", "shinbun", "kitte", "matcha", "maccha", "mattya", "sinbun",
                 "tisshu", "firumu", "chekku", "jetto", "uindou", "wo", "n", "kyouha", "e-tone", "ko-hi-"] {
        #expect(StandardRomaji.spells(word), "\(word)")
    }
    // c without h, l, x, q, tw, th: an input method reads them as kana, but they are not standard romaji, and none has
    // its own reason to be Japanese when in doubt (see RomajiSpellings)
    for word in ["code", "care", "core", "cicada", "ele", "two", "ltu", "xa", "quick", "kitt", "thi", "cco", "-e", "e-mail"] {
        #expect(!StandardRomaji.spells(word), "\(word)")
    }
    // MS-IME's jya, jyu, jye, jyo for じゃ, じゅ, じぇ, じょ: how people type Japanese with it; the words of the lexicon
    // with jy in them are not spelled so
    for word in ["jyuu", "nijyuu", "sakujyo", "jyunbi", "kanojyo", "jyaa", "jye"] {
        #expect(StandardRomaji.spells(word), "\(word)")
    }
    for word in ["jython", "jynx", "benjy", "jyutping", "jy"] {
        #expect(!StandardRomaji.spells(word), "\(word)")
    }
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
@Test("標準的なローマ字で綴れる語は、迷ったら日本語。文末が変わっても変わらない。標準的でない綴り（co）の英単語は英字のまま", .enabled(if: hasZenzaiWeights))
func standardRomajiDecidesWhenInDoubt() {
    // The ending used to tip the check: the end of the input made the letters likelier when it came right after them
    #expect(committed("mineninoboru") == "峰に登る")
    #expect(committed("mineninoborimasu") == "峰に登ります")
    #expect(!committed("minenimukaimasu").contains("mine"))
    // これは and コイン are natural, but core and coin are not how romaji writes them
    #expect(committed("corehadaijoubudesu") == "coreは大丈夫です")
    #expect(committed("coinwoireru") == "coinを入れる")
    // Nor is a word the identification layer is unsure about left to the converter when it is not standard romaji
    #expect(committed("cafedeaimashou") == "cafeで会いましょう")
}

@MainActor
@Test("MS-IME の綴り（jya / jyu / jye / jyo）で打った日本語も、迷ったら日本語（nijyuunonyuuryoku は「二重の入力」）", .enabled(if: hasZenzaiWeights))
func msIMESpellingsAreJapaneseWhenInDoubt() {
    #expect(committed("nijyuunonyuuryokuhasakujyosaremasu") == "二重の入力は削除されます")
    #expect(committed("nijyuunonyuuryoku") == "二重の入力")
    #expect(!committed("jyunsugaarimasu").contains("jyun"))
}

@MainActor
@Test("標準的でない綴りで読める英単語は、迷っても日本語にしない（code は コデ にならない）: 単独でも、日本語の中でも英字のまま", .enabled(if: hasZenzaiWeights))
func englishWordsSpelledOnlyByNonstandardRomajiStayLetters() {
    for word in ["code", "let", "two"] {
        #expect(committed(word) == word, "\(word)")
    }
    for (keys, word) in [("codewokaku", "code"), ("letwotukau", "let"), ("twowoerabu", "two"), ("thisdesu", "this"), ("cakewotaberu", "cake"),
                         ("themewokaeru", "theme"), ("lockwokakeru", "lock")] {
        #expect(committed(keys).hasPrefix(word), "\(keys) → \(committed(keys))")
    }
}
