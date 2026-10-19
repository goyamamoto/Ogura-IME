@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

/// Keys shown at once and converted in the background (`SegmentsManager.Context.conversionScheduler`). These tests run
/// when the Zenzai weights are in the repository (not an LFS pointer).
private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let resourcesDirectory = repository.appendingPathComponent("Ogura/Resources/gguf", isDirectory: true)
private let scriptModelDirectory = repository.appendingPathComponent("Ogura/Resources/ScriptModel", isDirectory: true)
private let hasModels = ((try? FileManager.default.attributesOfItem(
    atPath: resourcesDirectory.appendingPathComponent("ggml-model-Q5_K_M.gguf").path
)[.size] as? Int) ?? 0) > 1_000_000 && FileManager.default.fileExists(atPath: scriptModelDirectory.path)

@MainActor
private final class Host: InputSessionHost {
    var inserted: [String] = []
    var markedText = ""
    /// How many times the conversion in the background redrew the input
    var redrawn = 0
    func insertText(_ text: String) { self.inserted.append(text) }
    func updateMarkedText(_ markedText: SegmentsManager.MarkedText) { self.markedText = markedText.map(\.content).joined() }
    func switchInputMode(_ language: InputLanguage) {}
    func candidateRow(forNumberKey number: Int) -> Int { number - 1 }
    func leftSideContext(maxCount: Int) -> String? { "" }
    func rightSideContext(maxCount: Int) -> String? { nil }
    func conversionDidUpdate() { self.redrawn += 1 }
}

/// An input session as the app has it, converting in the background with `conversions`, or before each key is shown
/// without
@MainActor
private struct Typing {
    let session: InputSession
    let host: Host
    let pauses: TypingPauses
    let conversions: QueuedConversions?

    init(converter: KanaKanjiConverter, memory: URL, background: Bool) {
        let conversions = background ? QueuedConversions() : nil
        let pauses = TypingPauses()
        let manager = SegmentsManager(
            kanaKanjiConverter: converter,
            applicationDirectoryURL: memory,
            personalizationDirectoryURL: nil,
            context: .init(
                useZenzai: true,
                resourcesDirectoryURL: resourcesDirectory,
                liveConversionEnabled: true,
                learnedScriptIdentification: true,
                scriptModelDirectoryURL: scriptModelDirectory,
                conversionScheduler: conversions
            )
        )
        self.session = InputSession(segmentsManager: manager, settingsProvider: {
            InputSession.Settings(liveConversionEnabled: true, keyBindingStyle: .msIME, inputStyle: .mapped(id: .defaultRomanToKana))
        }, typingPauseScheduler: pauses.scheduler)
        self.host = Host()
        self.pauses = pauses
        self.conversions = conversions
        self.session.host = self.host
    }

    /// The texts of the candidates the window shows
    var candidateTexts: [String] {
        switch self.session.candidateWindow {
        case .hidden: []
        case .composing(let candidates, _), .selecting(let candidates, _): candidates.map(\.text)
        }
    }

    func type(_ keys: String) {
        for character in keys {
            let text = String(character)
            _ = self.session.handle(KeyEventCore(
                modifierFlags: character.isUppercase ? [.shift] : [],
                characters: text,
                charactersIgnoringModifiers: text.lowercased(),
                keyCode: 0
            ))
        }
    }

    func press(_ characters: String, keyCode: UInt16) {
        _ = self.session.handle(KeyEventCore(modifierFlags: [], characters: characters, charactersIgnoringModifiers: characters, keyCode: keyCode))
    }

    func enter() { self.press("\r", keyCode: 0x24) }
    func space() { self.press(" ", keyCode: 49) }

    /// Typing stops long enough for the thorough conversion, and the background has the time to make it
    func pause() {
        self.pauses.pause()
        self.conversions?.runAll()
    }

    /// Types `keys` one at a time, the background converting each before the next: what each key shows once converted
    func typeConverting(_ keys: String) -> [String] {
        keys.map { character in
            self.type(String(character))
            self.conversions?.runAll()
            return self.host.markedText
        }
    }
}

