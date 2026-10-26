@testable import Core
import Foundation

/// Conversions made in the background at a pace the test sets: each job takes `cost` seconds of a clock the test moves
/// on (`advance`), one after another as the conversion thread runs them, each starting when the one before is done or
/// when it is asked for, whichever is later. A slow Mac (the M1, a long input) is a long `cost`; keys typed every 30 ms
/// are `advance(by: 0.03)` between them. A job runs when it starts (the conversion thread takes it then, holding the
/// conversion lock) and is handed back when its time is over. A job the session called off before it started (a key
/// that waited for the conversion made it here, see `SegmentsManager.settleConversion`) returns at once when its turn
/// comes, as on the conversion thread: it takes no time and is not counted as waiting. Counts how many jobs that
/// convert were waiting at once (the session asks for one at a time, the input as it is then: keys typed faster than
/// they convert are converted together)
final class TimedConversions: ConversionScheduler, @unchecked Sendable {
    private struct Job {
        var id: Int
        var asked: Double
        var work: @Sendable () -> Void
        var deliver: @MainActor @Sendable () -> Void
    }

    private var jobs: [Job] = []
    /// The job being made: started, handed back at `done`
    private var running: (job: Job, done: Double)?
    private var clock = 0.0
    private var freeAt = 0.0
    private var nextID = 0
    let cost: Double
    /// The jobs waiting to be made each time one was asked for, and the jobs that returned at once
    private var waitingWhenAsked: [[Int]] = []
    private var calledOff: Set<Int> = []
    /// How many jobs ran
    private(set) var ran = 0

    /// The most jobs that convert waiting at once to be made (see `schedule`)
    var mostWaiting: Int {
        self.waitingWhenAsked.map { $0.filter { !self.calledOff.contains($0) }.count }.max() ?? 0
    }

    init(cost: Double) {
        self.cost = cost
    }

    func schedule(_ work: @escaping @Sendable () -> Void, then deliver: @escaping @MainActor @Sendable () -> Void) {
        self.jobs.append(Job(id: self.nextID, asked: self.clock, work: work, deliver: deliver))
        self.nextID += 1
        // The session asks for a job only when it has none of its own (`SegmentsManager.startBackgroundJob`): one asked
        // for while one is being made here means a key took that one's outcome (`settleConversion`), which on the
        // conversion thread waits until it is done (the job holds the conversion lock). It is done then, not waiting:
        // only the jobs not started count (this clock makes a job's work as it starts, so it cannot show that wait)
        self.waitingWhenAsked.append(self.jobs.map(\.id))
    }

    /// The clock moved on by `seconds`: the jobs started by then are run, and those done by then handed back, in order
    @MainActor
    func advance(by seconds: Double) {
        let end = self.clock + seconds
        while true {
            if let (job, done) = self.running {
                guard done <= end else {
                    break
                }
                self.running = nil
                self.clock = done
                self.freeAt = done
                job.deliver()
                continue
            }
            guard let job = self.jobs.first else {
                break
            }
            let start = max(job.asked, self.freeAt)
            guard start <= end else {
                break
            }
            self.jobs.removeFirst()
            self.clock = start
            // Made now, as the conversion thread would; one called off returns at once (well under a conversion's time)
            let started = ProcessInfo.processInfo.systemUptime
            ConversionLock.withLock(job.work)
            self.ran += 1
            let calledOff = ProcessInfo.processInfo.systemUptime - started < 0.0005
            if calledOff {
                self.calledOff.insert(job.id)
            }
            self.running = (job, start + (calledOff ? 0 : self.cost))
        }
        self.clock = end
    }

    /// The clock moved on until no job is left
    @MainActor
    func finish() {
        while !self.jobs.isEmpty || self.running != nil {
            self.advance(by: self.cost)
        }
    }
}
