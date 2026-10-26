import ContinuationMLX
@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

// Letters shown stay letters while typing goes on (see `SegmentsManager.shownMargin`): a Latin word the naturalness
// checks kept as letters, with kana read after it, is not read as kana again at a later key because the readings the
// checks compare changed with that key (tokenを発行s, then と券を発行す, then tokenを発行する again). The conversion once
// typing stops does not use what was shown: it decides afresh, so what is committed is what it was. The checks are the
// app's: Zenzai and the bundled reading judge (see `SegmentsManager.Context.readingJudge`).

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let models = EvaluationModels(repository: repository, environment: [:])
/// The bundled reading judge of the naturalness checks, where the tree has it
private let readingJudge = try? CoreMLReadingJudge(directory: repository.appendingPathComponent("Ogura/Resources/ReadingJudge", isDirectory: true))
private let hasModels = models.hasZenzai && readingJudge != nil

@MainActor
private final class ShownHost: InputSessionHost {
    var inserted: [String] = []
    var markedText = ""
    func insertText(_ text: String) { self.inserted.append(text) }
    func updateMarkedText(_ markedText: SegmentsManager.MarkedText) { self.markedText = markedText.map(\.content).joined() }
    func switchInputMode(_ language: InputLanguage) {}
    func candidateRow(forNumberKey number: Int) -> Int { number - 1 }
    func leftSideContext(maxCount: Int) -> String? { "" }
    func rightSideContext(maxCount: Int) -> String? { nil }
}

/// What a session showed and committed for a sentence typed
private struct Typed {
    /// What was shown after each key
    var shown: [String]
    /// What was shown once typing stopped
    var paused: String
    /// What Enter committed then
    var committed: String
}

/// What is shown after each key of `keys`, what is shown once typing stops, and what Enter commits then: live
/// conversion with Zenzai, the bundled identification model and the bundled reading judge
@MainActor
private func typed(_ keys: String) -> Typed {
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
    let host = ShownHost()
    session.host = host
    var shown: [String] = []
    for character in keys {
        let text = String(character)
        _ = session.handle(KeyEventCore(modifierFlags: character.isUppercase ? [.shift] : [], characters: text, charactersIgnoringModifiers: text.lowercased(), keyCode: 0))
        shown.append(host.markedText)
    }
    pauses.pause()
    let paused = host.markedText
    _ = session.handle(KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 0x24))
    return Typed(shown: shown, paused: paused, committed: host.inserted.joined())
}

/// The Latin words of `text` with something after them: runs of two or more letters, but one the text ends with, which
/// may still be being typed
private func settledLatinWords(_ text: String) -> [String] {
    var words: [String] = []
    var current = ""
    for character in text {
        if character.isASCII, character.isLetter {
            current.append(character)
        } else {
            if current.count >= 2 {
                words.append(current)
            }
            current = ""
        }
    }
    return words
}

/// The keys after which a Latin word shown with something after it was gone, with what was shown before and after
private func vanishings(_ shown: [String]) -> [String] {
    zip(shown, shown.dropFirst()).enumerated().compactMap { index, pair in
        let gone = settledLatinWords(pair.0).filter { !pair.1.contains($0) }
        return gone.isEmpty ? nil : "key \(index + 2): \(pair.0) → \(pair.1)"
    }
}

/// Sentences whose Latin word was read as kana for a key or two while what follows it was being typed, and as letters
/// again: the keys and what they commit
private let swayed: [(keys: String, committed: String)] = [
    ("tokenwohakkousuru", "tokenを発行する"),
    ("tokenwokakuninshite", "tokenを確認して"),
    ("konodata,sugokukyoumibukaikaraisshonimiyouyo.", "このdata、すごく興味深いから一緒に見ようよ。"),
    ("meanwokeisanshi,chosennosaitekinasentakushiwomitsukemashita.", "meanを計算し、chosenの最適な選択肢を見つけました。")
]

@MainActor
@Test("英字で表示した語は、続きを打っている間、かなに戻って消えない。確定する文字は変わらない", .enabled(if: hasModels), arguments: swayed.indices)
func lettersShownStayWhileTypingGoesOn(row: Int) {
    let sentence = swayed[row]
    let result = typed(sentence.keys)
    #expect(vanishings(result.shown).isEmpty, "\(sentence.keys): \(vanishings(result.shown))")
    #expect(result.committed == sentence.committed, "\(sentence.keys): shown \(result.shown.last ?? "")")
}

@MainActor
@Test("打鍵が止まったときの変換は、英字で表示していたことに引かれずに決め直す（rateを飲みます と表示していても ラテを飲みます）", .enabled(if: hasModels))
func conversionOnceTypingStopsDecidesAfresh() {
    let result = typed("ratewonomimasu")
    #expect(vanishings(result.shown).isEmpty, "\(vanishings(result.shown))")
    #expect(result.paused == "ラテを飲みます", "shown \(result.shown)")
    #expect(result.committed == result.paused)
}
