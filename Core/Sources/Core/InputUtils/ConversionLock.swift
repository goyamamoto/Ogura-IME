import Foundation

/// The lock the conversion runs under. The converter (`KanaKanjiConverter`), its sessions, the identification layer and
/// their caches are shared by every input session of the process and are not safe to use from two threads at once. The
/// conversion runs on the conversion thread while typing (see `BackgroundConversionScheduler`) and on the main thread
/// when a key needs its result at once (Space, Enter), and the app commits learning data on the main thread: each holds
/// this lock while it uses them. It is recursive, so the main thread can take it around work that takes it again
public enum ConversionLock {
    private static let lock = NSRecursiveLock()

    public static func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return try body()
    }
}

/// Runs the conversions made while typing off the main thread (see `SegmentsManager.Context.conversionScheduler`):
/// the key is shown at once from the conversion shown before it, and the conversion of the input corrects it when it
/// comes
public protocol ConversionScheduler: AnyObject, Sendable {
    /// Runs `work` under the conversion lock, then `deliver` on the main actor
    func schedule(_ work: @escaping @Sendable () -> Void, then deliver: @escaping @MainActor @Sendable () -> Void)
}

/// The conversion thread: one serial queue for the whole process, as the converter is shared
public final class BackgroundConversionScheduler: ConversionScheduler {
    public static let shared = BackgroundConversionScheduler()

    private let queue = DispatchQueue(label: "org.if0.inputmethod.ogura.conversion", qos: .userInteractive)

    public func schedule(_ work: @escaping @Sendable () -> Void, then deliver: @escaping @MainActor @Sendable () -> Void) {
        self.queue.async {
            ConversionLock.withLock(work)
            DispatchQueue.main.async {
                MainActor.assumeIsolated(deliver)
            }
        }
    }
}

/// A value handed between the main thread and the conversion thread, which the conversion lock or the order of the
/// two keeps from being used by both at once
final class Handed<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// An object handed to the main thread's work after a job, held weakly so the job does not keep it
final class WeaklyHanded<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}
