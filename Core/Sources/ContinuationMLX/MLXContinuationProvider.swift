import Core
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// How to use the chat template. Whether the template can be parsed, and whether it accepts a system role, is known only by trying
enum ChatTemplateMode: Int, Sendable {
    /// Build system and user messages with the template
    case systemAndUser
    /// A template without a system role (Gemma, etc.). Put the instructions into the request and build a user message only
    case userOnly
    /// The template cannot be parsed (Qwen3.5, Gemma 4, etc.). Guess the format from separator tokens and build the prompt by hand (`ChatFormat`)
    case manual
}

/// Writes continuations with an MLX model stored on this Mac. Apple Silicon only. Nothing is sent outside the Mac.
///
/// Put each model as a whole folder (config.json, safetensors, tokenizer.json) in the `LocalContinuationModels` location.
public struct MLXContinuationProvider: ContinuationProvider {
    /// How the draft is passed to the model
    public enum PromptStyle: Sendable {
        /// Pass the instructions and request in chat form, put the draft at the start of the model's reply, and let the model write from right after it (for small models)
        case completion
        /// Pass the instructions and a request that includes the draft in chat form, and let the model write the continuation as its reply (the same way as for Apple's model)
        case chat
    }

    public let modelDirectory: URL
    public let promptStyle: PromptStyle
    /// For experiments: replaces the completion-style instructions per language. If nil, the ContinuationPrompt defaults are used
    public var completionInstructions: [ContinuationPrompt.Language: String]?
    /// For experiments: replaces the completion-style request per language
    public var completionRequests: [ContinuationPrompt.Language: String]?
    /// A label for the replaced instructions. It is part of the cache key for the prompt header
    public var promptVariant = ""

    public init(modelDirectory: URL, promptStyle: PromptStyle = .completion) {
        self.modelDirectory = modelDirectory
        self.promptStyle = promptStyle
    }

    /// Creates a provider from the model name in settings. Returns nil if the name is empty
    public init?(modelName: String) {
        guard !modelName.isEmpty else {
            return nil
        }
        self.init(modelDirectory: LocalContinuationModels.modelDirectoryURL(named: modelName))
    }

    /// Maximum number of tokens to generate. Enough for 80 Japanese characters
    public static let maximumTokens = 120

    /// If the draft is this many characters or shorter, the draft is also included in the request (see `promptTokens`)
    public static let shortDraftLength = 40

    /// The end of the reply is blocked for this many first tokens.
    /// In the format that puts the draft at the start of the reply, a draft that ends with 「。」 can make the model end its reply right there, so the output is empty (this happens often with Gemma 4)
    public static let minimumTokens = 2

