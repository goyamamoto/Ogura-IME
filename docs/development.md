# 開発

## 必要なもの

- macOS 15 以降、Apple Silicon の Mac、Xcode 26.1 以降（MLX が Swift 6.3 のツールチェーンを要求します）
- Xcode の Metal ツールチェーン（MLX の Metal シェーダを組むのに必要。初回だけ約 700 MB のダウンロード）
- Git LFS（必須。モデル重みの submodule が LFS を使っています）
- SwiftLint

```bash
brew install git-lfs swiftlint
git lfs install
xcodebuild -downloadComponent MetalToolchain
```

MLX を含むため、初回のビルドには数分かかります。`swift build` / `swift test` は Core 本体とそのテストだけに使い、アプリは xcodebuild で組みます（SwiftPM のコマンドラインは Metal シェーダを組めません）。

## クローン

submodule に Zenzai の gguf 重みと言語モデル（`.marisa`）が含まれるため、`--recursive` が必要です。

```bash
git clone --recursive https://github.com/goyamamoto/Ogura-IME.git
cd Ogura-IME
```

かな漢字変換エンジン（AzooKeyKanaKanjiConverter）は、Zenzai が読みに与える確率を返す関数などを加えたフォーク（`goyamamoto/AzooKeyKanaKanjiConverter`）を使います。

既にクローン済みで submodule や LFS が揃っていない場合:

```bash
git submodule update --init
git -C Ogura/Resources/gguf lfs pull
git -C Ogura/Resources/base_n5_lm lfs pull
```

重みが取得できているかはサイズで確認できます。数十 MB 以上あれば実体、134 バイト程度なら LFS ポインタのままです。

```bash
ls -lh Ogura/Resources/gguf/ggml-model-Q5_K_M.gguf
```

Zenzai の既定のモデル genmai は、ビルドの前に GGUF を `Ogura/Resources/genmai/` に置きます（リポジトリには入っていません）。次のスクリプトが、公開リポジトリの Release `genmai-0.1.1-gguf` から変換済みの GGUF を取得し、SHA-256 を確かめます。`--convert` を付けると、配布元（genmai-310M の v1.0.0。重みは v0.1.1 と同一）の重みをダウンロードして同じ GGUF を作り直せます（python3.12 と cmake が必要で、作業に 5 GB ほど使う）。置かずにビルドしたアプリは zenz-v3.2-small だけを使います。genmai を置いても zenz-v3.2-small は第二意見と英字の確かめに使うので（[かな漢字変換](conversion.md)を参照）、submodule の重みは引き続き必要です。

```bash
Tools/build_genmai_gguf.sh
```

補助辞書（Mozc のオープンソース辞書の名詞で内蔵辞書にないもの）も、ビルドの前に作って `Ogura/Resources/Dictionary/supplement/` に置きます（辞書の本体はリポジトリに入っていません。[補助辞書の README](../Ogura/Resources/Dictionary/supplement/README.md) を参照）。変換エンジンのフォークのチェックアウト（`Core/Package.swift` が固定しているリビジョン、submodule 込み）が要ります。Mozc の辞書を取得し、フォークの CLI を組んで内蔵辞書の語彙を書き出し、差分を LOUDS 形式にします。置かずにビルドしたアプリは内蔵辞書だけで変換します。

```bash
git clone --recursive https://github.com/goyamamoto/AzooKeyKanaKanjiConverter /tmp/converter   # Core/Package.swift のリビジョンに checkout
Tools/build_supplement_dictionary.sh /tmp/converter /tmp/supplement-work
```

## ビルドとインストール

Release ビルドを署名して `/Library/Input Methods/` に入れ、入力ソースに登録します（`sudo` のパスワードを求められます）。

Apple Development 証明書で署名する場合は Team ID を渡します。Apple Developer Program に加入していない Personal Team でも構いません（Xcode > Settings > Accounts で Team ID を確認できます）。署名の同一性が再インストールでも変わらないので、macOS の許可設定が引き継がれます。

```bash
./install.sh --team <TEAM_ID>        # または OGURA_TEAM_ID=<TEAM_ID> ./install.sh
```

