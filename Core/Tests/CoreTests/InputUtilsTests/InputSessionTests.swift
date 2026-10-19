import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

/// Tests the whole path from key input to committed text, without going through IMK.
@MainActor
@Suite("InputSession")
struct InputSessionTests {
    /// Host that only records the operations the session performs on it.
    final class RecordingHost: InputSessionHost {
        var inserted: [String] = []
        var markedText: String = ""
        var inputModes: [InputLanguage] = []
        /// Text that leftSideContext returns (nil means no context).
        var leftContext: String?
        /// Record of the maxCount values passed to leftSideContext.
        var requestedLeftCounts: [Int] = []
        /// Mimics apps that include the marked text (including the faint suggestion text) in the left context they return.
        var includesMarkedTextInContext = false

        func insertText(_ text: String) {
            self.inserted.append(text)
        }
        func updateMarkedText(_ markedText: SegmentsManager.MarkedText) {
            self.markedText = markedText.map(\.content).joined()
            self.selectionRange = markedText.selectionRange
        }
        var selectionRange = NSRange(location: NSNotFound, length: 0)
        func switchInputMode(_ language: InputLanguage) {
            self.inputModes.append(language)
        }
        func candidateRow(forNumberKey number: Int) -> Int {
            number - 1
        }
        func leftSideContext(maxCount: Int) -> String? {
            self.requestedLeftCounts.append(maxCount)
            guard let leftContext else {
                return nil
            }
            let text = leftContext + (self.includesMarkedTextInContext ? self.markedText : "")
            return String(text.suffix(maxCount))
        }
        func rightSideContext(maxCount: Int) -> String? {
            nil
        }
    }

    /// Host that replaces marked text and inserts into the document with the same rules as an ordinary app (NSTextView).
    /// setMarkedText replaces the marked range if there is one; otherwise it inserts at the caret. insertText replaces the marked range and commits it.
    /// It checks the document itself, to catch bugs such as doubled text or faint suggestion text left in the document.
    final class StrictHost: InputSessionHost {
        private(set) var document: [Character]
        private(set) var caret: Int
        private(set) var marked: Range<Int>?
        /// Order of calls to the host ("insertText:…" / "setMarkedText:…").
        var calls: [String] = []
        var text: String { String(self.document) }
        var markedText: String { self.marked.map { String(self.document[$0]) } ?? "" }

        init(document: String) {
            self.document = Array(document)
            self.caret = self.document.count
        }
        private func replace(_ range: Range<Int>, with text: String) -> Range<Int> {
            self.document.replaceSubrange(range, with: Array(text))
            return range.lowerBound ..< range.lowerBound + text.count
        }
        func insertText(_ text: String) {
            self.calls.append("insertText:" + text)
            let placed = self.replace(self.marked ?? (self.caret ..< self.caret), with: text)
            self.marked = nil
            self.caret = placed.upperBound
        }
        func updateMarkedText(_ markedText: SegmentsManager.MarkedText) {
            let text = markedText.map(\.content).joined()
            self.calls.append("setMarkedText:" + text)
            let placed = self.replace(self.marked ?? (self.caret ..< self.caret), with: text)
            self.marked = text.isEmpty ? nil : placed
            self.caret = placed.upperBound
        }
        func switchInputMode(_ language: InputLanguage) {}
        func candidateRow(forNumberKey number: Int) -> Int {
            number - 1
        }
        func leftSideContext(maxCount: Int) -> String? {
            // Up to the start of the marked range if there is one, otherwise up to the caret (same as OguraInputController).
            let end = self.marked?.lowerBound ?? self.caret
            return String(self.document[max(0, end - maxCount) ..< end])
        }
        func rightSideContext(maxCount: Int) -> String? {
            nil
        }
    }

    /// Host that answers context reads from a copy of the document it takes once per frame (`drawFrame`), as WordCraft does.
    /// The copy holds the marked text (the faint suggestion text too) with the caret after it, so a read right after
    /// a change, before the next frame, still sees the old suggestion.
    final class FrameLaggingHost: InputSessionHost {
        let document: StrictHost
        private var frame: String

        init(document: String) {
            self.document = StrictHost(document: document)
            self.frame = document
        }
        func drawFrame() {
            self.frame = self.document.text
        }
        func insertText(_ text: String) {
            self.document.insertText(text)
        }
        func updateMarkedText(_ markedText: SegmentsManager.MarkedText) {
            self.document.updateMarkedText(markedText)
        }
        func switchInputMode(_ language: InputLanguage) {}
        func candidateRow(forNumberKey number: Int) -> Int {
            number - 1
        }
        func leftSideContext(maxCount: Int) -> String? {
            String(self.frame.suffix(maxCount))
        }
        func rightSideContext(maxCount: Int) -> String? {
            nil
        }
    }

    private static let converter = KanaKanjiConverter.withDefaultDictionary()

    private func makeSession(
        keyBindingStyle: Config.KeyBindingStyle.Value = .msIME,
        liveConversion: Bool = false,
        typeHalfWidthSymbols: Bool = false,
        now: @escaping @MainActor () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) -> (InputSession, RecordingHost) {
        let manager = SegmentsManager(
            kanaKanjiConverter: Self.converter,
            applicationDirectoryURL: freshTestLearningDirectory(),
            personalizationDirectoryURL: nil,
            context: .init(useZenzai: false, liveConversionEnabled: liveConversion)
        )
        // The converter is shared for speed: each session starts with nothing learned, whatever earlier tests committed
        manager.resetLearningData()
        let settings = InputSession.Settings(
            liveConversionEnabled: liveConversion,
            keyBindingStyle: keyBindingStyle,
            inputStyle: .mapped(id: .defaultRomanToKana),
            typeHalfWidthSymbols: typeHalfWidthSymbols
        )
        let session = InputSession(segmentsManager: manager, settingsProvider: { settings }, now: now)
        let host = RecordingHost()
        session.host = host
        return (session, host)
    }

