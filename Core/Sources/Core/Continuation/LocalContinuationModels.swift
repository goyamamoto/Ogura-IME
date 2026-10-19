import Foundation

/// Where MLX models on this Mac are stored. A folder `<Application Support>/Ogura/models/<name>/`
/// that holds config.json, safetensors, and tokenizer.json is treated as a model
public enum LocalContinuationModels {
    public static let directoryName = "models"

    public static func directoryURL(fileManager: FileManager = .default) -> URL {
        AppContainer.applicationSupportDirectoryURL(fileManager: fileManager).appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    public static func modelDirectoryURL(named name: String, fileManager: FileManager = .default) -> URL {
        Self.directoryURL(fileManager: fileManager).appendingPathComponent(name, isDirectory: true)
    }

    /// Returns the names of the installed models (folder names), sorted by name
    public static func installedModelNames(fileManager: FileManager = .default) -> [String] {
        Self.installedModelNames(in: Self.directoryURL(fileManager: fileManager), fileManager: fileManager)
    }

    public static func installedModelNames(in directory: URL, fileManager: FileManager = .default) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries
            .filter { Self.isModelDirectory($0, fileManager: fileManager) }
            .map(\.lastPathComponent)
            .sorted()
    }

    public static func isModelDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return fileManager.fileExists(atPath: url.appendingPathComponent("config.json").path)
    }
}
