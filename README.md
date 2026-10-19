# Ogura

macOS 向けの日本語入力システムです。[azooKey on macOS](https://github.com/azooKey/azooKey-Desktop) をベースに、端末内で動くニューラルかな漢字変換、打ったまま残る半角英字、MS-IME 互換のキー操作、端末内の言語モデルによる続きの書き足しを備えます。効率よく自然に日本語を入力できる環境を目指す個人プロジェクトで、特に、英語や専門用語の混じった文章を書くエンジニアや研究者を想定しています。

## コンセプト

効率よく自然に入力できる環境のために、言語モデルによる変換の正確さと、MS-IME や Google 日本語入力（Mozc）のように長く使われてきた使い勝手を一つにまとめています。

- **生成 AI と同じ水準の正確さで変換する**: 生成 AI が日本語を自在に扱うのと同じくらい正確なかな漢字変換を目指します。辞書で語を一つずつ当てるのではなく、言語モデル（LLM）が候補の日本語らしさを文脈ごと評価して、文全体として最も自然な変換を選びます。
- **半角英字を自動で見分ける**: ローマ字入力のまま打った英単語、製品名、コードの名前を見分けて、半角英字のまま変換します。文の途中の語も、大文字から打った名前も英字のまま残ります（`kyouhagithubnipushsita` → 今日はGitHubにpushした、`korehaOguradesu` → これはOguraです）。英数モードに切り替える必要はありません。
- **操作は MS-IME に合わせる**: 変換、文節の区切り直し、F6〜F10 や Ctrl+U/I/O などのキー操作を MS-IME に合わせています。Windows で身につけた操作がそのまま使えます。
- **続きを書く**: さらに、書きかけの文の後ろでキーを一つ押すと、Mac の中の言語モデルが続きを書き足します。気に入れば Tab で本文に、違えばもう一度押して別の案。文章はどこにも送りません。

**開発中です。** 個人で使いながら育てている段階で、動作は保証できません。

## 特徴

- **genmai と Zenzai による変換**: azooKey のニューラル変換エンジン Zenzai に [genmai](https://huggingface.co/subdiox/genmai) のモデルを載せ、前の文脈を見て端末内で変換する。打鍵が止まると入力全体を見直し、zenz-v3.2-small の第二意見も聞いて確定する変換を選ぶ（[かな漢字変換](docs/conversion.md)）
- **打鍵に遅れない表示**: キーを押すとすぐ表示し、変換は裏で進めて、届いたら表示を直す。長くなった入力は、終わりの 60 文字を直せるように残して、前を切りのいいところで自動で確定する（[かな漢字変換](docs/conversion.md)）
- **補助辞書**: 内蔵辞書にない名詞を [Mozc](https://github.com/google/mozc) のオープンソース辞書から補う
- **機械学習で半角英字の自動識別**: 打ったキーの一つ一つにローマ字か英単語かのラベルを付ける問題（系列ラベリング）として、学習したモデルが端末内で解く。日本語にも英単語にも読める語（`token` と「とけん」）は、変換エンジンの辞書と文脈に任せる（[半角英字の識別](docs/latin-identification.md)）
- **MS-IME 互換のキー操作**: Windows から来た人がそのまま使える。設定で macOS 標準の操作にも切り替え可能
- **続きを書く**: 書きかけの文の後ろで Shift+Tab を押すと、ローカル LLM（標準は macOS 26 の Apple Intelligence）が続きを書き足す。気に入れば Tab、違えばもう一度押して別の案
- **ネットワークに出ない**: 通信するコードも権限も持たず、テストで固定

## 動作環境

macOS 15 以降、Apple Silicon の Mac が必要です。「続きを書く」で Apple の端末内モデルを使うには macOS 26 以降が必要です。

## インストール

Apple Silicon の Mac と macOS 15 以降で動きます。[Releases](https://github.com/goyamamoto/Ogura-IME/releases) の pkg を開いてインストールします（管理者のパスワードを求められます）。pkg は Apple の Developer ID で署名していないので、初めて開くときに macOS が止めます。「システム設定」>「プライバシーとセキュリティ」の一番下に出る「このまま開く」を押すと進みます。ターミナルから入れる場合、この手順は要りません。

```sh
sudo installer -pkg ~/Downloads/Ogura-1.1-unsigned.pkg -target /
```

インストールしたアカウントでは、すぐに入力ソースの一覧に Ogura が出ます。ほかのアカウントでは、ログインし直すと出ます。一覧に出ないときは、ログアウトして再ログインしてください。

1. 「システム設定」>「キーボード」>「入力ソース」>「編集…」>「+」>「日本語」から Ogura を追加
2. メニューバーの入力メニューから Ogura（「お」のアイコン）を選択

ソースからビルドする場合は[開発](docs/development.md)を参照してください。azooKey on macOS を使っていた場合、`Tools/migrate_from_azookey.sh` を一度実行すると設定と学習データを引き継げます。

## ドキュメント

- [使い方](docs/usage.md): キー操作と設定
- [かな漢字変換](docs/conversion.md): genmai と zenz-v3.2-small の役割、打鍵中の表示と打鍵が止まったあとの徹底変換、長い入力の自動確定、第二意見、辞書、評価
- [続きを書く](docs/continuation.md): 使い方、モデルの選び方、うまくいかないとき、仕組み
- [半角英字の識別](docs/latin-identification.md): 英単語とローマ字の見分け方、学習データ、評価、苦手なこと
- [データの扱い](docs/privacy.md): 入力した内容をどう扱うか（テストで固定している保証）
- [開発](docs/development.md): ビルドとインストール、配布用 pkg、テスト、ツール、変換のスレッド

## azooKey との関係

Ogura は azooKey on macOS（MIT ライセンス、Copyright (c) 2025 Miwa Keita）をベースに作った、独立したプロジェクトです。azooKey の公式版ではなく、azooKey プロジェクトとは別に開発しています。

- **受け継いだもの**: かな漢字変換の中心である Zenzai と変換エンジン（AzooKeyKanaKanjiConverter）、そして入力メソッドの土台（キー入力の処理、候補ウィンドウ、ユーザ辞書、設定）。変換のモデルには、azooKey 標準の zenz-v3.2-small に加えて、同じ系統から学習された subdiox 氏の genmai を使っています。
- **Ogura で目指していること**: 効率よく自然に日本語を入力できる環境です。特に、エンジニアや研究者が英語や専門用語の混じった文章を手間なく正確に入力できること。
- **大切にしていること**: 文章を外部のサービスに送る機能は持たず、すべて Mac の中で処理します。
- azooKey の変更を追いかけてはおらず、必要なものだけを個別に取り込んでいます。azooKey と同じ Mac に入れて併用できます。

## 貢献について

個人プロジェクトとして不定期に開発しています。Issue や Pull Request は歓迎しますが、返答や取り込みに時間がかかることがあります。変換エンジン自体の改善は [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter) へ送るのが適切だと思います。

## ライセンス

MIT License。azooKey on macOS 由来の部分は Copyright (c) 2025 Miwa Keita、Ogura の固有の部分は Copyright (c) Go Yamamoto です。詳細は `LICENSE` を参照してください。

Zenzai のモデルと言語モデルは submodule として取り込んでおり、それぞれのリポジトリのライセンスに従います。アプリに入っている第三者の成果物とライセンスの一覧は `Ogura/Resources/Licenses/NOTICE.md` にあり、ライセンスの本文とともにアプリにも同梱しています。

補助辞書（`Ogura/Resources/Dictionary/supplement`）は [Mozc](https://github.com/google/mozc) のオープンソース辞書から作っています。Mozc は BSD 3-Clause License、辞書の語彙は IPAdic（奈良先端科学技術大学院大学）と沖縄辞書に由来し、それぞれの表示と免責を同じディレクトリの `LICENSE-mozc.txt` と `LICENSE-mozc-dictionary.txt` に収めています。

Zenzai の既定のモデル genmai（subdiox 氏、CC BY-SA 4.0。Miwa Keita 氏の zenz-v2.5-medium（CC BY-SA 4.0）をもとに学習したもの）は、GGUF に変換したものをビルド時にアプリに入れます。変換したモデルも CC BY-SA 4.0 です。変換の内容は `Ogura/Resources/genmai/README.md` にあります。

英単語とローマ字の見分けに使う読みの判定機（`Ogura/Resources/ReadingJudge`）は、hotchpotch 氏の japanese-reranker-xsmall-v2（MIT）を読みの組で追加学習したものです。その元の cl-nagoya/ruri-v3-pt-30m（名古屋大学 CL 研究室、Apache License 2.0）と sbintuitions/modernbert-ja-30m（SB Intuitions、MIT）の表示とライセンス本文を同じフォルダに収めています。追加学習した重みは Apache License 2.0 です。

## 謝辞

Ogura は azooKey on macOS と AzooKeyKanaKanjiConverter（Miwa Keita 氏ほか）なしには存在しません。Zenzai のモデルの一つに、subdiox 氏の [genmai](https://github.com/subdiox/genmai-ime) のモデルを使わせていただいています。azooKey on macOS は情報処理推進機構（IPA）の [2024年度未踏IT人材発掘・育成事業](https://www.ipa.go.jp/jinzai/mitou/it/2024/koubokekka.html) の支援を受けて開発されました。

azooKey が参考にした資料（上流の README より）:

- [https://mzp.hatenablog.com/entry/2017/09/17/220320](https://mzp.hatenablog.com/entry/2017/09/17/220320)
- [https://www.logcg.com/en/archives/2078.html](https://www.logcg.com/en/archives/2078.html)
- [https://stackoverflow.com/questions/27813151/how-to-develop-a-simple-input-method-for-mac-os-x-in-swift](https://stackoverflow.com/questions/27813151/how-to-develop-a-simple-input-method-for-mac-os-x-in-swift)
- [https://mzp.booth.pm/items/809262](https://mzp.booth.pm/items/809262)

### azooKey の関連プロジェクト

- [fcitx5-hazkey](https://github.com/7ka-Hiira/fcitx5-hazkey): Linux 向けクライアント
- [azooKey-Windows](https://github.com/fkunn1326/azooKey-Windows): Windows 向けクライアント
- [azoo-key-skkserv](https://github.com/gitusp/azoo-key-skkserv): SKK サーバ実装
