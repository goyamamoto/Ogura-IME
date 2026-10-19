import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

/// Clause editing needs Zenzai: only Zenzai converts up to the cursor that Shift+← / → moves. These tests run when the
/// Zenzai weights are in the repository (not an LFS pointer).
private let resourcesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Ogura/Resources/gguf", isDirectory: true)
private let hasZenzaiWeights = ((try? FileManager.default.attributesOfItem(
    atPath: resourcesDirectory.appendingPathComponent("ggml-model-Q5_K_M.gguf").path
)[.size] as? Int) ?? 0) > 1_000_000

@MainActor
private final class RecordingHost: InputSessionHost {
    var inserted: [String] = []
    var markedText = ""
    /// The clause being converted, and what is left after it
    var focused = ""
    var rest = ""
    func insertText(_ text: String) { self.inserted.append(text) }
    func updateMarkedText(_ markedText: SegmentsManager.MarkedText) {
        self.markedText = markedText.map(\.content).joined()
        self.focused = markedText.filter { $0.focus == .focused }.map(\.content).joined()
        self.rest = markedText.filter { $0.focus == .unfocused }.map(\.content).joined()
    }
    func switchInputMode(_ language: InputLanguage) {}
    func candidateRow(forNumberKey number: Int) -> Int { number - 1 }
    func leftSideContext(maxCount: Int) -> String? { "" }
    func rightSideContext(maxCount: Int) -> String? { nil }
}

@MainActor
@Test("英字の範囲を誤ったときは、文節を縮めて F10 で英字にすれば直せる", .enabled(if: hasZenzaiWeights))
func clauseEditFixesLatinRange() {
    let manager = SegmentsManager(
        kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
        applicationDirectoryURL: testLearningDirectory,
        personalizationDirectoryURL: nil,
        context: .init(useZenzai: true, resourcesDirectoryURL: resourcesDirectory, liveConversionEnabled: true)
    )
    let session = InputSession(segmentsManager: manager, settingsProvider: {
        InputSession.Settings(liveConversionEnabled: true, keyBindingStyle: .msIME, inputStyle: .mapped(id: .defaultRomanToKana))
    })
    let host = RecordingHost()
    session.host = host
    func key(_ code: UInt16, _ modifiers: KeyEventCore.ModifierFlag = []) -> KeyEventCore {
        KeyEventCore(modifierFlags: modifiers, characters: nil, charactersIgnoringModifiers: nil, keyCode: code)
    }
    for character in "Apocalypsehoterutoiueigagaarimasu" {
        let text = String(character)
        _ = session.handle(KeyEventCore(modifierFlags: character.isUppercase ? [.shift] : [], characters: text, charactersIgnoringModifiers: text.lowercased(), keyCode: 0))
    }
    #expect(session.handle(KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49)))
    // Move the end of the first clause until it ends after Apocalypse (…ぷせ|ほてる…): longer while more is left after
    // it, shorter while less is
    let rest = "ほてるというえいががあります"
    for _ in 0 ..< 30 where host.rest != rest {
        #expect(session.handle(key(host.rest.count > rest.count ? 124 : 123, [.shift])))
    }
    #expect(host.rest == rest, "\(host.focused)|\(host.rest)")
    #expect(session.handle(key(109)))  // F10
    #expect(host.inserted == ["Apocalypse"])
    #expect(session.handle(KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 0x24)))
    #expect(host.inserted.joined() == "Apocalypseホテルという映画があります")
}

@MainActor
@Test("学習版でも、文節を縮めると英字の語の中で区切れる", .enabled(if: hasZenzaiWeights))
func clauseEditShrinksIntoLatinWordWithLearnedIdentification() {
    let manager = SegmentsManager(
        kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
        applicationDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("ogura-clause-\(UUID().uuidString)", isDirectory: true),
        personalizationDirectoryURL: nil,
        context: .init(
            useZenzai: true,
            resourcesDirectoryURL: resourcesDirectory,
            liveConversionEnabled: true,
            learnedScriptIdentification: true,
            scriptModelDirectoryURL: resourcesDirectory.deletingLastPathComponent().appendingPathComponent("ScriptModel", isDirectory: true)
        )
    )
    let session = InputSession(segmentsManager: manager, settingsProvider: {
        InputSession.Settings(liveConversionEnabled: true, keyBindingStyle: .msIME, inputStyle: .mapped(id: .defaultRomanToKana))
    })
    let host = RecordingHost()
    session.host = host
    for character in "Sakehasakedesu" {
        let text = String(character)
        _ = session.handle(KeyEventCore(modifierFlags: character.isUppercase ? [.shift] : [], characters: text, charactersIgnoringModifiers: text.lowercased(), keyCode: 0))
    }
    #expect(host.markedText == "Sakeは酒です")
    #expect(session.handle(KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49)))
    // Shrink the first clause to Sake, then into it: each step keeps the clause end, even inside the Latin word, whose
    // letters stay letters on each side
    let shrink = KeyEventCore(modifierFlags: [.shift], characters: nil, charactersIgnoringModifiers: nil, keyCode: 123)
    for _ in 0 ..< 10 where host.focused != "Sake" {
        #expect(session.handle(shrink))
    }
    #expect(host.focused + "|" + host.rest == "Sake|はさけです")
    #expect(session.handle(shrink))
    #expect(host.focused + "|" + host.rest == "Sa|keはさけです")
}

