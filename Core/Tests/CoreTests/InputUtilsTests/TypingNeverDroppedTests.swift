@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

// A key typed is never dropped. Since background conversion the session took and dropped the keys that type once 16
// characters of the reading showed unconverted (`typingPausesAt`), silently: a key held down, a long input on a slow Mac
// (an M1 converts a key in about 130 ms at 80–99 characters, 430 ms at 120–139), or keys handed over with no time
// between them. The tests type at a set pace against a conversion of a set cost
// (`TimedConversions`) and check that every key went in, that the input stays bounded (a long input's start goes in), and
// that the conversions stay one at a time

/// The learned script identifier, which the conversion in the background needs (see `SegmentsManager.convertsTypingInBackground`)
private let scriptModelDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Ogura/Resources/ScriptModel", isDirectory: true)

@MainActor
private final class TypedHost: InputSessionHost {
    var inserted: [String] = []
    var markedText = ""
    func insertText(_ text: String) { self.inserted.append(text) }
    func updateMarkedText(_ markedText: SegmentsManager.MarkedText) { self.markedText = markedText.map(\.content).joined() }
    func switchInputMode(_ language: InputLanguage) {}
    func candidateRow(forNumberKey number: Int) -> Int { number - 1 }
    func leftSideContext(maxCount: Int) -> String? { nil }
    func rightSideContext(maxCount: Int) -> String? { nil }
}

/// A session converting in the background as the app does, at the pace of `conversions`
@MainActor
private func typingSession(_ conversions: TimedConversions) -> (session: InputSession, host: TypedHost) {
    let manager = SegmentsManager(
        kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
        applicationDirectoryURL: freshTestLearningDirectory(),
        personalizationDirectoryURL: nil,
        context: .init(useZenzai: false, liveConversionEnabled: true, learnedScriptIdentification: true, scriptModelDirectoryURL: scriptModelDirectory, conversionScheduler: conversions)
    )
    ConversionLock.withLock {
        manager.resetLearningData()
    }
    let session = InputSession(segmentsManager: manager, settingsProvider: {
        InputSession.Settings(liveConversionEnabled: true, keyBindingStyle: .msIME, inputStyle: .mapped(id: .defaultRomanToKana))
    })
    let host = TypedHost()
    session.host = host
    return (session, host)
}

private func key(_ character: Character, isRepeat: Bool = false) -> KeyEventCore {
    KeyEventCore(modifierFlags: [], characters: String(character), charactersIgnoringModifiers: String(character), keyCode: 0, isRepeat: isRepeat)
}

/// How fast keys come and conversions are made: a conversion's cost, the time between keys
struct TypingPace: Sendable, CustomTestStringConvertible {
    var cost: Double
    var interval: Double
    var testDescription: String { "conversion \(Int(self.cost * 1000)) ms, a key every \(Int(self.interval * 1000)) ms" }
}

@MainActor
@Test("変換が遅れても打った鍵は 1 つも捨てない: 1 回の変換が 120 ms・500 ms（遅い Mac の長い入力）で 30 ms ごとに 60 字、読みは打ったとおり（押しっぱなしの繰り返しは aKeyHeldDownLeavesNothingQueuedAfterItIsLetGo）", arguments: [
    TypingPace(cost: 0.12, interval: 0.03), TypingPace(cost: 0.5, interval: 0.03)
])
func noKeyIsDroppedWhileTheConversionIsBehind(_ pace: TypingPace) {
    let conversions = TimedConversions(cost: pace.cost)
    let (session, host) = typingSession(conversions)
    for index in 0 ..< 60 {
        #expect(session.handle(key("a")))
        if index == 0 {
            // Converting in the background as the app does (the learned identifier, which it needs, is read at the first key)
            #expect(session.segmentsManager.convertsTypingInBackground)
        }
        conversions.advance(by: pace.interval)
    }
    conversions.finish()
    // 60 kana: under the length whose start goes in on its own (80), so all of it is still the input
    #expect(session.segmentsManager.convertTarget == String(repeating: "あ", count: 60), "\(session.segmentsManager.convertTarget.count): \(session.segmentsManager.convertTarget)")
    #expect(host.inserted.isEmpty, "\(host.inserted)")
    // One conversion at a time: what was typed meanwhile is converted together (a job called off by a key that waited
    // for the conversion does nothing when its turn comes, see `TimedConversions`)
    #expect(conversions.mostWaiting <= 1, "\(conversions.mostWaiting) waiting at once")
}

