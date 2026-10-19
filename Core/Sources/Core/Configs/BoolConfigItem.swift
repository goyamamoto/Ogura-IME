import Foundation

protocol BoolConfigItem: ConfigItem<Bool> {
    static var `default`: Bool { get }
}

extension BoolConfigItem {
    public var value: Bool {
        get {
            if let value = Config.object(forKey: Self.key) {
                value as? Bool ?? Self.default
            } else {
                Self.default
            }
        }
        nonmutating set {
            Config.set(newValue, forKey: Self.key)
        }
    }
}

extension Config {
    /// Setting that enables debug features for prediction
    public struct DebugPredictiveTyping: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "org.if0.inputmethod.ogura.preference.debug.predictiveTyping"
    }
    /// Setting that enables live conversion
    public struct LiveConversion: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "org.if0.inputmethod.ogura.preference.enableLiveConversion"
    }
    /// Setting to type a backslash instead of the yen sign
    public struct TypeBackSlash: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "org.if0.inputmethod.ogura.preference.typeBackSlash"
    }
    /// Setting to type a half-width space (" ") instead of a full-width space (U+3000)
    public struct TypeHalfSpace: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "org.if0.inputmethod.ogura.preference.typeHalfSpace"
    }
    /// Setting to type symbols (% + = and so on) in half width rather than full width. The punctuation keys, the long
    /// vowel mark ー, the middle dot ・, and the brackets 「」『』 are Japanese writing and stay full width
    /// (`UserAction.halfWidthSymbolKeys`)
    public struct TypeHalfWidthSymbols: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "org.if0.inputmethod.ogura.preference.typeHalfWidthSymbols"
    }
    /// Setting to type full-width alphanumerics directly while the Option key is held
    public struct OptionDirectFullWidthInput: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "org.if0.inputmethod.ogura.preference.optionDirectFullWidthInput"
    }
    /// Setting to keep the input in Latin letters until it is committed when it starts with an uppercase letter (Shift+letter),
    /// as MS-IME and Google Japanese Input do. Off by default: a capital then starts a Latin word, and typing goes back to
    /// kana after it (see `LatinInputGuess`). Without live conversion the input always behaves as if this were on.
    public struct UppercaseStartsAlphabetInput: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "org.if0.inputmethod.ogura.preference.uppercaseStartsAlphabetInput"
    }
    /// Setting to offer the letters as typed as a conversion candidate when the input does not look like Japanese (see `LatinInputGuess`)
    public struct LatinCandidateForNonJapaneseInput: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "org.if0.inputmethod.ogura.preference.latinCandidateForNonJapaneseInput"
    }
    /// Setting to tell Latin words from romaji with the learned identification layer (see `TaggerScriptIdentifier`)
    /// rather than the rules (`RuleBasedScriptIdentifier`). On by default: the model gets 73 of the 73 hand-written
    /// sentences and 380 of 386 system messages right against the rules' 63 and 279 (see docs/latin-identification.md)
    public struct LearnedScriptIdentification: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "org.if0.inputmethod.ogura.preference.learnedScriptIdentification"
    }
}
