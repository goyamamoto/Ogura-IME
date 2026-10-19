import Foundation

/// The interface to an on-device model that generates a continuation of text.
///
/// Progress is streamed in order, each time as "the full text generated so far". Generation is complete when the stream ends.
/// Do not write implementations that use the network (Ogura never goes online).
public protocol ContinuationProvider: Sendable {
    /// Generates text that naturally follows right after `leftContext` (the text to the left of the cursor)
    func continuation(after leftContext: String) -> AsyncThrowingStream<String, any Error>
}

public enum ContinuationError: LocalizedError, Sendable, Equatable {
    /// The model cannot be used. The reason is a sentence shown to the user as is
    case unavailable(String)
    /// The model's safety filter stopped the input or the output. Worth retrying with a shorter context
    case blockedBySafetyFilter
    /// The context passed was too long. Worth retrying with a shorter context
    case contextTooLong
    /// The model is busy (limits on concurrent requests or on the request rate)
    case busy
    /// Any other failure. The reason is a sentence shown to the user as is
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .failed(let reason):
            reason
        case .blockedBySafetyFilter:
            "Apple のモデルが安全上の理由で続きを書きませんでした。少し書き足してからもう一度試してください"
        case .contextTooLong:
            "文章が長すぎて続きを書けませんでした"
        case .busy:
            "モデルが混み合っています。少し待ってからもう一度試してください"
        }
    }

    /// Failures that might succeed if retried with a shorter context
    public var isWorthRetryingWithShorterContext: Bool {
        switch self {
        case .blockedBySafetyFilter, .contextTooLong:
            true
        case .unavailable, .busy, .failed:
            false
        }
    }
}