@MainActor
private func freshMemory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ogura-background-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Keys of sentences with Latin words and Japanese mixed, capitals typed with Shift
private let sampleKeys = [
    "watasihagakuseidesu",
    "nihongonyuuryokunoseidowotakameru",
    "osakewonomu",
    "sorehadamedesu",
    "korehawindowsdesu",
    "zoomdekaigisuru",
    "kotlindekaku",
    "kanojohaAnnadesu",
    "Macdehaugokanai",
    "Pythondekaita",
    "korehaSHIFTdesu",
    "mousedeclicksuru",
    "Onnojoutaidetsukau"
]

@Test("すぐ出す表示: 前の変換に、そのあと打った読みを足す")
func instantDisplayGoesOnFromTheConversionShown() {
    // The romaji not yet read is replaced by what it reads as
    #expect(SegmentsManager.instantDisplay(of: "きょうは", after: ("きょうh", "今日h")) == "今日は")
    #expect(SegmentsManager.instantDisplay(of: "きょうはい", after: ("きょうは", "今日は")) == "今日はい")
    // Letters shown for a Latin word stay as shown
    #expect(SegmentsManager.instantDisplay(of: "ぎてゅbに", after: ("ぎてゅbn", "githubn")) == "githubに")
    // When what was shown does not end in the reading that changed, the reading as it is
    #expect(SegmentsManager.instantDisplay(of: "きょか", after: ("きょう", "今日")) == "きょか")
    #expect(SegmentsManager.instantDisplay(of: "かな", after: nil) == "かな")
}

@MainActor
@Test("背景で変換しても、各キーで変換を待つのと同じ表示と確定になる", .enabled(if: hasModels))
func backgroundConversionMatchesConvertingEachKey() throws {
    let converter = KanaKanjiConverter.withDefaultDictionary()
    let memory = freshMemory()
    defer { try? FileManager.default.removeItem(at: memory) }
    for keys in sampleKeys {
        var results: [[String]] = []
        for background in [false, true] {
            let typing = Typing(converter: converter, memory: memory, background: background)
            var shown = typing.typeConverting(keys)
            typing.pause()
            shown.append(typing.host.markedText)
            typing.enter()
            shown.append(typing.host.inserted.joined())
            typing.session.deactivate()
            results.append(shown)
        }
        #expect(results[0] == results[1], "\(keys)")
    }
}

@MainActor
@Test("変換を待たずに、前の変換に打った読みを足して出し、変換が来たら差し替える", .enabled(if: hasModels))
func keysShowBeforeTheirConversion() throws {
    let converter = KanaKanjiConverter.withDefaultDictionary()
    let memory = freshMemory()
    defer { try? FileManager.default.removeItem(at: memory) }
    let expected = Typing(converter: converter, memory: memory, background: false)
    let converted = expected.typeConverting("kyouhaii")

    let typing = Typing(converter: converter, memory: memory, background: true)
    _ = typing.typeConverting("kyouha")
    let shown = typing.host.markedText
    #expect(shown == converted[5])
    typing.type("i")
    // Shown at once, before the conversion is made
    #expect(typing.host.markedText == shown + "い")
    #expect(typing.conversions?.waiting == 1)
    typing.type("i")
    #expect(typing.host.markedText == shown + "いい")
    // One job at a time: the second key waits for the first to be done
    #expect(typing.conversions?.waiting == 1)
    let ran = typing.conversions?.ran ?? 0
    let redrawn = typing.host.redrawn
    typing.conversions?.runAll()
    // The job of the first key, then one for the input as it is
    #expect(typing.conversions?.ran == ran + 2)
    #expect(typing.host.markedText == converted[7])
    #expect(typing.host.redrawn > redrawn)
}

