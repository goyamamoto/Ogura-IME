import Core
import Foundation
import KanaKanjiConverterModule
import Testing

/// The text the pieces of an input action make, intentions preferred (％ for the % key)
private func inputString(from action: UserAction) -> String? {
    guard case .input(let pieces) = action else {
        return nil
    }
    return pieces.inputString(preferIntention: true)
}

/// What the key `key` makes in the Japanese mode
private func typed(_ key: String, modifiers: KeyEventCore.ModifierFlag = [], halfWidthSymbols: Bool, typeBackSlash: Bool = false) -> String? {
    inputString(from: UserAction.getUserAction(
        eventCore: KeyEventCore(modifierFlags: modifiers, characters: key, charactersIgnoringModifiers: key, keyCode: 0),
        inputLanguage: .japanese,
        typeBackSlash: typeBackSlash,
        typeHalfWidthSymbols: halfWidthSymbols
    ))
}

@Test func testHalfWidthSymbolsKeepSymbolKeysAsTyped() {
    for (key, fullWidth) in [("%", "％"), ("+", "＋"), ("=", "＝"), ("(", "（"), (")", "）"), ("?", "？"), ("!", "！"), ("@", "＠"), (":", "："), ("~", "〜"), ("\"", "”"), ("¥", "￥")] {
        #expect(typed(key, halfWidthSymbols: false) == fullWidth, "\(key)")
        #expect(typed(key, halfWidthSymbols: true) == key, "\(key)")
    }
    // The backslash key is the yen key unless Config.TypeBackSlash says otherwise
    #expect(typed("\\", halfWidthSymbols: true) == "¥")
    #expect(typed("\\", halfWidthSymbols: false, typeBackSlash: true) == "＼")
    #expect(typed("\\", halfWidthSymbols: true, typeBackSlash: true) == "\\")
}

@Test func testJapaneseWritingStaysFullWidthWithHalfWidthSymbols() {
    // The long vowel mark, the middle dot, and the brackets are Japanese writing, not symbols
    for (key, fullWidth) in [("-", "ー"), ("/", "・"), ("[", "「"), ("]", "」"), ("{", "『"), ("}", "』")] {
        #expect(typed(key, halfWidthSymbols: true) == fullWidth, "\(key)")
    }
    // The punctuation keys follow the punctuation setting either way (another test may be changing it meanwhile)
    #expect(["、", "，"].contains(typed(",", halfWidthSymbols: true)))
    #expect(["。", "．"].contains(typed(".", halfWidthSymbols: true)))
}

@Test func testOptionBracketsAreHalfWidthWithHalfWidthSymbols() {
    // With Option the keys make the bracket symbols rather than かぎかっこ: full width normally, half width in the mode
    struct OptionKey {
        var key: String
        var modifiers: KeyEventCore.ModifierFlag
        var fullWidth: String
        var halfWidth: String
    }
    let cases = [
        OptionKey(key: "[", modifiers: [.option], fullWidth: "［", halfWidth: "["),
        OptionKey(key: "[", modifiers: [.shift, .option], fullWidth: "｛", halfWidth: "{"),
        OptionKey(key: "]", modifiers: [.option], fullWidth: "］", halfWidth: "]"),
        OptionKey(key: "]", modifiers: [.shift, .option], fullWidth: "｝", halfWidth: "}"),
        OptionKey(key: "/", modifiers: [.option], fullWidth: "／", halfWidth: "/")
    ]
    for optionKey in cases {
        #expect(typed(optionKey.key, modifiers: optionKey.modifiers, halfWidthSymbols: false) == optionKey.fullWidth, "\(optionKey.key)")
        #expect(typed(optionKey.key, modifiers: optionKey.modifiers, halfWidthSymbols: true) == optionKey.halfWidth, "\(optionKey.key)")
    }
    // English input is letters and symbols as typed either way
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: KeyEventCore(modifierFlags: [], characters: "%", charactersIgnoringModifiers: "%", keyCode: 0),
        inputLanguage: .english,
        typeHalfWidthSymbols: false
    )) == "%")
}
