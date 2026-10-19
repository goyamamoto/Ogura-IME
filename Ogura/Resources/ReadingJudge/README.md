---
license: apache-2.0
base_model: hotchpotch/japanese-reranker-xsmall-v2
language: ja
---
# Reading judge for Ogura

`model.mlmodelc` in this folder is a small encoder that scores readings of typed keys: how likely the reading the user
meant is against the other readings of the same keys (tokenをおくって against とけんをおくって, みねにのぼる against
mineにのぼる). Ogura's naturalness checks for Latin words use it together with Zenzai (see `docs/latin-identification.md`).
It runs with Core ML on the Neural Engine. `tokenizer.json`, `tokenizer_config.json` and `special_tokens_map.json` are
the tokenizer of the model it was trained from.

## Lineage

| Model | Author | License | Relation |
| --- | --- | --- | --- |
| [sbintuitions/modernbert-ja-30m](https://huggingface.co/sbintuitions/modernbert-ja-30m) | SB Intuitions | MIT | Japanese ModernBERT, the base of the two below |
| [cl-nagoya/ruri-v3-pt-30m](https://huggingface.co/cl-nagoya/ruri-v3-pt-30m) | CL Research Group in Nagoya, Japan | Apache License 2.0 | Pre-trained from modernbert-ja-30m |
| [hotchpotch/japanese-reranker-xsmall-v2](https://huggingface.co/hotchpotch/japanese-reranker-xsmall-v2) | hotchpotch | MIT | Reranker (36.8M parameters) fine-tuned from ruri-v3-pt-30m |
| This model | Ogura (Go Yamamoto) | Apache License 2.0 | japanese-reranker-xsmall-v2 fine-tuned on pairs of readings |

## Training

- Pairs of a right reading and a wrong reading of the same keys; the input is the reading alone (hiragana, Latin words as
  typed), at most 64 tokens. Loss `softplus(-(s_right - s_wrong))`, 2 epochs, learning rate 3e-5.
- The pairs come from the sentences used to train Ogura's Latin identification layer (Mozc-dictionary sentences and
  sentences written by a language model run locally; see `docs/latin-identification.md`), with words chosen by English
  word frequency and the readings of common nouns in the Mozc dictionary.
- The fine-tuned weights were exported to Core ML (`model.mlmodelc`).

## Licenses and notices

The weights of this model are licensed under the Apache License 2.0 (`LICENSE-apache-2.0.txt` in this folder), Copyright
Go Yamamoto. They derive from the three models above, whose license notices are reproduced here; whoever redistributes
this model keeps the notices and the license text.

- modernbert-ja-30m: MIT License, Copyright (c) 2025 SB Intuitions.
- ruri-v3-pt-30m: Apache License, Version 2.0, CL Research Group in Nagoya, Japan. Changes in Ogura's model: fine-tuning
  on reading pairs and export to Core ML.
- japanese-reranker-xsmall-v2: MIT License (as its model card states), hotchpotch.
