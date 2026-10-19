import Core
import Foundation

/// A reading judge loading in the background: it scores nothing until the model in its directory is ready, so the
/// naturalness checks go by Zenzai alone until then (see `SegmentsManager.Context.readingJudge`). The app makes one at
/// launch and gives it to every input session
public final class BackgroundReadingJudge: ReadingJudge, @unchecked Sendable {
    private let lock = NSLock()
    private var judge: CoreMLReadingJudge?

    /// Starts loading the model in `directory` (see `CoreMLReadingJudge`). When it cannot be loaded, the checks keep
    /// going by Zenzai alone
    public init(directory: URL) {
        Task.detached(priority: .utility) { [weak self] in
            guard let judge = try? await CoreMLReadingJudge.load(directory: directory) else {
                return
            }
            self?.lock.withLock {
                self?.judge = judge
            }
        }
    }

    public func scores(of readings: [String]) -> [Float]? {
        self.lock.withLock { self.judge }?.scores(of: readings)
    }
}
