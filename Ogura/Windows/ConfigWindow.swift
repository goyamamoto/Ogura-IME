import Cocoa
import Core
import SwiftUI

/// The settings window. Built only from the standard TabView and Form. Items are split into the
/// tabs "変換" (Conversion), "入力" (Input), "辞書" (Dictionary), and "詳細" (Advanced).
struct ConfigWindow: View {
    @ConfigState private var liveConversion = Config.LiveConversion()
    @ConfigState private var zenzaiProfile = Config.ZenzaiProfile()
    @ConfigState private var learning = Config.Learning()

    @ConfigState private var inputStyle = Config.InputStyle()
    @ConfigState private var keyboardLayout = Config.KeyboardLayout()
    @ConfigState private var keyBindingStyle = Config.KeyBindingStyle()
    @ConfigState private var punctuationStyle = Config.PunctuationStyle()
    @ConfigState private var typeBackSlash = Config.TypeBackSlash()
    @ConfigState private var typeHalfSpace = Config.TypeHalfSpace()
    @ConfigState private var typeHalfWidthSymbols = Config.TypeHalfWidthSymbols()
    @ConfigState private var optionDirectFullWidthInput = Config.OptionDirectFullWidthInput()
    @ConfigState private var uppercaseStartsAlphabetInput = Config.UppercaseStartsAlphabetInput()
    @ConfigState private var latinCandidateForNonJapaneseInput = Config.LatinCandidateForNonJapaneseInput()
    @ConfigState private var learnedScriptIdentification = Config.LearnedScriptIdentification()

    @ConfigState private var userDictionary = Config.UserDictionary()
    @ConfigState private var systemUserDictionary = Config.SystemUserDictionary()

    @ConfigState private var inferenceLimit = Config.ZenzaiInferenceLimit()
    @ConfigState private var zenzaiModel = Config.ZenzaiModel()
    @ConfigState private var zenzaiPersonalizationLevel = Config.ZenzaiPersonalizationLevel()
    @ConfigState private var debugPredictiveTyping = Config.DebugPredictiveTyping()
    @ConfigState private var continuation = Config.Continuation()
    @ConfigState private var continuationLocalModelName = Config.ContinuationLocalModelName()
    @State private var installedLocalModels: [String] = []
    @ConfigState private var continuationKeyShiftTab = Config.ContinuationKeyShiftTab()
    @ConfigState private var continuationKeyControlSlash = Config.ContinuationKeyControlSlash()
    @ConfigState private var continuationKeyF19 = Config.ContinuationKeyF19()

    @State private var showingRomajiTableEditor = false
    @State private var showingLearningResetConfirmation = false
    @State private var learningResetMessage: String?
    @State private var systemUserDictionaryMessage: String?

    private var appDelegate: AppDelegate? {
        NSApplication.shared.delegate as? AppDelegate
    }

    var body: some View {
        TabView {
            self.conversionTab
                .tabItem { Label("変換", systemImage: "brain") }
            self.inputTab
                .tabItem { Label("入力", systemImage: "keyboard") }
            self.dictionaryTab
                .tabItem { Label("辞書", systemImage: "book.closed") }
            self.advancedTab
                .tabItem { Label("詳細", systemImage: "gearshape.2") }
        }
        .padding(12)
        .frame(width: 560, height: 480)
        .sheet(isPresented: self.$showingRomajiTableEditor) {
            RomajiTableEditorWindow(base: CustomInputTableStore.loadTable()) { exported in
                do {
                    _ = try CustomInputTableStore.save(exported: exported)
                    CustomInputTableStore.registerIfExists()
                } catch {
                    print("Failed to save custom input table: \(error)")
                }
            }
        }
    }

    // MARK: - Conversion

