# Ogura に含まれる成果物とライセンス

Ogura のアプリには次の成果物が入っています。ライセンスの本文は、このフォルダのファイルか、記した場所にあります。

## Ogura 本体

- Ogura: MIT License（`LICENSE-ogura.txt`）。[azooKey on macOS](https://github.com/azooKey/azooKey-Desktop)（Copyright (c) 2025 Miwa Keita）をベースにしています。

## かな漢字変換

- [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)（Miwa Keita 氏ほか）: MIT License（`LICENSE-AzooKeyKanaKanjiConverter.txt`）。Ogura は [goyamamoto/AzooKeyKanaKanjiConverter](https://github.com/goyamamoto/AzooKeyKanaKanjiConverter) のフォークを使っています。
- azooKey の内蔵辞書（azooKey_dictionary_storage、同パッケージに含まれる）: Apache License 2.0（`LICENSE-apache-2.0.txt`）
- 絵文字の辞書（[azooKey_emoji_dictionary_storage](https://github.com/azooKey/azooKey_emoji_dictionary_storage) v0.3、AzooKeyKanaKanjiConverter に含まれる）: もとのデータごとにライセンスが違います。[Mozc](https://github.com/google/mozc) の絵文字のデータ（emoji_data.tsv。Copyright 2010-2018, Google Inc.、BSD 3-Clause License。本文は補助辞書と同じ `../Dictionary/supplement/LICENSE-mozc.txt`）、Unicode の絵文字のデータと CLDR の日本語の注釈（Unicode, Inc.、Unicode License V3。著作権の表示と本文は `LICENSE-third-party-bundled.txt`）、azooKey が足した読み（azooKey、MIT License）
- 文字の n-gram の tokenizer（AzooKeyKanaKanjiConverter の EfficientNGram に含まれる）: [ku-nlp/gpt2-small-japanese-char](https://huggingface.co/ku-nlp/gpt2-small-japanese-char) の tokenizer のデータ。CC BY-SA 4.0（`LICENSE-cc-by-sa-4.0.txt`）
- [zenz-v3.2-small](https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf)（Miwa Keita 氏）: 同梱しているのは配布元のコミット c67e03e の GGUF で、その時点の配布元の表示は Apache License 2.0（`LICENSE-apache-2.0.txt`）です。配布元はその後、同じ重みの表示を CC BY-SA 4.0（`LICENSE-cc-by-sa-4.0.txt`）に変えています。配布されている GGUF を変えずに同梱しています
- [genmai](https://huggingface.co/subdiox/genmai-310M)（subdiox 氏。Miwa Keita 氏の zenz-v2.5-medium をもとに学習。v0.1.1、genmai-310M v1.0.0 と同一の重み）: CC BY-SA 4.0（`LICENSE-cc-by-sa-4.0.txt`）。GGUF への変換の内容は `../genmai/README.md` にあります。変換したモデルも CC BY-SA 4.0 です
- [base_n5_lm](https://huggingface.co/Miwa-Keita/base_n5_lm)（Miwa Keita 氏）: Zenzai の個人最適化に使う n-gram 言語モデル。配布元にライセンスの表示はありません。azooKey on macOS が同じ形で同梱しているものです
- [llama.cpp](https://github.com/ggml-org/llama.cpp)（The ggml authors。[azooKey/llama.cpp](https://github.com/azooKey/llama.cpp) のビルド）: MIT License（`LICENSE-llama.cpp.txt`）。含まれる llamafile の行列積（Mozilla Foundation、MIT License）の表示は `LICENSE-third-party-bundled.txt` にあります
- 補助辞書: [Mozc](https://github.com/google/mozc) のオープンソース辞書から作成。Mozc は BSD 3-Clause License、語彙は IPAdic（奈良先端科学技術大学院大学）と沖縄辞書に由来。表示と免責は `../Dictionary/supplement/LICENSE-mozc.txt` と `LICENSE-mozc-dictionary.txt`

## 半角英字の識別

- 読みの判定機: hotchpotch 氏の japanese-reranker-xsmall-v2（MIT）を読みの組で追加学習したもの。元の cl-nagoya/ruri-v3-pt-30m（名古屋大学 CL 研究室、Apache License 2.0）と sbintuitions/modernbert-ja-30m（SB Intuitions、MIT）の表示とライセンス本文は `../ReadingJudge/` にあります。追加学習した重みは Apache License 2.0
- 英単語とローマ字を見分けるモデルと語彙表（`../ScriptModel/`）: Ogura の一部（MIT License）

## 続きを書く

- [MLX Swift](https://github.com/ml-explore/mlx-swift)（ml-explore）: MIT License（`LICENSE-mlx-swift.txt`）。次のものを含みます: [MLX](https://github.com/ml-explore/mlx) と [MLX C](https://github.com/ml-explore/mlx-c)（Apple、MIT License）、{fmt}（MIT License）、JSON for Modern C++（MIT License）、PocketFFT（BSD 3-Clause License）、metal-cpp（Apple、Apache License 2.0）。表示と本文は `LICENSE-third-party-bundled.txt` と `LICENSE-apache-2.0.txt` にあります
- [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm)（ml-explore）: MIT License（`LICENSE-mlx-swift-lm.txt`）
- [swift-tokenizers](https://github.com/ensan-hcl/swift-tokenizers)（ensan-hcl 氏。Hugging Face の [swift-transformers](https://github.com/huggingface/swift-transformers) のフォーク）: Apache License 2.0（`LICENSE-swift-tokenizers.txt`）
- [Jinja](https://github.com/johnmai-dev/Jinja)（John Mai）: MIT License（`LICENSE-Jinja.txt`）

## ライブラリ

- [SwiftyMarisa](https://github.com/ensan-hcl/SwiftyMarisa)（Vladimir Solomenchuk）: BSD License（`LICENSE-SwiftyMarisa.txt`）。含まれる [marisa-trie](https://github.com/s-yata/marisa-trie)（Susumu Yata 氏）は BSD 2-Clause License で使っています（`LICENSE-third-party-bundled.txt`）
- [swift-collections](https://github.com/apple/swift-collections)、[swift-algorithms](https://github.com/apple/swift-algorithms)、[swift-numerics](https://github.com/apple/swift-numerics)（Apple）: Apache License 2.0（`LICENSE-swift-collections.txt`、`LICENSE-swift-algorithms.txt`、`LICENSE-swift-numerics.txt`）
