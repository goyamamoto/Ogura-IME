import Core
import CoreML
import Foundation
import MLXLMCommon

/// A `ReadingJudge` run by Core ML on the Neural Engine: a small encoder (a ModernBERT-Ja reranker trained on readings)
/// whose model takes `input_ids` and `attention_mask` of a fixed length and gives `score`. The directory holds the model
/// (model.mlmodelc as compiled, or model.mlpackage to compile) and its tokenizer (tokenizer.json, tokenizer_config.json)
public final class CoreMLReadingJudge: ReadingJudge, @unchecked Sendable {
    private let model: MLModel
    private let tokenizer: any MLXLMCommon.Tokenizer
    private let length: Int
    private let padToken: Int
    private let lock = NSLock()

    /// Loads the model in `directory` and waits for it
    public convenience init(directory: URL) throws {
        let loaded = Loaded()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                loaded.result = .success(try await Self.files(in: directory))
            } catch {
                loaded.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = loaded.result else {
            throw ContinuationError.failed("判定のモデルを読み込めませんでした")
        }
        let (tokenizer, compiled) = try result.get()
        try self.init(tokenizer: tokenizer, compiledModel: compiled)
    }

    /// Loads the model in `directory`
    public static func load(directory: URL) async throws -> CoreMLReadingJudge {
        let (tokenizer, compiled) = try await Self.files(in: directory)
        return try CoreMLReadingJudge(tokenizer: tokenizer, compiledModel: compiled)
    }

    /// The tokenizer in `directory`, and the model compiled: as shipped, or compiled now
    private static func files(in directory: URL) async throws -> (any MLXLMCommon.Tokenizer, URL) {
        let tokenizer = try await TransformersTokenizerLoader().load(from: directory)
        let compiled = directory.appendingPathComponent("model.mlmodelc", isDirectory: true)
        if FileManager.default.fileExists(atPath: compiled.path) {
            return (tokenizer, compiled)
        }
        return (tokenizer, try await MLModel.compileModel(at: directory.appendingPathComponent("model.mlpackage")))
    }

    private init(tokenizer: any MLXLMCommon.Tokenizer, compiledModel compiled: URL) throws {
        let configuration = MLModelConfiguration()
        // Not the CPU alone: the model is in fp16, which overflows there
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        guard let shape = model.modelDescription.inputDescriptionsByName["input_ids"]?.multiArrayConstraint?.shape, let length = shape.last?.intValue,
              let padToken = tokenizer.convertTokenToId("<pad>") else {
            throw ContinuationError.failed("判定のモデルの形が分かりません")
        }
        self.model = model
        self.tokenizer = tokenizer
        self.length = length
        self.padToken = padToken
    }

    public func scores(of readings: [String]) -> [Float]? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        var scores: [Float] = []
        for reading in readings {
            let tokens = self.tokens(of: reading)
            guard let ids = try? MLMultiArray(shape: [1, NSNumber(value: self.length)], dataType: .int32),
                  let mask = try? MLMultiArray(shape: [1, NSNumber(value: self.length)], dataType: .int32) else {
                return nil
            }
            for index in 0 ..< self.length {
                ids[index] = NSNumber(value: index < tokens.count ? tokens[index] : self.padToken)
                mask[index] = NSNumber(value: index < tokens.count ? 1 : 0)
            }
            guard let input = try? MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask]),
                  let output = try? self.model.prediction(from: input),
                  let score = output.featureValue(for: "score")?.multiArrayValue?[0].floatValue else {
                return nil
            }
            scores.append(score)
        }
        return scores
    }

    /// The tokens of `reading` with the start and end tokens, cut to the model's length from the start: the end of the
    /// input is where it is being typed
    public func tokens(of reading: String) -> [Int] {
        let tokens = self.tokenizer.encode(text: reading, addSpecialTokens: true)
        guard tokens.count > self.length, let first = tokens.first else {
            return tokens
        }
        return [first] + tokens.suffix(self.length - 1)
    }

    /// The tokenizer and the compiled model loaded by the task `init` waits for
    private final class Loaded: @unchecked Sendable {
        var result: Result<(any MLXLMCommon.Tokenizer, URL), any Error>?
    }
}