    private var conversionTab: some View {
        Form {
            Section {
                Toggle("ライブ変換", isOn: self.$liveConversion)
                TextField("変換プロフィール", text: self.$zenzaiProfile, prompt: Text("例：田中太郎/高校生"))
                Text("名前や仕事、趣味を書いておくと、それに合った変換が優先されます。端末の外には送られません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("履歴学習", selection: self.$learning) {
                    Text("学習する").tag(Config.Learning.Value.inputAndOutput)
                    Text("学習を停止").tag(Config.Learning.Value.onlyOutput)
                    Text("学習を無視").tag(Config.Learning.Value.nothing)
                }
                LabeledContent("履歴学習データ") {
                    HStack {
                        if let learningResetMessage {
                            Text(learningResetMessage).foregroundStyle(.secondary)
                        }
                        Button("リセット") {
                            self.showingLearningResetConfirmation = true
                        }
                        .confirmationDialog("履歴学習データをリセットしますか？", isPresented: self.$showingLearningResetConfirmation, titleVisibility: .visible) {
                            Button("リセット", role: .destructive) {
                                self.resetLearningData()
                            }
                            Button("キャンセル", role: .cancel) {}
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Input

    private var inputTab: some View {
        Form {
            Section {
                Picker("入力方式", selection: self.$inputStyle) {
                    Text("ローマ字").tag(Config.InputStyle.Value.default)
                    Text("かな入力（JIS）").tag(Config.InputStyle.Value.defaultKanaJIS)
                    Text("かな入力（US）").tag(Config.InputStyle.Value.defaultKanaUS)
                    Text("AZIK").tag(Config.InputStyle.Value.defaultAZIK)
                    Text("カスタム").tag(Config.InputStyle.Value.custom)
                }
                if self.inputStyle.value == .custom {
                    LabeledContent("カスタム入力テーブル") {
                        Button("編集") {
                            self.showingRomajiTableEditor = true
                        }
                    }
                }
                Picker("キーボード配列", selection: self.$keyboardLayout) {
                    Text("QWERTY").tag(Config.KeyboardLayout.Value.qwerty)
                    Text("Australian").tag(Config.KeyboardLayout.Value.australian)
                    Text("British").tag(Config.KeyboardLayout.Value.british)
                    Text("Colemak").tag(Config.KeyboardLayout.Value.colemak)
                    Text("Dvorak").tag(Config.KeyboardLayout.Value.dvorak)
                    Text("Dvorak - QWERTY ⌘").tag(Config.KeyboardLayout.Value.dvorakQwertyCommand)
                }
                Picker("変換のキー操作", selection: self.$keyBindingStyle) {
                    Text("MS-IME 互換").tag(Config.KeyBindingStyle.Value.msIME)
                    Text("macOS 標準").tag(Config.KeyBindingStyle.Value.macOS)
                }
                Picker("句読点", selection: self.$punctuationStyle) {
                    Text("、と。").tag(Config.PunctuationStyle.Value.kutenAndToten)
                    Text("、と．").tag(Config.PunctuationStyle.Value.periodAndToten)
                    Text("，と。").tag(Config.PunctuationStyle.Value.kutenAndComma)
                    Text("，と．").tag(Config.PunctuationStyle.Value.periodAndComma)
                }
            }
            Section {
                Toggle("先頭を大文字で打ったら、確定するまで英字入力にする（ライブ変換がオフのときは常にオン）", isOn: self.$uppercaseStartsAlphabetInput)
                Toggle("日本語らしくない入力には、打った英字のままの候補も出す", isOn: self.$latinCandidateForNonJapaneseInput)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("英単語とローマ字の見分けに学習モデルを使う", isOn: self.$learnedScriptIdentification)
                    Text("入力の中の英単語（iPhone、pig など）を、規則ではなく学習したモデルで見分けます。オフにすると規則で見分けます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("スペースは常に半角を入力", isOn: self.$typeHalfSpace)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("記号は常に半角を入力（% + = など）", isOn: self.$typeHalfWidthSymbols)
                    Text("句読点、長音のー、中黒の・、かぎかっこ「」『』は全角のままです。Option キーと一緒に打つ ［ ］ ｛ ｝ ／ も半角になります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("円記号の代わりにバックスラッシュを入力", isOn: self.$typeBackSlash)
                Toggle("Option キーで直接全角英数を入力", isOn: self.$optionDirectFullWidthInput)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Dictionary

    private var dictionaryTab: some View {
        Form {
            Section {
                LabeledContent("ユーザ辞書") {
                    HStack {
                        Text("\(self.userDictionary.value.items.count)件")
                        Button("編集") {
                            self.appDelegate?.openUserDictionaryEditorWindow()
                        }
                    }
                }
            }
            Section {
                LabeledContent("macOS のユーザ辞書") {
                    HStack {
                        Text(self.systemUserDictionaryStatus)
                        Button("読み込む") {
                            self.importSystemUserDictionary()
                        }
                        Button("消去") {
                            self.systemUserDictionary.value.lastUpdate = nil
                            self.systemUserDictionary.value.items = []
                            self.systemUserDictionaryMessage = nil
                            self.appDelegate?.exportUserDictionaryAndReloadConverter()
                        }
                    }
                }
                Text("「設定 > キーボード > ユーザ辞書」の内容を取り込みます。取り込んだ内容はこの IME の中でだけ使います。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Whether the app has genmai's weights (see Tools/build_genmai_gguf.sh)
    private var hasGenmai: Bool {
        Bundle.main.url(forResource: "ggml-model-Q5_K_M", withExtension: "gguf", subdirectory: "genmai") != nil
    }

    private var systemUserDictionaryStatus: String {
        if let systemUserDictionaryMessage {
            return systemUserDictionaryMessage
        }
        if self.systemUserDictionary.value.lastUpdate != nil {
            return "\(self.systemUserDictionary.value.items.count)件"
        }
        return "未読み込み"
    }

    // MARK: - Advanced

    private var advancedTab: some View {
        Form {
            Section {
                Picker("Zenzai のモデル", selection: self.$zenzaiModel) {
                    Text("zenz-v3.2-small").tag(Config.ZenzaiModel.Value.zenz)
                    Text("genmai").tag(Config.ZenzaiModel.Value.genmai)
                }
                .disabled(!self.hasGenmai)
                Text(self.hasGenmai
                        ? "genmai（subdiox 氏、CC BY-SA 4.0）は zenz-v2.5-medium をもとに学習したモデルで、zenz-v3.2-small の約 3 倍の大きさです。変換の精度が上がる代わりに、1 打鍵あたりの時間とメモリが増えます。英単語とローマ字の見分けには、どちらを選んでも zenz-v3.2-small を使います。"
                        : "このビルドには genmai が入っていないため、zenz-v3.2-small を使います。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("Zenzai の推論上限: \(self.$inferenceLimit.wrappedValue)", value: self.$inferenceLimit, in: 1 ... 50)
                Text("小さくすると入力中のもたつきが減り、大きくすると変換の精度が上がります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("パーソナライズ（Tuner 連携）", selection: self.$zenzaiPersonalizationLevel) {
                    Text("オフ").tag(Config.ZenzaiPersonalizationLevel.Value.off)
                    Text("弱め").tag(Config.ZenzaiPersonalizationLevel.Value.soft)
                    Text("普通").tag(Config.ZenzaiPersonalizationLevel.Value.normal)
                    Text("強め").tag(Config.ZenzaiPersonalizationLevel.Value.hard)
                }
                Toggle("予測入力（開発中）", isOn: self.$debugPredictiveTyping)
            }
            Section {
                Picker("続きを書く", selection: self.$continuation) {
                    Text("オフ").tag(Config.Continuation.Value.off)
                    Text("Apple の端末内モデル").tag(Config.Continuation.Value.foundationModels)
                    Text("Mac 内の MLX モデル").tag(Config.Continuation.Value.localModel)
                }
                Text("カーソルの前の文章（最大 \(InputSession.continuationContextLength) 文字）を Mac 内のモデルに渡して、続きを提案します。Tab または Enter で確定し、Esc で破棄します。通信は行いません。Apple の端末内モデルは macOS 26 以降で Apple Intelligence が有効なときに使えます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if self.$continuation.wrappedValue == .localModel {
                    Picker("モデル", selection: self.$continuationLocalModelName) {
                        if self.installedLocalModels.isEmpty {
                            Text("（モデルがありません）").tag("")
                        } else if !self.installedLocalModels.contains(self.$continuationLocalModelName.wrappedValue) {
                            Text("（選んでください）").tag(self.$continuationLocalModelName.wrappedValue)
                        }
                        ForEach(self.installedLocalModels, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .onAppear {
                        self.reloadInstalledLocalModels()
                    }
                    HStack {
                        Button("モデルのフォルダを開く") {
                            self.openLocalModelsDirectoryInFinder()
                        }
                        Button("一覧を更新") {
                            self.reloadInstalledLocalModels()
                        }
                    }
                    Text("Apple Silicon 専用です。MLX 形式のモデル（config.json、safetensors、tokenizer.json）をフォルダごと置いてください。モデルは Ogura のソースにある Tools/download_continuation_model.sh で入手できます（例: mlx-community/LFM2.5-1.2B-JP-202606-OptiQ-4bit）。使用後しばらくすると、自動でメモリを解放します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Shift+Tab で続きを書く", isOn: self.$continuationKeyShiftTab)
                Toggle("Ctrl+/ で続きを書く", isOn: self.$continuationKeyControlSlash)
                Toggle("F19 で続きを書く", isOn: self.$continuationKeyF19)
                Text("F19 は一般的なキーボードにはないため、キーボードのファームウェアや Karabiner-Elements で好きなキーに割り当ててください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("アプリデータ") {
                    Button("Finder で開く") {
                        self.openDataDirectoryInFinder()
                    }
                }
                LabeledContent("バージョン") {
                    Text(PackageMetadata.gitTag ?? PackageMetadata.gitCommit ?? "不明")
                        .monospaced()
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Actions

    private func resetLearningData() {
        guard let appDelegate else {
            self.learningResetMessage = "リセットに失敗しました"
            return
        }
        ConversionLock.withLock {
            appDelegate.kanaKanjiConverter.resetMemory()
        }
        self.learningResetMessage = "リセットしました"
        Task {
            try? await Task.sleep(for: .seconds(10))
            self.learningResetMessage = nil
        }
    }

    private func importSystemUserDictionary() {
        do {
            let entries = try SystemUserDictionaryHelper.fetchEntries()
            self.systemUserDictionary.value.items = entries.map { .init(word: $0.phrase, reading: $0.shortcut) }
            self.systemUserDictionary.value.lastUpdate = .now
            self.systemUserDictionaryMessage = nil
            self.appDelegate?.exportUserDictionaryAndReloadConverter()
        } catch {
            self.systemUserDictionaryMessage = "読み込みエラー: \(error.localizedDescription)"
        }
    }

    private func openDataDirectoryInFinder() {
        let url = AppContainer.applicationSupportDirectoryURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openLocalModelsDirectoryInFinder() {
        let url = LocalContinuationModels.directoryURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func reloadInstalledLocalModels() {
        self.installedLocalModels = LocalContinuationModels.installedModelNames()
        if self.$continuationLocalModelName.wrappedValue.isEmpty, let first = self.installedLocalModels.first {
            self.$continuationLocalModelName.wrappedValue = first
        }
    }
}

#Preview {
    ConfigWindow()
}
