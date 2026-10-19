import Foundation

/// namespace for `Config`
public enum Config {
    /// Inside the sandbox this is the settings file in the app's own container (the App Group suite is not used)
    nonisolated(unsafe) public static let userDefaults: UserDefaults = .standard

    public static func object(forKey key: String) -> Any? {
        Self.userDefaults.object(forKey: key)
    }

    public static func data(forKey key: String) -> Data? {
        Self.userDefaults.data(forKey: key)
    }

    public static func string(forKey key: String) -> String? {
        Self.userDefaults.string(forKey: key)
    }

    public static func set(_ value: Any?, forKey key: String) {
        Self.userDefaults.set(value, forKey: key)
    }
}

public protocol ConfigItem<Value> {
    static var key: String { get }
    associatedtype Value: Codable
    var value: Value { get nonmutating set }
}
