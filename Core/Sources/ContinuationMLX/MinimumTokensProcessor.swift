import MLX
import MLXLMCommon

/// Blocks the end of the reply until `minimumTokens` content tokens have been generated (when the context ends with a full stop, also blocks tokens that are only whitespace, newlines, or punctuation).
/// In the format that puts the draft at the start of the reply, a draft that ends with 「。」 makes the model end its reply right there, so the output is empty (this happens often with Gemma 4).
/// If only the end is blocked, the model picks the next candidates: a newline (the reply ends soon after, so it is still empty) or 「。」/「、」 (which gives 「。。」). So these are blocked too, to make the model write content
struct MinimumTokensProcessor: LogitProcessor {
    private let bannedTokenIds: [Int32]
    private let fillerTokenIds: Set<Int>
    private let minimumTokens: Int
    private var contentGenerated = 0

    /// - Parameters:
    ///   - stopTokenIds: Tokens that mark the end of a reply
    ///   - fillerTokenIds: Tokens that are only whitespace, newlines, or punctuation. They do not count as content
    ///   - banFillers: If true, also blocks fillerTokenIds until content appears (used when the context ends with punctuation)
    init(stopTokenIds: Set<Int>, fillerTokenIds: Set<Int>, banFillers: Bool, minimumTokens: Int) {
        self.bannedTokenIds = (banFillers ? stopTokenIds.union(fillerTokenIds) : stopTokenIds).sorted().map { Int32($0) }
        self.fillerTokenIds = fillerTokenIds
        self.minimumTokens = minimumTokens
    }

    mutating func prompt(_ prompt: MLXArray) {
        self.contentGenerated = 0
    }

    func process(logits: MLXArray) -> MLXArray {
        guard self.contentGenerated < self.minimumTokens, !self.bannedTokenIds.isEmpty else {
            return logits
        }
        let indices = MLXArray(self.bannedTokenIds).asType(.uint32)[.newAxis, 0...]
        let values = MLXArray(Array(repeating: -Float.infinity, count: self.bannedTokenIds.count))[.newAxis, 0...].asType(logits.dtype)
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