    private func key(_ character: Character) -> KeyEventCore {
        let string = String(character)
        return KeyEventCore(modifierFlags: character.isUppercase ? [.shift] : [], characters: string, charactersIgnoringModifiers: string.lowercased(), keyCode: 0)
    }
    private func keyCode(_ code: UInt16, modifiers: KeyEventCore.ModifierFlag = []) -> KeyEventCore {
        KeyEventCore(modifierFlags: modifiers, characters: nil, charactersIgnoringModifiers: nil, keyCode: code)
    }
    private let space = KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49)
    private let enter = KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 0x24)
    private let backspace = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 51)
    private let escape = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 53)

    private func type(_ text: String, into session: InputSession) {
        for character in text {
            #expect(session.handle(self.key(character)))
        }
    }

    @Test("ローマ字入力が未確定文字列になり、Enter でひらがなのまま確定する")
    func typingAndCommit() {
        let (session, host) = self.makeSession()
        self.type("nihongo", into: session)
        #expect(host.markedText == "にほんご")
        #expect(session.inputState == .composing)
        #expect(session.handle(self.enter))
        #expect(host.inserted == ["にほんご"])
        #expect(host.markedText.isEmpty)
        #expect(session.inputState == .none)
    }

    @Test("変換中の F10 は、選んでいる文節だけを英字にする（MS-IME と同じ）。macOS 標準ではその文節を確定する")
    func f10ConvertsSelectedClauseToLatin() {
        let (session, host) = self.makeSession(liveConversion: true)
        self.type("korehaWindowsdesu", into: session)
        #expect(session.handle(self.space))
        #expect(session.handle(self.keyCode(109)))
        #expect(host.markedText == "korehaWindowsです")
        #expect(host.inserted.isEmpty, "\(host.inserted)")
        #expect(session.handle(self.enter))
        #expect(host.inserted == ["korehaWindowsです"])

        let (macSession, macHost) = self.makeSession(keyBindingStyle: .macOS, liveConversion: true)
        self.type("korehaWindowsdesu", into: macSession)
        #expect(macSession.handle(self.space))
        #expect(macSession.handle(self.keyCode(109)))
        #expect(macHost.inserted == ["koreha"])
        #expect(macSession.handle(self.enter))
        #expect(macHost.inserted.joined() == "korehaWindowsです")
    }

    @Test("BackSpace の後も英字の語は英字のまま表示し、1文字ずつ消す")
    func backspaceKeepsLatinWords() {
        let (session, host) = self.makeSession(liveConversion: true)
        self.type("korehaWindowsdesu", into: session)
        #expect(session.handle(self.backspace))
        #expect(host.markedText == "これはWindowsで")
        #expect(session.handle(self.backspace))
        #expect(host.markedText == "これはWindows")
        #expect(session.handle(self.backspace))
        #expect(host.markedText == "これはWindow")

        // le made ぇ in Apple, but a Latin word loses one letter at a time
        let (appleSession, appleHost) = self.makeSession(liveConversion: true)
        self.type("Apple", into: appleSession)
        #expect(appleSession.handle(self.backspace))
        #expect(appleHost.markedText == "Appl")
        #expect(appleSession.handle(self.enter))
        #expect(appleHost.inserted == ["Appl"])
    }

    @Test("末尾の n は、そのまま Enter で確定しても「ん」になる（MS-IME と同じ）")
    func trailingNBecomesNWhenCommitted() {
        // Without live conversion, the kana as typed
        let (session, host) = self.makeSession()
        self.type("sumimasen", into: session)
        #expect(host.markedText == "すみませn")
        #expect(session.handle(self.enter))
        #expect(host.inserted == ["すみません"])

        // With live conversion, the conversion
        let (liveSession, liveHost) = self.makeSession(liveConversion: true)
        self.type("ugokimasen", into: liveSession)
        #expect(liveSession.handle(self.enter))
        #expect(liveHost.inserted == ["動きません"])

        // kaizen is also an English word, but its n becomes ん when the input ends, so it does not count as a letter
        // left over: committing with Enter or after Space keeps it Japanese
        let (enterSession, enterHost) = self.makeSession(liveConversion: true)
        self.type("UInokaizen", into: enterSession)
        #expect(enterSession.handle(self.enter))
        #expect(enterHost.inserted == ["UIの改善"])
        let (spaceSession, spaceHost) = self.makeSession(liveConversion: true)
        self.type("UInokaizen", into: spaceSession)
        #expect(spaceSession.handle(self.space))
        #expect(spaceSession.handle(self.enter))
        #expect(spaceHost.inserted.joined() == "UIの改善")
    }

    @Test("Space で変換し、Enter で候補を確定する")
    func convertAndCommit() {
        let (session, host) = self.makeSession()
        self.type("kyouhaiitenki", into: session)
        // With live conversion off, the first Space previews the top candidate and the second shows the candidate list.
        #expect(session.handle(self.space))
        #expect(session.inputState == .previewing)
        #expect(host.markedText != "きょうはいいてんき")
        #expect(session.handle(self.space))
        #expect(session.inputState == .selecting)
        guard case .selecting(let candidates, let selectionIndex) = session.candidateWindow else {
            Issue.record("candidate window should be shown")
            return
        }
        #expect(!candidates.isEmpty)
        #expect(selectionIndex == 0)
        #expect(session.handle(self.enter))
        #expect(host.inserted.count >= 1)
        #expect(host.inserted.joined().contains("今日"))
        #expect(host.markedText.isEmpty)
        #expect(session.inputState == .none)
    }

    @Test("日本語らしくない入力は、最初の Space で打った英字のまま表示し、Enter でそのまま確定する")
    func latinInputPreviewAndCommit() {
        for liveConversion in [false, true] {
            let (session, host) = self.makeSession(liveConversion: liveConversion)
            self.type("windows", into: session)
            #expect(session.handle(self.space))
            #expect(host.markedText == "windows")
            #expect(session.handle(self.enter))
            #expect(host.inserted == ["windows"])
        }
    }

    @Test("文の途中の英単語や大文字で始まる語は英字のまま変換する（butahapigdesu → 豚はpigです）")
    func latinWordInsideJapanese() {
        // Live conversion: Enter commits what is shown
        let (session, host) = self.makeSession(liveConversion: true)
        self.type("butahapigdesu", into: session)
        #expect(host.markedText == "豚はpigです")
        #expect(session.handle(self.enter))
        #expect(host.inserted == ["豚はpigです"])

        // Space shows the first clause; Enter commits it and the rest together (MS-IME)
        let (spaceSession, spaceHost) = self.makeSession(liveConversion: true)
        self.type("butahapigdesu", into: spaceSession)
        #expect(spaceSession.handle(self.space))
        #expect(spaceSession.handle(self.enter))
        #expect(spaceHost.inserted.joined() == "豚はpigです")

        // A word typed with a capital stays as typed even when it is not a known word, both live and after Space and Enter
        for (keys, expected) in [("korehaOguradesu", "これはOguraです"), ("watasihaiPadwotukau", "私はiPadを使う"), ("korehaMacdehaugokanai", "これはMacでは動かない")] {
            let (liveSession, liveHost) = self.makeSession(liveConversion: true)
            self.type(keys, into: liveSession)
            #expect(liveHost.markedText == expected)
            let (capitalSession, capitalHost) = self.makeSession(liveConversion: true)
            self.type(keys, into: capitalSession)
            #expect(capitalSession.handle(self.space))
            #expect(capitalSession.handle(self.enter))
            #expect(capitalHost.inserted.joined() == expected)
        }

        // Japanese that is also English (sake) stays Japanese
        let (japaneseSession, japaneseHost) = self.makeSession(liveConversion: true)
        self.type("osakewonomu", into: japaneseSession)
        #expect(japaneseHost.markedText == "お酒を飲む")
    }

    @Test("MS-IME: 変換中の BackSpace でひらがなに戻る")
    func backspaceCancelsConversion() {
        let (session, host) = self.makeSession(keyBindingStyle: .msIME)
        self.type("kyouha", into: session)
        #expect(session.handle(self.space))
        #expect(host.markedText != "きょうは")
        #expect(session.handle(self.backspace))
        #expect(session.inputState == .composing)
        #expect(host.markedText == "きょうは")
        #expect(host.inserted.isEmpty)
    }

    @Test("macOS 標準: 変換中の BackSpace は1文字削除する")
    func backspaceDeletesInMacOSStyle() {
        let (session, host) = self.makeSession(keyBindingStyle: .macOS)
        self.type("kyouha", into: session)
        #expect(session.handle(self.space))
        #expect(session.handle(self.backspace))
        #expect(host.markedText == "きょう")
    }

    @Test("Esc で入力を全消去し、アプリには渡さない")
    func escapeClearsComposition() {
        let (session, host) = self.makeSession()
        self.type("aiueo", into: session)
        #expect(session.handle(self.escape))
        #expect(host.markedText.isEmpty)
        #expect(session.inputState == .none)
        // Esc with no input is passed to the app.
        #expect(!session.handle(self.escape))
    }

    @Test("ライブ変換で変換されて見える入力の Esc は、ひらがなに戻して打ち続けられるようにし、もう一度押すと消す")
    func escapeShowsReadingBeforeClearing() {
        let (session, host) = self.makeSession(liveConversion: true)
        self.type("kyouhaiitenkidesu", into: session)
        #expect(host.markedText == "今日はいい天気です")
        #expect(session.handle(self.escape))
        #expect(host.markedText == "きょうはいいてんきです")
        #expect(session.inputState == .composing)
        // Typing goes on at the reading (MS-IME: the input stays unconverted until Space), so Esc then clears it
        self.type("ne", into: session)
        #expect(host.markedText == "きょうはいいてんきですね")
        #expect(session.handle(self.escape))
        #expect(host.markedText.isEmpty)
        #expect(session.inputState == .none)
        #expect(host.inserted.isEmpty)

        // The reading can look the same as what live conversion showed (a Latin word with kana around it): Esc still
        // stops there once, and only the next Esc clears the input
        let (latinSession, latinHost) = self.makeSession(liveConversion: true)
        self.type("korehaWindowsdesu", into: latinSession)
        #expect(latinHost.markedText == "これはWindowsです")
        #expect(latinSession.handle(self.escape))
        #expect(latinHost.markedText == "これはWindowsです")
        #expect(latinSession.inputState == .composing)
        #expect(latinSession.handle(self.escape))
        #expect(latinHost.markedText.isEmpty)
        #expect(latinSession.inputState == .none)
        #expect(latinHost.inserted.isEmpty)
    }

    @Test("読みを編集中に末尾が n のまま Enter を押すと、見えていた読みのまま ん にして確定する（変換に変わらない）")
    func enterWhileEditingReadingKeepsReadingWithTrailingN() {
        let (session, host) = self.makeSession(liveConversion: true)
        self.type("kyouha", into: session)
        #expect(host.markedText == "今日は")
        #expect(session.handle(self.escape))
        self.type("hon", into: session)
        #expect(host.markedText == "きょうはほn")
        #expect(session.handle(self.enter))
        #expect(host.inserted == ["きょうはほん"])
        #expect(session.inputState == .none)
    }

    @Test("英字モードへ切り替えると、未確定文字列は確定される読みの表示になる")
    func switchingToEnglishShowsTheReadingThatWillBeCommitted() {
        let (session, host) = self.makeSession(liveConversion: true)
        self.type("kyouha", into: session)
        #expect(host.markedText == "今日は")
        session.inputModeDidChange(to: .english)
        #expect(host.markedText == "きょうは")
        #expect(session.handle(self.enter))
        #expect(host.inserted == ["きょうは"])
    }

    @Test("入力中の ← → は読みの中でカーソルを動かし、その位置で打ち足しや削除ができる（MS-IME）。ライブ変換の表示はひらがなに戻り、Space で全体を変換する")
    func arrowKeysMoveTheCaretInsideTheReading() {
        let left = self.keyCode(123)
        let right = self.keyCode(124)
        let (session, host) = self.makeSession(liveConversion: true)
        self.type("kyouhaiitenkidesu", into: session)
        #expect(host.markedText == "今日はいい天気です")
        // ← goes back to the reading and moves the caret before す
        #expect(session.handle(left))
        #expect(host.markedText == "きょうはいいてんきです")
        #expect(host.selectionRange == NSRange(location: 10, length: 0))
        #expect(session.handle(left))
        #expect(host.selectionRange == NSRange(location: 9, length: 0))
        #expect(session.inputState == .composing)
        // Typing inserts at the caret, and the input stays at its reading
        self.type("ne", into: session)
        #expect(host.markedText == "きょうはいいてんきねです")
        #expect(host.selectionRange == NSRange(location: 10, length: 0))
        // Backspace deletes the character before the caret
        #expect(session.handle(self.backspace))
        #expect(host.markedText == "きょうはいいてんきです")
        #expect(host.selectionRange == NSRange(location: 9, length: 0))
        // → moves on, and stays at the end
        for _ in 0 ..< 3 {
            #expect(session.handle(right))
        }
        #expect(host.selectionRange.location == NSNotFound)
        #expect(host.markedText == "きょうはいいてんきです")
        // Space converts the whole reading
        #expect(session.handle(self.space))
        #expect(host.markedText == "今日はいい天気です")
        #expect(session.handle(self.enter))
        #expect(host.inserted == ["今日はいい天気です"])

        // Enter commits the reading as edited; Esc clears it
        let (readingSession, readingHost) = self.makeSession(liveConversion: true)
        self.type("kyouhaiitenkidesu", into: readingSession)
        #expect(readingSession.handle(self.escape))
        #expect(readingSession.handle(left))
        #expect(readingSession.handle(left))
        self.type("ne", into: readingSession)
        #expect(readingHost.markedText == "きょうはいいてんきねです")
        #expect(readingSession.handle(self.enter))
        #expect(readingHost.inserted == ["きょうはいいてんきねです"])
        #expect(readingSession.inputState == .none)

        // Without live conversion the reading is shown anyway; ← → move the caret the same way
        let (plainSession, plainHost) = self.makeSession(liveConversion: false)
        self.type("kyouha", into: plainSession)
        #expect(plainSession.handle(left))
        #expect(plainHost.selectionRange == NSRange(location: 3, length: 0))
        self.type("ne", into: plainSession)
        #expect(plainHost.markedText == "きょうねは")
        #expect(plainSession.handle(self.escape))
        #expect(plainHost.markedText.isEmpty)
    }

    @Test("読みの中のカーソルは、英字のまま残る語の手前で止まらず語の中を一字ずつ動き、かなの途中（きょ、てんき）にも立てる")
    func caretMovesThroughLatinWordsAndInsideKana() {
        let left = self.keyCode(123)
        let right = self.keyCode(124)
        let forwardDelete = self.keyCode(117)
        let (session, host) = self.makeSession(liveConversion: true)
        self.type("kyouhaTokyoniikimasu", into: session)
        #expect(host.markedText == "今日はTokyoに行きます")
        // The reading keeps Tokyo as typed; as typed its keys read Tおきょ, which the caret never shows
        var locations: [Int] = []
        for _ in 0 ..< 10 {
            #expect(session.handle(left))
            locations.append(host.selectionRange.location)
        }
        #expect(host.markedText == "きょうはTokyoにいきます")
        #expect(locations == [13, 12, 11, 10, 9, 8, 7, 6, 5, 4])
        // Typing before the word leaves it a word; Backspace takes what was typed
        self.type("ne", into: session)
        #expect(host.markedText == "きょうはねTokyoにいきます")
        #expect(host.selectionRange == NSRange(location: 5, length: 0))
        #expect(session.handle(self.backspace))
        #expect(host.markedText == "きょうはTokyoにいきます")
        #expect(host.selectionRange == NSRange(location: 4, length: 0))
        // Inside the word, Backspace takes one letter
        for _ in 0 ..< 3 {
            #expect(session.handle(right))
        }
        #expect(session.handle(self.backspace))
        #expect(host.markedText == "きょうはTo" + "yoにいきます")
        #expect(host.selectionRange == NSRange(location: 6, length: 0))
        #expect(session.handle(self.enter))
        #expect(host.inserted == ["きょうはToyoにいきます"])

        // Inside a kana made of several keys (き|ょ, てん|き), the kana is fixed as its characters and the caret stands
        // between them; what is typed there does not read with them
        let (kanaSession, kanaHost) = self.makeSession(liveConversion: true)
        self.type("kyouhaiitenkidesu", into: kanaSession)
        for _ in 0 ..< 3 {
            #expect(kanaSession.handle(left))
        }
        #expect(kanaHost.markedText == "きょうはいいてんきです")
        #expect(kanaHost.selectionRange == NSRange(location: 8, length: 0))
        self.type("ne", into: kanaSession)
        #expect(kanaHost.markedText == "きょうはいいてんねきです")
        #expect(kanaHost.selectionRange == NSRange(location: 9, length: 0))
        for _ in 0 ..< 20 {
            #expect(kanaSession.handle(left))
        }
        #expect(kanaSession.handle(right))
        #expect(kanaHost.selectionRange == NSRange(location: 1, length: 0))
        self.type("ka", into: kanaSession)
        #expect(kanaHost.markedText == "きかょうはいいてんねきです")
        #expect(kanaSession.handle(forwardDelete))
        #expect(kanaHost.markedText == "きかうはいいてんねきです")
        #expect(kanaHost.selectionRange == NSRange(location: 2, length: 0))
        // Space converts the whole reading, wherever the caret was
        #expect(kanaSession.handle(self.space))
        #expect(kanaHost.selectionRange.location == NSNotFound || kanaSession.inputState == .selecting)
        #expect(kanaHost.markedText.hasSuffix("です"))
    }

    @Test("ライブ変換で、変換中や文節を編集したあとの Esc は、文節を元に戻してひらがなの入力中に戻る")
    func escapeAfterConversionGoesBackToReading() {
        let shiftLeft = self.keyCode(123, modifiers: [.shift])
        let controlK = KeyEventCore(modifierFlags: [.control], characters: "k", charactersIgnoringModifiers: "k", keyCode: 40)
        for (name, edits) in [("Space", []), ("Shift+←", [shiftLeft]), ("Ctrl+K", [controlK]), ("Space 2回", [self.space])] {
            let (session, host) = self.makeSession(liveConversion: true)
            self.type("kyouhaiitenkidesu", into: session)
            #expect(session.handle(self.space))
            let converted = host.markedText
            for edit in edits {
                #expect(session.handle(edit))
            }
            #expect(session.handle(self.escape))
            #expect(host.markedText == "きょうはいいてんきです", "\(name) の後の Esc でひらがなに戻る")
            #expect(session.inputState == .composing, "\(name) の後の Esc で入力中に戻る")
            #expect(host.inserted.isEmpty)
            #expect(session.handle(self.space))
            #expect(host.markedText == converted, "\(name) の後に戻すと、文節の区切りも最初の変換に戻る")
        }
        // A segment already committed stays committed, and the rest goes back to its reading (macOS style: → commits
        // the first clause)
        let (session, host) = self.makeSession(keyBindingStyle: .macOS, liveConversion: true)
        self.type("kyouhaiitenkidesu", into: session)
        #expect(session.handle(self.space))
        #expect(session.handle(self.keyCode(124)))
        #expect(host.inserted == ["今日は"])
        #expect(session.handle(self.escape))
        #expect(host.markedText == "いいてんきです")
        #expect(session.inputState == .composing)
        // MS-IME style: → only moves on to the next clause, so nothing is committed and the whole input goes back to
        // its reading
        let (msSession, msHost) = self.makeSession(liveConversion: true)
        self.type("kyouhaiitenkidesu", into: msSession)
        #expect(msSession.handle(self.space))
        #expect(msSession.handle(self.keyCode(124)))
        #expect(msHost.inserted.isEmpty)
        #expect(msSession.handle(self.escape))
        #expect(msHost.markedText == "きょうはいいてんきです")
        #expect(msSession.inputState == .composing)
    }

    @Test("先頭を大文字で打つと英字のまま確定できる（ライブ変換がオフのときは確定まで英字）")
    func uppercaseStartsAlphabetWord() {
        let (session, host) = self.makeSession()
        self.type("Apple", into: session)
        #expect(host.markedText == "Apple")
        #expect(session.handle(self.enter))
        #expect(host.inserted == ["Apple"])
    }

    @Test("ライブ変換では、先頭の大文字で始まる語の後は自動でかなに戻る")
    func uppercaseStartsLatinWordWithLiveConversion() {
        let (session, host) = self.makeSession(liveConversion: true)
        self.type("Applewotukau", into: session)
        #expect(host.markedText == "Appleを使う")
        #expect(session.handle(self.enter))
        #expect(host.inserted == ["Appleを使う"])
        // The spell checker takes acde for ACDE, but a word does not start inside Mac. A capital after it still starts
        // one (Pro), and capitals in a row stay Latin letters (SHIFT)
        for (keys, expected) in [
            ("Macdehaugokanai", "Macでは動かない"),
            ("MacBookProdehaugokimasen.", "MacBookProでは動きません。"),
            ("SHIFTwoosu", "SHIFTを押す"),
            ("SHIFT", "SHIFT"),
            // A word also ends before a symbol, and keeps the capital typed though the spell checker suggests ctrl
            ("Ctrl+Idejouhouwomimasu.", "Ctrl＋Iで情報を見ます。"),
            // Not a known word and no kana reading (あpとs), but letters are left over, so it ends before を
            ("Aptoswotukaimashou", "Aptosを使いましょう"),
            ("korehaAptosdesu", "これはAptosです")
        ] {
            let (capitalSession, capitalHost) = self.makeSession(liveConversion: true)
            self.type(keys, into: capitalSession)
            #expect(capitalHost.markedText == expected)
        }
    }

    @Test("Ctrl+I でカタカナに変換し、Enter で確定する")
    func controlIConvertsToKatakana() {
        let (session, host) = self.makeSession(keyBindingStyle: .msIME)
        self.type("tenki", into: session)
        let controlI = KeyEventCore(modifierFlags: [.control], characters: "\t", charactersIgnoringModifiers: "i", keyCode: 34)
        #expect(session.handle(controlI))
        #expect(host.markedText == "テンキ")
        #expect(host.inserted.isEmpty, "\(host.inserted)")
        #expect(session.inputState == .selecting)
        #expect(session.handle(self.enter))
        #expect(host.inserted == ["テンキ"])
        #expect(session.inputState == .none)
    }

    @Test("英数キーのダブルタップで半角英数として確定し英字モードへ移る")
    func eisuDoubleTapCommitsAsRoman() {
        var clock: TimeInterval = 100
        let (session, host) = self.makeSession(now: { clock })
        self.type("test", into: session)
        #expect(session.handle(self.keyCode(102)))
        clock += 0.1
        #expect(session.handle(self.keyCode(102)))
        #expect(host.inserted == ["test"])
        #expect(session.inputLanguage == .english)
        #expect(host.inputModes.last == .english)
    }

    @Test("英字モードでは未確定文字列を作らずにそのまま挿入する")
    func englishModeInsertsDirectly() {
        let (session, host) = self.makeSession()
        session.inputModeDidChange(to: .english)
        #expect(session.handle(self.key("a")))
        #expect(host.inserted == ["a"])
        #expect(host.markedText.isEmpty)
    }

    @Test("Command 付きのキーはアプリに渡す")
    func commandKeysFallThrough() {
        let (session, _) = self.makeSession()
        let commandC = KeyEventCore(modifierFlags: [.command], characters: "c", charactersIgnoringModifiers: "c", keyCode: 8)
        #expect(!session.handle(commandC))
        self.type("ai", into: session)
        #expect(!session.handle(commandC))
    }

    @Test("OS からの確定要求で未確定文字列を挿入して空にする")
    func commitCompositionFromHost() {
        let (session, host) = self.makeSession()
        self.type("sakura", into: session)
        session.commitComposition()
        #expect(host.inserted == ["さくら"])
        #expect(host.markedText.isEmpty)
        #expect(session.inputState == .none)
    }

    @Test("候補ウィンドウのクリックは、MS-IME では候補を選んで次の文節へ進み、macOS 標準では確定する")
    func candidateWindowSubmission() {
        let (session, host) = self.makeSession(keyBindingStyle: .macOS)
        self.type("sakura", into: session)
        #expect(session.handle(self.space))
        session.selectCandidateRow(0)
        session.submitCandidateFromWindow()
        #expect(host.inserted.count == 1)
        #expect(host.markedText.isEmpty)

        // MS-IME: the clause chosen stays shown, with the rest; Enter commits them all
        let (msSession, msHost) = self.makeSession(keyBindingStyle: .msIME)
        self.type("kyouhasakura", into: msSession)
        #expect(msSession.handle(self.space))
        #expect(msSession.handle(self.space))
        msSession.selectCandidateRow(1)
        let chosen = msSession.segmentsManager.selectedCandidate?.text ?? ""
        msSession.submitCandidateFromWindow()
        #expect(msHost.inserted.isEmpty)
        #expect(msSession.inputState == .selecting)
        #expect(msHost.markedText.hasPrefix(chosen), "\(chosen) / \(msHost.markedText)")
        #expect(msSession.handle(self.enter))
        #expect(msHost.inserted.count == 1)
        #expect(msHost.inserted.joined().hasPrefix(chosen), "\(chosen) / \(msHost.inserted)")
    }

    // MARK: - Continuation

    /// Model that only streams a fixed list of partial outputs.
    final class FakeContinuationProvider: ContinuationProvider, @unchecked Sendable {
        /// Each call returns the next element. When they run out, it repeats the last one.
        let attempts: [[String]]
        let error: (any Error)?
        /// Which error to throw on which call (0-based).
        let errorsByAttempt: [Int: any Error]
        private(set) var receivedContexts: [String] = []
        init(snapshots: [String], error: (any Error)? = nil) {
            self.attempts = [snapshots]
            self.error = error
            self.errorsByAttempt = [:]
        }
        init(attempts: [[String]], errorsByAttempt: [Int: any Error] = [:]) {
            self.attempts = attempts
            self.error = nil
            self.errorsByAttempt = errorsByAttempt
        }
        func continuation(after leftContext: String) -> AsyncThrowingStream<String, any Error> {
            let index = self.receivedContexts.count
            let snapshots = self.attempts[min(index, self.attempts.count - 1)]
            self.receivedContexts.append(leftContext)
            let error = self.errorsByAttempt[index] ?? self.error
            return AsyncThrowingStream { stream in
                for snapshot in snapshots {
                    stream.yield(snapshot)
                }
                stream.finish(throwing: error)
            }
        }
    }

    private let continuationKey = KeyEventCore(modifierFlags: [.shift], characters: "\u{19}", charactersIgnoringModifiers: "\u{19}", keyCode: 48)
    private let controlSlash = KeyEventCore(modifierFlags: [.control], characters: "/", charactersIgnoringModifiers: "/", keyCode: 44)
    private let f19 = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: UserAction.continuationKeyCode)
    private let tab = KeyEventCore(modifierFlags: [], characters: "\t", charactersIgnoringModifiers: "\t", keyCode: 48)

    struct ContinuationFixture {
        let session: InputSession
        let host: RecordingHost
        let provider: FakeContinuationProvider
    }

    private func makeContinuationSession(snapshots: [String] = ["明日は", "明日は晴れるでしょう。"], error: (any Error)? = nil) -> ContinuationFixture {
        let (session, host) = self.makeSession()
        host.leftContext = "今日は雨だった。"
        let provider = FakeContinuationProvider(snapshots: snapshots, error: error)
        session.continuationProvider = provider
        return ContinuationFixture(session: session, host: host, provider: provider)
    }

    struct StrictFixture {
        let session: InputSession
        let host: StrictHost
        let provider: FakeContinuationProvider
    }

    private func makeStrictSession(document: String = "今日は雨だった。", attempts: [[String]] = [["明日は", "明日は晴れるでしょう。"]]) -> StrictFixture {
        let (session, _) = self.makeSession()
        let host = StrictHost(document: document)
        session.host = host
        let provider = FakeContinuationProvider(attempts: attempts)
        session.continuationProvider = provider
        return StrictFixture(session: session, host: host, provider: provider)
    }

    @Test("本文を持つホストで: 提案の受け入れは本文を二重にせず、薄い表示も残さない")
    func acceptingGhostLeavesCleanDocument() async {
        let fixture = self.makeStrictSession()
        let (session, host) = (fixture.session, fixture.host)
        #expect(session.handle(self.continuationKey))
        #expect(host.text == "今日は雨だった。…")
        await session.waitForContinuation()
        #expect(host.text == "今日は雨だった。明日は晴れるでしょう。")
        #expect(host.markedText == "明日は晴れるでしょう。")
        host.calls.removeAll()
        #expect(session.handle(self.tab))
        #expect(host.text == "今日は雨だった。明日は晴れるでしょう。")
        #expect(host.marked == nil)
        #expect(host.caret == host.document.count)
        // Replace the faint suggestion text with the real text. If we delete it first and then insert, apps that update slowly replace the text committed just before with the suggestion.
        #expect(host.calls.first == "insertText:明日は晴れるでしょう。", "受け入れは insertText から始める")
    }

    @Test("英語では語の間の空白を戻す。語の途中や日本語では入れない")
    func restoringWordSpace() {
        typealias S = InputSession
        #expect(S.presentableContinuation(from: " We will get back to you soon.", after: "Thank you for your email.") == " We will get back to you soon.")
        #expect(S.presentableContinuation(from: "We will get back to you soon.", after: "Thank you for your email.") == " We will get back to you soon.", "Apple のモデルの出力は空白で始まらない")
        #expect(S.presentableContinuation(from: "ail soon.", after: "Thank you for your em") == "ail soon.", "語の途中")
        #expect(S.presentableContinuation(from: " soon.", after: "We will get back to you") == " soon.")
        #expect(S.presentableContinuation(from: "明日は晴れるでしょう。", after: "今日は雨だった。") == "明日は晴れるでしょう。")
    }

    @Test("本文を持つホストで: 受け入れてすぐもう一度押すと、確定した提案の後ろに次の提案が付く")
    func acceptThenRequestAgainAppendsAfterAcceptedText() async {
        let fixture = self.makeStrictSession(attempts: [["明日は晴れるでしょう。"], ["傘はいらない。"]])
        let (session, host, provider) = (fixture.session, fixture.host, fixture.provider)
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(session.handle(self.tab))
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(provider.receivedContexts.last == "今日は雨だった。明日は晴れるでしょう。", "確定した提案も文脈に入る")
        #expect(host.text == "今日は雨だった。明日は晴れるでしょう。傘はいらない。")
        #expect(host.markedText == "傘はいらない。")
        #expect(session.handle(self.tab))
        #expect(host.text == "今日は雨だった。明日は晴れるでしょう。傘はいらない。")
        #expect(host.marked == nil)
    }

    @Test("本文を持つホストで: 表示中にもう一度押すと、古い提案は消えて新しい提案だけが付く")
    func regenerateReplacesGhostInDocument() async {
        let fixture = self.makeStrictSession(attempts: [["明日は晴れるでしょう。"], ["傘はいらない。"]])
        let (session, host, provider) = (fixture.session, fixture.host, fixture.provider)
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(session.handle(self.continuationKey))
        #expect(host.text == "今日は雨だった。…")
        await session.waitForContinuation()
        #expect(provider.receivedContexts == ["今日は雨だった。", "今日は雨だった。"], "古い提案は文脈に入らない")
        #expect(host.text == "今日は雨だった。傘はいらない。")
        #expect(host.markedText == "傘はいらない。")
    }

    @Test("文書の写しを次の描画まで更新しないアプリでも、表示中にもう一度押したときに古い提案や知らせが文脈に混ざらない")
    func regenerateDoesNotReadStaleSuggestion() async {
        let (session, _) = self.makeSession()
        let host = FrameLaggingHost(document: "今日は雨だった。")
        session.host = host
        let provider = FakeContinuationProvider(attempts: [["今日は雨だった。"], ["今日は雨だった。"], ["今日は雨だった。"], ["明日は晴れるでしょう。"], ["傘はいらない。"]])
        session.continuationProvider = provider
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        host.drawFrame()
        #expect(host.document.text == "今日は雨だった。（続きを思いつきませんでした）")
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        host.drawFrame()
        #expect(host.document.text == "今日は雨だった。明日は晴れるでしょう。")
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(provider.receivedContexts.allSatisfy { $0 == "今日は雨だった。" }, "知らせや前の提案が文脈に混ざらない")
        #expect(host.document.text == "今日は雨だった。傘はいらない。")
    }

    @Test("提案を閉じた後にもう一度押すと、文脈を読み直す")
    func requestAfterDismissReadsContextAgain() async {
        let fixture = self.makeStrictSession(attempts: [["明日は晴れるでしょう。"], ["傘はいらない。"]])
        let (session, host, provider) = (fixture.session, fixture.host, fixture.provider)
        let escape = KeyEventCore(modifierFlags: [], characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", keyCode: 53)
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(session.handle(escape))
        host.insertText("外は寒い。")
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(provider.receivedContexts == ["今日は雨だった。", "今日は雨だった。外は寒い。"])
    }

    @Test("本文を持つホストで: Esc、他のキー、確定の要求、知らせの受け入れのどれでも本文は変わらない")
    func dismissingGhostRestoresDocument() async {
        let escape = KeyEventCore(modifierFlags: [], characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", keyCode: 53)
        let leftArrow = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 123)
        for way in ["escape", "arrow", "commit", "deactivate"] {
            let fixture = self.makeStrictSession()
            let (session, host) = (fixture.session, fixture.host)
            #expect(session.handle(self.continuationKey))
            await session.waitForContinuation()
            #expect(host.text == "今日は雨だった。明日は晴れるでしょう。")
            switch way {
            case "escape":
                #expect(session.handle(escape))
            case "arrow":
                #expect(!session.handle(leftArrow))
            case "commit":
                session.commitComposition()
            default:
                session.deactivate()
            }
            #expect(host.text == "今日は雨だった。", "\(way) の後に本文が元に戻る")
            #expect(host.marked == nil, "\(way) の後に未確定範囲が残らない")
        }
        let messageFixture = self.makeStrictSession(attempts: [["今日は雨だった。"]])
        let (session, host) = (messageFixture.session, messageFixture.host)
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(host.text == "今日は雨だった。（続きを思いつきませんでした）")
        #expect(session.handle(self.tab))
        #expect(host.text == "今日は雨だった。", "知らせは受け入れても本文に入らない")
        #expect(host.marked == nil)
    }

    @Test("未入力で Shift+Tab を押すと左文脈を渡して続きを薄く表示し、Tab で確定する")
    func continuationIsShownAsGhostAndAcceptedWithTab() async {
        let fixture = self.makeContinuationSession()
        let (session, host, provider) = (fixture.session, fixture.host, fixture.provider)
        #expect(session.handle(self.continuationKey))
        #expect(host.markedText == "…", "生成中は省略記号を出す")
        await session.waitForContinuation()
        #expect(provider.receivedContexts == ["今日は雨だった。"])
        #expect(host.markedText == "明日は晴れるでしょう。")
        #expect(session.continuation?.isGenerating == false)
        #expect(host.inserted.isEmpty, "Tab を押すまで本文には入れない")

        #expect(session.handle(self.tab))
        #expect(host.inserted == ["明日は晴れるでしょう。"])
        #expect(session.continuation == nil)
        #expect(host.markedText.isEmpty)
    }

    @Test("モデルが直前の文章を繰り返してから書き始めても、重なった部分は見せない")
    func continuationDropsRepeatedContext() async {
        let fixture = self.makeContinuationSession(snapshots: ["今日は", "今日は雨だった。", "今日は雨だった。明日は", "今日は雨だった。明日は晴れるでしょう。"])
        let (session, host) = (fixture.session, fixture.host)
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(host.markedText == "明日は晴れるでしょう。")
        #expect(session.handle(self.tab))
        #expect(host.inserted == ["明日は晴れるでしょう。"])
    }

    @Test("壊れた出力（丸写し・繰り返し）なら、上限までやり直してから良い出力を使う")
    func continuationRetriesBrokenOutput() async {
        let fixture = self.makeContinuationSession()
        let (session, host) = (fixture.session, fixture.host)
        let provider = FakeContinuationProvider(attempts: [
            ["今日は雨だった。"],
            ["明日も雨だろう。明日も雨だろう。"],
            ["明日は晴れるでしょう。"]
        ])
        session.continuationProvider = provider
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(provider.receivedContexts.count == 3)
        #expect(host.markedText == "明日は晴れるでしょう。")
        #expect(session.handle(self.tab))
        #expect(host.inserted == ["明日は晴れるでしょう。"])
    }

    @Test("指示について語る出力（「書きかけの文章を渡してください」）は壊れた出力として出し直す")
    func continuationRetriesTaskTalk() async {
        let fixture = self.makeContinuationSession()
        let (session, host) = (fixture.session, fixture.host)
        let provider = FakeContinuationProvider(attempts: [
            ["書きかけの文章を渡してください。"],
            ["ない。どこで生れたか見当がつかぬ。（1文：80文字）"],
            ["明日は晴れるでしょう。"]
        ])
        session.continuationProvider = provider
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(provider.receivedContexts.count == 3)
        #expect(host.markedText == "明日は晴れるでしょう。")
    }

    @Test("提案が出ている間にフォーカスが移って確定を求められたら、表示を消して本文には入れない")
    func commitCompositionClearsGhost() async {
        let fixture = self.makeContinuationSession()
        let (session, host) = (fixture.session, fixture.host)
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(host.markedText == "明日は晴れるでしょう。")
        session.commitComposition()
        #expect(host.markedText.isEmpty, "薄い表示を残すと、アプリが本文として確定してしまう")
        #expect(host.inserted.isEmpty)
        #expect(session.continuation == nil)
    }

    @Test("知らせが出ている間にフォーカスが移っても、知らせを本文に残さない")
    func commitCompositionClearsMessage() async {
        let fixture = self.makeContinuationSession()
        let (session, host) = (fixture.session, fixture.host)
        session.continuationProvider = FakeContinuationProvider(attempts: [["今日は雨だった。"]])
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(host.markedText == "（続きを思いつきませんでした）")
        session.commitComposition()
        #expect(host.markedText.isEmpty)
        #expect(host.inserted.isEmpty)
    }

    @Test("提案が出ている間に他のキーを押したら、表示を消してからアプリに渡す")
    func fallthroughKeyClearsGhost() async {
        let fixture = self.makeContinuationSession()
        let (session, host) = (fixture.session, fixture.host)
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(host.markedText == "明日は晴れるでしょう。")
        let leftArrow = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 123)
        #expect(!session.handle(leftArrow), "未入力なら矢印キーはアプリに渡す")
        #expect(host.markedText.isEmpty)
        #expect(host.inserted.isEmpty)
        #expect(session.continuation == nil)
    }

    @Test("提案が出ている間にもう一度押すと、古い提案を消して「…」を出してから生成し直す")
    func regenerateShowsEllipsisImmediately() async {
        let fixture = self.makeContinuationSession()
        let (session, host, provider) = (fixture.session, fixture.host, fixture.provider)
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(host.markedText == "明日は晴れるでしょう。")
        #expect(session.handle(self.continuationKey))
        #expect(host.markedText == "…")
        await session.waitForContinuation()
        #expect(provider.receivedContexts.count == 2)
        #expect(host.markedText == "明日は晴れるでしょう。")
    }

    @Test("表示中の提案や知らせは次の文脈に含めない（未確定文字列を文脈に含めて返すアプリでも）")
    func ghostIsClearedBeforeReadingContext() async {
        let fixture = self.makeContinuationSession()
        let (session, host) = (fixture.session, fixture.host)
        host.includesMarkedTextInContext = true
        let provider = FakeContinuationProvider(attempts: [["今日は雨だった。"], ["今日は雨だった。"], ["今日は雨だった。"], ["明日は晴れるでしょう。"]])
        session.continuationProvider = provider
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(host.markedText == "（続きを思いつきませんでした）")
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(provider.receivedContexts.count == 4)
        #expect(provider.receivedContexts.allSatisfy { $0 == "今日は雨だった。" }, "知らせや「…」が文脈に混ざらない")
        #expect(host.markedText == "明日は晴れるでしょう。")
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(provider.receivedContexts.last == "今日は雨だった。", "前の提案も文脈に混ざらない")
    }

    @Test("壊れた出力が続いても、上限で止めて知らせを出す（無限にやり直さない）")
    func continuationGivesUpAfterMaxAttempts() async {
        let fixture = self.makeContinuationSession()
        let (session, host) = (fixture.session, fixture.host)
        let provider = FakeContinuationProvider(attempts: [["今日は雨だった。"]])
        session.continuationProvider = provider
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(provider.receivedContexts.count == InputSession.continuationMaxAttempts)
        #expect(host.markedText == "（続きを思いつきませんでした）")
        #expect(session.continuation?.isGenerating == false)
        #expect(session.handle(self.tab) == true, "知らせだけのときは Tab で何も入れずに閉じる")
        #expect(host.inserted.isEmpty)
    }

    @Test("安全フィルタで止められたら、文脈を末尾だけに縮めてやり直す")
    func continuationRetriesSafetyFilterWithShorterContext() async {
        let fixture = self.makeContinuationSession()
        let (session, host) = (fixture.session, fixture.host)
        host.leftContext = String(repeating: "あ", count: 300) + "今日は雨だった。"
        let provider = FakeContinuationProvider(
            attempts: [[], ["明日は晴れるでしょう。"]],
            errorsByAttempt: [0: ContinuationError.blockedBySafetyFilter]
        )
        session.continuationProvider = provider
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(provider.receivedContexts.count == 2)
        #expect(provider.receivedContexts[0].count == 308)
        #expect(provider.receivedContexts[1].count == 308 / InputSession.continuationContextShrinkFactor)
        #expect(provider.receivedContexts[1].hasSuffix("今日は雨だった。"), "末尾を残す")
        #expect(host.markedText == "明日は晴れるでしょう。")
    }

    @Test("安全フィルタに止められ続けたら、上限で止めて日本語の知らせを出す")
    func continuationGivesUpOnPersistentSafetyFilter() async {
        let fixture = self.makeContinuationSession()
        let (session, host) = (fixture.session, fixture.host)
        let provider = FakeContinuationProvider(snapshots: [], error: ContinuationError.blockedBySafetyFilter)
        session.continuationProvider = provider
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(provider.receivedContexts.count == InputSession.continuationMaxAttempts)
        #expect(host.markedText == "（Apple のモデルが安全上の理由で続きを書きませんでした。少し書き足してからもう一度試してください）")
        #expect(session.continuation?.isGenerating == false)
    }

    @Test("壊れた出力の判定")
    func brokenContinuationDetection() {
        typealias S = InputSession
        let context = "昨日は雨だったが、今日は朝から晴れている。"
        #expect(!S.isBrokenContinuation("明日も晴れるといいなと思う。", after: context))
        #expect(S.isBrokenContinuation("", after: context), "空")
        #expect(S.isBrokenContinuation("そして、今日は朝から晴れている。だから出かけよう。", after: context), "文脈の末尾の句の丸写し")
        #expect(S.isBrokenContinuation("今日は朝から晴れているので、散歩に出かけた。", after: context), "末尾の句の書き直し")
        #expect(S.isBrokenContinuation("昨日は雨だったが、今日は朝から晴れている。明日も晴れる。", after: context), "文脈の丸写し")
        #expect(!S.isBrokenContinuation("今日は朝から出かけた。", after: context), "本文 15 文字以下の引用は許す")
        #expect(S.isBrokenContinuation("出かけよう。出かけよう。", after: context), "同じ文の繰り返し")
        #expect(S.isBrokenContinuation("散歩に行くのが楽しみで、散歩に行くのが楽しみで、散歩に行くのが楽しみだ", after: context), "同じ語句の繰り返し（8 文字以上が 3 回）")
        #expect(S.isBrokenContinuation("散歩に行くのが楽しみで仕方がないので、散歩に行くのが楽しみで仕方がないのだ", after: context), "同じ語句の繰り返し（16 文字以上が 2 回）")
        #expect(!S.isBrokenContinuation("この会議は、プロジェクトの進捗を確認するため開催されました。プロジェクトの進捗を確認する中で、いくつかの課題が浮き彫りになりました。", after: "本日の会議の議事録を共有します。"), "12 文字の名詞句を 2 回使うのは繰り返しではない")
        #expect(!S.isBrokenContinuation("散歩に行くのが楽しみで、散歩に行くのが楽しみだ", after: context), "短い語句が 2 回だけなら普通の文でもあり得るので許す")
        #expect(!S.isBrokenContinuation("議題は「新商品の開発進捗」と「予算管理の見直し」でした。まず、新商品の開発進捗については、試作が完成したとの報告がありました。", after: "本日の会議の議事録を共有します。"), "話題の名詞句を 2 回使うのは繰り返しではない")
        #expect(!S.isBrokenContinuation("はい。はい。", after: context), "短い相づちの繰り返しは許す")

        let letter = "先日はお忙しいところお時間をいただき、ありがとうございました。来月の初めまでに改善案をお送りすることになりました。つきましては、"
        #expect(!S.isBrokenContinuation("この度の打ち合わせを誠にありがとうございました。", after: letter), "決まり文句の引用は許す")
        #expect(S.isBrokenContinuation("来月の初めまでに改善案をお送りすることになりました。", after: letter), "文脈の言い直しは壊れている")
        let names = "まずは LFM2.5-1.2B-JP を既定にして、Qwen3.5-2B は英語向けの選択肢として残す方針です。"
        #expect(!S.isBrokenContinuation("LFM2.5-1.2B-JP の速さと Qwen3.5-2B の英語力を両立できます。", after: names), "製品名の引用は本文の文字として数えない")
        #expect(!S.isBrokenContinuation("Qwen3.5-2B は速く、Qwen3.5-2B は賢い。", after: names), "製品名の繰り返しは壊れていない")
        #expect(S.isBrokenContinuation("Qwen3.5-2B は英語向けの選択肢として残す。Qwen3.5-2B は英語向けの選択肢として残す。", after: names), "本文の繰り返しは壊れている")
        #expect(S.isBrokenContinuation("どうぞ書きかけの文章をお知らせください。", after: context), "指示について語っている")
        #expect(S.isBrokenContinuation("どのような文章でしょうか。どうぞお見せください。", after: "お疲れ様です。"), "文章を求める返事")
        #expect(S.brokenContinuationReason("どのような文章でしょうか。", after: "お疲れ様です。") == "指示について語っている")
        #expect(S.brokenContinuationReason("", after: "お疲れ様です。") == "空")
        #expect(S.brokenContinuationReason("明日は晴れるでしょう。", after: "今日は雨だった。") == nil)
        let mail = "お世話になっております。先日はご確認のほどよろしくお願いいたします、とお伝えしましたが、" + String(repeating: "その後の状況をご報告します。", count: 12) + "改めて日程を調整したく存じます。"
        #expect(!S.isBrokenContinuation("ご確認のほどよろしくお願いいたします。", after: mail), "150 文字より前にある決まり文句の再利用は丸写しではない")
        #expect(S.isBrokenContinuation("お世話になっております。先日はご確認のほどよろしくお願いいたします、とお伝えしました。", after: mail), "前のほうでも 24 文字以上の丸写しは壊れている")
        #expect(S.presentableContinuation(from: "。明日は晴れる。明後日も晴れる。その次も晴れる。さらに晴れる。", after: "今日は雨だった。") == "明日は晴れる。明後日も晴れる。その次も晴れる。", "句読点の整理と 3 文の上限")
        #expect(!S.isBrokenContinuation("the allocation of funds to different departments.", after: "We discussed the budget for next quarter and"), "英語の短い定型句は指示文と重なっても許す")
        #expect(!S.isBrokenContinuation("We will get back to you soon with the requested information.", after: "Thank you for your email."))
        #expect(S.isBrokenContinuation("散歩に出かけた。（1文：80文字）", after: context), "文字数の但し書き")
        #expect(S.isBrokenContinuation("[ここに続き] を書いた。", after: context), "穴埋め")

        let english = "Thank you for taking the time to meet with us yesterday. We discussed the budget for next quarter"
        #expect(!S.isBrokenContinuation("and agreed to revisit the numbers next week.", after: english))
        #expect(!S.isBrokenContinuation("The numbers for next quarter look fine.", after: english), "英語では本文 30 文字未満の引用を許す")
        #expect(S.isBrokenContinuation("we discussed the budget for next quarter and more.", after: english), "英語でも長い丸写しは壊れている")
        #expect(S.isBrokenContinuation("We will follow up soon. We will follow up soon.", after: english), "同じ文の繰り返し")
    }

    @Test("繰り返し部分の切り落とし")
    func removingRepeatedPrefix() {
        typealias S = InputSession
        #expect(S.removingRepeatedPrefix(from: "明日は晴れる。", after: "今日は雨だった。") == "明日は晴れる。")
        #expect(S.removingRepeatedPrefix(from: "今日は雨だった。明日は晴れる。", after: "今日は雨だった。") == "明日は晴れる。")
        #expect(S.removingRepeatedPrefix(from: "雨だった。明日は晴れる。", after: "昨日も今日は雨だった。") == "明日は晴れる。")
        #expect(S.removingRepeatedPrefix(from: "だった。明日は", after: "今日は雨だった") == "。明日は", "句点は続きとして残す")
        #expect(S.removingRepeatedPrefix(from: "今日は雨", after: "今日は雨だった。").isEmpty, "文脈をなぞっている途中は空")
        #expect(S.removingRepeatedPrefix(from: "今日は雨だった。", after: "今日は雨だった。").isEmpty, "繰り返しだけなら空")
        #expect(S.removingRepeatedPrefix(from: "はい。", after: "今日は") == "はい。", "1文字の一致では削らない")
        #expect(S.removingRepeatedPrefix(from: "", after: "今日は").isEmpty)
        #expect(S.removingRepeatedPrefix(from: "今日は 雨", after: "今日は雨だった。").isEmpty, "空白の違いは無視する")

        let letter = "社内で検討した結果、来月の初めまでに改善案をまとめてお送りすることになりました。つきましては、"
        #expect(
            S.removingRepeatedPrefix(from: "来月の初めに改善案をまとめてお送りすることになりました。つきましては、またお忙しいところ恐縮ですが、ご確認ください。", after: letter)
                == "またお忙しいところ恐縮ですが、ご確認ください。",
            "言い回しを変えたなぞり直しも落とす"
        )
        #expect(S.removingRepeatedPrefix(from: "来月の初めに改善案をまとめてお送りすることになりました。つきましては", after: letter).isEmpty, "なぞり直しの途中は空")
        #expect(
            S.removingRepeatedPrefix(from: "今日は朝から晴れているので、散歩に出かけた。", after: "昨日は雨だったが、今日は朝から晴れている。") == "今日は朝から晴れているので、散歩に出かけた。",
            "句の後ろが文脈と違えば書き直しなので、断片を残さずそのまま返す"
        )
        #expect(
            S.removingRepeatedPrefix(from: "明日は晴れる。つきましては、散歩に行く。", after: "今日は雨だった。つきましては、") == "明日は晴れる。つきましては、散歩に行く。",
            "末尾の句が後ろに出ても、その前が似ていなければ落とさない"
        )
    }

    @Test("続きを書くキーは設定で個別にオフにできる。オフにしたキーは続きを書かない")
    func continuationKeysCanBeDisabledIndividually() {
        let shiftTab = self.continuationKey
        let controlSlash = self.controlSlash
        let f19 = self.f19
        func isContinuation(_ event: KeyEventCore, _ keys: ContinuationKeys) -> Bool {
            if case .continuation = UserAction.getUserAction(eventCore: event, inputLanguage: .japanese, typeBackSlash: false, keyBindingStyle: .msIME, continuationKeys: keys) {
                return true
            }
            return false
        }
        #expect(isContinuation(shiftTab, .all))
        #expect(isContinuation(controlSlash, .all))
        #expect(isContinuation(f19, .all))

        #expect(!isContinuation(shiftTab, [.controlSlash, .f19]))
        #expect(!isContinuation(controlSlash, [.shiftTab, .f19]))
        #expect(!isContinuation(f19, [.shiftTab, .controlSlash]))
        #expect(!isContinuation(f19, []))
    }

    @Test("Enter でも確定し、Esc なら何も入れずに消える。Ctrl+/ と F19 でも始められる")
    func continuationEnterAcceptsEscapeDiscards() async {
        let fixture = self.makeContinuationSession()
        let (session, host) = (fixture.session, fixture.host)
        #expect(session.handle(self.controlSlash))
        await session.waitForContinuation()
        #expect(session.handle(self.enter))
        #expect(host.inserted == ["明日は晴れるでしょう。"])

        host.inserted = []
        #expect(session.handle(self.f19))
        await session.waitForContinuation()
        #expect(session.handle(self.escape))
        #expect(host.inserted.isEmpty)
        #expect(session.continuation == nil)
        #expect(host.markedText.isEmpty)
    }

    @Test("続きの表示中に文字を打つと、提案は消えて通常の入力になる")
    func typingDismissesContinuation() async {
        let fixture = self.makeContinuationSession()
        let (session, host) = (fixture.session, fixture.host)
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        self.type("a", into: session)
        #expect(session.continuation == nil)
        #expect(host.inserted.isEmpty)
        #expect(host.markedText == "あ")
        #expect(session.inputState == .composing)
    }

    @Test("入力中に押すと未確定文字列を確定してから続きを書く")
    func continuationWhileComposingCommitsFirst() async {
        let fixture = self.makeContinuationSession()
        let (session, host, provider) = (fixture.session, fixture.host, fixture.provider)
        self.type("kyou", into: session)
        #expect(session.handle(self.continuationKey))
        #expect(host.inserted == ["きょう"])
        #expect(session.inputState == .none)
        await session.waitForContinuation()
        #expect(provider.receivedContexts.count == 1)
        #expect(host.markedText == "明日は晴れるでしょう。")
    }

    @Test("モデルが使えないときは理由を薄く表示し、Enter で本文に入れない")
    func continuationShowsErrorMessage() async {
        let fixture = self.makeContinuationSession(snapshots: [], error: ContinuationError.unavailable("端末内モデルが使えません"))
        let (session, host) = (fixture.session, fixture.host)
        #expect(session.handle(self.continuationKey))
        await session.waitForContinuation()
        #expect(host.markedText == "（端末内モデルが使えません）")
        #expect(session.handle(self.enter))
        #expect(host.inserted.isEmpty)
        #expect(session.continuation == nil)
    }

    @Test("モデル未設定や文脈なしでも落ちずに知らせる")
    func continuationWithoutProviderOrContext() {
        let (session, host) = self.makeSession()
        #expect(session.handle(self.continuationKey))
        #expect(host.markedText == "（設定の「続きを書く」がオフです）")
        #expect(session.handle(self.escape))

        session.continuationProvider = FakeContinuationProvider(snapshots: ["x"])
        host.leftContext = nil
        #expect(session.handle(self.continuationKey))
        #expect(host.markedText == "（続きを書くための文章がカーソルの前にありません）")
        #expect(session.continuation?.isGenerating == false)
    }

    @Test("英字の語の直前に残った n は ん になる")
    func nBeforeLatinWordBecomesN() {
        let (session, host) = self.makeSession(liveConversion: true)
        // GIF typed with Shift is a Latin word; the n of shon has no letter after it to read it as romaji
        self.type("anime-shonGIF", into: session)
        #expect(host.markedText.hasSuffix("ションGIF"), "\(host.markedText)")
        #expect(session.handle(self.enter))
        #expect(host.inserted.joined().hasSuffix("ションGIF"), "\(host.inserted)")
    }

    @Test("nn と打った ん は英字の語の前でもそのまま")
    func doubleNBeforeLatinWordStaysN() {
        let (session, host) = self.makeSession(liveConversion: true)
        self.type("kugirisennDock", into: session)
        #expect(host.markedText.hasSuffix("んDock") || host.markedText.hasSuffix("線Dock"), "\(host.markedText)")
    }

    @Test("記号を半角で入力する設定では % が半角のままで変換され、ー と 「 は全角のまま")
    func halfWidthSymbols() {
        let (session, host) = self.makeSession(typeHalfWidthSymbols: true)
        self.type("kakaku50%", into: session)
        #expect(host.markedText == "かかく50%")
        #expect(session.handle(self.space))
        #expect(host.markedText.hasSuffix("50%"), "\(host.markedText)")
        #expect(session.handle(self.enter))
        #expect(host.inserted.joined().hasSuffix("50%"), "\(host.inserted)")
        self.type("ra-men[", into: session)
        #expect(host.markedText == "らーめん「")
    }

    @Test("Zenzai なしでも → で文節を一つずつ移り、確定は Enter でまとめて行う")
    func clausesMoveOneByOneWithoutZenzai() {
        let (session, host) = self.makeSession(liveConversion: true)
        self.type("watashihaashitatoukyouniikimasu", into: session)
        #expect(session.handle(self.space))
        #expect(host.markedText == "私は明日東京に行きます")
        let right = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 124)
        for _ in 0 ..< 3 {
            #expect(session.handle(right))
        }
        #expect(host.inserted.isEmpty, "\(host.inserted)")
        #expect(host.markedText == "私は明日東京に行きます")
        #expect(session.handle(self.enter))
        #expect(host.inserted == ["私は明日東京に行きます"])
        #expect(host.markedText.isEmpty)
    }

    @Test("macOS 標準のキー操作では、→ は先頭の文節を確定して次の文節へ進む")
    func rightArrowCommitsTheFirstClauseInMacOSStyle() {
        let (session, host) = self.makeSession(keyBindingStyle: .macOS, liveConversion: true)
        self.type("watashihaashitatoukyouniikimasu", into: session)
        #expect(session.handle(self.space))
        let right = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 124)
        for _ in 0 ..< 3 {
            #expect(session.handle(right))
        }
        #expect(host.inserted.joined() == "私は明日東京に", "\(host.inserted)")
        #expect(host.markedText == "行きます")
    }

    @Test("文節を移ったあとの BackSpace と Esc は、移った文節も含めてひらがなに戻す")
    func backspaceAndEscapeAfterMovingClauses() {
        let right = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 124)
        let backspace = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 51)
        let escape = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 53)

        let (session, host) = self.makeSession(liveConversion: true)
        self.type("kyouhaiitenkidesune", into: session)
        #expect(session.handle(self.space))
        #expect(session.handle(right))
        #expect(session.handle(backspace))
        #expect(host.markedText == "きょうはいいてんきですね")
        #expect(host.inserted.isEmpty)
        #expect(session.handle(self.enter))
        #expect(host.inserted == ["きょうはいいてんきですね"])

        let (escSession, escHost) = self.makeSession(liveConversion: true)
        self.type("kyouhaiitenkidesune", into: escSession)
        #expect(escSession.handle(self.space))
        #expect(escSession.handle(right))
        #expect(escSession.handle(escape))
        #expect(escSession.inputState == .composing)
        // Esc goes back to the reading, as it does for a conversion without clauses moved (see
        // escapeAfterConversionGoesBackToReading); Enter then commits the reading
        #expect(escHost.markedText == "きょうはいいてんきですね")
        #expect(escHost.inserted.isEmpty)
        #expect(escSession.handle(self.enter))
        #expect(escHost.inserted == ["きょうはいいてんきですね"])
    }

    @Test("MS-IME では F6〜F10 は確定せず、入力をその形で見せる。続けて押すと MS-IME と同じに変わり、Enter で確定する")
    func functionKeysChangeTheFormWithoutCommitting() {
        let f6 = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 97)
        let f7 = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 98)
        let f8 = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 100)
        let f9 = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 101)
        let f10 = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 109)

        let (session, host) = self.makeSession(liveConversion: true)
        self.type("toukyou", into: session)
        let shown: [(KeyEventCore, String)] = [
            (f7, "トウキョウ"), (f7, "トウキョう"), (f7, "トウキょう"),
            (f6, "とうきょう"), (f6, "とうきょウ"),
            (f8, "ﾄｳｷｮｳ"), (f8, "ﾄｳｷｮう"),
            (f10, "toukyou"), (f10, "TOUKYOU"), (f10, "Toukyou"), (f10, "toukyou"),
            (f9, "ｔｏｕｋｙｏｕ"), (f9, "ＴＯＵＫＹＯＵ")
        ]
        for (key, text) in shown {
            #expect(session.handle(key))
            #expect(host.markedText == text)
            #expect(session.inputState == .selecting)
            #expect(host.inserted.isEmpty, "\(host.inserted)")
        }
        #expect(session.handle(self.enter))
        #expect(host.inserted == ["ＴＯＵＫＹＯＵ"])
        #expect(host.markedText.isEmpty)

        // macOS standard: committed at once, as before
        let (macSession, macHost) = self.makeSession(keyBindingStyle: .macOS, liveConversion: true)
        self.type("toukyou", into: macSession)
        #expect(macSession.handle(f7))
        #expect(macHost.inserted == ["トウキョウ"])
        #expect(macSession.inputState == .none)
    }

    @Test("文節に F7 を押すとその文節だけカタカナになり、→ で次の文節へ移れて、Enter でまとめて確定する")
    func functionKeyChangesOnlyTheClause() {
        let f7 = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 98)
        let right = KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 124)
        let (session, host) = self.makeSession(liveConversion: true)
        self.type("kyouhaiitenkidesune", into: session)
        #expect(session.handle(self.space))
        #expect(session.handle(right))
        #expect(session.handle(f7))
        #expect(host.markedText == "今日はイイ天気ですね")
        #expect(host.inserted.isEmpty, "\(host.inserted)")
        if case .selecting = session.candidateWindow {
            Issue.record("The candidate list should close when a function key changes the clause")
        }
        // Space opens the list again, the katakana form first and the next candidate selected, as Space does; ↑ goes
        // back to the katakana form
        #expect(session.handle(self.space))
        guard case .selecting(let candidates, let index) = session.candidateWindow else {
            Issue.record("Space should show the candidates again")
            return
        }
        #expect(candidates.first?.text == "イイ")
        #expect(index == 1)
        #expect(host.markedText == "今日はいい天気ですね")
        #expect(session.handle(KeyEventCore(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 126)))
        #expect(host.markedText == "今日はイイ天気ですね")
        #expect(session.handle(right))
        #expect(host.markedText == "今日はイイ天気ですね")
        #expect(session.handle(self.enter))
        #expect(host.inserted == ["今日はイイ天気ですね"])
    }

    @Test("記号は普段は全角で入力される")
    func fullWidthSymbolsByDefault() {
        let (session, host) = self.makeSession()
        self.type("kakaku50%", into: session)
        #expect(host.markedText == "かかく50％")
    }
}