証明書がない場合は ad-hoc 署名でインストールできます。ローカルでの動作確認用で、配布には使えません。

```bash
./install.sh --adhoc
```

どちらも毎回 clean して依存ライブラリから作り直します。`--incremental` を付けると前回のビルド（`build/DerivedData`）の上に作るので、Ogura や Core だけを変えたときは早く終わります。

### 配布用の pkg を作る

`pkgbuild.sh` で配布用の pkg を `build/pkg/` に作ります。Apple Silicon（arm64）と macOS 15 以降に限ってインストールでき、`/Library/Input Methods/` に入ります。インストール後に動いている古い Ogura を止め、インストールしたアカウントの入力ソースに登録する（`Tools/RegisterInputSource.swift` をコンパイルした補助プログラムを postinstall が実行する）ので、ログアウトせずに使え、更新は入力ソースを選び直すだけで反映されます。genmai の GGUF（上の「クローン」）を置いてから実行してください。無いと止まります。

pkg は二通りに作れます。

- `--unsigned`: アプリは ad-hoc 署名、pkg は無署名。Apple Developer Program なしで作れ、どの Apple Silicon Mac でも動きます。ただしダウンロードした pkg を Gatekeeper が一度止めるので、利用者には README の「インストール」の手順（「このまま開く」か、ターミナルの `sudo installer`）が必要です。出力は `Ogura-<版>-unsigned.pkg`
- `--team <TEAM_ID>`: Developer ID で署名して公証。ほかのアプリと同じようにダブルクリックで入ります。出力は `Ogura-<版>.pkg`

署名して公証するには、この Mac で一度だけ、次を用意します。

1. Apple Developer Program に加入し、Xcode > Settings > Accounts > Manage Certificates で「Developer ID Application」と「Developer ID Installer」の証明書を作る（Personal Team では作れません）
2. Apple ID の管理画面で App 用パスワードを作り、公証の資格情報を登録する
3. MLX のシェーダを組む Metal Toolchain を入れる

```bash
xcrun notarytool store-credentials "Notarytool" --apple-id <Apple ID> --team-id <TEAM_ID> --password <App 用パスワード>
xcodebuild -downloadComponent MetalToolchain
```

配布のたびに Xcode で MARKETING_VERSION（利用者に見せる版で、pkg の版になります）を上げてから実行します。ビルド番号（CFBundleVersion）は install.sh と pkgbuild.sh がビルド時に履歴のコミット数から付けるので、手で変える必要はありません。

```bash
./pkgbuild.sh --team <TEAM_ID>     # 署名・公証した pkg（数分〜十数分。依存を取り直してビルドする）
./pkgbuild.sh --unsigned           # ad-hoc 署名のアプリを無署名の pkg に（Developer ID なしで配る）
```

公証のプロファイル名は環境変数 `OGURA_NOTARY_PROFILE`、Installer 証明書の名前は `OGURA_INSTALLER_IDENTITY` で変えられます。

インストール後、Ogura のプロセスを kill すると次回選択時に新しいビルドが起動します。挙動がおかしいときは入力ソースから Ogura を外して追加し直すか、ログアウト・再ログインしてください。

## テストと lint

```bash
swift test --package-path Core          # Core の単体テスト（データ保護テストを含む）
xcodebuild -project Ogura.xcodeproj -scheme Ogura -only-testing:OguraTests test CODE_SIGNING_ALLOWED=NO
swiftlint --quiet --strict
```

`swift test` は一つのプロセスの中でテストを順に動かします（多くのテストは変換を伴い、メインスレッドで一つずつ動く）。`Tools/test_core_parallel.sh` は Core のテストを release でビルドし、テストのファイルごと（重いファイルはテストごと）に別のプロセスで同時に動かします。ビルドのスレッドとテストのプロセスの数は CPU のコアの数から決めます（コード生成のスレッドはすべてのコア、プロセスは最も速い段のコアと残りの半分）。M5 Max では、ファイルを一つ変えたあとのビルドが 53 秒から 20 秒に、テストが 50 秒から 12 秒になりました。ビルドは `build/core-tests` に置き、各プロセスの出力は `build/core-tests-logs` に出ます。