/// A session converting with Zenzai and live conversion, with the rules for Latin words or the bundled model
@MainActor
private func makeSession(learned: Bool = false) -> (InputSession, RecordingHost) {
    let manager = SegmentsManager(
        kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
        applicationDirectoryURL: testLearningDirectory,
        personalizationDirectoryURL: nil,
        context: .init(
            useZenzai: true,
            resourcesDirectoryURL: resourcesDirectory,
            liveConversionEnabled: true,
            learnedScriptIdentification: learned,
            scriptModelDirectoryURL: resourcesDirectory.deletingLastPathComponent().appendingPathComponent("ScriptModel", isDirectory: true)
        )
    )
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

@MainActor
@Test("Zenzai の変換を退けた文でも、文節を縮められる", .enabled(if: hasZenzaiWeights))
func clauseShrinksWhenZenzaiConversionIsReplaced() {
    // Zenzai writes Windows for ウインドウズ typed as uindouzu, so the converter on its own converts in its place; it too
    // converts only up to the end of the clause, or the clause would stay the whole input
    let (session, host) = makeSession()
    type("tatoebawindowstokakebauindouzuninaranaidesu", into: session)
    for _ in 0 ..< 4 {
        #expect(session.handle(KeyEventCore(modifierFlags: [.shift], characters: nil, charactersIgnoringModifiers: nil, keyCode: 123)))
    }
    #expect(host.focused == "例えばwindowsと書けばウインドウズになら", "\(host.focused)|\(host.rest)")
    #expect(host.rest == "ないです")
    #expect(session.handle(KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 0x24)))
    #expect(host.inserted.joined() == "例えばwindowsと書けばウインドウズにならないです")
}

@MainActor
@Test("変換中の文節の後ろに残る英単語は、打った英字のまま見せる（うぃんどws ではなく windows）", .enabled(if: hasZenzaiWeights))
func latinWordAfterTheClauseShowsAsTyped() {
    let (session, host) = makeSession()
    type("korehawindowsdesu", into: session)
    #expect(session.handle(KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49)))
    #expect(host.focused == "これは", "\(host.focused)|\(host.rest)")
    #expect(host.rest == "windowsです")
}

@MainActor
@Test("英単語の中で文節を区切っても、両側は打った英字のまま（win|dows）", .enabled(if: hasZenzaiWeights))
func clauseEndInsideLatinWordKeepsLettersOnBothSides() {
    for learned in [false, true] {
        let (session, host) = makeSession(learned: learned)
        type("korehawindowsdesu", into: session)
        #expect(session.handle(KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49)))
        var shown: [String] = []
        for _ in 0 ..< 3 {
            #expect(session.handle(KeyEventCore(modifierFlags: [.shift], characters: nil, charactersIgnoringModifiers: nil, keyCode: 124)))
            shown.append(host.focused + "|" + host.rest)
        }
        // The n of win is a letter of the word, not ん
        #expect(shown == ["これはw|indowsです", "これはwi|ndowsです", "これはwin|dowsです"], "\(learned ? "learned" : "rules"): \(shown)")
    }
}

@MainActor
@Test("英単語のある文でも、→ で文節を一つずつ確定できる（最後まで一度に確定しない）", .enabled(if: hasZenzaiWeights))
func clausesAfterLatinWordCommitOneByOne() {
    // The converter reads windows as a word for each letter, so its own first clause of what is left (windowsと…) ends
    // after w; the first clause takes the word whole instead of the whole input
    for learned in [false, true] {
        let (session, host) = makeSession(learned: learned)
        type("tatoebawindowstokakebauindouzuninaranaidesu", into: session)
        #expect(session.handle(KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49)))
        var focused = [host.focused]
        for _ in 0 ..< 2 {
            #expect(session.handle(KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 124)))
            focused.append(host.focused)
        }
        #expect(focused == ["例えば", "windowsと", "書けば"], "\(learned ? "learned" : "rules"): \(focused)")
        #expect(host.inserted.joined() == "例えばwindowsと", "\(host.inserted)")
    }
}

@MainActor
@Test("→ で確定するのは文節一つずつで、最後から二番目の文節を確定しても最後の文節は残る", .enabled(if: hasZenzaiWeights))
func secondToLastClauseCommitsAlone() {
    // The converter's own first clauses are longest first, and its entries can be phrases (に行き): the first clause is
    // the best conversion's, cut into words
    let (session, host) = makeSession()
    type("watashihaashitatoukyouniikimasu", into: session)
    #expect(session.handle(KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49)))
    var focused = [host.focused]
    for _ in 0 ..< 3 {
        #expect(session.handle(KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 124)))
        focused.append(host.focused)
    }
    #expect(focused == ["私は", "明日", "東京に", "行きます"], "\(focused)")
    #expect(host.inserted.joined() == "私は明日東京に")
}
