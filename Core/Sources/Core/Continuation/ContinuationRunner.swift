import Foundation

/// Runs generation and decides whether the result is a usable continuation or a message. InputSession (the IME) and the evaluation CLI go through the same flow.
/// Clearly broken output (repetition, restated instructions, etc.) and generation stopped by the safety filter are retried, up to the attempt limit.
/// The safety filter often reacts to something somewhere in the context, so a retry after it shrinks the context to its end
public enum ContinuationRunner {
    /// The record of one generation
    public struct Attempt: Sendable {
        /// The context passed to the model in this attempt
        public let context: String
        /// The raw model output
        public let raw: String
        /// The form the IME shows (overlap removed, punctuation tidied, sentence count limited)
        public let shown: String
        /// The reason the output was judged broken. nil means it is usable
        public let brokenReason: String?
        /// The reason generation was stopped (safety filter, etc.)
        public let error: ContinuationError?
        public let duration: TimeInterval
    }

    public enum Outcome: Equatable, Sendable {
        case continuation(String)
        /// A message shown instead of a continuation
        case message(String)
    }

    public struct Result: Sendable {
        public let outcome: Outcome
        public let attempts: [Attempt]
    }

    public static let noIdeaMessage = "続きを思いつきませんでした"

    /// `onSnapshot` receives progress (in the shown form). `onRetry` is called before each retry.
    /// Throws CancellationError if the caller's Task is cancelled
    @MainActor
    public static func run(
        provider: any ContinuationProvider,
        context fullContext: String,
        maxAttempts: Int = InputSession.continuationMaxAttempts,
        onSnapshot: (String) -> Void = { _ in },
        onRetry: () -> Void = {}
    ) async throws -> Result {
        var context = fullContext
        var attempts: [Attempt] = []
        for attempt in 1 ... max(1, maxAttempts) {
            let isLastAttempt = attempt >= maxAttempts
            let started = Date()
            do {
                var raw = ""
                var shown = ""
                for try await snapshot in provider.continuation(after: context) {
                    try Task.checkCancellation()
                    raw = snapshot
                    shown = InputSession.presentableContinuation(from: snapshot, after: context)
                    onSnapshot(shown)
                }
                try Task.checkCancellation()
                let reason = InputSession.brokenContinuationReason(shown, after: context)
                attempts.append(Attempt(context: context, raw: raw, shown: shown, brokenReason: reason, error: nil, duration: Date().timeIntervalSince(started)))
                guard let reason else {
                    return Result(outcome: .continuation(shown), attempts: attempts)
                }
                _ = reason
                if isLastAttempt {
                    return Result(outcome: .message(Self.noIdeaMessage), attempts: attempts)
                }
                onRetry()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ContinuationError {
                attempts.append(Attempt(context: context, raw: "", shown: "", brokenReason: nil, error: error, duration: Date().timeIntervalSince(started)))
                guard error.isWorthRetryingWithShorterContext, !isLastAttempt else {
                    return Result(outcome: .message(error.localizedDescription), attempts: attempts)
                }
                context = String(context.suffix(max(1, context.count / InputSession.continuationContextShrinkFactor)))
                onRetry()
            } catch {
                return Result(outcome: .message(error.localizedDescription), attempts: attempts)
            }
        }
        return Result(outcome: .message(attempts.last?.error?.localizedDescription ?? Self.noIdeaMessage), attempts: attempts)
    }
}
