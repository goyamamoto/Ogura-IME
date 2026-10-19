import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

/// Regression tests for MS-IME compatible key operations (the conversion key setting set to MS-IME compatible).
@Suite("MS-IME キー操作")
struct MSIMEKeyBindingTests {
    private func event(_ logicalKey: String?, _ modifiers: KeyEventCore.ModifierFlag, keyCode: UInt16 = 0) -> KeyEventCore {
        KeyEventCore(modifierFlags: modifiers, characters: logicalKey, charactersIgnoringModifiers: logicalKey, keyCode: keyCode)
    }

    private func action(_ logicalKey: String, _ style: Config.KeyBindingStyle.Value) -> UserAction {
        UserAction.getUserAction(eventCore: self.event(logicalKey, [.control]), inputLanguage: .japanese, keyBindingStyle: style)
    }

    @Test("Ctrl+U/I/O/P/T は F6〜F10 と同じ変換になる")
    func controlLettersConvertLikeFunctionKeys() {
        let expected: [(String, UserAction.Function)] = [("u", .six), ("i", .seven), ("o", .eight), ("p", .nine), ("t", .ten)]
        for (key, function) in expected {
            guard case .function(let got) = self.action(key, .msIME), got == function else {
                Issue.record("Ctrl+\(key) should be function(\(function)), got \(self.action(key, .msIME))")
                return
            }
        }
    }

    @Test("Ctrl+K/L で文節を縮める・伸ばす、Ctrl+E/X で前候補・次候補")
    func controlSegmentAndCandidateKeys() {
        guard case .editSegment(-1) = self.action("k", .msIME) else {
            Issue.record("Ctrl+K should shrink segment, got \(self.action("k", .msIME))")
            return
        }
        guard case .editSegment(1) = self.action("l", .msIME) else {
            Issue.record("Ctrl+L should expand segment, got \(self.action("l", .msIME))")
            return
        }
        guard case .navigation(.up) = self.action("e", .msIME) else {
            Issue.record("Ctrl+E should be previous candidate, got \(self.action("e", .msIME))")
            return
        }
        guard case .navigation(.down) = self.action("x", .msIME) else {
            Issue.record("Ctrl+X should be next candidate, got \(self.action("x", .msIME))")
            return
        }
        guard case .navigation(.right) = self.action("n", .msIME) else {
            Issue.record("Ctrl+N should move to the next clause, got \(self.action("n", .msIME))")
            return
        }
    }

    @Test("Ctrl+Z/G は取消、Ctrl+Enter は確定")
    func controlCancelAndCommitKeys() {
        guard case .escape = self.action("z", .msIME), case .escape = self.action("g", .msIME) else {
            Issue.record("Ctrl+Z / Ctrl+G should cancel")
            return
        }
        let controlEnter = UserAction.getUserAction(
            eventCore: self.event("\r", [.control], keyCode: 0x24),
            inputLanguage: .japanese,
            keyBindingStyle: .msIME
        )
        guard case .enter = controlEnter else {
            Issue.record("Ctrl+Enter should commit, got \(controlEnter)")
            return
        }
    }

    @Test("macOS 標準の設定では従来の割り当てが維持される")
    func macOSStyleKeepsLegacyBindings() {
        guard case .navigation(.up) = self.action("p", .macOS) else {
            Issue.record("Ctrl+P in macOS style should move up")
            return
        }
        guard case .editSegment(-1) = self.action("i", .macOS) else {
            Issue.record("Ctrl+I in macOS style should shrink segment")
            return
        }
        guard case .function(.seven) = self.action("k", .macOS) else {
            Issue.record("Ctrl+K in macOS style should be katakana")
            return
        }
        guard case .unknown = self.action("z", .macOS) else {
            Issue.record("Ctrl+Z in macOS style should be unknown")
            return
        }
    }

