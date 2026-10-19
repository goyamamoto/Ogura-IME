import Core
import Foundation

/// Conversions made in the background as the app makes them (see `SegmentsManager.Context.conversionScheduler`), run only
/// when a test says so: `runAll()` runs each job under the conversion lock and hands back what it made, as the conversion
/// thread does, until none is left
final class QueuedConversions: ConversionScheduler, @unchecked Sendable {
    private var jobs: [(work: @Sendable () -> Void, deliver: @MainActor @Sendable () -> Void)] = []
    /// The jobs run so far
    private(set) var ran = 0

    /// The jobs waiting
    var waiting: Int {
        self.jobs.count
    }

    func schedule(_ work: @escaping @Sendable () -> Void, then deliver: @escaping @MainActor @Sendable () -> Void) {
        self.jobs.append((work, deliver))
    }

    /// Runs the jobs waiting, and those they leave, as the conversion thread would once it has the time
    @MainActor
    func runAll() {
        while !self.jobs.isEmpty {
            let job = self.jobs.removeFirst()
            ConversionLock.withLock(job.work)
            self.ran += 1
            job.deliver()
        }
    }
}
