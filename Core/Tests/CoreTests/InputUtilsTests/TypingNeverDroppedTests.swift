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

/// A key typed (a key held down repeats it at the pace given: the session takes a repeat as any key that types)
private func key(_ character: Character) -> KeyEventCore {
    KeyEventCore(modifierFlags: [], characters: String(character), charactersIgnoringModifiers: String(character), keyCode: 0)
}

/// How fast keys come and conversions are made: a conversion's cost, the time between keys, whether a key is held down
struct TypingPace: Sendable, CustomTestStringConvertible {
    var cost: Double
    var interval: Double
    var held: Bool
    var testDescription: String { "conversion \(Int(self.cost * 1000)) ms, a key every \(Int(self.interval * 1000)) ms\(self.held ? ", held" : "")" }
}

@MainActor
@Test("変換が遅れても打った鍵は 1 つも捨てない: 1 回の変換が 120 ms・500 ms（M1 の長い入力）で 30 ms ごとに 60 字、押しっぱなし（20 ms ごと）でも、読みは打ったとおり", arguments: [
    TypingPace(cost: 0.12, interval: 0.03, held: false), TypingPace(cost: 0.5, interval: 0.03, held: false), TypingPace(cost: 0.5, interval: 0.02, held: true)
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

@MainActor
@Test("押しっぱなしの鍵が 300 回続いても、入力は長い入力の始まりが入ることで限られ、どの鍵も読みを 1 字伸ばすか始まりを入れる（黙って何もしない鍵が無い）")
func aKeyHeldDownLongIsBoundedAndNeverLost() {
    let conversions = TimedConversions(cost: 0.5)
    let (session, host) = typingSession(conversions)
    var longest = 0
    for index in 0 ..< 300 {
        let (reading, inserted) = (session.segmentsManager.convertTarget.count, host.inserted.count)
        #expect(session.handle(key("a")))
        let grew = session.segmentsManager.convertTarget.count == reading + 1
        #expect(grew || host.inserted.count > inserted, "key \(index): nothing happened (reading \(reading))")
        longest = max(longest, session.segmentsManager.convertTarget.count)
        conversions.advance(by: 0.02)
    }
    // Bounded: a long input's start goes in (see `SegmentsManager.committedAnywhereFrom`)
    #expect(!host.inserted.isEmpty)
    #expect(longest <= SegmentsManager.committedAnywhereFrom + InputSession.typingPausesAt, "the input grew to \(longest)")
    #expect(conversions.mostWaiting <= 1)
}
