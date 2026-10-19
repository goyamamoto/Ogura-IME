import Foundation

extension Config {
    /// Model used for 「続きを書く」 ("continue writing"). Only on-device models can be selected.
    public struct Continuation: CustomCodableConfigItem {
        public enum Value: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
            case off
            /// Apple's on-device model on macOS 26 (Foundation Models)
            case foundationModels
            /// MLX-format model stored on this Mac (Apple Silicon)
            case localModel
        }

        public init() {}
        public static let `default`: Value = .foundationModels
        public static let key: String = "org.if0.inputmethod.ogura.preference.continuation"
    }

    /// Folder name of the MLX model used for "continue writing" (inside the `LocalContinuationModels` directory)
    public struct ContinuationLocalModelName: StringConfigItem {
        public init() {}
        public static let key: String = "org.if0.inputmethod.ogura.preference.continuation.localModelName"
    }

    /// Continue writing with Shift+Tab
    public struct ContinuationKeyShiftTab: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "org.if0.inputmethod.ogura.preference.continuation.key.shiftTab"
    }
    /// Continue writing with Ctrl+/
    public struct ContinuationKeyControlSlash: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "org.if0.inputmethod.ogura.preference.continuation.key.controlSlash"
    }
    /// Continue writing with F19 (meant to be assigned on the keyboard side)
    public struct ContinuationKeyF19: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "org.if0.inputmethod.ogura.preference.continuation.key.f19"
    }
}

/// Key combinations that trigger "continue writing"
public struct ContinuationKeys: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shiftTab = ContinuationKeys(rawValue: 1 << 0)
    public static let controlSlash = ContinuationKeys(rawValue: 1 << 1)
    public static let f19 = ContinuationKeys(rawValue: 1 << 2)
    public static let all: ContinuationKeys = [.shiftTab, .controlSlash, .f19]

    /// Read from the settings
    public static var current: ContinuationKeys {
        var keys: ContinuationKeys = []
        if Config.ContinuationKeyShiftTab().value { keys.insert(.shiftTab) }
        if Config.ContinuationKeyControlSlash().value { keys.insert(.controlSlash) }
        if Config.ContinuationKeyF19().value { keys.insert(.f19) }
        return keys
    }
}
