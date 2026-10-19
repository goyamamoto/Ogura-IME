import Foundation

/// 「続きを書く」 (write the continuation): one key makes an on-device model write a continuation of the text to the left of the cursor,
/// shown faintly (ghost) after the marked text. Tab or Enter accepts it, Esc discards it, and any other key discards it and goes on with normal input.
extension InputSession {
    public struct Continuation: Equatable, Sendable {
        /// The text generated so far
        public var text: String
        public var isGenerating: Bool
        /// A message shown instead of the text (the model cannot be used, etc.)
        public var message: String?

        /// The string shown after the marked text
        var displayText: String {
            if let message {
                return "（\(message)）"
            }
            if self.text.isEmpty, self.isGenerating {
                return "…"
            }
            return self.text
        }
    }

    /// Maximum length (in characters) of the context read from the host for a continuation. The context is read only when this key is pressed
    public static let continuationContextLength = 400

    /// Maximum number of attempts when the output is broken (including the first generation). Never retries forever
    public static let continuationMaxAttempts = 3

    /// Whether the output is clearly broken. See `brokenContinuationReason`
    public static func isBrokenContinuation(_ text: String, after context: String) -> Bool {
        Self.brokenContinuationReason(text, after: context) != nil
    }

    /// If the output is clearly broken, returns the reason. Empty output, restated instructions, long copies of the context, and repeated sentences or phrases count as broken.
    /// Lengths count only script characters (kana and kanji for Japanese, Latin letters for English), not product names, digits, or symbols
    public static func brokenContinuationReason(_ text: String, after context: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "空"
        }
        let language = ContinuationPrompt.Language.detect(in: context)
        // Talks about the instructions or the request instead of continuing the text (「書きかけの文章を渡してください」 "Please give me the draft", 「80文字以内で」 "within 80 characters", etc.)
        if ContinuationPrompt.talksAboutTheTask(text, language: language, context: context) {
            return "指示について語っている"
        }
        // A copy of the context: 16 or more script characters (30 for English) from near the end (the last 150 characters), or 24 or more (50 for English) from earlier.
        // Set phrases (「ありがとうございました」 "thank you", 「よろしくお願いいたします」 "best regards", etc.) and quoted proper nouns are allowed
        let tail = String(context.suffix(150))
        let quoteLength = language == .english ? 30 : 16
        if ContinuationPrompt.longestCommonSubstringWeight(text, tail, language: language) >= quoteLength {
            return "文脈の丸写し"
        }
        let farQuoteLength = language == .english ? 50 : 24
        if context.count > tail.count, ContinuationPrompt.longestCommonSubstringWeight(text, context, language: language) >= farQuoteLength {
            return "文脈の丸写し"
        }
        // Contains the last clause of the context as is. removingRepeatedPrefix has already dropped any retrace at the start, so if the clause is still there, it is a restatement
        if let clause = Self.trailingClause(of: context, language: language), language.weight(of: clause) >= 6,
           Self.removingWhitespace(text).contains(Self.removingWhitespace(clause)) {
            return "末尾の言い直し"
        }
        // The same sentence (4 or more script characters) appears twice
        let terminators = CharacterSet(charactersIn: "。！？!?.").union(.whitespacesAndNewlines)
        let sentences = ContinuationPrompt.sentences(in: text)
            .map { $0.trimmingCharacters(in: terminators) }
            .filter { language.weight(of: $0) >= 4 }
        if Set(sentences).count < sentences.count {
            return "同じ文の繰り返し"
        }
        // The same phrase appears again and again at different places (going around in circles inside a sentence): twice for 16 or more script characters (40 for English), three times for 8 or more (20 for English).
        // Catching short phrases at 2 times would also throw away normal sentences that just use a topic noun phrase twice, as in 「新商品の開発進捗」 and 「プロジェクトの進捗を確認」
        let longPhrase = language == .english ? 40 : 16
        var seen: Set<String> = []
        for phrase in Self.phrases(in: text, length: longPhrase, language: language) where !seen.insert(phrase).inserted {
            return "語句の繰り返し"
        }
        let shortPhrase = language == .english ? 20 : 8
        var counts: [String: Int] = [:]
        for phrase in Self.phrases(in: text, length: shortPhrase, language: language) {
            counts[phrase, default: 0] += 1
            if counts[phrase] == 3 {
                return "語句の繰り返し"
            }
        }
        return nil
    }

    /// Turns the model output into the shown form: drops the part that retraces the end of the context, tidies punctuation at the boundary, and limits the number of sentences.
    /// The IME and the evaluation CLI go through the same processing
    public static func presentableContinuation(from snapshot: String, after context: String) -> String {
        let text = ContinuationPrompt.limitingSentences(
            ContinuationPrompt.trimmingBoundaryPunctuation(Self.removingRepeatedPrefix(from: snapshot, after: context), after: context)
        )
        return ContinuationPrompt.restoringWordSpace(text, raw: snapshot, after: context)
    }

    /// Cuts out phrases that contain `length` script characters, one starting at each script character (symbols and digits in between are included as is)
    static func phrases(in text: String, length: Int, language: ContinuationPrompt.Language) -> [String] {
        let chars = Array(text)
        let scriptIndices = chars.indices.filter { language.isScriptCharacter(chars[$0]) }
        guard scriptIndices.count >= length else {
            return []
        }
        return (0 ... (scriptIndices.count - length)).map { String(chars[scriptIndices[$0] ... scriptIndices[$0 + length - 1]]) }
    }

    /// Even when asked for a continuation, a model sometimes repeats the preceding text before it starts writing.
    /// Drops the part where the end of the context and the start of the generated text overlap (longest match), and returns empty while generation is still retracing the context.
    /// A model may also retrace with slightly different wording (「来月の初めまでに」 -> 「来月の初めに」, "by early next month" -> "early next month"), so if the text is similar up to the last clause of the context, drops up to there
    public static func removingRepeatedPrefix(from generated: String, after context: String) -> String {
        let generated = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !generated.isEmpty, !context.isEmpty else {
            return generated
        }
        // If the whole generated text appears in the context, the model is still repeating (or it ended with only a repetition). Differences in whitespace are ignored
        if generated.count >= 2, Self.removingWhitespace(context).contains(Self.removingWhitespace(generated)) {
            return ""
        }
        let contextChars = Array(context)
        let generatedChars = Array(generated)
        let maxOverlap = min(contextChars.count, generatedChars.count)
        if maxOverlap >= 2 {
            for length in stride(from: maxOverlap, through: 2, by: -1) where contextChars.suffix(length) == generatedChars.prefix(length) {
                return String(generatedChars.dropFirst(length)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let end = Self.endOfRestatedPrefix(in: generated, after: context) {
            return String(generated[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return generated
    }

    static func removingWhitespace(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    /// Clause separators
    private static let clauseSeparators: Set<Character> = ["。", "！", "？", "!", "?", "、", "，", ",", ".", ";", ":", "\n"]

    /// The last clause of the context (earlier clauses are included until it has 4 or more script characters). Trailing separators and whitespace are excluded
    static func trailingClause(of context: String, language: ContinuationPrompt.Language) -> String? {
        var chars = Array(context)
        while let last = chars.last, last.isWhitespace || Self.clauseSeparators.contains(last) {
            chars.removeLast()
        }
        var start = chars.count
        var weight = 0
        while start > 0 {
            let character = chars[start - 1]
            if weight >= 4, Self.clauseSeparators.contains(character) {
                break
            }
            start -= 1
            if language.isScriptCharacter(character) {
                weight += 1
            }
        }
        guard weight >= 4 else {
            return nil
        }
        return String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// If the start of the generated text retraces the end of the context, returns where the retrace ends (right after the last clause of the context and the separator that followed it in the context).
    /// Only when the last clause appears as is, followed by the same separator as in the context, and the part before it is also similar to the matching part of the context (half or more of the character 2-grams overlap).
    /// If what follows the clause differs from the context (for example, 「晴れている。」 rewritten as 「晴れているので、」), it is a rewrite of the sentence, so it is not dropped and is left to be treated as broken output
    static func endOfRestatedPrefix(in generated: String, after context: String) -> String.Index? {
        let language = ContinuationPrompt.Language.detect(in: context)
        guard let clause = Self.trailingClause(of: context, language: language),
              let found = generated.range(of: clause),
              let clauseInContext = context.range(of: clause, options: .backwards) else {
            return nil
        }
        let head = String(generated[..<found.lowerBound])
        let contextHead = String(context[..<clauseInContext.lowerBound])
        if !head.isEmpty {
            // A retrace is not longer than the context
            guard head.count <= contextHead.count + 2, Self.bigramSimilarity(head, String(contextHead.suffix(head.count))) >= 0.5 else {
                return nil
            }
        }
        let contextTail = context[clauseInContext.upperBound...]
        let rest = generated[found.upperBound...]
        guard rest.isEmpty || rest.hasPrefix(contextTail) else {
            return nil
        }
        var end = rest.isEmpty ? generated.endIndex : generated.index(found.upperBound, offsetBy: contextTail.count)
        while end < generated.endIndex, generated[end].isWhitespace {
            end = generated.index(after: end)
        }
        return end
    }

    /// Dice coefficient of character 2-grams (whitespace excluded)
    static func bigramSimilarity(_ lhs: String, _ rhs: String) -> Double {
        func bigrams(_ text: String) -> [String: Int] {
            let chars = Array(text.filter { !$0.isWhitespace })
            guard chars.count >= 2 else {
                return [:]
            }
            var result: [String: Int] = [:]
            for i in 0 ..< (chars.count - 1) {
                result[String(chars[i ... i + 1]), default: 0] += 1
            }
            return result
        }
        let left = bigrams(lhs)
        let right = bigrams(rhs)
        let total = left.values.reduce(0, +) + right.values.reduce(0, +)
        guard total > 0 else {
            return 0
        }
        let common = left.reduce(0) { $0 + min($1.value, right[$1.key] ?? 0) }
        return Double(2 * common) / Double(total)
    }
    /// Key handling while a continuation is shown. nil means: clear the display and go on with normal handling
    func handleContinuationKey(userAction: UserAction) -> Bool? {
        guard let continuation = self.continuation else {
            return nil
        }
        switch userAction {
        case .continuation:
            // The document has not changed while the suggestion was shown (any other key or a click ends it), so write
            // for the same context. Reading it again right after clearing the suggestion is not safe: some apps answer
            // from a copy of the document they refresh only on their next frame, which still holds the old suggestion
            self.requestContinuation(context: self.continuationContext)
            return true
        case .tab, .enter:
            if continuation.message == nil, !continuation.text.isEmpty {
                // Replace the faint display (marked text) with the text. If the display is cleared first and the text is inserted after,
                // apps that are slow to update the marked range may replace the text just before it, so replace it with a single insertText call
                self.cancelContinuation(clearingDisplay: false)
                self.host?.insertText(continuation.text)
            } else {
                self.cancelContinuation()
            }
            self.host?.updateMarkedText(self.markedText)
            return true
        case .escape:
            self.cancelContinuation()
            self.host?.updateMarkedText(self.markedText)
            return true
        default:
            self.cancelContinuation()
            return nil
        }
    }

    /// Starts writing a continuation. `context` is the text before the cursor when the caller already knows it; otherwise it is read from the host
    func requestContinuation(context knownContext: String? = nil) {
        self.cancelContinuation()
        self.continuationGeneration += 1
        let generation = self.continuationGeneration
        guard let provider = self.continuationProvider else {
            self.continuation = Continuation(text: "", isGenerating: false, message: "設定の「続きを書く」がオフです")
            self.host?.updateMarkedText(self.markedText)
            return
        }
        // cancelContinuation has already cleared earlier suggestions and messages from the app, so they do not mix into the context read here
        let context = knownContext ?? self.host?.leftSideContext(maxCount: Self.continuationContextLength) ?? ""
        guard !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.continuation = Continuation(text: "", isGenerating: false, message: "続きを書くための文章がカーソルの前にありません")
            self.host?.updateMarkedText(self.markedText)
            return
        }
        self.continuation = Continuation(text: "", isGenerating: true, message: nil)
        self.continuationContext = context
        self.host?.updateMarkedText(self.markedText)
        self.continuationTask = Task { [weak self] in
            await self?.generateContinuation(provider: provider, context: context, generation: generation)
        }
    }

    /// The factor for shrinking the context when generation is stopped by the safety filter, etc.: 400 -> 100 -> 25 characters
    public static let continuationContextShrinkFactor = 4

    /// Runs generation (the flow is in ContinuationRunner) and shows progress and messages.
    /// Checks the request number so that the result of an old request does not overwrite a newer display
    private func generateContinuation(provider: any ContinuationProvider, context: String, generation: Int) async {
        let result: ContinuationRunner.Result
        do {
            result = try await ContinuationRunner.run(
                provider: provider,
                context: context,
                onSnapshot: { [weak self] text in
                    guard let self, self.continuationGeneration == generation else {
                        return
                    }
                    self.continuation?.text = text
                    self.host?.updateMarkedText(self.markedText)
                },
                onRetry: { [weak self] in
                    guard let self, self.continuationGeneration == generation else {
                        return
                    }
                    self.continuation?.text = ""
                    self.host?.updateMarkedText(self.markedText)
                }
            )
        } catch {
            // Cancelled (a new request, or the display was stopped)
            return
        }
        guard self.continuationGeneration == generation else {
            return
        }
        switch result.outcome {
        case .continuation(let text):
            self.continuation?.text = text
            self.finishContinuation(message: nil)
        case .message(let message):
            self.finishContinuation(message: message)
        }
    }

    private func finishContinuation(message: String?) {
        self.continuation?.isGenerating = false
        if let message {
            self.continuation?.text = ""
            self.continuation?.message = message
        }
        self.host?.updateMarkedText(self.markedText)
    }

    /// Waits until generation finishes (for tests, and for callers that want to wait for completion before committing)
    public func waitForContinuation() async {
        await self.continuationTask?.value
    }

    /// Stops showing the continuation. If it was shown, also clears the app's display right away (`clearingDisplay`).
    /// If the display is left, the app commits the marked text into the document when focus moves,
    /// and 「（続きを思いつきませんでした）」 ("(Could not think of a continuation)") or an earlier suggestion mixes into the next context read.
    /// Only when a suggestion is accepted, the display is not cleared but replaced with insertText (the caller does this)
    func cancelContinuation(clearingDisplay: Bool = true) {
        self.continuationTask?.cancel()
        self.continuationTask = nil
        let wasShowing = self.continuation != nil
        self.continuation = nil
        self.continuationContext = nil
        if wasShowing, clearingDisplay {
            self.host?.updateMarkedText(self.markedText)
        }
    }
}

extension SegmentsManager.MarkedText {
    /// Appends a faint (ghost) string at the end. The cursor position does not change
    func appendingGhost(_ ghost: String) -> Self {
        var copy = self
        copy.text.append(Element(content: ghost, focus: .ghost))
        return copy
    }
}
