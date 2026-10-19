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
    /// The clauses before the one being converted, the clause being converted, and what is left after it
    var before = ""
    var focused = ""
    var rest = ""
    func insertText(_ text: String) { self.inserted.append(text) }
    var selectionRange = NSRange(location: NSNotFound, length: 0)
    /// The text shown with the caret inside the reading as |, at the end when the caret is not shown
    var withCaret: String {
        guard self.selectionRange.location != NSNotFound else {
            return self.markedText + "|"
        }
        let text = Array(self.markedText)
        return String(text.prefix(self.selectionRange.location)) + "|" + String(text.dropFirst(self.selectionRange.location))
    }
    func updateMarkedText(_ markedText: SegmentsManager.MarkedText) {
        self.markedText = markedText.map(\.content).joined()
        self.selectionRange = markedText.selectionRange
        let parts = Array(markedText)
        let focusedIndex = parts.firstIndex { $0.focus == .focused }
        self.before = parts.prefix(focusedIndex ?? 0).map(\.content).joined()
        self.focused = focusedIndex.map { parts[$0].content } ?? ""
        self.rest = focusedIndex.map { parts.dropFirst($0 + 1).map(\.content).joined() } ?? ""
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
        applicationDirectoryURL: freshTestLearningDirectory(),
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
    // Move the end of the first clause until it ends after Apocalypse (…ぷせ|ほてる…): shorter while it takes kana
    // after the word, longer while it is shorter than the word. The rest shows converted, from the conversion of
    // the whole input
    let rest = "ホテルという映画があります"
    for _ in 0 ..< 30 where host.rest != rest {
        #expect(session.handle(key(host.focused.allSatisfy(\.isASCII) ? 124 : 123, [.shift])))
    }
    #expect(host.rest == rest, "\(host.focused)|\(host.rest)")
    // F10 makes the clause the letters as typed, without committing (MS-IME); Enter commits it with the rest
    #expect(session.handle(key(109)))  // F10
    #expect(host.focused + "|" + host.rest == "Apocalypse|" + rest, "\(host.focused)|\(host.rest)")
    #expect(host.inserted.isEmpty, "\(host.inserted)")
    #expect(session.handle(KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 0x24)))
    #expect(host.inserted == ["Apocalypseホテルという映画があります"])
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
    #expect(host.focused + "|" + host.rest == "Sake|は酒です")
    #expect(session.handle(shrink))
    #expect(host.focused + "|" + host.rest == "Sak|eは酒です")
}

@MainActor
@Test("英字の語の終わりが打ったままの読みのかなの区切りと違っても、Shift+← は語の終わりで止まり、語の中へ一字ずつ戻れる（Yamamotosan|に）", .enabled(if: hasZenzaiWeights))
func clauseEndMovesIntoALatinWordWhoseEndIsNoKanaBoundary() {
    // As typed, sanni reads さんい (nn is ん), so the end of the word is inside a kana; the converter reads にあいます after
    // the word, and the end moves by its kana
    let (session, host) = makeSession(learned: true)
    type("kyouhaYamamotosanniaimasu", into: session)
    #expect(host.markedText == "今日はYamamotosanに会います")
    let shrink = KeyEventCore(modifierFlags: [.shift], characters: nil, charactersIgnoringModifiers: nil, keyCode: 123)
    let extend = KeyEventCore(modifierFlags: [.shift], characters: nil, charactersIgnoringModifiers: nil, keyCode: 124)
    var seen: [String] = []
    for _ in 0 ..< 10 where host.focused != "今日はYamamotosa" {
        #expect(session.handle(shrink))
        seen.append(host.focused + "|" + host.rest)
    }
    #expect(seen.suffix(3) == ["今日はYamamotosanに|会います", "今日はYamamotosan|に会います", "今日はYamamotosa|nに会います"], "\(seen)")
    #expect(session.handle(extend))
    #expect(host.focused + "|" + host.rest == "今日はYamamotosan|に会います")
    #expect(session.handle(extend))
    #expect(host.focused + "|" + host.rest == "今日はYamamotosanに|会います")
}

/// A session converting with Zenzai and live conversion, with the rules for Latin words or the bundled model
@MainActor
private func makeSession(learned: Bool = false) -> (InputSession, RecordingHost) {
    let manager = SegmentsManager(
        kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
        applicationDirectoryURL: freshTestLearningDirectory(),
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
@Test("英単語のある文でも、→ で文節を一つずつ移れる（最後まで一度に飛ばず、確定もしない）", .enabled(if: hasZenzaiWeights))
func clausesAfterLatinWordMoveOneByOne() {
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
        #expect(host.before == "例えばwindowsと", "\(host.before)|\(host.focused)|\(host.rest)")
        #expect(host.inserted.isEmpty, "\(host.inserted)")
        // Enter commits the clauses as shown
        let shown = host.markedText
        #expect(session.handle(KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 0x24)))
        #expect(host.inserted.joined() == shown, "\(host.inserted)")
    }
}

@MainActor
@Test("→ で文節を一つずつ移り、最後の文節で止まる。← で戻れ、Enter で全部確定する", .enabled(if: hasZenzaiWeights))
func clausesMoveOneByOne() {
    // The converter's own first clauses are longest first, and its entries can be phrases (に行き): the first clause is
    // the best conversion's, cut into words
    let (session, host) = makeSession()
    type("watashihaashitatoukyouniikimasu", into: session)
    #expect(session.handle(KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49)))
    #expect(host.focused + "|" + host.rest == "私は|明日東京に行きます")
    var focused = [host.focused]
    let right = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 124)
    for _ in 0 ..< 4 {
        #expect(session.handle(right))
        focused.append(host.focused)
    }
    // The fourth → has no clause to go to
    #expect(focused == ["私は", "明日", "東京に", "行きます", "行きます"], "\(focused)")
    #expect(host.before == "私は明日東京に")
    #expect(host.inserted.isEmpty, "\(host.inserted)")
    #expect(session.handle(KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 123)))
    #expect(host.before + "|" + host.focused + "|" + host.rest == "私は明日|東京に|行きます")
    #expect(session.handle(KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 0x24)))
    #expect(host.inserted == ["私は明日東京に行きます"])
}

