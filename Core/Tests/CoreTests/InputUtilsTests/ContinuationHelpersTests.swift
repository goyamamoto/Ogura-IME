import Core
import Foundation
import Testing

@Suite("続きを書くの補助")
struct ContinuationHelpersTests {
    @Test("モデル置き場からは config.json のあるフォルダだけを名前順に拾う")
    func installedModelNamesListsModelDirectories() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ogura-models-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        for name in ["b-model", "a-model"] {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        }
        try fileManager.createDirectory(at: root.appendingPathComponent("not-a-model"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("stray.safetensors"))
        try fileManager.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent(".hidden/config.json"))

        #expect(LocalContinuationModels.installedModelNames(in: root, fileManager: fileManager) == ["a-model", "b-model"])
        #expect(LocalContinuationModels.installedModelNames(in: root.appendingPathComponent("missing"), fileManager: fileManager).isEmpty)
    }

    @Test("モデル置き場はアプリ自身のコンテナの中")
    func modelsDirectoryIsInsideApplicationSupport() {
        let directory = LocalContinuationModels.directoryURL()
        #expect(directory.path.hasPrefix(AppContainer.applicationSupportDirectoryURL().path))
        #expect(directory.lastPathComponent == "models")
        #expect(LocalContinuationModels.modelDirectoryURL(named: "x").lastPathComponent == "x")
    }

    @Test("文字種から言語を判定する")
    func languageDetection() {
        #expect(ContinuationPrompt.Language.detect(in: "今日は晴れです。") == .japanese)
        #expect(ContinuationPrompt.Language.detect(in: "Thank you for your time yesterday,") == .english)
        #expect(ContinuationPrompt.Language.detect(in: "今日は MacBook を買った。") == .japanese)
        #expect(ContinuationPrompt.Language.detect(in: "Apple の Foundation Models と mlx-swift-lm の両方を試した。Qwen3.5-2B と LFM2.5-1.2B-JP では") == .japanese, "ラテン文字の語が多くても、かながあれば日本語")
        #expect(ContinuationPrompt.Language.detect(in: "Tools/download_continuation_model.sh mlx-community/Qwen3.5-2B-4bit を実行してから、設定で Mac 内の MLX モデルを選ぶ。") == .japanese)
        #expect(ContinuationPrompt.Language.detect(in: "See https://example.com/path for the details of 東京 office") == .english)
        #expect(ContinuationPrompt.Language.detect(in: "") == .japanese)
        #expect(ContinuationPrompt.Language.japanese.weight(of: "LFM2.5-1.2B-JP のトレーニング") == 7, "本文の文字はかなと漢字だけ")
        #expect(ContinuationPrompt.Language.english.weight(of: "Qwen3.5-2B is fast.") == 11)
        #expect(ContinuationPrompt.instructions(for: .english).contains("English"))
        #expect(ContinuationPrompt.userPrompt(leftContext: "Dear Mr. Smith,").hasPrefix("Write only"))
    }

    @Test("英語のピリオドは、空白か末尾が続くときだけ文の区切り")
    func limitingEnglishSentences() {
        #expect(ContinuationPrompt.limitingSentences("One. Two. Three. Four.") == "One. Two. Three.")
        #expect(ContinuationPrompt.limitingSentences("See version 3.5 today. Next one. More", maximum: 2) == "See version 3.5 today. Next one.")
        #expect(ContinuationPrompt.limitingSentences("Only one sentence here") == "Only one sentence here")
        #expect(ContinuationPrompt.limitingSentences("「行く。」「行かない。」「行く。」と言い合った。") == "「行く。」「行かない。」「行く。」", "閉じ括弧は文に含める")
        #expect(ContinuationPrompt.sentences(in: "Qwen3.5 は速い。LFM2.5 も。\n次") == ["Qwen3.5 は速い。", "LFM2.5 も。", "\n", "次"])
        #expect(ContinuationPrompt.sentences(in: "e.g. this. Next") == ["e.g.", " this.", " Next"])
    }

    @Test("続きは 3 文まで。途中の文は残す")
    func limitingSentences() {
        #expect(ContinuationPrompt.limitingSentences("一。二。三。四。") == "一。二。三。")
        #expect(ContinuationPrompt.limitingSentences("一。二") == "一。二")
        #expect(ContinuationPrompt.limitingSentences("一！二？三！四") == "一！二？三！")
        #expect(ContinuationPrompt.limitingSentences("一。二。三", maximum: 2) == "一。二。")
        #expect(ContinuationPrompt.limitingSentences("ひとつだけ") == "ひとつだけ")
        #expect(ContinuationPrompt.firstParagraph("一行目。\n二行目。") == "一行目。")
        #expect(ContinuationPrompt.firstParagraph("\n本文") == "本文")
    }

    @Test("上限で切れた出力は、最後の完結していない文を落とす")
    func droppingIncompleteLastSentence() {
        typealias P = ContinuationPrompt
        #expect(P.droppingIncompleteLastSentence("一。二") == "一。")
        #expect(P.droppingIncompleteLastSentence("一。二。") == "一。二。")
        #expect(P.droppingIncompleteLastSentence("「一。二。」三") == "「一。二。」", "閉じ括弧は文に含める")
        #expect(P.droppingIncompleteLastSentence("途中") == "途中", "完結した文がなければそのまま")
        #expect(P.droppingIncompleteLastSentence("One. Two") == "One.")
        #expect(P.droppingIncompleteLastSentence("  一！二 \n") == "一！")
        #expect(P.droppingIncompleteLastSentence("").isEmpty)
    }

    @Test("文脈が句読点で終わっていれば、続きの先頭の句読点は落とす")
    func trimmingBoundaryPunctuation() {
        typealias P = ContinuationPrompt
        #expect(P.trimmingBoundaryPunctuation("。明日は晴れる。", after: "今日は雨だった。") == "明日は晴れる。")
        #expect(P.trimmingBoundaryPunctuation("、明日は晴れる。", after: "今日は雨だった。") == "明日は晴れる。")
        #expect(P.trimmingBoundaryPunctuation("。。 明日は晴れる。", after: "今日は雨だった。\n") == "明日は晴れる。", "末尾の改行は無視し、重なった句読点も空白も落とす")
        #expect(P.trimmingBoundaryPunctuation("、天気が良い。", after: "今日は") == "、天気が良い。", "文の途中なら読点で始まってよい")
        #expect(P.trimmingBoundaryPunctuation("明日は晴れる。", after: "今日は雨だった。") == "明日は晴れる。")
        #expect(P.trimmingBoundaryPunctuation(". We agreed.", after: "We met.") == "We agreed.")
        #expect(P.trimmingBoundaryPunctuation("", after: "今日は雨だった。").isEmpty)
    }

    @Test("文脈そのものがその言い回しを使っていれば、指示について語っているとは見なさない")
    func talksAboutTheTaskRespectsContext() {
        typealias P = ContinuationPrompt
        let readme = "Ogura には続きを書く機能があります。Shift+Tab を押すと、書きかけの文章の続きを薄く表示します。"
        #expect(!P.talksAboutTheTask("この機能は、書きかけの文章の続きをその場で提案します。", language: .japanese, context: readme), "機能の説明を書いている")
        #expect(P.talksAboutTheTask("この機能は、書きかけの文章の続きをその場で提案します。", language: .japanese), "文脈がなければ従来どおり")
        #expect(P.talksAboutTheTask("どうぞ書きかけの文章をお知らせください。80文字以内で書き足します。", language: .japanese, context: readme), "文脈にない言い回し（80文字）は数える")
        #expect(!P.talksAboutTheTask("詳しくは [設定](settings.md) を参照してください。", language: .japanese, context: "手順は [インストール](install.md) に書いてあります。"), "Markdown のリンクがある文書なら角括弧は数えない")
        #expect(P.talksAboutTheTask("[ここに続き] を書きます。", language: .japanese, context: "今日は雨だった。"))
        #expect(!P.talksAboutTheTask("文体（敬体か常体か）と話題を合わせるのが大切です。", language: .japanese, context: "指示には「文体（敬体か常体か）と話題を合わせる」と書いてある。"), "指示文の丸写しも、文脈にある言い回しなら許す")
    }

    @Test("指示や依頼について語る出力を見分ける")
    func talksAboutTheTask() {
        typealias P = ContinuationPrompt
        #expect(P.talksAboutTheTask("どうぞ書きかけの文章をお知らせください。", language: .japanese))
        #expect(P.talksAboutTheTask("こちらは、元の文章の流れを切らずに書き足した例です。", language: .japanese))
        #expect(P.talksAboutTheTask("ない。どこで生れたかとんと見当がつかぬ。（1文：80文字）", language: .japanese))
        #expect(P.talksAboutTheTask("[ここに書き足す文章] と掲げました。", language: .japanese), "穴埋めの角括弧")
        #expect(P.talksAboutTheTask("文体や話題は元の文章に合わせ、1〜2文、80文字以内で続きを書き足します。", language: .japanese))
        #expect(P.talksAboutTheTask("この文章の続きを書きましょう。", language: .japanese))
        #expect(P.talksAboutTheTask("前置き、説明、引用符、箇条書きの記号を付けずに書きます。", language: .japanese), "指示文の丸写し")
        #expect(P.talksAboutTheTask("どうぞ文章を入力してください。", language: .japanese), "文章を求める返事")
        #expect(P.talksAboutTheTask("この文章を提示してください。", language: .japanese))
        #expect(P.talksAboutTheTask("以下が続きます。", language: .japanese))
        #expect(P.talksAboutTheTask("さらに詳細を付け加えると、例えば...（続きはユーザーの文章に続く）", language: .japanese))
        #expect(P.talksAboutTheTask("この部分から文章を自然に繋げていきましょう。", language: .japanese))
        #expect(P.talksAboutTheTask("指示に従い、文章の続きから記述を始めます。", language: .japanese), "依頼の復唱")
        #expect(P.talksAboutTheTask("では、引き続き本文へと進みます。どうぞよろしくお願いいたします。", language: .japanese))
        #expect(P.talksAboutTheTask("ご提示いただいた文章の続きから執筆を開始します。", language: .japanese))
        #expect(P.talksAboutTheTask("それでは、次の文へと進めていきますね。", language: .japanese), "今の指示の復唱")
        #expect(P.talksAboutTheTask("同じ文体と話題を維持し、読者が混乱しないようにすることが求められます。", language: .japanese))
        #expect(P.talksAboutTheTask("ここまでの文章を読み、末尾の直後に書き進めます。", language: .japanese))
        #expect(P.talksAboutTheTask("私は日本語の文章の書き手です。ご依頼に応じて、文章を自然に書き進めます。", language: .japanese))
        #expect(P.talksAboutTheTask("加える分は短く、文の途中で終わらないようにします。", language: .japanese), "指示文の丸写し（8 文字以上の重なり）")
        #expect(P.talksAboutTheTask("この文章を基に、次の内容を記述していきます。", language: .japanese))
        #expect(P.talksAboutTheTask("次に進むべきは、特定のトピックに関する詳細な文章を作成することです。", language: .japanese))
        #expect(P.talksAboutTheTask("私はAIです。どのように続けましょうか。", language: .japanese), "大文字でも引っかける")
        #expect(P.talksAboutTheTask("私は日本語の文章を書くことを得意としています。", language: .japanese))
        #expect(P.talksAboutTheTask("この指示に従い、これから書き始める文章は、これまでの応答の続きとなります。", language: .japanese))
        // Do not flag phrases that appear in ordinary sentences (a retry would be wasted).
        for text in [
            "報告書を作成して、金曜日までに送付します。", "案内の文章を作成しましたので、ご確認いただけますと幸いです。",
            "測定の結果は、docs/latency.md に記述していきます。", "三日坊主にならないように、明日も続けて書きたい。", "ログは同じファイルに続けて書き込みます。",
            "ご依頼の通り、見積書を添付いたします。", "担当者の指示に従って作業を進めました。", "パスワードは 20 文字以内で設定してください。",
            "以下は設定ファイルの例です。", "久しぶりに小説を書き始めた。", "弊社は Web アプリケーションの開発を得意としています。", "ログは末尾から順に確認してください。"
        ] {
            #expect(!P.talksAboutTheTask(text, language: .japanese), Comment(rawValue: text))
        }
        for text in [
            "We will continue the discussion next week.", "I have attached the draft agenda for your review.",
            "The author of the report will join the call.", "Thank you for the prompt reply."
        ] {
            #expect(!P.talksAboutTheTask(text, language: .english), Comment(rawValue: text))
        }
        #expect(!P.talksAboutTheTask("ご依頼の件、承知いたしました。明日までにお送りします。", language: .japanese), "業務の文の「依頼」「承知」は許す")
        #expect(P.talksAboutTheTask("Here is the text you have written so far, continued:", language: .english))
        #expect(!P.talksAboutTheTask("引き続き調査を続けますので、結果は来週ご報告します。", language: .japanese), "「続けます」だけでは引っかけない")
        #expect(!P.talksAboutTheTask("メールの本文に日時を記載しました。以下のように変更しています。", language: .japanese), "「本文」「以下のように」だけでは引っかけない")
        #expect(!P.talksAboutTheTask("この件について、ご指示いただけますと幸いです。", language: .japanese), "業務の文の「指示」は許す")
        #expect(!P.talksAboutTheTask("その後、雨が続きますので、傘をお持ちください。", language: .japanese), "「続きます」だけでは引っかけない")
        #expect(!P.talksAboutTheTask("以下の通り、来週の金曜日までにご返信いただけますと幸いです。", language: .japanese))
        #expect(!P.talksAboutTheTask("ユーザーがキーを入れるたびに、変換候補を計算して表示します。", language: .japanese))
        #expect(!P.talksAboutTheTask("部屋を明るく照らしてくれた。", language: .japanese))
        #expect(!P.talksAboutTheTask("", language: .japanese))
        #expect(P.talksAboutTheTask("Here is the continuation of your draft:", language: .english))
        #expect(P.talksAboutTheTask("I'll continue the text in one or two sentences.", language: .english))
        #expect(!P.talksAboutTheTask("the potential opportunities for growth and expansion.", language: .english))
        #expect(!P.talksAboutTheTask("it looks like we'll have to make some cuts, but the overall efficiency will improve with these adjustments.", language: .english), "with the のような定型句は指示文と重なっても許す")
        #expect(!P.talksAboutTheTask("gave an overview of the current financial situation.", language: .english))
    }

    @Test("チャット形式はテンプレートの文面で決め、文面に区切りがなければ語彙で決める")
    func chatFormatDetection() {
        let gemma4Template = "{{ bos_token }}<|turn>system\n{{ messages[0]['content'] }}<turn|>\n<|turn>model\n"
        // Gemma 4's vocabulary has both <|im_start|> and <think>, but the template text takes priority.
        #expect(ChatFormat.detect(templateText: gemma4Template) { ["<|im_start|>", "<think>", "<|turn>"].contains($0) } == .gemma4)
        #expect(ChatFormat.detect(templateText: "{% for m in messages %}<|im_start|>{{ m.role }}\n{{ m.content }}<|im_end|>\n{% endfor %}<think>") { _ in false } == .chatML(think: true))
        #expect(ChatFormat.detect(templateText: nil) { $0 == "<|im_start|>" } == .chatML(think: false))
        #expect(ChatFormat.detect(templateText: "{{ bos_token }}{% for m in messages %}<start_of_turn>{{ m.role }}\n{{ m.content }}<end_of_turn>\n{% endfor %}") { _ in true } == .gemma)
        #expect(ChatFormat.detect(templateText: nil) { $0 == "<|start_header_id|>" } == .llama3)
        #expect(ChatFormat.detect(templateText: "{{ messages[0]['content'] }}") { _ in false } == .plain, "区切りが書かれていないテンプレートなら語彙で決める")
        #expect(ChatFormat.gemma4.prompt(instructions: "指示", request: "依頼") == "<bos><|turn>system\n指示<turn|>\n<|turn>user\n依頼<turn|>\n<|turn>model\n")
        #expect(ChatFormat.gemma.prompt(instructions: "i", request: "r") == "<bos><start_of_turn>user\ni\n\nr<end_of_turn>\n<start_of_turn>model\n")
        #expect(ChatFormat.chatML(think: true).prompt(instructions: "i", request: "r").hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
        #expect(ChatFormat.chatML(think: false).prompt(instructions: "i", request: "r").hasSuffix("<|im_start|>assistant\n"))
        #expect(ChatFormat.llama3.prompt(instructions: "i", request: "r").hasPrefix("<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\ni<|eot_id|>"))
        #expect(ChatFormat.plain.prompt(instructions: "i", request: "r") == "i\n\nr\n\n")
        #expect(ChatFormat.endOfTurnTokens.contains("<turn|>") && ChatFormat.endOfTurnTokens.contains("<|im_end|>"))
    }

    @Test("出力の掃除: 空白・引用符・思考タグを落とす")
    func promptCleanStripsNoise() {
        #expect(ContinuationPrompt.clean("  明日は晴れる。\n") == "明日は晴れる。")
        #expect(ContinuationPrompt.clean("「明日は晴れる。」") == "明日は晴れる。")
        #expect(ContinuationPrompt.clean("<think>考え中</think>明日は晴れる。") == "明日は晴れる。")
        #expect(ContinuationPrompt.clean("<think>まだ考え中").isEmpty)
        #expect(ContinuationPrompt.clean("**散歩に出かけよう。**") == "散歩に出かけよう。")
        #expect(ContinuationPrompt.clean("今日は**とても**晴れ。") == "今日はとても晴れ。")
        #expect(ContinuationPrompt.userPrompt(leftContext: "今日は").hasSuffix("今日は"))
    }

    @Test("出力の掃除: チャット形式の制御トークンを落とし、ほかの角括弧は残す")
    func promptCleanStripsControlTokens() {
        #expect(ContinuationPrompt.clean("<channel|>今日は山本さんに会います。") == "今日は山本さんに会います。")
        #expect(ContinuationPrompt.clean("<|channel>考え中<channel|>明日は晴れる。") == "明日は晴れる。")
        #expect(ContinuationPrompt.clean("<|channel>まだ考え中").isEmpty)
        #expect(ContinuationPrompt.clean("明日は晴れる。<turn|>") == "明日は晴れる。")
        #expect(ContinuationPrompt.clean("a < b で、b > c です。") == "a < b で、b > c です。")
        #expect(ContinuationPrompt.clean("<div>タグ</div>は残す") == "<div>タグ</div>は残す")
    }

    @Test("制御トークンの形: 括弧の内側の縁に縦棒がある語か、決まった印")
    func controlTokenShape() {
        for token in ["<|turn>", "<turn|>", "<|channel>", "<channel|>", "<|im_start|>", "<|im_end|>", "<|eot_id|>", "<think>", "</think>", "<start_of_turn>", "<end_of_turn>", "<eos>"] {
            #expect(ContinuationPrompt.isControlToken(token), "\(token)")
        }
        for token in ["<unused0>", "<div>", "<a|b>", "<|>", "||", "今日", "<|空 白|>", "<" + String(repeating: "x", count: 50) + "|>"] {
            #expect(!ContinuationPrompt.isControlToken(token), "\(token)")
        }
    }

    @MainActor
    @Test("制御トークンの形や記号だけの出力は壊れている。句点だけや英字の語は許す")
    func controlTokenLookalikesAreBroken() {
        let context = "酒は酒です。\n仕事します\nごとします。\n\n導きます。"
        #expect(InputSession.brokenContinuationReason("<|\"|>}", after: context) == "制御トークンの形")
        #expect(InputSession.brokenContinuationReason("））", after: context) == "記号だけ")
        #expect(InputSession.brokenContinuationReason("。", after: "変換のやり直しが効くと随分と楽になります") == nil)
        #expect(InputSession.brokenContinuationReason("Windows", after: "使うのは") == nil)
        #expect(InputSession.brokenContinuationReason("これで完了です。", after: context) == nil)
    }

    @MainActor
    @Test("短い語尾は、文脈のどこかにあっても言い直しとはしない")
    func shortEndingIsNotARepetition() {
        let context = "公園で講演会をするのはちょっと恥ずかしいです。\n\n講演会を公園でするのはちょっと恥ずかしい"
        #expect(InputSession.removingRepeatedPrefix(from: "です。", after: context) == "です。")
        #expect(InputSession.removingRepeatedPrefix(from: "恥ずかしいです。", after: context) == "です。", "文脈の末尾との重なりは落とす")
        #expect(InputSession.removingRepeatedPrefix(from: "公園で講演会をするのはちょっと恥ずかしいです。", after: context).isEmpty, "一文の丸写しは落とす")
        #expect(InputSession.removingRepeatedPrefix(from: "恥ずかしい", after: context).isEmpty, "末尾をなぞっている途中は空")
    }
}