@MainActor
@Test("間を置かずに渡された鍵（往復の再生の打ち直し）も 1 つも捨てない: 変換は 1 度も届かないまま 40 字")
func noKeyIsDroppedWhenKeysComeWithNoTimeBetween() {
    let conversions = TimedConversions(cost: 0.1)
    let (session, _) = typingSession(conversions)
    for _ in 0 ..< 40 {
        #expect(session.handle(key("a")))
    }
    conversions.finish()
    #expect(session.segmentsManager.convertTarget == String(repeating: "あ", count: 40), "\(session.segmentsManager.convertTarget.count)")
}

/// Counts what a test is told, from any thread
private final class Told: @unchecked Sendable {
    private let lock = NSLock()
    private var told = 0
    var count: Int { self.lock.withLock { self.told } }
    func add() { self.lock.withLock { self.told += 1 } }
}

@MainActor
@Test("押しっぱなし（最初の 1 回は押した鍵、続く 299 回は OS の繰り返し、毎秒 30）で変換が追いつかなくても: (a) 押した鍵は必ず読みに入る（離した後に押した鍵も）(b) 遅れは 16 字まで (c) 離した後（最後の鍵の後）に main で待つ鍵が残らない（変換を待つ繰り返しが積もって、離した後も字が出続けない）")
func aKeyHeldDownLeavesNothingQueuedAfterItIsLetGo() {
    // A conversion slower than the keys repeat (a slower Mac at about 100 kana: 16 repeats come in 0.53 s, a conversion of
    // them takes about 0.6 s and more)
    let (cost, interval) = (1.0, 1.0 / 30)
    let conversions = TimedConversions(cost: cost)
    let (session, _) = typingSession(conversions)
    let waits = Told()
    InputSession.typingWaitObserver = { waits.add() }
    defer { InputSession.typingWaitObserver = nil }
    // The main thread's clock: a key that waits for the conversion takes it (the conversion made there, about `cost`),
    // and the keys after it wait in the system's queue meanwhile
    var (clock, mainFree, longest) = (0.0, 0.0, 0)
    for index in 0 ..< 300 {
        let waited = waits.count
        let start = max(clock, mainFree)
        #expect(session.handle(key("a", isRepeat: index > 0)))
        if index == 0 {
            // (a) The key pressed goes in
            #expect(session.segmentsManager.convertTarget == "あ")
        }
        // (b)
        #expect(session.segmentsManager.unconvertedCharacterCount <= InputSession.typingPausesAt)
        mainFree = waits.count > waited ? start + cost : start
        longest = max(longest, session.segmentsManager.convertTarget.count)
        conversions.advance(by: interval)
        clock += interval
    }
    let last = clock - interval
    // (c) Nothing left waiting once the key is let go: what shows then is what was typed
    #expect(mainFree <= last + interval, "the repeats were still being handled \(String(format: "%.2f", mainFree - last)) s after the last one (\(waits.count) keys waited)")
    // (a) A key pressed after the key held down is let go goes in, waiting for the conversion if it must
    let reading = session.segmentsManager.convertTarget
    #expect(session.handle(key("i")))
    #expect(session.segmentsManager.convertTarget.hasSuffix("い"), "\(session.segmentsManager.convertTarget) (was \(reading))")
    // Bounded: a long input's start goes in (see `SegmentsManager.committedAnywhereFrom`)
    #expect(longest <= SegmentsManager.committedAnywhereFrom + InputSession.typingPausesAt, "the input grew to \(longest)")
    #expect(conversions.mostWaiting <= 1)
}
