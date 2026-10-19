extension Config {
    enum Deprecated {}
}

extension Config.Deprecated {
    /// Setting to type 「,」「.」 instead of 「、」「。」
    /// - note: Replaced by PunctuationStyle in v0.1.2 and later
    struct TypeCommaAndPeriod: BoolConfigItem {
        static let `default` = false
        static let key: String = "org.if0.inputmethod.ogura.preference.typeCommaAndPeriod"
    }

    /// Setting to use Zenzai
    /// - note: Removed in v0.1.2 and later. Zenzai is always on.
    @available(*, deprecated, message: "ZenzaiIntegration.value is always true")
    struct ZenzaiIntegration: BoolConfigItem {
        static let `default` = true
        static let key: String = "org.if0.inputmethod.ogura.preference.enableZenzai"
    }

}
