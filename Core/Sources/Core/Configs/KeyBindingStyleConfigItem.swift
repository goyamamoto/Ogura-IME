import Foundation

extension Config {
    /// Style of key bindings for conversion operations
    public struct KeyBindingStyle: CustomCodableConfigItem {
        public enum Value: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
            /// Same bindings as MS-IME on Windows (Ctrl+U/I/O/P/T, BackSpace during conversion cancels the conversion, Enter commits everything)
            case msIME
            /// azooKey / macOS standard (Ctrl+J/K/L, cursor movement with Ctrl+P/N/F/B)
            case macOS
        }

        public init() {}
        public static let `default`: Value = .msIME
        public static let key: String = "org.if0.inputmethod.ogura.preference.keyBindingStyle"
    }
}