    public func continuation(after leftContext: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { stream in
            let task = Task {
                do {
                    let modelName = self.modelDirectory.lastPathComponent
                    guard LocalContinuationModels.isModelDirectory(self.modelDirectory) else {
                        throw ContinuationError.unavailable("モデル「\(modelName)」が見つかりません。設定の「続きを書く」でモデルを選び直してください")
                    }
                    let container: ModelContainer
                    do {
                        container = try await MLXModelCache.shared.container(for: self.modelDirectory)
                    } catch {
                        throw ContinuationError.unavailable("モデル「\(modelName)」を読み込めませんでした（\(error.localizedDescription)）")
                    }
                    let parameters = GenerateParameters(maxTokens: Self.maximumTokens, temperature: 0.7, repetitionPenalty: 1.1)
                    let tokenizer = await container.perform { $0.tokenizer }
                    let promptTokens = await self.promptTokens(tokenizer: tokenizer, leftContext: leftContext)
                    let stopTokenIds = await container.perform { Self.stopTokenIds(context: $0) }
                    let fillerTokenIds = await MLXModelCache.shared.fillerTokens(for: self.modelDirectory) { Self.fillerTokenIds(tokenizer: tokenizer) }
                    let banFillers = Self.endsWithPunctuation(leftContext)
                    let components = GenerationComponents(logitProcessorFactory: {
                        MinimumTokensProcessor(stopTokenIds: stopTokenIds, fillerTokenIds: fillerTokenIds, banFillers: banFillers, minimumTokens: Self.minimumTokens)
                    })
                    try await container.perform { (context: ModelContext) in
                        let input = LMInput(tokens: MLXArray(promptTokens))
                        let generations = try MLXLMCommon.generate(input: input, parameters: parameters, context: context, components: components)
                        for await shown in Self.shownTexts(of: generations) {
                            stream.yield(shown)
                        }
                    }
                    try Task.checkCancellation()
                    stream.finish()
                } catch let error as ContinuationError {
                    stream.finish(throwing: error)
                } catch is CancellationError {
                    stream.finish(throwing: CancellationError())
                } catch {
                    stream.finish(throwing: ContinuationError.failed("続きの生成に失敗しました（\(error.localizedDescription)）"))
                }
            }
            stream.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Streams the text to show in the IME as generation goes on. If the output was cut off at the token limit, the last value streamed is the text without its last incomplete sentence
    static func shownTexts(of generations: AsyncStream<Generation>) -> AsyncStream<String> {
        AsyncStream { stream in
            let task = Task {
                var text = ""
                var truncated = false
                for await generation in generations {
                    if Task.isCancelled {
                        break
                    }
                    switch generation {
                    case .chunk(let chunk):
                        text += chunk
                        stream.yield(ContinuationPrompt.clean(ContinuationPrompt.firstParagraph(text)))
                    case .info(let info):
                        truncated = info.generationTokenCount >= Self.maximumTokens
                    default:
                        break
                    }
                }
                if truncated {
                    // If the output was cut off at the limit, do not show the last incomplete sentence
                    stream.yield(ContinuationPrompt.clean(ContinuationPrompt.droppingIncompleteLastSentence(ContinuationPrompt.firstParagraph(text))))
                }
                stream.finish()
            }
            stream.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// The prompt passed to the model, decoded back to a string (for checking)
    public func promptText(for leftContext: String) async throws -> String {
        let container = try await MLXModelCache.shared.container(for: self.modelDirectory)
        let tokenizer = await container.perform { $0.tokenizer }
        let tokens = await self.promptTokens(tokenizer: tokenizer, leftContext: leftContext)
        return tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
    }

    /// IDs of tokens that are only whitespace, newlines, or punctuation. Found by scanning the vocabulary once (only short tokens are decoded, so it takes about 0.1 seconds).
    /// Used to block these tokens until content appears (`MinimumTokensProcessor`)
    static func fillerTokenIds(tokenizer: any MLXLMCommon.Tokenizer) -> Set<Int> {
        guard let bridge = tokenizer as? TokenizerBridge else {
            return []
        }
        var ids: Set<Int> = []
        for id in 0 ..< bridge.vocabularySize {
            // Tokens that are only whitespace or punctuation are short in the vocabulary too (even in byte-level BPE, 「。」 is 3 characters)
            guard let raw = bridge.convertIdToToken(id), raw.count <= 8 else {
                continue
            }
            if Self.isFiller(tokenizer.decode(tokenIds: [id], skipSpecialTokens: false)) {
                ids.insert(id)
            }
        }
        return ids
    }

    /// Marks that separate sentences. Brackets and quotation marks are not included: 「。」 right after a context that ends with 「）」, and 「「」 right after 「。」, are natural, so they are not blocked
    private static let fillerCharacters: Set<Character> = [
        "。", "、", "，", "．", ",", ".", "!", "?", "！", "？", "…", "‥", "・", ":", ";", "：", "；"
    ]

    /// Whether the text is made only of whitespace, newlines, and sentence separator marks
    static func isFiller(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isWhitespace || $0.isNewline || Self.fillerCharacters.contains($0) }
    }

    /// Whether the context ends with punctuation (trailing whitespace is ignored)
    static func endsWithPunctuation(_ context: String) -> Bool {
        guard let last = context.last(where: { !$0.isWhitespace }) else {
            return false
        }
        return Self.fillerCharacters.contains(last)
    }

    /// Tokens that mark the end of a reply: the eos tokens from the model config and the tokenizer, plus the end-of-turn tokens of each chat format
    static func stopTokenIds(context: ModelContext) -> Set<Int> {
        var ids = context.configuration.eosTokenIds
        if let eos = context.tokenizer.eosTokenId {
            ids.insert(eos)
        }
        for token in ChatFormat.endOfTurnTokens + Array(context.configuration.extraEOSTokens) {
            if let id = context.tokenizer.convertTokenToId(token) {
                ids.insert(id)
            }
        }
        return ids
    }

    /// completion: Builds "instructions + request" with the chat template, and puts the draft after it as the start of the model's reply.
    /// The model generates from right after the end of the draft, so even small models rarely restate it.
    /// A short draft (`shortDraftLength` or shorter) is also included in the request. If a draft like 「了解しました。」 ("Understood.") is only put at the start of the reply,
    /// the model takes it as its own answer to the request and asks back 「どのような文章を書きますか」 ("What kind of text should I write?") (almost every time with Gemma 4 and sarashina).
    /// With the draft in the request, the model can tell it is a draft. This does not happen with long drafts, so they are not added (it would make the prompt longer).
    /// chat: Builds the instructions and a request that includes the draft, and lets the model write the continuation as its reply
    func promptTokens(tokenizer: any MLXLMCommon.Tokenizer, leftContext: String) async -> [Int] {
        let language = ContinuationPrompt.Language.detect(in: leftContext)
        switch self.promptStyle {
        case .completion:
            let instructions = self.completionInstructions?[language] ?? ContinuationPrompt.completionInstructions(for: language)
            let request = self.completionRequests?[language] ?? ContinuationPrompt.completionUserPrompt(for: language)
            // Let the model write the trailing whitespace (a word token with a leading space then follows naturally; if the whitespace is kept, the output tends to start with a digit or similar)
            let draft = String(leftContext.reversed().drop(while: \.isWhitespace).reversed())
            let draftTokens = Self.encodeDraft(draft, tokenizer: tokenizer)
            if draft.count <= Self.shortDraftLength {
                let header = await MLXModelCache.shared.withChatTemplateMode(for: self.modelDirectory) { mode in
                    Self.headerTokens(tokenizer: tokenizer, instructions: instructions, request: request + "\n\n" + draft, startingAt: mode)
                }
                return header + draftTokens
            }
            // The header does not depend on the context, so cache it per model (template processing is slow)
            let header = await MLXModelCache.shared.header(for: self.modelDirectory, key: "completion-\(language)-\(self.promptVariant)") { mode in
                Self.headerTokens(tokenizer: tokenizer, instructions: instructions, request: request, startingAt: mode)
            }
            return header + draftTokens
        case .chat:
            let instructions = ContinuationPrompt.instructions(for: language)
            let request = ContinuationPrompt.userPrompt(leftContext: leftContext)
            return await MLXModelCache.shared.withChatTemplateMode(for: self.modelDirectory) { mode in
                Self.headerTokens(tokenizer: tokenizer, instructions: instructions, request: request, startingAt: mode)
            }
        }
    }

    /// Encodes the draft into tokens. Tokenizers without a newline token (sarashina, etc.) turn a newline into <unk>, so newlines are replaced with spaces
    static func encodeDraft(_ draft: String, tokenizer: any MLXLMCommon.Tokenizer) -> [Int] {
        let tokens = tokenizer.encode(text: draft, addSpecialTokens: false)
        if let unknown = tokenizer.unknownToken.flatMap({ tokenizer.convertTokenToId($0) }), tokens.contains(unknown),
           tokenizer.encode(text: "\n", addSpecialTokens: false).contains(unknown) {
            return tokenizer.encode(text: draft.replacingOccurrences(of: "\n", with: " "), addSpecialTokens: false)
        }
        return tokens
    }

    /// Builds the instructions and request in the model's chat format
    static func headerTokens(tokenizer: any MLXLMCommon.Tokenizer, instructions: String, request: String, startingAt mode: ChatTemplateMode? = nil) -> (tokens: [Int], mode: ChatTemplateMode) {
        let built = Self.chatTokens(tokenizer: tokenizer, instructions: instructions, request: request, startingAt: mode)
        // Tokenizers without a newline token (sarashina, etc.) turn a newline into <unk>, so replace newlines with spaces and build again
        if let unknown = tokenizer.unknownToken.flatMap({ tokenizer.convertTokenToId($0) }), built.tokens.contains(unknown) {
            return Self.chatTokens(
                tokenizer: tokenizer,
                instructions: instructions.replacingOccurrences(of: "\n", with: " "),
                request: request.replacingOccurrences(of: "\n", with: " "),
                startingAt: built.mode
            )
        }
        return built
    }

    /// Builds with the template. If the template cannot be used, guesses the format from separator tokens and builds the prompt by hand.
    /// Passing the mode that worked before as `startingAt` skips the earlier tries (which would fail). Parsing an unreadable template takes more than 1 second before it fails
    static func chatTokens(tokenizer: any MLXLMCommon.Tokenizer, instructions: String, request: String, startingAt mode: ChatTemplateMode? = nil) -> (tokens: [Int], mode: ChatTemplateMode) {
        let additionalContext: [String: any Sendable] = ["enable_thinking": false]
        let first = mode ?? .systemAndUser
        if first.rawValue <= ChatTemplateMode.systemAndUser.rawValue,
           let tokens = try? tokenizer.applyChatTemplate(
            messages: [["role": "system", "content": instructions], ["role": "user", "content": request]],
            tools: nil,
            additionalContext: additionalContext
           ) {
            return (tokens, .systemAndUser)
        }
        // For templates without a system role (Gemma, etc.), put the instructions into the request
        if first.rawValue <= ChatTemplateMode.userOnly.rawValue,
           let tokens = try? tokenizer.applyChatTemplate(
            messages: [["role": "user", "content": instructions + "\n\n" + request]],
            tools: nil,
            additionalContext: additionalContext
           ) {
            return (tokens, .userOnly)
        }
        // If the old Jinja implementation cannot parse the template (Qwen3.5, etc.), guess the format from the special tokens
        return (tokenizer.encode(text: Self.manualChatPrompt(tokenizer: tokenizer, instructions: instructions, request: request), addSpecialTokens: false), .manual)
    }

    /// Picks the Gemma 4 / Gemma / ChatML / Llama 3 format and builds the prompt. The format is decided by the template text (see `ChatFormat`)
    static func manualChatPrompt(tokenizer: any MLXLMCommon.Tokenizer, instructions: String, request: String) -> String {
        let format = ChatFormat.detect(templateText: (tokenizer as? TokenizerBridge)?.chatTemplateText) { tokenizer.convertTokenToId($0) != nil }
        return format.prompt(instructions: instructions, request: request)
    }

    /// Releases the model to free memory if it is not used for a while (called when the IME becomes inactive)
    public static func releaseModel(after delay: TimeInterval) {
        Task {
            await MLXModelCache.shared.scheduleRelease(after: delay)
        }
    }

    public static func releaseModelNow() async {
        await MLXModelCache.shared.release()
    }
}