@MainActor
@Test("変換が来る前の Enter は、入力全体を変換して確定する", .enabled(if: hasModels))
func enterBeforeTheConversionCommitsTheWholeInput() throws {
    let converter = KanaKanjiConverter.withDefaultDictionary()
    let memory = freshMemory()
    defer { try? FileManager.default.removeItem(at: memory) }
    let keys = "kyouhaiitenkidesune"
    let expected = Typing(converter: converter, memory: memory, background: false)
    _ = expected.typeConverting(keys)
    expected.enter()

    let typing = Typing(converter: converter, memory: memory, background: true)
    _ = typing.typeConverting(String(keys.prefix(8)))
    typing.type(String(keys.dropFirst(8)))
    #expect(typing.host.markedText != expected.host.inserted.joined())
    typing.enter()
    #expect(typing.host.inserted == expected.host.inserted)
    // Nothing left to come for the input committed
    typing.conversions?.runAll()
    #expect(typing.host.markedText.isEmpty)
}

@MainActor
@Test("変換が来る前の Space は、入力全体の候補を出す", .enabled(if: hasModels))
func spaceBeforeTheConversionConvertsTheWholeInput() throws {
    let converter = KanaKanjiConverter.withDefaultDictionary()
    let memory = freshMemory()
    defer { try? FileManager.default.removeItem(at: memory) }
    let keys = "watasihagakuseidesu"
    let expected = Typing(converter: converter, memory: memory, background: false)
    _ = expected.typeConverting(keys)
    expected.space()

    let typing = Typing(converter: converter, memory: memory, background: true)
    _ = typing.typeConverting(String(keys.prefix(5)))
    typing.type(String(keys.dropFirst(5)))
    typing.space()
    #expect(typing.host.markedText == expected.host.markedText)
    #expect(typing.candidateTexts == expected.candidateTexts)
    #expect(!typing.candidateTexts.isEmpty)
}

@MainActor
@Test("打鍵が止まると徹底変換を背景で作り、来たら表示する。その前にキーを打てば捨てる", .enabled(if: hasModels))
func thoroughConversionInTheBackground() throws {
    let converter = KanaKanjiConverter.withDefaultDictionary()
    let memory = freshMemory()
    defer { try? FileManager.default.removeItem(at: memory) }
    let keys = "kisyagakisyadekisyasita"
    let expected = Typing(converter: converter, memory: memory, background: false)
    _ = expected.typeConverting(keys)
    expected.pause()
    let paused = expected.host.markedText
    expected.type(".")
    let afterKey = expected.host.markedText

    let typing = Typing(converter: converter, memory: memory, background: true)
    _ = typing.typeConverting(keys)
    typing.pause()
    #expect(typing.host.markedText == paused)

    // Asked for while the conversion of the last key is still being made: it waits for it
    let waiting = Typing(converter: converter, memory: memory, background: true)
    _ = waiting.typeConverting(String(keys.dropLast()))
    waiting.type(String(keys.suffix(1)))
    waiting.pauses.pause()
    #expect(waiting.conversions?.waiting == 1)
    waiting.conversions?.runAll()
    #expect(waiting.host.markedText == paused)

    // Called off before it is made (a key that needs the conversion is coming): not shown, and asked for again when
    // typing stops again
    let calledOff = Typing(converter: converter, memory: memory, background: true)
    let typed = calledOff.typeConverting(keys).last
    calledOff.pauses.pause()
    calledOff.session.segmentsManager.callOffThoroughConversion()
    calledOff.conversions?.runAll()
    #expect(calledOff.host.markedText == typed)
    #expect(calledOff.session.segmentsManager.canShowThoroughConversion)

    // A key typed before it is made: dropped, and the key converts as it would after it
    let interrupted = Typing(converter: converter, memory: memory, background: true)
    _ = interrupted.typeConverting(keys)
    interrupted.pauses.pause()
    interrupted.type(".")
    interrupted.conversions?.runAll()
    #expect(interrupted.host.markedText == afterKey)
}

