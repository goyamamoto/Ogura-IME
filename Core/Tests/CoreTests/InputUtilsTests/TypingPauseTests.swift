import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

/// The thorough conversion is shown once typing stops, and Enter commits what is shown (see `InputSession`). The tests
/// with Zenzai run when its weights are in the repository (not an LFS pointer), with the app's models when they are
/// built (genmai, with zenz-v3.2-small as the second opinion: see `EvaluationModels`).
private let models = EvaluationModels(
    repository: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
    environment: [:]
)

@MainActor
private final class PauseHost: InputSessionHost {
    var inserted: [String] = []
    var markedText = ""
    func insertText(_ text: String) { self.inserted.append(text) }
    func updateMarkedText(_ markedText: SegmentsManager.MarkedText) { self.markedText = markedText.map(\.content).joined() }
    func switchInputMode(_ language: InputLanguage) {}
    func candidateRow(forNumberKey number: Int) -> Int { number - 1 }
    func leftSideContext(maxCount: Int) -> String? { "" }
    func rightSideContext(maxCount: Int) -> String? { nil }
}

/// The clock of the keys' timestamps, which the tests move
@MainActor
private final class Clock {
    var now: TimeInterval = 100
}

/// A session typed into, what its host was told, and the pauses the test makes
@MainActor
private struct Typing {
    let session: InputSession
    let host: PauseHost
    let pauses: TypingPauses

    init(zenzai: Bool, clock: Clock = Clock()) {
        let manager = SegmentsManager(
            kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
            applicationDirectoryURL: freshTestLearningDirectory(),
            personalizationDirectoryURL: nil,
            context: .init(
                useZenzai: zenzai,
                resourcesDirectoryURL: models.resourcesDirectoryURL,
                liveConversionEnabled: true,
                zenzaiWeightURL: models.zenzaiWeightURL,
                supplementaryDictionaryURL: models.supplementaryDictionaryURL
            )
        )
        self.pauses = TypingPauses()
        self.session = InputSession(segmentsManager: manager, settingsProvider: {
            InputSession.Settings(liveConversionEnabled: true, keyBindingStyle: .msIME, inputStyle: .mapped(id: .defaultRomanToKana))
        }, typingPauseScheduler: self.pauses.scheduler, uptime: { clock.now })
        self.host = PauseHost()
        self.session.host = self.host
    }

    func type(_ keys: String) {
        for character in keys {
            let text = String(character)
            _ = self.session.handle(KeyEventCore(modifierFlags: [], characters: text, charactersIgnoringModifiers: text, keyCode: 0))
        }
    }
}

private func enter(pressedAt timestamp: TimeInterval? = nil) -> KeyEventCore {
    KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 0x24, timestamp: timestamp)
}

private let space = KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49)
private let backspace = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 51)
/// The last is shown as 四月 while typing and as 4月 once typing stops with genmai and the second opinion
private let sentences = ["kyouhaiitenkidesune", "nihonngodejoshinotsukaikatahajuuyoudesu.", "shigatsunijinjiidougaaru."]

@MainActor
@Test("打鍵が止まる前の Enter は、表示している変換をそのまま確定する", .enabled(if: models.hasZenzai), arguments: sentences)
func enterBeforePauseCommitsWhatIsShown(keys: String) {
    let typing = Typing(zenzai: true)
    typing.type(keys)
    let shown = typing.host.markedText
    #expect(typing.session.handle(enter()))
    #expect(typing.host.inserted == [shown])
}

@MainActor
@Test("打鍵が止まると徹底変換を表示し、Enter はそれを確定する", .enabled(if: models.hasZenzai), arguments: sentences)
func pauseShowsThoroughConversionAndEnterCommitsIt(keys: String) {
    let typing = Typing(zenzai: true)
    typing.type(keys)
    #expect(typing.pauses.pause())
    let shown = typing.host.markedText
    // An event that leaves the input as it is does not convert it thoroughly again
    typing.session.inputModeDidChange(to: .japanese)
    #expect(!typing.pauses.pause())
    #expect(typing.session.handle(enter()))
    #expect(typing.host.inserted == [shown])
}

@MainActor
@Test("genmai のときは、打鍵が止まると表示が変わる文がある", .enabled(if: models.hasZenzai && models.zenzaiWeightURL != nil))
func pauseChangesWhatIsShownWithGenmai() {
    let changed = sentences.filter { keys in
        let typing = Typing(zenzai: true)
        typing.type(keys)
        let typed = typing.host.markedText
        typing.pauses.pause()
        return typing.host.markedText != typed
    }
    #expect(!changed.isEmpty)
}

@MainActor
@Test("徹底変換を表示する前に押した Enter はその前の表示を、表示した後に押した Enter は徹底変換を確定する", .enabled(if: models.hasZenzai), arguments: sentences)
func enterPressedWhileThoroughConversionIsMadeCommitsWhatWasSeen(keys: String) {
    // Pressed while the thorough conversion was being made (the main thread busy), once it could be seen, and made up
    // without a time
    for (pressedAt, seesThorough) in [(100.9, false), (101.2, true), (0, true)] {
        let clock = Clock()
        let typing = Typing(zenzai: true, clock: clock)
        typing.type(keys)
        let typed = typing.host.markedText
        clock.now = 101
        typing.pauses.pause()
        let thorough = typing.host.markedText
        #expect(typing.session.handle(enter(pressedAt: pressedAt)))
        #expect(typing.host.inserted == [seesThorough ? thorough : typed], "pressed at \(pressedAt)")
    }
}

