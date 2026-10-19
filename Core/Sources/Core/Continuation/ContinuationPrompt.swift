import Foundation

/// The instructions passed to the model for 「続きを書く」 (write the continuation), and cleanup of its output. Shared by both backends (Apple / MLX)
public enum ContinuationPrompt {
    /// The language of the draft. It decides the instructions, how sentences are counted, and the thresholds for detecting broken output
    public enum Language: Sendable, Equatable {
        case japanese
        case english

        /// Detects the language from the character types. Even a little kana means Japanese (a Japanese sentence contains kana, however much Latin text such as product names it has).
        /// The text is treated as English only when it has no kana and more Latin letters than kanji
        public static func detect(in text: String) -> Language {
            var kana = 0
            var kanji = 0
            var latin = 0
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 0x3041 ... 0x30FF, 0xFF66 ... 0xFF9F:
                    kana += 1
                case 0x3400 ... 0x9FFF, 0xF900 ... 0xFAFF:
                    kanji += 1
                case 0x41 ... 0x5A, 0x61 ... 0x7A, 0xC0 ... 0x24F:
                    latin += 1
                default:
                    break
                }
            }
            if kana >= 2 {
                return .japanese
            }
            return latin > kanji ? .english : .japanese
        }

        /// Whether the character is a script character: kana and kanji for Japanese, Latin letters for English.
        /// Used so that product names, digits, and symbols are not counted when measuring the length of quotes and repetitions
        public func isScriptCharacter(_ character: Character) -> Bool {
            guard let scalar = character.unicodeScalars.first else {
                return false
            }
            switch self {
            case .japanese:
                switch scalar.value {
                case 0x3041 ... 0x30FF, 0x3400 ... 0x9FFF, 0xF900 ... 0xFAFF, 0xFF66 ... 0xFF9F:
                    return true
                default:
                    return false
                }
            case .english:
                return character.isLetter
            }
        }

        /// The number of script characters
        public func weight(of text: some StringProtocol) -> Int {
            text.reduce(0) { $0 + (self.isScriptCharacter($1) ? 1 : 0) }
        }
    }

    public static func instructions(for language: Language) -> String {
        switch language {
        case .japanese:
            """
            あなたは日本語の文章を書く手伝いをします。ユーザーは書きかけの文章の末尾を渡します。
            その直後に自然につながる続きだけを書いてください。
            - 渡された文章やその一部を出力に含めない。最初の一文字から新しい内容を書く。
            - 前置き、説明、引用符、箇条書きの記号を付けない。
            - 文体（敬体か常体か）と話題を元の文章に合わせる。
            - 1〜2文、全体で80文字以内。文の途中で終わらない。
            """
        case .english:
            """
            You help the user write English text. The user gives you the end of a draft.
            Write only the text that naturally continues right after it.
            - Do not repeat the draft or any part of it. Start with new content from the first character.
            - No preamble, explanation, quotation marks, or list markers.
            - Match the register (formal or casual) and the topic of the draft.
            - One or two sentences, at most 40 words. Do not stop mid-sentence.
            """
        }
    }

    /// Instructions for the completion format (the draft is put at the start of the model's reply, and the model generates from right after it).
    /// They frame the model as the author itself, and leave out numbers for sentence or character counts and the words 「書きかけ」 (draft) and 「ユーザー」 (user).
    /// Small models repeat these back: they add a note like 「（80文字以内）」 ("(80 characters or less)") or reply 「書きかけの文章を渡してください」 ("Please give me the draft").
    /// (Measured with 18 contexts x 4 models x 2 runs, restating dropped from 26% to 13%. The wording is separate from the instructions for Apple's model)
    public static func completionInstructions(for language: Language) -> String {
        switch language {
        case .japanese:
            """
            あなたは日本語の文章の書き手です。出力の冒頭にある文章は、あなた自身がここまでに書いたものです。
            その末尾の直後から、同じ文章を自然に書き進めます。末尾が句点で終わっていても、必ず次の文へ進みます。
            - 文章を言い直したり、最初から書き直したりしない。
            - 前置き、説明、引用符、箇条書きや見出しの記号を付けない。
            - 文体（敬体か常体か）と話題はここまでの文章に合わせる。
            - 加える分は短く、文の途中で終わらない。
            """
        case .english:
            """
            You are the author. Your output begins with the English text you have written so far.
            Keep writing that same text naturally from right after its end. Even if it ends with a full stop, go on to the next sentence.
            - Never restate it or start over.
            - No preamble, explanation, quotation marks, bullets, or Markdown.
            - Match its register (formal or casual) and topic.
            - Keep it brief; never stop mid-sentence.
            """
        }
    }

    public static func completionUserPrompt(for language: Language) -> String {
        switch language {
        case .japanese:
            "あなた自身の文章を、末尾の直後から書き進めてください。"
        case .english:
            "Keep writing your own text from right after its end."
        }
    }

    public static func userPrompt(leftContext: String) -> String {
        Self.userPrompt(leftContext: leftContext, language: .detect(in: leftContext))
    }

    static func userPrompt(leftContext: String, language: Language) -> String {
        switch language {
        case .japanese:
            "次の書きかけの文章の続きだけを書いてください。文章そのものは繰り返さないでください。\n\n" + leftContext
        case .english:
            "Write only the continuation of the following draft. Do not repeat the draft itself.\n\n" + leftContext
        }
    }

    /// A continuation does not cross paragraphs. Uses the text up to the first newline (if there is nothing before the newline, uses the whole text)
    public static func firstParagraph(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newline = trimmed.firstIndex(where: \.isNewline) {
            return String(trimmed[..<newline])
        }
        return trimmed
    }

    /// Sentence terminators. A Latin period counts as a terminator only when whitespace or the end of the text follows it (so "e.g." and "3.5" are not split)
    static let sentenceTerminators: Set<Character> = ["。", "！", "？", "!", "?"]

    /// Whether the character at the index ends a sentence
    static func isSentenceTerminator(at index: String.Index, in text: String) -> Bool {
        let character = text[index]
        if Self.sentenceTerminators.contains(character) {
            return true
        }
        let next = text.index(after: index)
        return character == "." && (next == text.endIndex || text[next].isWhitespace)
    }

    /// Splits the text into sentences (each terminator stays with its sentence). A newline also separates sentences
    public static func sentences(in text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if Self.isSentenceTerminator(at: index, in: text) || text[index].isNewline {
                result.append(text[start ..< next])
                start = next
            }
            index = next
        }
        if start < text.endIndex {
            result.append(text[start...])
        }
        return result
    }

    /// A continuation has at most `maximum` sentences. If there are more complete sentences, cuts the text there (an incomplete sentence is kept as is).
    /// The instructions ask for 1 to 2 sentences, so this cut normally does not happen. It is a guard against models that like to write long text
    public static func limitingSentences(_ text: String, maximum: Int = 3) -> String {
        var count = 0
        var index = text.startIndex
        while index < text.endIndex {
            var next = text.index(after: index)
            if Self.isSentenceTerminator(at: index, in: text) {
                count += 1
                if count == maximum {
                    // If a closing bracket follows, as in 「行く。」, include it in the sentence
                    while next < text.endIndex, Self.closers.contains(text[next]) {
                        next = text.index(after: next)
                    }
                    return String(text[..<next])
                }
            }
            index = next
        }
        return text
    }

    /// Closing brackets and closing quotation marks that come right after the end of a sentence
    private static let closers: Set<Character> = ["」", "』", "）", ")", "\"", "”", "'", "’"]

    /// Drops the last incomplete sentence of output that was cut off at the limit. If there is no complete sentence, returns the text as is. Closing brackets and closing quotation marks stay with their sentence
    public static func droppingIncompleteLastSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lastEnd: String.Index?
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            if Self.isSentenceTerminator(at: index, in: trimmed) {
                var end = trimmed.index(after: index)
                while end < trimmed.endIndex, Self.closers.contains(trimmed[end]) {
                    end = trimmed.index(after: end)
                }
                lastEnd = end
            }
            index = trimmed.index(after: index)
        }
        guard let lastEnd, lastEnd < trimmed.endIndex else {
            return trimmed
        }
        return String(trimmed[..<lastEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The number of script characters (counted with `Language.isScriptCharacter`) in the longest part shared by the two texts
    public static func longestCommonSubstringWeight(_ text: String, _ other: String, language: Language) -> Int {
        Self.longestCommonSubstring(text, other, language: language).weight
    }

    /// The longest part shared by the two texts (the one with the most script characters), and its number of script characters
    public static func longestCommonSubstring(_ text: String, _ other: String, language: Language) -> (text: String, weight: Int) {
        let a = Array(text)
        let b = Array(other)
        guard !a.isEmpty, !b.isEmpty else {
            return ("", 0)
        }
        // weightPrefix[i] is the number of script characters in a[0 ..< i]
        var weightPrefix = [0]
        weightPrefix.reserveCapacity(a.count + 1)
        for character in a {
            weightPrefix.append(weightPrefix[weightPrefix.count - 1] + (language.isScriptCharacter(character) ? 1 : 0))
        }
        var best = 0
        var bestRange = 0 ..< 0
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1 ... a.count {
            for j in 1 ... b.count {
                if a[i - 1] == b[j - 1] {
                    let length = previous[j - 1] + 1
                    current[j] = length
                    let weight = weightPrefix[i] - weightPrefix[i - length]
                    if weight > best {
                        best = weight
                        bestRange = (i - length) ..< i
                    }
                } else {
                    current[j] = 0
                }
            }
            swap(&previous, &current)
        }
        return (String(a[bestRange]), best)
    }

    /// If the context ends with punctuation and the continuation also starts with punctuation (「。。」, 「。、」), drops the punctuation at the start of the continuation.
    /// If the context ends mid-sentence, a continuation that starts with 「、」 is natural, so it is left as is
    public static func trimmingBoundaryPunctuation(_ text: String, after context: String) -> String {
        let punctuation: Set<Character> = ["。", "、", "，", "．", ",", ".", "!", "?", "！", "？", ";", ":", "；", "："]
        guard let last = context.last(where: { !$0.isWhitespace }), punctuation.contains(last) else {
            return text
        }
        var result = Substring(text)
        while let first = result.first, first.isWhitespace || punctuation.contains(first) {
            result = result.dropFirst()
        }
        return result.count == text.count ? text : String(result)
    }

    /// In English, restores the space between words. Post-processing drops leading whitespace, so "We" used to be attached right after "email.", giving "email.We".
    /// Adds one space only when the context ends with a sentence separator, or when the model output started with whitespace (it started a new word). Never adds one inside a word ("em" + "ail")
    public static func restoringWordSpace(_ text: String, raw: String, after context: String) -> String {
        guard Language.detect(in: context) == .english,
              let last = context.last, !last.isWhitespace,
              let first = text.first, first.isLetter || first.isNumber || "\"“‘(".contains(first) else {
            return text
        }
        let separators: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "\"", "”"]
        guard raw.first?.isWhitespace == true || separators.contains(last) else {
            return text
        }
        return " " + text
    }

    /// Phrases that tend to appear when the output talks about the request or the instructions instead of continuing the text (compared in lowercase)
    static func taskPhrases(for language: Language) -> [String] {
        switch language {
        case .japanese:
            [
                "書きかけ", "元の文章", "続きを書", "続きを提案", "続きを執筆", "書き足", "80文字", "1〜2文", "1～2文", "一文か二文",
                "以下がその", "以下が続", "（続き", "(続き",
                // Asking the user to give the text (Gemma 4 tends to reply this way to short drafts)
                "どのような文章", "文章を提示", "文章を入力", "文章をお見せ", "文章をお送り", "文章を教え", "文章をどうぞ", "文章を渡", "文章をお渡し", "文章を完成", "文章をお聞かせ", "文章をお願い",
                "ユーザーの文章", "いただいた文章", "ご指定の文章", "文章自体を", "自然につな", "自然に繋",
                // Restating the request before starting to write (「では、文章の続きから執筆を始めます」 "Now I will start writing the continuation", 「次の文へと進みます」 "I will go on to the next sentence")
                "文章の続き", "文章を続け", "文章を繋げ", "文章をつなげ", "続きから執筆", "続きから記述", "執筆を始め", "執筆を開始", "記述を始め", "記述を開始", "本文へと", "書き進め",
                "次の文へ", "次の文から", "次の文を", "末尾の直後", "ここまでに書いた", "文章の書き手", "文章を書く際", "文章作成", "詳細な文章を作成", "文章執筆", "文章を生成", "文章を求め", "文体と話題", "執筆を続け", "この文章を基に",
                // Phrases that also appear in normal sentences (「指示に従って作業」 "work as instructed", 「ご依頼の通り」 "as you requested", 「文字以内」 "within N characters", 「書き始めた」 "started writing", 「末尾から」 "from the end", etc.) are not listed. They would cause useless retries
                "ご指示の通り", "この指示に従", "与えられた指示", "次の指示", "ご提示いただ", "私はai", "文章を書くことを得意"
            ]
        case .english:
            [
                "your draft", "of the draft", "continuation", "here is the", "here's the", "i'll continue", "i will continue", "continue the text", "continue your", "continue writing", "your text",
                "please provide", "provide the text", "40 words", "two sentences", "one or two sentences",
                "you have written", "written so far", "your own text", "keep writing", "as the author", "i am the author", "from right after", "the text you"
            ]
        }
    }

    /// The texts of the instructions and requests passed to the model. If the output shares a long stretch with them, it is talking about the instructions instead of continuing the text
    static func instructionTexts(for language: Language) -> [String] {
        [
            Self.instructions(for: language),
            Self.completionInstructions(for: language),
            Self.completionUserPrompt(for: language),
            Self.userPrompt(leftContext: "", language: language)
        ]
    }

    /// Whether the output talks about the instructions or the request itself instead of continuing the text
    /// (「書きかけの文章を渡してください」 "Please give me the draft", 「1〜2文、80文字以内で書き足します」 "I will add 1 to 2 sentences within 80 characters", 「[ここに書き足す文章]」 "[text to add here]", etc.).
    /// True if the output contains a phrase about the request, contains placeholder square brackets, or shares 8 or more script characters (20 for English) verbatim with the instruction texts.
    /// English uses a longer threshold because short set phrases (with the, of the, etc.) often overlap with the instructions.
    /// If the context (the draft) itself has the same phrase or square brackets, the user is just writing about that topic, so it does not count
    /// (if 「続きを書く」 appears while the user is writing a description of this feature, the output is not broken)
    public static func talksAboutTheTask(_ text: String, language: Language, context: String = "") -> Bool {
        let lowered = text.lowercased()
        let loweredContext = context.lowercased()
        if Self.taskPhrases(for: language).contains(where: { lowered.contains($0) && !loweredContext.contains($0) }) {
            return true
        }
        if text.contains("[") && text.contains("]") && !(context.contains("[") && context.contains("]")) {
            return true
        }
        let overlap = language == .english ? 20 : 8
        return Self.instructionTexts(for: language).contains { instruction in
            let common = Self.longestCommonSubstring(text, instruction, language: language)
            return common.weight >= overlap && !context.contains(common.text)
        }
    }

    /// Drops the surrounding whitespace, quotation marks, and thinking tags that models tend to add
    public static func clean(_ text: String) -> String {
        var result = text
        // A reasoning model's <think>…</think> (if it is not closed, everything after it is still thinking)
        if let open = result.range(of: "<think>") {
            if let close = result.range(of: "</think>", range: open.upperBound ..< result.endIndex) {
                result.removeSubrange(open.lowerBound ..< close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound ..< result.endIndex)
            }
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("「", "」"), ("“", "”"), ("\"", "\""), ("**", "**")] where result.hasPrefix(open) && result.hasSuffix(close) && result.count >= open.count + close.count {
            result = String(result.dropFirst(open.count).dropLast(close.count))
        }
        // Markdown emphasis marks are not needed in prose
        result = result.replacingOccurrences(of: "**", with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
