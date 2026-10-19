import Foundation

/// The format used to build a chat prompt by hand for an MLX model. For models whose template the old Jinja implementation cannot parse (Qwen3.5, Gemma 4, etc.)
public enum ChatFormat: Equatable, Sendable {
    case gemma4
    case gemma
    case chatML(think: Bool)
    case llama3
    case plain

    /// Separator tokens used to guess the format
    static let markers = ["<|turn>", "<start_of_turn>", "<|im_start|>", "<|start_header_id|>"]

    /// If the template text names separator tokens, decide by them. Otherwise, decide by the tokens in the vocabulary.
    /// The vocabulary is unreliable (Gemma 4's vocabulary has both <|im_start|> and <think>), so the template text wins
    public static func detect(templateText: String?, hasToken: (String) -> Bool) -> ChatFormat {
        let template = templateText ?? ""
        let templateNamesMarker = Self.markers.contains { template.contains($0) }
        func uses(_ marker: String) -> Bool {
            templateNamesMarker ? template.contains(marker) : hasToken(marker)
        }
        if uses("<|turn>") {
            return .gemma4
        }
        if uses("<start_of_turn>") {
            return .gemma
        }
        if uses("<|im_start|>") {
            // For thinking models (Qwen3, etc.), add an empty thinking block to turn thinking off
            return .chatML(think: uses("<think>"))
        }
        if uses("<|start_header_id|>") {
            return .llama3
        }
        return .plain
    }

    /// Builds the instructions and request, and ends at the start of the reply (the draft goes after it)
    public func prompt(instructions: String, request: String) -> String {
        switch self {
        case .gemma4:
            // Thinking is off by default
            "<bos><|turn>system\n\(instructions)<turn|>\n<|turn>user\n\(request)<turn|>\n<|turn>model\n"
        case .gemma:
            // Up to Gemma 3, there is no system role
            "<bos><start_of_turn>user\n\(instructions)\n\n\(request)<end_of_turn>\n<start_of_turn>model\n"
        case .chatML(let think):
            "<|im_start|>system\n\(instructions)<|im_end|>\n<|im_start|>user\n\(request)<|im_end|>\n<|im_start|>assistant\n" + (think ? "<think>\n\n</think>\n\n" : "")
        case .llama3:
            "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n\(instructions)<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n\(request)<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"
        case .plain:
            instructions + "\n\n" + request + "\n\n"
        }
    }

    /// Tokens that mark the end of a reply in each format. Used to block them for the first few tokens
    public static let endOfTurnTokens = ["<turn|>", "<end_of_turn>", "<|im_end|>", "<|eot_id|>", "<|endoftext|>", "<|end_of_text|>", "</s>", "<eos>", "<|end|>"]
}
