# Ogura

macOS 向けの日本語入力システムです。AI 技術の進歩を取り入れて、効率よく自然に日本語を入力できる環境を目指しています。特に、英語や専門用語の混じった文章を書くエンジニアや研究者を想定しています。[azooKey on macOS](https://github.com/azooKey/azooKey-Desktop) をベースにした個人プロジェクトです。キー操作は MS-IME との互換を重視しています。

## コンセプト

効率よく自然に入力できる環境のために、azooKey の変換エンジンが持つ変換の正確さと、MS-IME や Google 日本語入力（Mozc）のように長く使われてきた使い勝手を一つにまとめています。

- **変換の正確さは azooKey から**: かな漢字変換には、azooKey のニューラル変換エンジン「Zenzai」を使います。辞書だけで変換する方式と違い、前の文脈も見て変換します。
- **操作は MS-IME に合わせる**: 変換、文節の区切り直し、F6〜F10 や Ctrl+U/I/O などのキー操作を MS-IME に合わせています。Windows で身につけた操作がそのまま使えます。
- **半角英字を自動で見分ける**: ローマ字入力のまま打った英単語、製品名、コードの名前を見分けて、半角英字のまま変換します。文の途中の語も、大文字から打った名前も英字のまま残ります（`kyouhagithubnipushsita` → 今日はGitHubにpushした、`korehaOguradesu` → これはOguraです）。英数モードに切り替える必要はありません。
- **続きを書く**: さらに、書きかけの文の後ろでキーを一つ押すと、Mac の中の言語モデルが続きを書き足します。気に入れば Tab で本文に、違えばもう一度押して別の案。文章はどこにも送りません。

**開発中です。** 個人で使いながら育てている段階で、動作は保証できません。

## 特徴

- **Zenzai による変換**: 端末内で動くニューラルかな漢字変換（[AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)）。変換プロフィール、履歴学習、ユーザ辞書、[Tuner](https://github.com/azooKey/Tuner) の個人最適化モデルに対応
- **MS-IME 互換のキー操作**: Windows から来た人がそのまま使える。設定で macOS 標準の操作にも切り替え可能
- **ライブ変換**
- **機械学習で半角英字の自動識別**: ローマ字で打った英単語や製品名、文の途中で大文字から打った語を、学習したモデルが見分けて半角英字のまま変換する。日本語にも英単語にも読める語（`token` と「とけん」）は、変換エンジンの辞書と文脈に任せる。モデルは Mac の中で動き、1 打鍵あたり数ミリ秒。設定の「英単語とローマ字の見分けに学習モデルを使う」で有効にする（オフのときは規則で見分ける）。
- **AZIK** などのローマ字テーブルのカスタマイズ
- **続きを書く**: 書きかけの文の後ろで Shift+Tab を押すと、ローカル LLM（標準は macOS 26 の Apple Intelligence）が続きを書き足す。気に入れば Tab、違えばもう一度押して別の案
- **ネットワークに出ない**: 通信するコードも権限も持たず、テストで固定

### 半角英字の識別の仕組み

ローマ字入力では、`token` が英単語か「とけん」か、`Sakeha` が Sake か「さけは」かを、キーだけから決める必要があります。Ogura はこれを、打ったキーの一つ一つに「ローマ字」「英単語の始まり」「英単語の続き」のどれかのラベルを付ける問題（系列ラベリング）として解きます。ラベルの付け方それぞれに点数を付け、最も良いものを選びます。

- **何を見るか**: 前後の文字、大文字かどうか、ローマ字として読めるか、英単語らしい綴りか（文字の並びの統計）、知っている英単語や製品名か、その部分を日本語として読むとどんな語になるか
- **どう学習したか**: 辞書から作った日本語文と、端末内の言語モデルに書かせた英単語交じりの日本語文を、さまざまなローマ字の打ち方で打った形にして学習しています。点数は線形モデル（semi-Markov CRF）と、それを補正する小さなニューラルネットワーク（双方向 LSTM）で計算します
- **迷うとき**: 英単語とも日本語とも読める小文字の語は、その確からしさを付けてかな漢字変換エンジンに渡し、辞書と文脈で決めてもらいます

手書きの評価用の文 70 文では、英字の範囲を正しく見分けた文は規則で 63 文、学習モデルで 70 文です。詳しくは [半角英字の識別](docs/latin-identification.md) を参照してください。

## 動作環境

macOS 15 以降、Apple Silicon の Mac が必要です。「続きを書く」で Apple の端末内モデルを使うには macOS 26 以降が必要です。

## インストール

配布用のパッケージはまだ公開していません。ソースからビルドしてインストールします（[開発](docs/development.md)を参照）。pkg を受け取った場合は開いてインストールします（初めて入れたときはログアウトして再ログインすると入力ソースの一覧に出ます）。インストール後は次の手順で使えます。

1. ビルドしたアカウントと別のアカウントで使う場合は、そのアカウントで `Tools/register_input_source.sh` を実行するか、ログアウトして再ログイン
2. 「システム設定」>「キーボード」>「入力ソース」>「編集…」>「+」>「日本語」から Ogura を追加
3. メニューバーの入力メニューから Ogura（「お」のアイコン）を選択

azooKey on macOS を使っていた場合、`Tools/migrate_from_azookey.sh` を一度実行すると設定と学習データを引き継げます。

## ドキュメント

- [使い方](docs/usage.md): キー操作と設定
- [続きを書く](docs/continuation.md): 使い方、モデルの選び方、うまくいかないとき、仕組み
- [半角英字の識別](docs/latin-identification.md): 英単語とローマ字の見分け方、学習データ、評価、苦手なこと
- [データの扱い](docs/privacy.md): 入力した内容をどう扱うか（テストで固定している保証）
- [開発](docs/development.md): ビルドとインストール、配布用 pkg、テスト、ツール

## azooKey との関係

Ogura は azooKey on macOS（MIT ライセンス、Copyright (c) 2025 Miwa Keita）をベースに作った、独立したプロジェクトです。azooKey の公式版ではなく、azooKey プロジェクトとは別に開発しています。

- **受け継いだもの**: かな漢字変換の中心である Zenzai と変換エンジン（AzooKeyKanaKanjiConverter）、そして入力メソッドの土台（キー入力の処理、候補ウィンドウ、ユーザ辞書、設定）。
- **Ogura で目指していること**: 効率よく自然に日本語を入力できる環境です。特に、エンジニアや研究者が英語や専門用語の混じった文章を手間なく正確に入力できること。
- **大切にしていること**: 文章を外部のサービスに送る機能は持たず、すべて Mac の中で処理します。
- azooKey の変更を追いかけてはおらず、必要なものだけを個別に取り込んでいます。azooKey と同じ Mac に入れて併用できます。

## 貢献について

個人プロジェクトとして不定期に開発しています。Issue や Pull Request は歓迎しますが、返答や取り込みに時間がかかることがあります。変換エンジン自体の改善は [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter) へ送るのが適切だと思います。

## ライセンス

MIT License。azooKey on macOS 由来の部分は Copyright (c) 2025 Miwa Keita、Ogura の固有の部分は Copyright (c) Go Yamamoto です。詳細は `LICENSE` を参照してください。

Zenzai のモデルと言語モデルは submodule として取り込んでおり、それぞれのリポジトリのライセンスに従います。

## 謝辞

Ogura は azooKey on macOS と AzooKeyKanaKanjiConverter（Miwa Keita 氏ほか）なしには存在しません。azooKey on macOS は情報処理推進機構（IPA）の [2024年度未踏IT人材発掘・育成事業](https://www.ipa.go.jp/jinzai/mitou/it/2024/koubokekka.html) の支援を受けて開発されました。

azooKey が参考にした資料（上流の README より）:

- [https://mzp.hatenablog.com/entry/2017/09/17/220320](https://mzp.hatenablog.com/entry/2017/09/17/220320)
- [https://www.logcg.com/en/archives/2078.html](https://www.logcg.com/en/archives/2078.html)
- [https://stackoverflow.com/questions/27813151/how-to-develop-a-simple-input-method-for-mac-os-x-in-swift](https://stackoverflow.com/questions/27813151/how-to-develop-a-simple-input-method-for-mac-os-x-in-swift)
- [https://mzp.booth.pm/items/809262](https://mzp.booth.pm/items/809262)

### azooKey の関連プロジェクト

- [fcitx5-hazkey](https://github.com/7ka-Hiira/fcitx5-hazkey): Linux 向けクライアント
- [azooKey-Windows](https://github.com/fkunn1326/azooKey-Windows): Windows 向けクライアント
- [azoo-key-skkserv](https://github.com/gitusp/azoo-key-skkserv): SKK サーバ実装
