import Core
import Foundation
import Hub
import MLXLMCommon
import Tokenizers

/// Adapts a swift-transformers tokenizer to the mlx-swift-lm `Tokenizer`.
/// It only reads tokenizer.json in the model folder and never downloads anything
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizerConfig = try Self.readJSONObject(at: directory.appendingPathComponent("tokenizer_config.json"), description: "tokenizer_config.json")
        let tokenizerData = try Self.readJSONObject(at: directory.appendingPathComponent("tokenizer.json"), description: "tokenizer.json")
        let upstream: any Tokenizers.Tokenizer
        do {
            upstream = try Tokenizers.AutoTokenizer.from(
                tokenizerConfig: Config(try Self.normalizingTokenizerClass(tokenizerConfig, tokenizerData: tokenizerData)),
                tokenizerData: Config(tokenizerData)
            )
        } catch let error as Tokenizers.TokenizerError {
            throw ContinuationError.failed(Self.describe(error))
        }
        let separateTemplate = Self.separateChatTemplate(in: directory)
        return TokenizerBridge(
            upstream,
            chatTemplate: separateTemplate,
            chatTemplateText: separateTemplate ?? tokenizerConfig["chat_template"] as? String,
            vocabularySize: Self.vocabularySize(in: tokenizerData)
        )
    }

    /// The vocabulary size (largest token ID + 1). In BPE / WordPiece, vocab maps "token -> ID", and added tokens are counted too.
    /// In Unigram, vocab is an array of [token, score]. Added tokens cannot be looked up by ID (looking up outside the array crashes), so they are not counted
    static func vocabularySize(in tokenizerData: [NSString: Any]) -> Int {
        var maxId = -1
        let model = tokenizerData["model"] as? [NSString: Any] ?? [:]
        if let vocab = model["vocab"] as? [NSString: Any] {
            for case let id as Int in vocab.values {
                maxId = max(maxId, id)
            }
            for case let token as [NSString: Any] in tokenizerData["added_tokens"] as? [Any] ?? [] {
                if let id = token["id"] as? Int {
                    maxId = max(maxId, id)
                }
            }
        } else if let vocab = model["vocab"] as? [Any] {
            maxId = vocab.count - 1
        }
        return maxId + 1
    }

    private static func readJSONObject(at url: URL, description: String) throws -> [NSString: Any] {
        guard let data = try? Data(contentsOf: url) else {
            throw ContinuationError.failed("\(description) が見つかりません")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [NSString: Any] else {
            throw ContinuationError.failed("\(description) を読み込めません")
        }
        return object
    }

    /// Picks the class that matches the model type in tokenizer.json.
    /// Newer transformers (v5) put an implementation name like "TokenizersBackend" in tokenizer_class,
    /// and even a name like "LlamaTokenizer" can hold a Unigram (SentencePiece) model, so the model type wins over the name.
    /// Combinations that the built-in implementations cannot read are rejected here (going on anyway crashes inside the implementation)
    static func normalizingTokenizerClass(_ tokenizerConfig: [NSString: Any], tokenizerData: [NSString: Any]) throws -> [NSString: Any] {
        var config = tokenizerConfig
        let model = tokenizerData["model"] as? [NSString: Any] ?? [:]
        let modelType = model["type"] as? String ?? ""
        let className = (config["tokenizer_class"] as? String)?.replacingOccurrences(of: "Fast", with: "") ?? ""
        switch modelType {
        case "BPE":
            guard model["merges"] != nil else {
                throw ContinuationError.failed("tokenizer.json に merges がないため、この BPE トークナイザは読み込めません")
            }
            if !Self.knownBPETokenizerClasses.contains(className) {
                config["tokenizer_class"] = "PreTrainedTokenizer"
            }
        case "Unigram":
            config["tokenizer_class"] = "T5Tokenizer"
        case "WordPiece":
            config["tokenizer_class"] = "BertTokenizer"
        default:
            throw ContinuationError.failed(modelType.isEmpty ? "トークナイザの方式が分かりません" : "トークナイザの方式 \(modelType) には対応していません")
        }
        return config
    }

    /// Class names of the built-in implementations that read BPE
    private static let knownBPETokenizerClasses: Set<String> = [
        "CodeGenTokenizer", "CodeLlamaTokenizer", "FalconTokenizer", "GemmaTokenizer", "GPT2Tokenizer", "LlamaTokenizer",
        "WhisperTokenizer", "CohereTokenizer", "Qwen2Tokenizer", "PreTrainedTokenizer"
    ]

    static func describe(_ error: Tokenizers.TokenizerError) -> String {
        switch error {
        case .missingConfig:
            "トークナイザの設定が見つかりません"
        case .missingTokenizerClassInConfig:
            "tokenizer_config.json に tokenizer_class がありません"
        case .unsupportedTokenizer(let name):
            "トークナイザ \(name) には対応していません"
        case .missingVocab, .malformedVocab:
            "tokenizer.json の語彙を読み込めません"
        case .chatTemplate(let message):
            "チャットテンプレートを適用できません（\(message)）"
        case .tooLong(let message), .mismatchedConfig(let message):
            message
        }
    }

    /// Newer models put the chat template in a separate file, not in tokenizer_config.json
    static func separateChatTemplate(in directory: URL) -> String? {
        if let text = try? String(contentsOf: directory.appendingPathComponent("chat_template.jinja"), encoding: .utf8), !text.isEmpty {
            return text
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("chat_template.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = object["chat_template"] as? String, !text.isEmpty {
            return text
        }
        return nil
    }
}

/// It does not change after loading, so it is treated as Sendable
struct TokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
    private let upstream: any Tokenizers.Tokenizer
    /// The template from a separate file, used when tokenizer_config.json has no template
    private let chatTemplate: String?
    /// The template text (wherever it was found). Even if the template cannot be parsed, it is used to guess the separator tokens
    let chatTemplateText: String?
    /// The vocabulary size (token IDs are 0 ..< vocabularySize)
    let vocabularySize: Int

    init(_ upstream: any Tokenizers.Tokenizer, chatTemplate: String?, chatTemplateText: String?, vocabularySize: Int = 0) {
        self.upstream = upstream
        self.chatTemplate = chatTemplate
        self.chatTemplateText = chatTemplateText
        self.vocabularySize = vocabularySize
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        self.upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        self.upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        self.upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        self.upstream.convertIdToToken(id)
    }

    var bosToken: String? { self.upstream.bosToken }
    var eosToken: String? { self.upstream.eosToken }
    var unknownToken: String? { self.upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        let template: Tokenizers.ChatTemplateArgument?
        if self.upstream.hasChatTemplate {
            template = nil
        } else if let chatTemplate {
            template = .literal(chatTemplate)
        } else {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
        return try self.upstream.applyChatTemplate(
            messages: messages.map { $0 as [String: Any] },
            chatTemplate: template,
            addGenerationPrompt: true,
            truncation: false,
            maxLength: nil,
            tools: tools?.map { $0 as [String: Any] },
            additionalContext: additionalContext.map { $0 as [String: Any] }
        )
    }
}