@MainActor
@Test("文節を区切り直しても、候補は文節のものだけで、入力全体のカタカナ・ひらがなは混ざらない。残りは変換したまま見せる", .enabled(if: hasZenzaiWeights))
func clauseCandidatesStayWithinTheClause() {
    // The converter adds the kana forms of the whole input to its candidates: with them listed for the clause, Space
    // turned the whole input into katakana
    let (session, host) = makeSession()
    type("kyouhaiitenkidesune", into: session)
    #expect(session.handle(KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49)))
    #expect(host.focused + "|" + host.rest == "今日は|いい天気ですね")
    #expect(session.handle(KeyEventCore(modifierFlags: [.shift], characters: nil, charactersIgnoringModifiers: nil, keyCode: 123)))
    #expect(host.focused + "|" + host.rest == "今日|はいい天気ですね", "\(host.focused)|\(host.rest)")
    guard case .selecting(let candidates, _) = session.candidateWindow else {
        Issue.record("The candidates should show after the clause is shortened")
        return
    }
    let texts = candidates.map(\.text)
    #expect(!texts.contains("キョウハイイテンキデスネ"), "\(texts)")
    #expect(!texts.contains("きょうはいいてんきですね"), "\(texts)")
    #expect(texts.allSatisfy { $0.count <= "きょう".count }, "\(texts)")
    // Space moves within the clause's candidates, and → keeps everything in the input
    let space = KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49)
    #expect(session.handle(space))
    #expect(host.focused.count <= "きょう".count, "\(host.focused)|\(host.rest)")
    #expect(host.rest == "はいい天気ですね", "\(host.focused)|\(host.rest)")
    #expect(session.handle(KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 124)))
    #expect(host.inserted.isEmpty, "\(host.inserted)")
    #expect(host.markedText.count > "きょう".count, host.markedText.isEmpty ? "empty" : "\(host.before)|\(host.focused)|\(host.rest)")
}

@MainActor
@Test("入力の残りをそのまま英字にした候補は、文節の候補に混ざらない", .enabled(if: hasZenzaiWeights))
func typedLettersOfTheWholeInputStayOutOfClauseCandidates() {
    // The letters as typed are offered for input that may not be Japanese (korehawindowsdesu); they are for the whole
    // input, so a clause of it does not list them
    let (session, host) = makeSession()
    type("tatoebawindowstokakebauindouzuninaranaidesu", into: session)
    #expect(session.handle(KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49)))
    #expect(session.handle(KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 124)))
    #expect(host.focused == "windowsと", "\(host.before)|\(host.focused)|\(host.rest)")
    guard case .selecting(let candidates, _) = session.candidateWindow else {
        Issue.record("The candidates should show for the clause")
        return
    }
    let texts = candidates.map(\.text)
    #expect(!texts.contains("windowstokakebauindouzuninaranaidesu"), "\(texts)")
    #expect(texts.allSatisfy { $0.count <= "windowsと".count }, "\(texts)")
}

@MainActor
@Test("読みの中のカーソル（←）は、大文字で始まる英字の語の手前で止まらず語の中を一字ずつ進み、打ち足しと削除はその位置に入る（Yamamotosan）", .enabled(if: hasZenzaiWeights))
func readingCaretPassesThroughACapitalizedWord() {
    let (session, host) = makeSession(learned: true)
    type("kyouhaYamamotosanniaimasu", into: session)
    #expect(host.markedText == "今日はYamamotosanに会います")
    let left = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 123)
    let backspace = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 51)
    // ← goes back to the reading, which keeps the word as typed, and moves the caret by its characters: into the word
    // letter by letter, although as typed its last n and the n of ni make one ん
    var seen: [String] = []
    for _ in 0 ..< 8 {
        #expect(session.handle(left))
        seen.append(host.withCaret)
    }
    #expect(seen == [
        "きょうはYamamotosanにあいま|す", "きょうはYamamotosanにあい|ます", "きょうはYamamotosanにあ|います", "きょうはYamamotosanに|あいます",
        "きょうはYamamotosan|にあいます", "きょうはYamamotosa|nにあいます", "きょうはYamamotos|anにあいます", "きょうはYamamoto|sanにあいます"
    ])
    // What is typed goes in at the caret, and Backspace takes the letter before it
    type("ne", into: session)
    #expect(host.withCaret == "きょうはYamamotone|さんいあいます")
    #expect(session.handle(backspace))
    #expect(session.handle(backspace))
    #expect(host.withCaret == "きょうはYamamoto|さんいあいます")
    #expect(session.handle(backspace))
    #expect(host.withCaret == "きょうはYamamot|さんいあいます")
}
