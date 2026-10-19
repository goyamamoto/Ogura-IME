import MLX
import MLXLMCommon

/// Blocks the end of the reply until `minimumTokens` content tokens have been generated (when the context ends with a full stop, also blocks tokens that are only whitespace, newlines, or punctuation).
/// In the format that puts the draft at the start of the reply, a draft that ends with 「。」 makes the model end its reply right there, so the output is empty (this happens often with Gemma 4).
/// If only the end is blocked, the model picks the next candidates: a newline (the reply ends soon after, so it is still empty) or 「。」/「、」 (which gives 「。。」). So these are blocked too, to make the model write content
struct MinimumTokensProcessor: LogitProcessor {
    private let bannedTokenIds: [Int32]
    /// Banned at every step: the chat format's control tokens (see `ContinuationPrompt.isControlToken`), which are never
    /// part of the text written. Gemma 4 given its draft as the start of its reply sometimes closed a thinking channel it
    /// never opened (<channel|>) and answered the request instead of going on
    private let controlTokenIds: [Int32]
    private let fillerTokenIds: Set<Int>
    private let minimumTokens: Int
    private var contentGenerated = 0

    /// - Parameters:
    ///   - stopTokenIds: Tokens that mark the end of a reply
    ///   - fillerTokenIds: Tokens that are only whitespace, newlines, or punctuation. They do not count as content
    ///   - banFillers: If true, also blocks fillerTokenIds until content appears (used when the context ends with punctuation)
    ///   - controlTokenIds: Tokens blocked throughout (the chat format's control tokens other than those that end the reply)
    init(stopTokenIds: Set<Int>, fillerTokenIds: Set<Int>, banFillers: Bool, minimumTokens: Int, controlTokenIds: Set<Int> = []) {
        self.bannedTokenIds = (banFillers ? stopTokenIds.union(fillerTokenIds) : stopTokenIds).sorted().map { Int32($0) }
        self.controlTokenIds = controlTokenIds.sorted().map { Int32($0) }
        self.fillerTokenIds = fillerTokenIds
        self.minimumTokens = minimumTokens
    }

    mutating func prompt(_ prompt: MLXArray) {
        self.contentGenerated = 0
    }

    func process(logits: MLXArray) -> MLXArray {
        var banned = self.controlTokenIds
        if self.contentGenerated < self.minimumTokens {
            banned += self.bannedTokenIds
        }
        guard !banned.isEmpty else {
            return logits
        }
        let indices = MLXArray(banned).asType(.uint32)[.newAxis, 0...]
        let values = MLXArray(Array(repeating: -Float.infinity, count: banned.count))[.newAxis, 0...].asType(logits.dtype)
        return putAlong(logits, indices, values: values, axis: -1)
    }

    mutating func didSample(token: MLXArray) {
        guard self.contentGenerated < self.minimumTokens else {
            return
        }
        let id = Int(token.asType(.int32).item(Int32.self))
        if !self.fillerTokenIds.contains(id) {
            self.contentGenerated += 1
        }
    }
}
