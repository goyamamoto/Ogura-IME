import Foundation
import KanaKanjiConverterModule

public enum InputState: Sendable, Hashable {
    case none
    case attachDiacritic(String)
    case composing
    case previewing
    case selecting
    case unicodeInput(String)

    // This kind of code can only get complex, so disable the lint
    // swiftlint:disable:next cyclomatic_complexity
    public func event(
        eventCore event: KeyEventCore,
        userAction: UserAction,
        inputLanguage: InputLanguage,
        liveConversionEnabled: Bool,
        keyBindingStyle: Config.KeyBindingStyle.Value = .macOS
    ) -> (ClientAction, ClientActionCallback) {
        if case .continuation = userAction {
            switch self {
            case .none:
                return (.requestContinuation, .fallthrough)
            case .composing, .previewing, .selecting:
                return (.commitMarkedTextAndRequestContinuation, .transition(.none))
            case .attachDiacritic, .unicodeInput:
                return (.fallthrough, .fallthrough)
            }
        }
        if event.modifierFlags.contains(.command) {
            return (.fallthrough, .fallthrough)
        }
        if event.modifierFlags.contains(.option) {
            switch userAction {
            case .input, .deadKey, .backspace, .deleteForward:
                break
            case .enter where self == .composing:
                break
            case .tab where self == .composing || self == .previewing || self == .selecting:
                break
            case .navigation(let direction) where self == .composing || self == .previewing || self == .selecting:
                switch direction {
                case .up, .down, .left, .right:
                    return (.consume, .fallthrough)
                }
            case .escape where self == .composing || self == .previewing || self == .selecting:
                return (.consume, .fallthrough)
            case .英数 where self == .composing || self == .previewing || self == .selecting:
                return (.consume, .fallthrough)
            case .かな where self == .composing || self == .previewing || self == .selecting:
                return (.consume, .fallthrough)
            default:
                return (.fallthrough, .fallthrough)
            }
        }
        if event.modifierFlags.contains(.control) {
            switch userAction {
            case .unknown where self == .composing || self == .previewing || self == .selecting:
                return (.consume, .fallthrough)
            default:
                break
            }
        }
        switch self {
        case .none:
            switch userAction {
            case .input(let string):
                switch inputLanguage {
                case .japanese:
                    return (.appendPieceToMarkedText(string), .transition(.composing))
                case .english:
                    // Insert directly
                    return (.insertWithoutMarkedText(string.inputString(preferIntention: true)), .fallthrough)
                }
            case .deadKey(let diacritic):
                if inputLanguage == .english {
                    return (.consume, .transition(.attachDiacritic(diacritic)))
                } else {
                    return (.fallthrough, .fallthrough)
                }
            case .number(let number):
                switch inputLanguage {
                case .japanese:
                    return (.appendPieceToMarkedText([number.inputPiece]), .transition(.composing))
                case .english:
                    return (.insertWithoutMarkedText(number.inputString), .fallthrough)
                }
            case .英数:
                return (.selectInputLanguage(.english), .fallthrough)
            case .かな:
                return (.selectInputLanguage(.japanese), .fallthrough)
            case .space(let isFullSpace):
                if inputLanguage != .english && isFullSpace {
                    return (.insertWithoutMarkedText("　"), .fallthrough)
                } else {
                    return (.insertWithoutMarkedText(" "), .fallthrough)
                }
            case .startUnicodeInput:
                return (.enterUnicodeInputMode, .transition(.unicodeInput("")))
            case .unknown, .navigation, .backspace, .deleteForward, .enter, .escape, .function, .editSegment, .tab, .forget, .continuation:
                return (.fallthrough, .fallthrough)
            }
        case .attachDiacritic(let diacritic):
            switch userAction {
            case .input(let string):
                let string = string.inputString(preferIntention: true)
                if let result = DiacriticAttacher.attach(deadKeyChar: diacritic, with: string, shift: event.modifierFlags.contains(.shift)) {
                    return (.insertWithoutMarkedText(result), .transition(.none))
                } else {
                    return (.insertWithoutMarkedText(diacritic + string), .transition(.none))
                }
            case .deadKey(let newDiacritic):
                return (.insertWithoutMarkedText(diacritic), .transition(.attachDiacritic(newDiacritic)))
            case .number(let number):
                return (.insertWithoutMarkedText(diacritic + number.inputString), .transition(.none))
            case .backspace, .escape:
                return (.stopComposition, .transition(.none))
            case .かな:
                return (.selectInputLanguage(.japanese), .transition(.none))
            case .function:
                return (.consume, .fallthrough)
            case .enter:
                return (.insertWithoutMarkedText(diacritic + "\n"), .transition(.none))
            case .tab:
                return (.insertWithoutMarkedText(diacritic + "\t"), .transition(.none))
            case .startUnicodeInput:
                return (.insertWithoutMarkedText(diacritic), .transition(.unicodeInput("")))
            case .unknown, .space, .英数, .navigation, .editSegment, .forget, .deleteForward, .continuation:
                return (.insertWithoutMarkedText(diacritic), .transition(.none))
            }
        case .composing:
            switch userAction {
            case .input(let string):
                return (.appendPieceToMarkedText(string), .fallthrough)
            case .number(let number):
                return (.appendPieceToMarkedText([number.inputPiece]), .fallthrough)
            case .backspace:
                if event.modifierFlags.contains(.option) {
                    return (.consume, .fallthrough)
                } else {
                    return (.removeLastMarkedText, .basedOnBackspace(ifIsEmpty: .none, ifIsNotEmpty: .composing))
                }
            case .deleteForward:
                // Forward delete during conversion is handled by the IME, not passed through to the app (#355)
                if event.modifierFlags.contains(.option) {
                    return (.consume, .fallthrough)
                } else {
                    return (.removeForwardMarkedText, .basedOnBackspace(ifIsEmpty: .none, ifIsNotEmpty: .composing))
                }
            case .enter:
                if event.modifierFlags.contains(.option) {
                    return (.consume, .fallthrough)
                } else {
                    return (.commitMarkedText, .transition(.none))
                }
            case .escape:
                return (.stopComposition, .transition(.none))
            case .space:
                if inputLanguage == .english {
                    return (.appendToMarkedText(" "), .fallthrough)
                } else if liveConversionEnabled {
                    return (.enterCandidateSelectionMode, .transition(.selecting))
                } else {
                    return (.enterFirstCandidatePreviewMode, .transition(.previewing))
                }
            case let .function(function):
                switch function {
                case .six:
                    return (.submitHiraganaCandidate, .transition(.none))
                case .seven:
                    return (.submitKatakanaCandidate, .transition(.none))
                case .eight:
                    return (.submitHankakuKatakanaCandidate, .transition(.none))
                case .nine:
                    return (.submitFullWidthRomanCandidate, .transition(.none))
                case .ten:
                    return (.submitHalfWidthRomanCandidate, .transition(.none))
                }
            case .forget:
                return (.consume, .fallthrough)
            case .tab:
                if event.modifierFlags.contains(.option) {
                    return (.consume, .fallthrough)
                } else {
                    return (.acceptPredictionCandidate, .fallthrough)
                }
            case .英数:
                return (.selectInputLanguage(.english), .fallthrough)
            case .かな:
                return (.selectInputLanguage(.japanese), .fallthrough)
            case .navigation(let direction):
                if direction == .down {
                    return (.enterCandidateSelectionMode, .transition(.selecting))
                } else if direction == .right && event.modifierFlags.contains(.shift) {
                    return (.editSegment(1), .transition(.selecting))
                } else if direction == .left && event.modifierFlags.contains(.shift) {
                    return (.editSegment(-1), .transition(.selecting))
                } else {
                    // Consume navigation keys
                    return (.consume, .fallthrough)
                }
            case .editSegment(let count):
                return (.editSegment(count), .transition(.selecting))
            case .startUnicodeInput:
                return (.commitMarkedText, .transition(.unicodeInput("")))
            case .unknown, .deadKey, .continuation:
                return (.fallthrough, .fallthrough)
            }
        case .previewing:
            switch userAction {
            case .input(let string):
                return (.commitMarkedTextAndAppendPieceToMarkedText(string), .transition(.composing))
            case .number(let number):
                return (.commitMarkedTextAndAppendPieceToMarkedText([number.inputPiece]), .transition(.composing))
            case .backspace:
                if event.modifierFlags.contains(.option) {
                    return (.consume, .fallthrough)
                } else if keyBindingStyle == .msIME {
                    // MS-IME: BackSpace after conversion does not delete a character. It cancels the conversion and goes back to hiragana
                    return (.cancelConversion, .transition(.composing))
                } else {
                    return (.removeLastMarkedText, .transition(.composing))
                }
            case .deleteForward where keyBindingStyle == .msIME:
                return (.cancelConversion, .transition(.composing))
            case .enter:
                return (.commitMarkedText, .transition(.none))
            case .space:
                return (.enterCandidateSelectionMode, .transition(.selecting))
            case .escape:
                return (.hideCandidateWindow, .transition(.composing))
            case let .function(function):
                switch function {
                case .six:
                    return (.submitHiraganaCandidate, .transition(.none))
                case .seven:
                    return (.submitKatakanaCandidate, .transition(.none))
                case .eight:
                    return (.submitHankakuKatakanaCandidate, .transition(.none))
                case .nine:
                    return (.submitFullWidthRomanCandidate, .transition(.none))
                case .ten:
                    return (.submitHalfWidthRomanCandidate, .transition(.none))
                }
            case .英数:
                return (.selectInputLanguage(.english), .fallthrough)
            case .かな:
                return (.selectInputLanguage(.japanese), .fallthrough)
            case .forget, .tab, .deleteForward:
                return (.consume, .fallthrough)
            case .navigation(let direction):
                if direction == .down {
                    return (.enterCandidateSelectionMode, .transition(.selecting))
                } else if direction == .right && event.modifierFlags.contains(.shift) {
                    return (.editSegment(1), .transition(.selecting))
                } else if direction == .left && event.modifierFlags.contains(.shift) {
                    return (.editSegment(-1), .transition(.selecting))
                } else {
                    // Consume navigation keys
                    return (.consume, .fallthrough)
                }
            case .editSegment(let count):
                return (.editSegment(count), .transition(.selecting))
            case .startUnicodeInput:
                return (.commitMarkedText, .transition(.unicodeInput("")))
            case .unknown, .deadKey, .continuation:
                return (.fallthrough, .fallthrough)
            }
        case .selecting:
            switch userAction {
            case .input(let string):
                // FIXME: This differs from the macOS standard. In the macOS standard, selecting goes back to composing and input continues.
                return (.commitMarkedTextAndAppendPieceToMarkedText(string), .transition(.composing))
            case .enter:
                if keyBindingStyle == .msIME {
                    // MS-IME: Enter commits the selected candidate and the remaining segments together
                    return (.commitAllCandidates, .transition(.none))
                } else {
                    return (.submitSelectedCandidate, .basedOnSubmitCandidate(ifIsEmpty: .none, ifIsNotEmpty: .previewing))
                }
            case .backspace:
                if event.modifierFlags.contains(.option) {
                    return (.consume, .fallthrough)
                } else if keyBindingStyle == .msIME {
                    return (.cancelConversion, .transition(.composing))
                } else {
                    return (.removeLastMarkedText, .basedOnBackspace(ifIsEmpty: .none, ifIsNotEmpty: .composing))
                }
            case .deleteForward where keyBindingStyle == .msIME:
                return (.cancelConversion, .transition(.composing))
            case .escape:
                if liveConversionEnabled {
                    return (.hideCandidateWindow, .transition(.composing))
                } else {
                    return (.enterFirstCandidatePreviewMode, .transition(.previewing))
                }
            case .space:
                // If Shift is held, move up
                if event.modifierFlags.contains(.shift) {
                    return (.selectPrevCandidate, .fallthrough)
                } else {
                    return (.selectNextCandidate, .fallthrough)
                }
            case .navigation(let direction):
                if direction == .right {
                    if event.modifierFlags.contains(.shift) {
                        return (.editSegment(1), .fallthrough)
                    } else {
                        return (.submitSelectedCandidate, .basedOnSubmitCandidate(ifIsEmpty: .none, ifIsNotEmpty: .selecting))
                    }
                } else if direction == .left && event.modifierFlags.contains(.shift) {
                    return (.editSegment(-1), .fallthrough)
                } else if direction == .down {
                    return (.selectNextCandidate, .fallthrough)
                } else if direction == .up {
                    return (.selectPrevCandidate, .fallthrough)
                } else {
                    return (.consume, .fallthrough)
                }
            case let .function(function):
                switch function {
                case .six:
                    return (.submitHiraganaCandidate, .basedOnSubmitCandidate(ifIsEmpty: .none, ifIsNotEmpty: .selecting))
                case .seven:
                    return (.submitKatakanaCandidate, .basedOnSubmitCandidate(ifIsEmpty: .none, ifIsNotEmpty: .selecting))
                case .eight:
                    return (.submitHankakuKatakanaCandidate, .basedOnSubmitCandidate(ifIsEmpty: .none, ifIsNotEmpty: .selecting))
                case .nine:
                    return (.submitFullWidthRomanCandidate, .basedOnSubmitCandidate(ifIsEmpty: .none, ifIsNotEmpty: .selecting))
                case .ten:
                    return (.submitHalfWidthRomanCandidate, .basedOnSubmitCandidate(ifIsEmpty: .none, ifIsNotEmpty: .selecting))
                }
            case .number(let num):
                switch num {
                case .one, .two, .three, .four, .five, .six, .seven, .eight, .nine:
                    return (.selectNumberCandidate(num.intValue), .basedOnSubmitCandidate(ifIsEmpty: .none, ifIsNotEmpty: .previewing))
                case .zero, .shiftZero:
                    return (.commitMarkedTextAndAppendPieceToMarkedText([num.inputPiece]), .transition(.composing))
                }
            case .editSegment(let count):
                return (.editSegment(count), .transition(.selecting))
            case .forget:
                return (.forgetMemory, .fallthrough)
            case .英数:
                // In this case, commit and start alphanumeric input
                // FIXME: This differs from the macOS standard. Specifically, only the equivalent of selectInputLanguage(.english) happens.
                return (.commitMarkedTextAndSelectInputLanguage(.english), .fallthrough)
            case .かな:
                return (.selectInputLanguage(.japanese), .fallthrough)
            case .tab, .deleteForward:
                return (.consume, .fallthrough)
            case .startUnicodeInput:
                return (.submitSelectedCandidateAndEnterUnicodeInputMode, .transition(.unicodeInput("")))
            case .unknown, .deadKey, .continuation:
                return (.fallthrough, .fallthrough)
            }
        case .unicodeInput(let codePoint):
            switch userAction {
            case .input(let pieces):
                let input = pieces.inputString(preferIntention: true).lowercased()
                // Accept hexadecimal digits only
                let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
                let filteredInput = input.unicodeScalars.filter { hexChars.contains($0) }.map { String($0) }.joined()
                if !filteredInput.isEmpty {
                    return (.appendToUnicodeInput(filteredInput), .transition(.unicodeInput(codePoint + filteredInput)))
                } else {
                    return (.consume, .fallthrough)
                }
            case .number(let number):
                let digit = number.inputString
                return (.appendToUnicodeInput(digit), .transition(.unicodeInput(codePoint + digit)))
            case .backspace:
                if codePoint.isEmpty {
                    return (.cancelUnicodeInput, .transition(.none))
                } else {
                    let newCodePoint = String(codePoint.dropLast())
                    return (.removeLastUnicodeInput, .transition(.unicodeInput(newCodePoint)))
                }
            case .enter, .space:
                if codePoint.isEmpty {
                    return (.cancelUnicodeInput, .transition(.none))
                } else {
                    return (.submitUnicodeInput(codePoint), .transition(.none))
                }
            case .escape:
                return (.cancelUnicodeInput, .transition(.none))
            case .英数, .かな, .tab, .forget, .function, .navigation, .editSegment, .deadKey, .startUnicodeInput, .unknown, .deleteForward, .continuation:
                return (.consume, .fallthrough)
            }
        }
    }
}