```bash
Tools/test_core_parallel.sh             # ビルドしてテスト（--no-build で前回のビルドのまま、--jobs <n> で同時に動かす数）
```

## ツール


| スクリプト                                  | 用途                                                                                                           |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `Tools/register_input_source.sh`       | ログアウトせずに現在のアカウントへ入力ソースを登録する（`Tools/RegisterInputSource.swift` を swift で動かす。pkg の postinstall は同じものをコンパイルして使う）        |
| `Tools/migrate_from_azookey.sh`        | azooKey の設定と学習データを Ogura のコンテナへ引き継ぐ                                                                          |
| `Tools/download_continuation_model.sh` | 「続きを書く」用の MLX モデルを Hugging Face から Ogura のモデル置き場に入れる                                                         |
| `Tools/build_genmai_gguf.sh`           | genmai の GGUF を公開リポジトリの Release から取得して SHA-256 を確かめ、`Ogura/Resources/genmai/` に置く。`--convert` で配布元の重みから作り直す（上の「クローン」を参照） |
| `Tools/build_supplement_dictionary.sh` | Mozc のオープンソース辞書から、内蔵辞書にない名詞の補助辞書を作り直す（`Ogura/Resources/Dictionary/supplement/README.md` を参照）                 |
| `Tools/test_core_parallel.sh`          | Core のテストを release でビルドし、テストのファイルごとに別のプロセスで同時に動かす（上の「テストと lint」を参照）                                        |
| `pkgbuild.sh`                          | 配布用 pkg を作る。`--team` で Developer ID 署名と公証（証明書が必要）、`--unsigned` で ad-hoc 署名のアプリを無署名の pkg に（上の「配布用の pkg を作る」を参照）      |


## 変換のスレッド

キーは IMK からメインスレッドに届き、変換は別のスレッド（`BackgroundConversionScheduler`、プロセスに一つの直列のキュー）で行います。手を入れるときは次の決まりを守ってください。

- **変換エンジンは鍵を取って使う**: 変換エンジン（`KanaKanjiConverter`）、そのセッション、半角英字の識別層とそのキャッシュは、すべての入力セッションで共有していて、二つのスレッドから同時に使えません。使うときは、メインスレッドでも別のスレッドでも `ConversionLock.withLock` の中で使います。アプリ側で学習データを書き出すときも同じです。
- **打鍵中の変換は写しで行う**: 文字のキーは、`SegmentsManager` が入力に足して、すぐ表示を返します。変換は、入力の状態の写し（`ConversionSnapshot`）を変換用のもう一つの `SegmentsManager` に渡して行い、結果だけを戻します。変換が新しく入力の状態を読むときは、`ConversionSnapshot` にも足してください。足さないと、別のスレッドの変換だけが古い値で動きます。
- **アプリには、メインスレッドからだけ問い合わせる**: 文脈（カーソル前後の文字列）は、ジョブを作るときにメインスレッドで読んで渡します。変換の中から IMK やアプリに問い合わせてはいけません。スペルチェッカーもメインスレッドでしか使えないので、規則による識別層を選んでいるときは、変換をメインスレッドで行います。
- **変換を使うキーは、先に変換を揃える**: Space、Enter、Backspace など、文字の入力以外の操作は `InputSession` が `withSettledConversion` の中で処理します。打鍵が止まったあとの徹底変換を打ち切り、鍵を取り、別のスレッドの結果を受け取るか、入力全体を変換してから処理します。
- **テスト**: `SegmentsManager.Context.conversionScheduler` を渡さなければ、各キーをその場で変換します（ほとんどのテストはこれ）。テストでは `QueuedConversions` を渡すと、別のスレッドの変換をテストが指示したときに走らせられます。

## トラブルシューティング

- 「Packages are not supported when using legacy build locations」と出る場合は Xcode の Locations 設定を Default に戻してください
- 変換精度が妙に低い場合は、モデル重みが LFS ポインタのままになっていないか上記の方法で確認してください
- 入力ソースに Ogura が出てこない場合は、`Tools/register_input_source.sh` を実行するか、ログアウト・再ログインしてください
