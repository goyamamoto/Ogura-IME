import Foundation

public struct KeyEventCore: Codable, Sendable, Equatable {
    public struct ModifierFlag: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let shift   = ModifierFlag(rawValue: 1 << 0)
        public static let control = ModifierFlag(rawValue: 1 << 1)
        public static let option  = ModifierFlag(rawValue: 1 << 2)
        public static let command = ModifierFlag(rawValue: 1 << 3)
    }

    public init(modifierFlags: ModifierFlag, characters: String?, charactersIgnoringModifiers: String?, keyCode: UInt16, timestamp: TimeInterval? = nil) {
        self.modifierFlags = modifierFlags
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.keyCode = keyCode
        self.timestamp = timestamp
    }
    public var modifierFlags: ModifierFlag
    public var characters: String?
    public var charactersIgnoringModifiers: String?
    public var keyCode: UInt16
    /// When the key was pressed, in seconds since the system started (NSEvent.timestamp, ProcessInfo.systemUptime): the
    /// key is handled later when the main thread was busy. Nil when not known
    public var timestamp: TimeInterval?

    /// The same key, whenever it was pressed
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.modifierFlags == rhs.modifierFlags && lhs.characters == rhs.characters
            && lhs.charactersIgnoringModifiers == rhs.charactersIgnoringModifiers && lhs.keyCode == rhs.keyCode
    }
}
