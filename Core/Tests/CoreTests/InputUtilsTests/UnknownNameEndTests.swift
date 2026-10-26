import ContinuationMLX
@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

// Where a name the lexicon does not know ends, typed with a capital and followed by kana: the identification layer
// reads the first letter of the kana into the name (SoftBanks+は for SoftBankshato…) or the whole kana (SoftBanksha),
// since nothing tells it where an unknown name ends. The naturalness checks compare the name ending earlier, the rest
// read as Japanese (SoftBank社と), and take it when Zenzai and the reading judge find it likelier (see
// `SegmentsManager.shorterWordMargin`). A name that does end in that letter keeps it (Windowsは, Jobsは). The other way
// round, the layer can give a name's last letter to the kana (Laker+しゃ for Lakershaka…, Bank+っしゃ for Banksshano…):
// the checks compare the name one key longer too (see `ScriptTagger.longerWords`).

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let models = EvaluationModels(repository: repository, environment: [:])
/// The bundled reading judge of the naturalness checks, where the tree has it
private let readingJudge = try? CoreMLReadingJudge(directory: repository.appendingPathComponent("Ogura/Resources/ReadingJudge", isDirectory: true))
private let hasModels = models.hasZenzai && readingJudge != nil

/// What typing `keys`, a pause and Enter commit: live conversion with Zenzai, the bundled identification model and the
/// bundled reading judge
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
    let pauses = TypingPauses()
    let manager = SegmentsManager(
        kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
        applicationDirectoryURL: freshTestLearningDirectory(),
        personalizationDirectoryURL: nil,
        context: .init(
            useZenzai: true,
            resourcesDirectoryURL: models.resourcesDirectoryURL,
            liveConversionEnabled: true,
            learnedScriptIdentification: true,
            scriptModelDirectoryURL: repository.appendingPathComponent("Ogura/Resources/ScriptModel", isDirectory: true),
            zenzaiWeightURL: models.zenzaiWeightURL,
            supplementaryDictionaryURL: models.supplementaryDictionaryURL,
            readingJudge: readingJudge
        )
    )
    let session = InputSession(segmentsManager: manager, settingsProvider: {
        InputSession.Settings(liveConversionEnabled: true, keyBindingStyle: .msIME, inputStyle: .mapped(id: .defaultRomanToKana), typeHalfWidthSymbols: true)
    }, typingPauseScheduler: pauses.scheduler)
    let host = Host()
    session.host = host
    for character in keys {
        let text = String(character)
        _ = session.handle(KeyEventCore(modifierFlags: character.isUppercase ? [.shift] : [], characters: text, charactersIgnoringModifiers: text.lowercased(), keyCode: 0))
    }
    pauses.pause()
    _ = session.handle(KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 0x24))
    return host.inserted.joined()
}

/// Names the lexicon does not know, with kana after them whose first letter the identification layer reads into the name
private let endingEarlier: [(keys: String, committed: String)] = [
    ("SoftBankshatokeiyakushimashita", "SoftBank社と契約しました"),
    ("SoftBankshanoseihinwotsukatteimasu", "SoftBank社の製品を使っています"),
    ("PayPalshanoseihinwotsukatteimasu", "PayPal社の製品を使っています"),
    ("DocuSignshanoseihinwotsukatteimasu", "DocuSign社の製品を使っています"),
    ("Marshaakaidesu", "Marsは赤いです"),
    ("Teslashanoseihinwokaimashita", "Tesla社の製品を買いました"),
    ("Teslashagahappyoushimashita", "Tesla社が発表しました"),
    ("Teslashatokeiyakushimashita", "Tesla社と契約しました"),
    ("PayPalshahariekiwoageteimasu", "PayPal社は利益を上げています"),
    ("PayPalshanoriekihaookiidesu", "PayPal社の利益は大きいです"),
    ("SoftBankshahariekiwoageteimasu", "SoftBank社は利益を上げています"),
    ("DocuSignshahariekiwoageteimasu", "DocuSign社は利益を上げています")
]

@MainActor
@Test("辞書にない名前の終わり: 続くかなの頭の字まで名前に読まれても、手前で終えたほうが自然ならそこまで（SoftBank社と、Marsは）", .enabled(if: hasModels), arguments: endingEarlier.indices)
func unknownNameEndsBeforeTheKana(row: Int) {
    let sentence = endingEarlier[row]
    #expect(committed(sentence.keys) == sentence.committed, "\(sentence.keys)")
}

