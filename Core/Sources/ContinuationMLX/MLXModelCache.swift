import Foundation
import MLXLMCommon

/// Keeps one loaded model. Loading takes about 1 second, so the model is kept while it is used in a row,
/// and released to free memory when it has not been used for a while
actor MLXModelCache {
    static let shared = MLXModelCache()

    private var loaded: (directory: URL, container: ModelContainer)?
    private var loading: (directory: URL, task: Task<ModelContainer, any Error>)?
    private var releaseTask: Task<Void, Never>?
    /// Per model: the tokens of the prompt header (instructions + request), which does not depend on the context.
    /// Processing the template (including the time until parsing an unreadable template fails) can take more than 1 second, so build it once and remember it
    private var headers: [String: [Int]] = [:]
    /// Per model: the IDs of tokens that are only whitespace, newlines, or punctuation (built by scanning the vocabulary once)
    private var fillerTokens: [String: Set<Int>] = [:]
    /// Per model: how to use the chat template. Parsing an unreadable template takes more than 1 second before it fails, so remember the mode once it is known
    private var chatTemplateModes: [String: ChatTemplateMode] = [:]

    func container(for directory: URL) async throws -> ModelContainer {
        self.releaseTask?.cancel()
        self.releaseTask = nil
        if let loaded, loaded.directory == directory {
            return loaded.container
        }
        if let loading, loading.directory == directory {
            return try await loading.task.value
        }
        self.loaded = nil
        self.headers = [:]
        self.fillerTokens = [:]
        let task = Task {
            try await loadModelContainer(from: directory, using: TransformersTokenizerLoader())
        }
        self.loading = (directory, task)
        defer {
            if self.loading?.directory == directory {
                self.loading = nil
            }
        }
        let container = try await task.value
        self.loaded = (directory, container)
        return container
    }

    /// Releases the model to free memory if it is not used for `delay` seconds. It is loaded again on the next use
    func scheduleRelease(after delay: TimeInterval) {
        self.releaseTask?.cancel()
        self.releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else {
                return
            }
            await self?.release()
        }
    }

    func release() {
        self.loaded = nil
        self.headers = [:]
        self.fillerTokens = [:]
        self.releaseTask = nil
    }

    /// Tokens of the model in `directory` that are only whitespace, newlines, or punctuation. If they are not cached, builds them with `make` and remembers them
    func fillerTokens(for directory: URL, make: @Sendable () -> Set<Int>) -> Set<Int> {
        if let tokens = self.fillerTokens[directory.path] {
            return tokens
        }
        let tokens = make()
        self.fillerTokens[directory.path] = tokens
        return tokens
    }

    /// The prompt header for `key` of the model in `directory`. If it is not cached, builds it with `make` and remembers it
    func header(for directory: URL, key: String, make: @Sendable (ChatTemplateMode?) -> (tokens: [Int], mode: ChatTemplateMode)) -> [Int] {
        let cacheKey = directory.path + "|" + key
        if let header = self.headers[cacheKey] {
            return header
        }
        let header = self.withChatTemplateMode(for: directory, make: make)
        self.headers[cacheKey] = header
        return header
    }

    /// Passes the remembered template mode of the model in `directory` to `make`, and remembers the mode that `make` used
    func withChatTemplateMode(for directory: URL, make: @Sendable (ChatTemplateMode?) -> (tokens: [Int], mode: ChatTemplateMode)) -> [Int] {
        let made = make(self.chatTemplateModes[directory.path])
        self.chatTemplateModes[directory.path] = made.mode
        return made.tokens
    }

    var isLoaded: Bool {
        self.loaded != nil
    }
}
