import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

/// What the converter learns while Zenzai is on (`SegmentsManager.ZenzaiLearning`). These tests run when the Zenzai weights
/// are in the repository (not an LFS pointer).
private let resourcesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Ogura/Resources/gguf", isDirectory: true)
private let hasZenzaiWeights = ((try? FileManager.default.attributesOfItem(
    atPath: resourcesDirectory.appendingPathComponent("ggml-model-Q5_K_M.gguf").path
)[.size] as? Int) ?? 0) > 1_000_000

@MainActor
private final class Host: InputSessionHost {
    var inserted: [String] = []
    func insertText(_ text: String) { self.inserted.append(text) }
    func updateMarkedText(_ markedText: SegmentsManager.MarkedText) {}
    func switchInputMode(_ language: InputLanguage) {}
    func candidateRow(forNumberKey number: Int) -> Int { number - 1 }
    func leftSideContext(maxCount: Int) -> String? { "" }
    func rightSideContext(maxCount: Int) -> String? { nil }
}

/// Types `keys` with live conversion and commits them: with Enter, or after Space `spaces` times (the candidate picked),
/// then saves what was learned, as the app does when Ogura is left
@MainActor
private func commit(_ keys: String, spaces: Int = 0, converter: KanaKanjiConverter, memory: URL) -> String {
    let manager = SegmentsManager(
        kanaKanjiConverter: converter,
        applicationDirectoryURL: memory,
        personalizationDirectoryURL: nil,
        context: .init(useZenzai: true, resourcesDirectoryURL: resourcesDirectory, liveConversionEnabled: true, learnedScriptIdentification: false)
    )
    let session = InputSession(segmentsManager: manager, settingsProvider: {
        InputSession.Settings(liveConversionEnabled: true, keyBindingStyle: .msIME, inputStyle: .mapped(id: .defaultRomanToKana))
    })
    let host = Host()
    session.host = host
    for character in keys {
        let text = String(character)
        _ = session.handle(KeyEventCore(modifierFlags: [], characters: text, charactersIgnoringModifiers: text, keyCode: 0))
    }
    for _ in 0 ..< spaces {
        _ = session.handle(KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49))
    }
    _ = session.handle(KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 0x24))
    session.deactivate()
    manager.deactivate(flushLearningData: true)
    return host.inserted.joined()
}

@MainActor
private func freshMemory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ogura-zenzai-learning-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
@Test("Zenzai では受け入れた変換を学習せず、同音の語を別の文へ引きずらない（税金を納める の後も 国を治める）", .enabled(if: hasZenzaiWeights))
func acceptedConversionDoesNotDragHomophones() {
    let converter = KanaKanjiConverter.withDefaultDictionary()
    let memory = freshMemory()
    defer { try? FileManager.default.removeItem(at: memory) }
    #expect(commit("zeikinnwoosameru.", spaces: 1, converter: converter, memory: memory).contains("納める"))
    let next = commit("ougakuniwoosameru.", converter: converter, memory: memory)
    #expect(next == "王が国を治める。", "\(next)")
}

@MainActor
@Test("選び直した候補は学習し、次も先に出る（機械ではなく機会）", .enabled(if: hasZenzaiWeights))
func pickedCandidateIsLearned() {
    let converter = KanaKanjiConverter.withDefaultDictionary()
    let (memory, untouched) = (freshMemory(), freshMemory())
    defer {
        try? FileManager.default.removeItem(at: memory)
        try? FileManager.default.removeItem(at: untouched)
    }
    let first = commit("kikai", converter: converter, memory: untouched)
    let picked = commit("kikai", spaces: 2, converter: converter, memory: memory)
    #expect(picked != first, "the second candidate: \(picked)")
    #expect(commit("kikai", converter: converter, memory: memory) == picked)
}
