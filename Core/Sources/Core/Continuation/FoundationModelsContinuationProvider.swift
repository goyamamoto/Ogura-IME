import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Writes continuations with Apple's on-device model on macOS 26 (Foundation Models). Nothing is sent outside the Mac.
@available(macOS 26.0, *)
public struct FoundationModelsContinuationProvider: ContinuationProvider {
    public init() {}

    public func continuation(after leftContext: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { stream in
            let task = Task {
                do {
                    let model = SystemLanguageModel.default
                    switch model.availability {
                    case .available:
                        break
                    case .unavailable(let reason):
                        throw ContinuationError.unavailable(Self.describe(reason))
                    @unknown default:
                        throw ContinuationError.unavailable("Apple の端末内モデルが使えません")
                    }
                    let session = LanguageModelSession(model: model, instructions: ContinuationPrompt.instructions(for: .detect(in: leftContext)))
                    let options = GenerationOptions(temperature: 0.7, maximumResponseTokens: 120)
                    let prompt = ContinuationPrompt.userPrompt(leftContext: leftContext)
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        try Task.checkCancellation()
                        stream.yield(ContinuationPrompt.clean(snapshot.content))
                    }
                    stream.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    stream.finish(throwing: Self.translate(error))
                } catch {
                    stream.finish(throwing: error)
                }
            }
            stream.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Turns the English errors of Foundation Models ("Content Likely Unsafe", etc.) into messages that can be shown to the user
    static func translate(_ error: LanguageModelSession.GenerationError) -> ContinuationError {
        switch error {
        case .guardrailViolation, .refusal:
            .blockedBySafetyFilter
        case .exceededContextWindowSize:
            .contextTooLong
        case .rateLimited, .concurrentRequests:
            .busy
        case .assetsUnavailable:
            .unavailable("端末内モデルを準備中です。しばらく待ってからもう一度試してください")
        case .unsupportedLanguageOrLocale:
            .failed("この言語には端末内モデルが対応していません")
        case .unsupportedGuide, .decodingFailure:
            .failed("端末内モデルの応答を読み取れませんでした")
        @unknown default:
            .failed(error.localizedDescription)
        }
    }

    static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            "この Mac では Apple の端末内モデルを使えません"
        case .appleIntelligenceNotEnabled:
            "システム設定で Apple Intelligence を有効にしてください"
        case .modelNotReady:
            "端末内モデルを準備中です。しばらく待ってからもう一度試してください"
        @unknown default:
            "Apple の端末内モデルが使えません"
        }
    }
}
#endif
