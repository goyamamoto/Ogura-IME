@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

// An input let go while its conversion is made in the background (the app lets an input controller go when the text it
// typed into goes away, e.g. a window closed right after a key): the job converts in its twin, whose sessions are the
// input's own and go with it. The clause-edit matrix found the job left waiting stopping the process
// ("SegmentsManager lost its conversion session"); the job is now called off as the input goes, and looks at that under
// the conversion lock before it converts

/// The learned script identifier, which the conversions in the background need (see `SegmentsManager.convertsTypingInBackground`)
private let scriptModelDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Ogura/Resources/ScriptModel", isDirectory: true)

@MainActor
private final class ReleaseHost: InputSessionHost {
    var inserted: [String] = []
    func insertText(_ text: String) { self.inserted.append(text) }
    func updateMarkedText(_ markedText: SegmentsManager.MarkedText) {}
    func switchInputMode(_ language: InputLanguage) {}
    func candidateRow(forNumberKey number: Int) -> Int { number - 1 }
    func leftSideContext(maxCount: Int) -> String? { nil }
    func rightSideContext(maxCount: Int) -> String? { nil }
}

/// Runs each job on a thread of its own under the conversion lock, holding the lock `hold` seconds before the job's work
/// (the conversion of a long input), and tells when it took the lock
private final class SlowConversions: ConversionScheduler, @unchecked Sendable {
    let hold: Double
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "ManagerReleaseTests.conversion")

    init(hold: Double) {
        self.hold = hold
    }

    /// Waits for the jobs started so far (those of the word put in first) and forgets that they started and ended
    func drain() {
        while self.finished.wait(timeout: .now() + 0.5) == .success {}
        while self.started.wait(timeout: .now()) == .success {}
    }

    func schedule(_ work: @escaping @Sendable () -> Void, then deliver: @escaping @MainActor @Sendable () -> Void) {
        self.queue.async {
            ConversionLock.withLock {
                self.started.signal()
                Thread.sleep(forTimeInterval: self.hold)
                work()
            }
            self.finished.signal()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { deliver() }
            }
        }
    }
}

/// An input converting in the background with `scheduler`, the identification layer read (a word typed and put in
/// first, its conversion on the main thread)
@MainActor
private func typingSession(_ scheduler: any ConversionScheduler) -> (session: InputSession, host: ReleaseHost) {
    let manager = SegmentsManager(
        kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
        applicationDirectoryURL: freshTestLearningDirectory(),
        personalizationDirectoryURL: nil,
        context: .init(
            useZenzai: false, liveConversionEnabled: true, learnedScriptIdentification: true, scriptModelDirectoryURL: scriptModelDirectory,
            conversionScheduler: scheduler
        )
    )
    let session = InputSession(segmentsManager: manager, settingsProvider: {
        InputSession.Settings(liveConversionEnabled: true, keyBindingStyle: .msIME, inputStyle: .mapped(id: .defaultRomanToKana))
    })
    let host = ReleaseHost()
    session.host = host
    typeKeys("hai", into: session)
    _ = session.handle(KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 0x24))
    return (session, host)
}

@MainActor
private func typeKeys(_ romaji: String, into session: InputSession) {
    for character in romaji {
        _ = session.handle(KeyEventCore(modifierFlags: [], characters: String(character), charactersIgnoringModifiers: String(character), keyCode: 0))
    }
}

@MainActor
@Test("裏の変換が待ち行列にある間に入力を手放しても、その仕事は手放した入力の変換のセッションを使わない（落ちない）")
func anInputLetGoWithItsConversionWaiting() {
    let conversions = QueuedConversions()
    var typing: (session: InputSession, host: ReleaseHost)? = typingSession(conversions)
    weak var manager = typing?.session.segmentsManager
    #expect(manager?.convertsTypingInBackground == true, "the conversions are to be made in the background, as in the app")
    if let typing {
        typeKeys("kyouhaiitenki", into: typing.session)
    }
    #expect(conversions.waiting > 0, "a conversion is to be waiting")
    typing = nil
    #expect(manager == nil, "the input is let go")
    // The conversion thread gets to the job now (before: it converted in the sessions removed, and the process stopped)
    conversions.runAll()
}

@MainActor
@Test("裏の変換が走っている間に入力を手放すと、手放しは変換が終わるのを待ってからセッションを消す（落ちない）")
func anInputLetGoWhileItsConversionRuns() {
    // No wait before the job's work: it is past its look at being called off, converting a long input, when the input goes
    let conversions = SlowConversions(hold: 0)
    var typing: (session: InputSession, host: ReleaseHost)? = typingSession(conversions)
    conversions.drain()
    weak var manager = typing?.session.segmentsManager
    if let typing {
        typeKeys("kyouhaiitenkidesukaasitahaamegahurusoudesuyosoredemodekakemasuka", into: typing.session)
    }
    #expect(conversions.started.wait(timeout: .now() + 5) == .success, "a conversion is to start")
    Thread.sleep(forTimeInterval: 0.002)
    let letGo = ProcessInfo.processInfo.systemUptime
    typing = nil
    let waited = ProcessInfo.processInfo.systemUptime - letGo
    #expect(manager == nil, "the input is let go")
    #expect(conversions.finished.wait(timeout: .now() + 5) == .success, "the conversion is to end")
    // Letting go waited for the conversion running (the lock): its sessions went once it was done
    print("RELEASE_WAITED \(waited)")
}

@MainActor
@Test("裏の変換が終わった直後（結果を受け取る前）に入力を手放しても落ちない")
func anInputLetGoRightAfterItsConversion() {
    let conversions = SlowConversions(hold: 0)
    var typing: (session: InputSession, host: ReleaseHost)? = typingSession(conversions)
    conversions.drain()
    weak var manager = typing?.session.segmentsManager
    if let typing {
        typeKeys("kyouhaiitenki", into: typing.session)
    }
    #expect(conversions.finished.wait(timeout: .now() + 5) == .success, "the conversion is to end")
    // Its outcome waits on the main queue, for an input no longer there
    typing = nil
    #expect(manager == nil, "the input is let go")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
}