@MainActor
@Test("徹底変換を表示したあとの Space は、表示している変換を文節に分ける", .enabled(if: models.hasZenzai), arguments: sentences)
func spaceAfterPauseKeepsThoroughConversion(keys: String) {
    let typing = Typing(zenzai: true)
    typing.type(keys)
    #expect(typing.pauses.pause())
    let shown = typing.host.markedText
    #expect(typing.session.handle(space))
    #expect(typing.host.markedText == shown)
    #expect(typing.session.handle(enter()))
    #expect(typing.host.inserted == [shown])
}

/// Sentences whose rest was converted again at each → before it kept what Space showed (云った for いった, 大いばり)
private let clauseSentences = ["yagatehigakurekakaruto,souhamataitta.", "inuha,shippowofutte,ooibariniibarimashita.", "matsukurajuunaihaazentonatta."]

@MainActor
@Test("→ で文節を移っても、表示はそのままで、Enter はそれを確定する", .enabled(if: models.hasZenzai), arguments: sentences + clauseSentences)
func movingClausesKeepsWhatIsShown(keys: String) {
    let typing = Typing(zenzai: true)
    typing.type(keys)
    typing.pauses.pause()
    #expect(typing.session.handle(space))
    let shown = typing.host.markedText
    for _ in 0 ..< 20 {
        _ = typing.session.handle(KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 124))
        #expect(typing.host.markedText == shown)
    }
    #expect(typing.session.handle(enter()))
    #expect(typing.host.inserted == [shown])
}

/// Inputs whose first clause is made shorter with Shift+← before → (the clause ending inside テレビ or 映画, where the rest
/// shows what is left of the word as read), and one with a Latin word, whose candidates count keys
private let editedClauses: [(keys: String, shorter: Int)] = [("terebiwomiru", 2), ("eigawomita", 2), ("kyouhaiitenkidesune", 2), ("tatoebawindowstokakebauindouzuninaranaidesu", 0)]

@MainActor
@Test("文節の区切りを語の途中に動かしたあとや英字の語があるときも、→ で表示は変わらない", .enabled(if: models.hasZenzai), arguments: editedClauses)
func movingClausesAfterEditingKeepsWhatIsShown(input: (keys: String, shorter: Int)) {
    let typing = Typing(zenzai: true)
    typing.type(input.keys)
    typing.pauses.pause()
    #expect(typing.session.handle(space))
    for _ in 0 ..< input.shorter {
        _ = typing.session.handle(KeyEventCore(modifierFlags: [.shift], characters: nil, charactersIgnoringModifiers: nil, keyCode: 123))
    }
    let shown = typing.host.markedText
    for _ in 0 ..< 20 {
        _ = typing.session.handle(KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 124))
        #expect(typing.host.markedText == shown)
    }
    #expect(typing.session.handle(enter()))
    #expect(typing.host.inserted == [shown])
}

@MainActor
@Test("徹底変換を表示したあとも、次のキーは打鍵中の変換から続く", .enabled(if: models.hasZenzai), arguments: sentences)
func keyAfterPauseGoesOnFromConversionWhileTyping(keys: String) {
    // The same keys typed with a pause before the last one, and without: the thorough conversion is made in copies of
    // the converter's sessions, so the last key converts as if there had been no pause
    let paused = Typing(zenzai: true)
    paused.type(String(keys.dropLast()))
    paused.pauses.pause()
    paused.type(String(keys.suffix(1)))
    let straight = Typing(zenzai: true)
    straight.type(keys)
    #expect(paused.host.markedText == straight.host.markedText)
}

@MainActor
@Test("次のキー、確定、読みの表示で、止まるのを待つ徹底変換は取り消される", .enabled(if: models.hasZenzai))
func pendingThoroughConversionIsCancelled() {
    let typing = Typing(zenzai: true)
    typing.type("kyouhaiitenki")
    #expect(typing.session.handle(enter()))
    #expect(!typing.pauses.pause())
    // The reading shown after a delete is not converted
    typing.type("kyouhaiitenki")
    #expect(typing.session.handle(backspace))
    #expect(!typing.pauses.pause())
    // A key typed after the pause was scheduled schedules it again, for the input as it then is
    typing.type("desu")
    #expect(typing.pauses.pause())
    let shown = typing.host.markedText
    #expect(typing.session.handle(enter()))
    #expect(typing.host.inserted.last == shown)
}

@MainActor
@Test("Zenzai を使わないときは、打鍵が止まっても何も走らない")
func nothingRunsAtPauseWithoutZenzai() {
    let typing = Typing(zenzai: false)
    typing.type("kyouhaiitenkidesune")
    let shown = typing.host.markedText
    #expect(!typing.pauses.pause())
    #expect(typing.session.handle(enter()))
    #expect(typing.host.inserted == [shown])
}
