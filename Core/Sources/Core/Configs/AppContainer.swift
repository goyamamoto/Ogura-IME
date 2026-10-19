import Foundation

/// Storage location inside the app's own sandbox container.
///
/// We do not use an App Group (shared container). With ad-hoc signing and no certificate, the app cannot have an App Group tied to a Team ID,
/// and on macOS 15 and later, every access to such a shared container asks the user for permission to "access data from other apps".
/// Inside the sandbox this is `~/Library/Containers/<bundle id>/Data/Library/Application Support/Ogura`.
public enum AppContainer {
    #if os(macOS)
    public static func applicationSupportDirectoryURL(fileManager: FileManager = .default) -> URL {
        Self.applicationSupportDirectoryURL(
            libraryApplicationSupportURL: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        )
    }

    static func applicationSupportDirectoryURL(libraryApplicationSupportURL: URL) -> URL {
        libraryApplicationSupportURL.appendingPathComponent("Ogura", isDirectory: true)
    }

    /// Where learning history and the user dictionary are stored
    public static func memoryDirectoryURL(fileManager: FileManager = .default) -> URL {
        Self.applicationSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("memory", isDirectory: true)
    }

    /// Where the personalized models (`lm_*.marisa`) produced by Tuner are stored
    public static func personalizationDirectoryURL(fileManager: FileManager = .default) -> URL {
        Self.applicationSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("p13n_v1", isDirectory: true)
    }
    #endif
}
