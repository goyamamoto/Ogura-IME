import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@testable import Core

/// Tests that lock in the input data protection guarantees at the level of source code and build settings.
/// Each test matches an item in docs/privacy.md.
@Suite("データ保護")
struct DataProtectionTests {
    /// This file is in Core/Tests/CoreTests/SecurityTests/
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SecurityTests
        .deletingLastPathComponent()  // CoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // Core
        .deletingLastPathComponent()  // repository root

    private static func swiftFiles(under relativePaths: [String]) throws -> [(path: String, text: String)] {
        var results: [(String, String)] = []
        for relativePath in relativePaths {
            let root = Self.repositoryRoot.appendingPathComponent(relativePath, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                throw TestError.missingDirectory(root.path)
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = String(url.path.dropFirst(Self.repositoryRoot.path.count + 1))
                results.append((relative, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        #expect(!results.isEmpty, "no swift files found under \(relativePaths)")
        return results
    }

    private enum TestError: Error {
        case missingDirectory(String)
    }

    @Test("アプリ本体と Core にネットワーク通信のコードが存在しない")
    func noNetworkCodeInSources() throws {
        // API names that can be used for network access. If one shows up in the sources, always check that it is intended.
        let forbidden = [
            "URLSession", "URLRequest", "NSURLConnection", "NWConnection", "NWListener", "NWBrowser",
            "import Network", "CFSocket", "CFStream", "CFReadStreamCreateWithFTPURL", "getaddrinfo",
            "NSXPCConnection", "NSAppleScript", "Process(", "OpenAI", "api.openai.com", "Bearer "
        ]
        let files = try Self.swiftFiles(under: ["Core/Sources/Core", "Core/Sources/ContinuationMLX", "Ogura"])
        for (path, text) in files {
            for token in forbidden where text.contains(token) {
                Issue.record("\(path) contains \(token)")
            }
            // URL strings are allowed only in the menu item that opens the GitHub link (reference URLs in comments are excluded).
            for line in text.split(separator: "\n")
            where (line.contains("http://") || line.contains("https://")) && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let isAllowedRepositoryLink = path.hasSuffix("OguraInputControllerHelper.swift")
                    && line.contains("https://github.com/azooKey/azooKey-Desktop")
                if !isAllowedRepositoryLink {
                    Issue.record("\(path) contains a URL literal: \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }

    @Test("entitlements はサンドボックスと App Group だけで、ネットワーク権限を持たない")
    func entitlementsGrantNoNetworkAccess() throws {
        let url = Self.repositoryRoot.appendingPathComponent("Ogura/Ogura.entitlements")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: 0, format: nil)
        let entitlements = try #require(plist as? [String: Any])

        let allowedKeys: Set<String> = [
            "com.apple.security.app-sandbox",
            "com.apple.security.temporary-exception.mach-register.global-name"
        ]
        #expect(Set(entitlements.keys).isSubset(of: allowedKeys), "unexpected entitlements: \(Set(entitlements.keys).subtracting(allowedKeys))")
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(entitlements["com.apple.security.network.client"] == nil)
        #expect(entitlements["com.apple.security.network.server"] == nil)
        // With an App Group, ad-hoc signing shows a permission dialog about "data from other apps", so we do not use a shared container.
        #expect(entitlements["com.apple.security.application-groups"] == nil)
    }

    @Test("依存パッケージはコミットで固定され、出どころが既知の GitHub 組織に限られる")
    func dependenciesArePinnedToKnownSources() throws {
        let packageSwift = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("Core/Package.swift"), encoding: .utf8)
        #expect(packageSwift.contains("revision: \""), "AzooKeyKanaKanjiConverter must be pinned by revision")
        #expect(!packageSwift.contains("branch:"), "dependencies must not float on a branch")

        let resolvedURL = Self.repositoryRoot.appendingPathComponent("Core/Package.resolved")
        let resolved = try JSONSerialization.jsonObject(with: Data(contentsOf: resolvedURL)) as? [String: Any]
        let pins = try #require(resolved?["pins"] as? [[String: Any]])
        #expect(!pins.isEmpty)
        let allowedPrefixes = [
            "https://github.com/azooKey/",
            // Ogura's fork of AzooKeyKanaKanjiConverter (this repository only, not the account)
            "https://github.com/goyamamoto/AzooKeyKanaKanjiConverter",
            "https://github.com/apple/",
            "https://github.com/ensan-hcl/",
            "https://github.com/johnmai-dev/Jinja",
            // MLX backend for the continuation feature (Apple's MLX and the Hugging Face tokenizer)
            "https://github.com/ml-explore/",
            "https://github.com/huggingface/",
            "https://github.com/swiftlang/",
            "https://github.com/ibireme/yyjson"
        ]
        for pin in pins {
            let location = pin["location"] as? String ?? ""
            #expect(allowedPrefixes.contains { location.hasPrefix($0) }, "unexpected dependency source: \(location)")
            let revision = (pin["state"] as? [String: Any])?["revision"] as? String ?? ""
            #expect(revision.count == 40 && revision.allSatisfy(\.isHexDigit), "\(location) is not pinned to a commit")
        }
    }

    @Test("入力を扱うコードは標準出力やログに入力内容を書かない")
    func inputHandlingCodeDoesNotLogInput() throws {
        let files = try Self.swiftFiles(under: ["Core/Sources/Core/InputUtils", "Core/Sources/Core/Continuation", "Core/Sources/ContinuationMLX", "Ogura/InputController"])
        for (path, text) in files {
            for token in ["print(", "NSLog(", "os_log(", "debugPrint(", "dump("] where text.contains(token) {
                Issue.record("\(path) writes to stdout/log with \(token)")
            }
            // os.Logger output is allowed only when it sets privacy: .private explicitly.
            for line in text.split(separator: "\n")
            where (line.contains("logger.") || line.contains("Logger.")) && line.contains("\\(") && !line.contains("privacy: .private") {
                Issue.record("\(path) logs interpolated data without privacy: .private: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    @Test("学習データの保存先はアプリ自身の Application Support 配下に限られる")
    func learningDataLivesInUserContainer() {
        let memoryDirectory = AppContainer.memoryDirectoryURL().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        // In the sandbox this becomes ~/Library/Containers/<bundle id>/Data/Library/Application Support/Ogura
        #expect(memoryDirectory.hasPrefix(home + "/Library/"), "memory directory must be under ~/Library: \(memoryDirectory)")
        #expect(memoryDirectory.hasSuffix("/Library/Application Support/Ogura/memory"), "memory directory must be the app's own Application Support: \(memoryDirectory)")
        #expect(!memoryDirectory.contains("/Group Containers/"), "shared containers trigger the “data from other apps” prompt: \(memoryDirectory)")
        #expect(!memoryDirectory.hasPrefix("/tmp") && !memoryDirectory.hasPrefix("/Users/Shared"))
    }

    @MainActor
    @Test("ホストアプリから読む文脈はカーソル前後の限られた文字数に留まる")
    func hostContextReadIsBounded() {
        final class RecordingDelegate: SegmentManagerDelegate {
            var requestedCounts: [Int] = []
            func getLeftSideContext(maxCount: Int) -> String? {
                self.requestedCounts.append(maxCount)
                return String(repeating: "あ", count: maxCount)
            }
            func getRightSideContext(maxCount: Int) -> String? {
                self.requestedCounts.append(maxCount)
                return String(repeating: "い", count: maxCount)
            }
        }
        let delegate = RecordingDelegate()
        let manager = SegmentsManager(
            kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
            applicationDirectoryURL: testLearningDirectory,
            personalizationDirectoryURL: nil,
            context: .init(useZenzai: false)
        )
        manager.delegate = delegate
        manager.insertAtCursorPosition("tenki", inputStyle: .roman2kana)
        manager.update(requestRichCandidates: true)

        #expect(!delegate.requestedCounts.isEmpty, "context should be requested through the delegate")
        #expect(delegate.requestedCounts.allSatisfy { $0 == SegmentsManager.ContextLength.conversion })
        #expect(SegmentsManager.ContextLength.conversion <= 50, "context window must stay small")
    }

    @MainActor
    @Test("「続きを書く」の文脈はキーを押したときにだけ、上限の文字数まで読む")
    func continuationContextIsReadOnlyOnKeyAndBounded() async {
        let host = InputSessionTests.RecordingHost()
        host.leftContext = String(repeating: "あ", count: 1000)
        let manager = SegmentsManager(
            kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
            applicationDirectoryURL: testLearningDirectory,
            personalizationDirectoryURL: nil,
            context: .init(useZenzai: false, liveConversionEnabled: false)
        )
        let settings = InputSession.Settings(liveConversionEnabled: false, keyBindingStyle: .msIME, inputStyle: .mapped(id: .defaultRomanToKana))
        let session = InputSession(segmentsManager: manager, settingsProvider: { settings })
        session.host = host
        let provider = InputSessionTests.FakeContinuationProvider(snapshots: ["い"])
        session.continuationProvider = provider

        // Normal typing and conversion read only the short context used for conversion.
        for character in "tenki" {
            _ = session.handle(KeyEventCore(modifierFlags: [], characters: String(character), charactersIgnoringModifiers: String(character), keyCode: 0))
        }
        _ = session.handle(KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49))
        _ = session.handle(KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 0x24))
        #expect(host.requestedLeftCounts.allSatisfy { $0 <= SegmentsManager.ContextLength.conversion })
        #expect(provider.receivedContexts.isEmpty)

        // Only when the key is pressed, read the context up to the limit, once.
        host.requestedLeftCounts = []
        _ = session.handle(KeyEventCore(modifierFlags: [.shift], characters: nil, charactersIgnoringModifiers: nil, keyCode: 48))
        await session.waitForContinuation()
        #expect(host.requestedLeftCounts == [InputSession.continuationContextLength])
        #expect(InputSession.continuationContextLength <= 400)
        #expect(provider.receivedContexts.map(\.count) == [InputSession.continuationContextLength])
    }

    @MainActor
    @Test("学習データは指定したディレクトリの中にだけ書かれる")
    func learningDataIsWrittenOnlyToGivenDirectory() throws {
        let fileManager = FileManager.default
        let sandboxRoot = fileManager.temporaryDirectory.appendingPathComponent("ogura-data-protection-\(UUID().uuidString)", isDirectory: true)
        let memoryDirectory = sandboxRoot.appendingPathComponent("memory", isDirectory: true)
        let siblingDirectory = sandboxRoot.appendingPathComponent("sibling", isDirectory: true)
        try fileManager.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: siblingDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: sandboxRoot)
        }

        let manager = SegmentsManager(
            kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
            applicationDirectoryURL: memoryDirectory,
            personalizationDirectoryURL: nil,
            context: .init(useZenzai: false)
        )
        manager.insertAtCursorPosition("kyouhaiitenki", inputStyle: .roman2kana)
        manager.update(requestRichCandidates: true)
        manager.requestSelectingNextCandidate()
        let candidate = try #require(manager.selectedCandidate)
        manager.prefixCandidateCommited(candidate, leftSideContext: "")
        manager.deactivate(flushLearningData: true)

        let written = try fileManager.contentsOfDirectory(atPath: memoryDirectory.path)
        let sibling = try fileManager.contentsOfDirectory(atPath: siblingDirectory.path)
        #expect(!written.isEmpty, "learning data should be flushed into the memory directory")
        #expect(sibling.isEmpty, "nothing may be written outside the memory directory")
    }
}
