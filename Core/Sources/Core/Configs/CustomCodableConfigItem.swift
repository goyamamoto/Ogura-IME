//
//  LearningConfig.swift
//  Ogura
//
//  Created by miwa on 2024/04/27.
//

import Foundation
import struct KanaKanjiConverterModuleWithDefaultDictionary.ConvertRequestOptions
import enum KanaKanjiConverterModuleWithDefaultDictionary.LearningType

protocol CustomCodableConfigItem: ConfigItem {
    static var `default`: Value { get }
}

extension CustomCodableConfigItem {
    public var value: Value {
        get {
            guard let data = Config.data(forKey: Self.key) else {
                print(#file, #line, "data is not set yet")
                return Self.default
            }
            do {
                let decoded = try JSONDecoder().decode(Value.self, from: data)
                return decoded
            } catch {
                print(#file, #line, error)
                return Self.default
            }
        }
        nonmutating set {
            do {
                let encoded = try JSONEncoder().encode(newValue)
                Config.set(encoded, forKey: Self.key)
            } catch {
                print(#file, #line, error)
            }
        }
    }
}

extension Config {
    /// Setting for what the converter learns from (input and output, output only, or nothing)
    public struct Learning: CustomCodableConfigItem {
        public enum Value: String, Codable, Equatable, Hashable, Sendable {
            case inputAndOutput
            case onlyOutput
            case nothing

            public var learningType: LearningType {
                switch self {
                case .inputAndOutput:
                    .inputAndOutput
                case .onlyOutput:
                    .onlyOutput
                case .nothing:
                    .nothing
                }
            }
        }

        public init() {}
        static let `default`: Value = .inputAndOutput
        public static let key: String = "org.if0.inputmethod.ogura.preference.learning"
    }
}

extension Config {
    public struct UserDictionaryEntry: Sendable, Codable, Identifiable {
        public init(word: String, reading: String, hint: String? = nil) {
            self.id = UUID()
            self.word = word
            self.reading = reading
            self.hint = hint
        }

        public var id: UUID
        public var word: String
        public var reading: String
        var hint: String?

        public var nonNullHint: String {
            get {
                hint ?? ""
            }
            set {
                if newValue.isEmpty {
                    hint = nil
                } else {
                    hint = newValue
                }
            }
        }
    }

    public struct UserDictionary: CustomCodableConfigItem {
        public struct Value: Codable, Sendable {
            public var items: [UserDictionaryEntry]
        }

        public var items: Value = Self.default

        public init(items: Value = Self.default) {
            self.items = items
        }

        public static let `default`: Value = .init(items: [
            .init(word: "Ogura", reading: "おぐら", hint: "アプリ")
        ])
        public static let key: String = "org.if0.inputmethod.ogura.preference.user_dictionary_temporal2"
    }

    public struct SystemUserDictionary: CustomCodableConfigItem {
        public struct Value: Codable, Sendable {
            public var lastUpdate: Date?
            public var items: [UserDictionaryEntry]
        }

        public var items: Value = Self.default

        public init(items: Value = Self.default) {
            self.items = items
        }

        public static let `default`: Value = .init(items: [])
        public static let key: String = "org.if0.inputmethod.ogura.preference.system_user_dictionary"
    }
}

extension Config {
    /// Personalization strength for Zenzai
    public struct ZenzaiPersonalizationLevel: CustomCodableConfigItem {
        public enum Value: String, Codable, Equatable, Hashable, Sendable {
            case off
            case soft
            case normal
            case hard

            public var alpha: Float {
                switch self {
                case .off:
                    0
                case .soft:
                    0.5
                case .normal:
                    1.0
                case .hard:
                    1.5
                }
            }
        }

        public init() {}
        public static let `default`: Value = .normal
        public static let key: String = "org.if0.inputmethod.ogura.preference.zenzai.personalization_level"
    }

    /// The Zenzai model the conversion uses
    public struct ZenzaiModel: CustomCodableConfigItem {
        public enum Value: String, Codable, Equatable, Hashable, Sendable {
            /// zenz-v3.2-small
            case zenz
            /// genmai, a fine-tune of zenz-v2.5-medium about three times as large as zenz-v3.2-small: more accurate,
            /// slower. zenz-v3.2-small when the resources have no genmai (see Tools/build_genmai_gguf.sh)
            case genmai
        }

        public init() {}
        public static let `default`: Value = .genmai
        public static let key: String = "org.if0.inputmethod.ogura.preference.zenzai.model"
    }
}

extension Config {
    public struct InputStyle: CustomCodableConfigItem {
        public enum Value: String, Codable, Equatable, Hashable, Sendable {
            case `default`
            case defaultAZIK
            case defaultKanaJIS
            case defaultKanaUS
            case custom
        }

        public init() {}
        public static let `default`: Value = .default
        public static let key: String = "org.if0.inputmethod.ogura.preference.input_style"
    }
}

extension Config {
    /// Keyboard layout setting
    public struct KeyboardLayout: CustomCodableConfigItem {
        public enum Value: String, Codable, Equatable, Hashable, Sendable {
            case qwerty
            case australian
            case british
            case colemak
            case dvorak
            case dvorakQwertyCommand

            public var layoutIdentifier: String {
                switch self {
                case .qwerty:
                    return "com.apple.keylayout.US"
                case .australian:
                    return "com.apple.keylayout.Australian"
                case .british:
                    return "com.apple.keylayout.British"
                case .colemak:
                    return "com.apple.keylayout.Colemak"
                case .dvorak:
                    return "com.apple.keylayout.Dvorak"
                case .dvorakQwertyCommand:
                    return "com.apple.keylayout.DVORAK-QWERTYCMD"
                }
            }
        }

        public init() {}
        public static let `default`: Value = .qwerty
        public static let key: String = "org.if0.inputmethod.ogura.preference.keyboard_layout"
    }

}
