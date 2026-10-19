import Foundation

/// Scheduler that delays work on the MainActor until a set time has passed since the last operation.
///
/// When input handling and saving learning data share the same actor,
/// this keeps synchronous work off the critical path while the user is still typing.
public final class DebouncedActionScheduler {
    public typealias Action = @MainActor @Sendable () -> Void
    public typealias Schedule = (TimeInterval, @escaping Action) -> Void

    private let schedule: Schedule
    private var generation: UInt64 = 0
    private var pendingAction: Action?

    public init(
        schedule: @escaping Schedule = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                action()
            }
        }
    ) {
        self.schedule = schedule
    }

    @MainActor public var isPending: Bool {
        pendingAction != nil
    }

    @MainActor public func schedule(after delay: TimeInterval, action: @escaping Action) {
        pendingAction = action
        arm(after: delay)
    }

    @MainActor public func postponeIfScheduled(after delay: TimeInterval) {
        guard pendingAction != nil else {
            return
        }
        arm(after: delay)
    }

    @MainActor public func cancel() {
        generation &+= 1
        pendingAction = nil
    }

    @MainActor private func arm(after delay: TimeInterval) {
        generation &+= 1
        let scheduledGeneration = generation
        schedule(delay) { [weak self] in
            guard let self,
                  self.generation == scheduledGeneration,
                  let action = self.pendingAction else {
                return
            }
            self.pendingAction = nil
            action()
        }
    }
}