/// Names whose last letter the identification layer reads into the kana after them
private let endingLater: [(keys: String, committed: String)] = [
    ("Lakershakachimashita", "Lakersは勝ちました"),
    ("GoldmanSachshahappyoushimashita", "GoldmanSachsは発表しました"),
    ("Lexushatakaidesu", "Lexusは高いです"),
    ("Banksshanoseihinwotsukatteimasu", "Banks社の製品を使っています")
]

@MainActor
@Test("辞書にない名前の終わり: 最後の字が続くかなに読まれても、一字延ばしたほうが自然ならそこまで（Lakersは、Banks社）", .enabled(if: hasModels), arguments: endingLater.indices)
func unknownNameKeepsTheLetterTheKanaTook(row: Int) {
    let sentence = endingLater[row]
    #expect(committed(sentence.keys) == sentence.committed, "\(sentence.keys)")
}

/// Names that end in the letter the kana after them could start with, and names followed by は: they stay as typed
private let keptWhole: [(keys: String, committed: String)] = [
    ("Windowshabenridesu", "Windowsは便利です"),
    ("Jobshakoukatarimashita", "Jobsはこう語りました"),
    ("AWShabenridesu", "AWSは便利です"),
    ("Slackyamemashita", "Slackやめました"),
    ("SoftBankhaookiikaishadesu", "SoftBankは大きい会社です"),
    ("Appleshahakotoshimoseichoushiteimasu", "Apple社は今年も成長しています"),
    ("Sonyshanoseihinwotsukatteimasu", "Sony社の製品を使っています"),
    ("Kanagawakennniikimasu", "Kanagawa県に行きます"),
    ("Celticshakachimashita", "Celticsは勝ちました"),
    ("Simpsonshaomoshiroidesu", "Simpsonsは面白いです"),
    ("Texashahiroidesu", "Texasは広いです"),
    ("shindangakanryousuruto,kekkagaFinderuindounihyoujisaremasu.", "診断が完了すると、結果がFinderウインドウに表示されます。")
]

@MainActor
@Test("名前の終わりの字は、その名前のものならそのまま（Windowsは、Jobsは、Slackやめました）", .enabled(if: hasModels), arguments: keptWhole.indices)
func nameKeepsItsLastLetter(row: Int) {
    let sentence = keptWhole[row]
    #expect(committed(sentence.keys) == sentence.committed, "\(sentence.keys)")
}

/// A capital marks Latin wherever it is typed, also where the model reads it as kana (て+sla for Tesla)
private let capitalsStayLetters: [(keys: String, committed: String)] = [
    ("Teslanokurumadesu", "Teslaの車です"),
    ("watashihaTeslanokurumaninorimasu", "私はTeslaの車に乗ります"),
    ("Hadeshakowaidesu", "Hadesは怖いです"),
    ("Kyouhaiitenkidesu", "Kyouはいい天気です"),
    ("Takahashisangakita", "Takahashiさんが来た")
]

@MainActor
@Test("大文字は文頭でも文中でも英字の始まり（Teslaの車、Hadesは、Kyouは）", .enabled(if: hasModels), arguments: capitalsStayLetters.indices)
func capitalStaysALetter(row: Int) {
    let sentence = capitalsStayLetters[row]
    #expect(committed(sentence.keys) == sentence.committed, "\(sentence.keys)")
}

@MainActor
@Test("未対応: Tesla と「しゃ」には分かれるが、変換が「社」を「車」と書く（Tesla車の車です）。直れば known issue が外れる", .enabled(if: hasModels))
func teslaCompanyIsWrittenAsCar() {
    let text = committed("Teslashanokurumadesu")
    #expect(text.hasPrefix("Tesla") && !text.hasPrefix("Teslas"))
    withKnownIssue {
        #expect(text == "Tesla社の車です")
    }
}

/// Japanese typed with a capital first, whose letters make no sense: the one case a capital reads as kana
private let clearlyJapanese: [(keys: String, committed: String)] = [
    ("Arigatougozaimasu", "ありがとうございます"),
    ("Watashihagakuseidesu", "私は学生です"),
    ("Ohayougozaimasu", "おはようございます"),
    ("Sumimasendeshita", "すみませんでした"),
    ("Konohonwoyomimashita", "この本を読みました")
]

@MainActor
@Test("英字では意味が通らず明らかに日本語のときだけ、大文字もかなに読む（ありがとうございます）", .enabled(if: hasModels), arguments: clearlyJapanese.indices)
func clearlyJapaneseReadsACapitalAsKana(row: Int) {
    let sentence = clearlyJapanese[row]
    #expect(committed(sentence.keys) == sentence.committed, "\(sentence.keys)")
}
