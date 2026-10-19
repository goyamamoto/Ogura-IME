import Core
import Foundation

/// What an input session leaves for when typing stops (the thorough conversion, see `InputSession`), run only when a test
/// says typing stopped: pass `scheduler` to the session and call `pause()` there
@MainActor
final class TypingPauses {
    private var pending: DebouncedActionScheduler.Action?

    /// Where the session converts in the background, as the app does, when the evaluations are asked to (see
    /// `init(environment:)`): the background catches up after every `keysPerConversion` keys, and when typing stops
    let conversions: QueuedConversions?
    private let keysPerConversion: Int
    private var keysTyped = 0

    init() {
        self.conversions = nil
        self.keysPerConversion = 1
    }

    /// With `OGURA_EVAL_BACKGROUND=<n>`, the session converts in the background, catching up after every n keys (1: after
    /// each key, which converts as before each key is shown; 3: keys typed three times as fast as they convert, the keys
    /// between converted together)
    init(environment: [String: String]) {
        let keys = environment["OGURA_EVAL_BACKGROUND"].flatMap(Int.init)
        self.conversions = keys.map { _ in QueuedConversions() }
        self.keysPerConversion = max(1, keys ?? 1)
    }

    /// A key was typed: the background catches up when its turn comes
    func keyTyped() {
        self.keysTyped += 1
        if self.keysTyped % self.keysPerConversion == 0 {
            self.conversions?.runAll()
        }
    }

    /// Where the background evaluations stand, for the first line of a report
    static func backgroundDescription(_ environment: [String: String]) -> String {
        environment["OGURA_EVAL_BACKGROUND"].map { "every \($0) keys" } ?? "none"
    }

    private(set) lazy var scheduler = DebouncedActionScheduler { [weak self] _, action in
        // The session schedules on the main actor, as the scheduler's own methods do
        MainActor.assumeIsolated {
            self?.pending = action
        }
    }

    /// Typing stops long enough for what was scheduled to run. Returns whether anything was left to run (not cancelled
    /// since it was scheduled)
    @discardableResult
    func pause() -> Bool {
        defer {
            self.pending = nil
        }
        guard let action = self.pending, self.scheduler.isPending else {
            self.conversions?.runAll()
            return false
        }
        action()
        // Typing stopped long enough for the background to make what it was asked for
        self.conversions?.runAll()
        return true
    }

    /// Whether the evaluations pause before Enter, as a user who reads what is shown does: `OGURA_EVAL_PAUSE=0` presses
    /// Enter right after the last key instead
    static func pausesBeforeEnter(_ environment: [String: String]) -> Bool {
        environment["OGURA_EVAL_PAUSE"] != "0"
    }

    /// Typing stops before Enter when the evaluations pause there (see `pausesBeforeEnter`). Returns whether it stopped
    @discardableResult
    func pauseBeforeEnter(_ environment: [String: String]) -> Bool {
        guard Self.pausesBeforeEnter(environment) else {
            return false
        }
        self.pause()
        return true
    }

    /// Whether the evaluations pause after `key` too, in the middle of the input, as a user who stops at the end of a
    /// phrase and goes on does: after each key that types punctuation or a closing bracket with
    /// `OGURA_EVAL_PAUSE=punctuation`
    static func pausesAfter(_ key: Character, _ environment: [String: String]) -> Bool {
        environment["OGURA_EVAL_PAUSE"] == "punctuation" && ",.!?])".contains(key)
    }

    /// Where the evaluations pause, for the first line of a report
    static func description(_ environment: [String: String]) -> String {
        switch environment["OGURA_EVAL_PAUSE"] {
        case "0": "none"
        case "punctuation": "after punctuation and before Enter"
        default: "before Enter"
        }
    }
}