    @Test("入力がない状態では Ctrl 系ショートカットをアプリに素通しする")
    func controlShortcutsFallThroughWhenNotComposing() {
        for key in ["z", "x", "n", "k", "u", "e", "g"] {
            let userAction = self.action(key, .msIME)
            let (clientAction, callback) = InputState.none.event(
                eventCore: self.event(key, [.control]),
                userAction: userAction,
                inputLanguage: .japanese,
                liveConversionEnabled: false,
                keyBindingStyle: .msIME
            )
            guard case .fallthrough = clientAction, case .fallthrough = callback else {
                Issue.record("Ctrl+\(key) with no composition should fall through, got \(clientAction)")
                return
            }
        }
    }

    @Test("変換中の BackSpace / Delete は文字を消さずに変換を取り消す")
    func backspaceCancelsConversion() {
        let backspace = self.event(nil, [], keyCode: 51)
        let forwardDelete = self.event(nil, [], keyCode: 0x75)
        for state in [InputState.previewing, .selecting] {
            for (keyEvent, userAction) in [(backspace, UserAction.backspace), (forwardDelete, .deleteForward)] {
                let (clientAction, callback) = state.event(
                    eventCore: keyEvent,
                    userAction: userAction,
                    inputLanguage: .japanese,
                    liveConversionEnabled: false,
                    keyBindingStyle: .msIME
                )
                guard case .cancelConversion = clientAction, case .transition(.composing) = callback else {
                    Issue.record("\(userAction) in \(state) should cancel conversion, got \(clientAction), \(callback)")
                    return
                }
            }
            // With the macOS standard setting, it deletes one character as before.
            let (legacyAction, _) = state.event(
                eventCore: backspace,
                userAction: .backspace,
                inputLanguage: .japanese,
                liveConversionEnabled: false,
                keyBindingStyle: .macOS
            )
            guard case .removeLastMarkedText = legacyAction else {
                Issue.record("Backspace in \(state) with macOS style should delete, got \(legacyAction)")
                return
            }
        }
    }

    @Test("候補選択中の Enter は残りの文節ごと確定する")
    func enterCommitsAllSegments() {
        let enter = self.event("\r", [], keyCode: 0x24)
        let (clientAction, callback) = InputState.selecting.event(
            eventCore: enter,
            userAction: .enter,
            inputLanguage: .japanese,
            liveConversionEnabled: false,
            keyBindingStyle: .msIME
        )
        guard case .commitAllCandidates = clientAction, case .transition(.none) = callback else {
            Issue.record("Enter in selecting should commit all, got \(clientAction), \(callback)")
            return
        }
        let (legacyAction, _) = InputState.selecting.event(
            eventCore: enter,
            userAction: .enter,
            inputLanguage: .japanese,
            liveConversionEnabled: false,
            keyBindingStyle: .macOS
        )
        guard case .submitSelectedCandidate = legacyAction else {
            Issue.record("Enter in selecting with macOS style should submit only the selected candidate, got \(legacyAction)")
            return
        }
    }

    @MainActor
    @Test("変換取消のあとはひらがなに戻り、文節編集もリセットされて末尾に入力が続く")
    func cancelConversionRestoresHiragana() {
        let manager = SegmentsManager(
            kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
            applicationDirectoryURL: freshTestLearningDirectory(),
            personalizationDirectoryURL: nil,
            context: .init(useZenzai: false)
        )
        manager.insertAtCursorPosition("kyouha", inputStyle: .roman2kana)
        #expect(manager.convertTarget == "きょうは")
        manager.insertCompositionSeparator(inputStyle: .roman2kana, skipUpdate: true)
        manager.update(requestRichCandidates: true)
        // Cancel from a state where a segment was shortened and a candidate was selected.
        manager.editSegment(count: -1)
        manager.requestSelectingNextCandidate()
        #expect(manager.selectedCandidate != nil)

        manager.cancelConversion()

        #expect(manager.selectedCandidate == nil)
        #expect(manager.convertTarget == "きょうは")
        let marked = manager.getCurrentMarkedText(inputState: .composing)
        #expect(marked.map(\.content).joined() == "きょうは")
        if case .hidden = manager.getCurrentCandidateWindow(inputState: .selecting) {
        } else {
            Issue.record("Candidate window should be hidden after cancel")
        }
        // Characters typed next are added at the end.
        manager.insertAtCursorPosition("i", inputStyle: .roman2kana)
        #expect(manager.convertTarget == "きょうはい")
    }
}
