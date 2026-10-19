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

かな漢字変換エンジン（AzooKeyKanaKanjiConverter）は、Zenzai が読みに与える確率を返す関数を一つ加えたフォーク（`goyamamoto/AzooKeyKanaKanjiConverter`）を使います。

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

### 配布用の pkg を作る

`pkgbuild.sh` で、Developer ID で署名して公証した pkg を `build/pkg/Ogura-<版>.pkg` に作ります。Apple Silicon（arm64）と macOS 15 以降に限ってインストールでき、`/Library/Input Methods/` に入ります。インストール後に動いている古い Ogura を止めるので、更新は入力ソースを選び直すだけで反映されます。

この Mac で一度だけ、次を用意します。

1. Apple Developer Program に加入し、Xcode > Settings > Accounts > Manage Certificates で「Developer ID Application」と「Developer ID Installer」の証明書を作る（Personal Team では作れません）
2. Apple ID の管理画面で App 用パスワードを作り、公証の資格情報を登録する
3. MLX のシェーダを組む Metal Toolchain を入れる

```bash
xcrun notarytool store-credentials "Notarytool" --apple-id <Apple ID> --team-id <TEAM_ID> --password <App 用パスワード>
xcodebuild -downloadComponent MetalToolchain
```

配布のたびに Xcode で MARKETING_VERSION（pkg の版になります）を上げてから実行します。

```bash
./pkgbuild.sh --team <TEAM_ID>     # 署名・公証した pkg（数分〜十数分。依存を取り直してビルドする）
./pkgbuild.sh --unsigned           # 署名も公証もしない pkg。中身の確認用で、配布には使えない
```

公証のプロファイル名は環境変数 `OGURA_NOTARY_PROFILE`、Installer 証明書の名前は `OGURA_INSTALLER_IDENTITY` で変えられます。

インストール後、Ogura のプロセスを kill すると次回選択時に新しいビルドが起動します。挙動がおかしいときは入力ソースから Ogura を外して追加し直すか、ログアウト・再ログインしてください。

## テストと lint

```bash
swift test --package-path Core          # Core の単体テスト（データ保護テストを含む）
xcodebuild -project Ogura.xcodeproj -scheme Ogura -only-testing:OguraTests test CODE_SIGNING_ALLOWED=NO
swiftlint --quiet --strict
```

## ツール


| スクリプト                                  | 用途                                                                                                           |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `Tools/register_input_source.sh`       | ログアウトせずに現在のアカウントへ入力ソースを登録する                                                                                  |
| `Tools/migrate_from_azookey.sh`        | azooKey の設定と学習データを Ogura のコンテナへ引き継ぐ                                                                          |
| `Tools/download_continuation_model.sh` | 「続きを書く」用の MLX モデルを Hugging Face から Ogura のモデル置き場に入れる                                                         |
| `pkgbuild.sh`                          | Developer ID 署名と公証を行い配布用 pkg を作る（`--team`、証明書が必要）。`--unsigned` で署名なしの確認用 pkg                                 |


## トラブルシューティング

- 「Packages are not supported when using legacy build locations」と出る場合は Xcode の Locations 設定を Default に戻してください
- 変換精度が妙に低い場合は、モデル重みが LFS ポインタのままになっていないか上記の方法で確認してください
- 入力ソースに Ogura が出てこない場合は、`Tools/register_input_source.sh` を実行するか、ログアウト・再ログインしてください