@MainActor
@Test("変換が大きく遅れたら文字キーを受け付けず、追いついたら再び受け付ける（押しっぱなしのキー）", .enabled(if: hasModels))
func typingPausesWhileTheConversionIsFarBehind() throws {
    let converter = KanaKanjiConverter.withDefaultDictionary()
    let memory = freshMemory()
    defer { try? FileManager.default.removeItem(at: memory) }
    let typing = Typing(converter: converter, memory: memory, background: true)
    _ = typing.typeConverting("kyouha")
    let converted = typing.host.markedText
    // A key held down: the background does not catch up
    typing.type(String(repeating: "a", count: 40))
    let segmentsManager = typing.session.segmentsManager
    #expect(segmentsManager.unconvertedCharacterCount == InputSession.typingPausesAt)
    #expect(typing.host.markedText == converted + String(repeating: "あ", count: InputSession.typingPausesAt))
    // The other keys still work: Backspace waits for the conversion and deletes
    _ = typing.session.handle(KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 51))
    #expect(segmentsManager.convertTarget == "きょうは" + String(repeating: "あ", count: InputSession.typingPausesAt - 1))
    // Typing again once the conversion caught up
    typing.conversions?.runAll()
    #expect(segmentsManager.unconvertedCharacterCount == 0)
    typing.type("i")
    #expect(segmentsManager.convertTarget.hasSuffix("い"))
}

/// Keys for a reading of at least `characters` characters: the sample sentences one after another, each ending with 。
private func sentenceKeys(atLeast characters: Int) -> String {
    var keys = ""
    var reading = ComposingText()
    for sentence in sampleKeys where reading.convertTarget.count < characters {
        let typed = sentence.filter { $0.isLetter && $0.isLowercase } + "."
        keys += typed
        reading.insertAtCursorPosition(typed.map { .init(piece: .key(intention: nil, input: $0, modifiers: []), inputStyle: .mapped(id: .defaultRomanToKana)) })
    }
    return keys
}

@MainActor
@Test("長い入力は、打鍵が止まって徹底変換を表示したあと、後ろの 60 文字より前の終わった文までを確定する", .enabled(if: hasModels), arguments: [false, true])
func longInputCommitsTheSentencesDone(background: Bool) throws {
    let converter = KanaKanjiConverter.withDefaultDictionary()
    let memory = freshMemory()
    defer { try? FileManager.default.removeItem(at: memory) }
    let keys = sentenceKeys(atLeast: SegmentsManager.committedAtPauseFrom) + "korehatuduki"
    let typing = Typing(converter: converter, memory: memory, background: background)
    _ = typing.typeConverting(keys)
    // Not while typing: only once the thorough conversion is shown
    #expect(typing.host.inserted.isEmpty)
    let shown = typing.host.markedText
    typing.pause()
    let committed = typing.host.inserted.joined()
    #expect(committed.hasSuffix("。"), "\(committed)")
    // The end stays to correct
    let left = typing.session.segmentsManager.convertTarget
    #expect(left.count >= SegmentsManager.keptUncommitted)
    #expect(left.hasSuffix("これはつづき"))
    // The rest converts after what was committed, and Enter commits it
    typing.conversions?.runAll()
    typing.enter()
    #expect(typing.host.inserted.joined().count >= shown.count - 2)
    #expect(typing.host.inserted.joined().hasPrefix(committed))
}

@MainActor
@Test("さらに長くなると、打鍵が止まらなくても語の区切りで前を確定し、後ろの 60 文字を残す（押しっぱなしのキー）", .enabled(if: hasModels), arguments: [false, true])
func veryLongInputCommitsWithoutAPause(background: Bool) throws {
    let converter = KanaKanjiConverter.withDefaultDictionary()
    let memory = freshMemory()
    defer { try? FileManager.default.removeItem(at: memory) }
    let typing = Typing(converter: converter, memory: memory, background: background)
    _ = typing.typeConverting(String(repeating: "a", count: SegmentsManager.committedAnywhereFrom + 20))
    let committed = typing.host.inserted.joined()
    #expect(!committed.isEmpty)
    let reading = typing.session.segmentsManager.convertTarget
    #expect(reading.count >= SegmentsManager.keptUncommitted)
    #expect(reading.count < SegmentsManager.committedAnywhereFrom)
}
