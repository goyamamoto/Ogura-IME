---
license: cc-by-sa-4.0
base_model: subdiox/genmai
language: ja
---
# genmai (GGUF) for Ogura

`ggml-model-Q5_K_M.gguf` in this folder is [genmai](https://huggingface.co/subdiox/genmai) v0.1.1 by subdiox, a
kana-kanji conversion model fine-tuned from [zenz-v2.5-medium](https://huggingface.co/Miwa-Keita/zenz-v2.5-medium) by
Miwa Keita, converted to GGUF for Zenzai, the neural conversion of Ogura's converter.

- License: [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/), as genmai's and zenz-v2.5-medium's.
- Changes: `model.safetensors` of genmai (revision 06b60eb) converted to GGUF with the conversion script of
  [azooKey/llama.cpp](https://github.com/azooKey/llama.cpp) b4846 and quantized to Q5_K_M, with the metadata key
  `zenzai.attention.precision` = `f32` added, which has the converter compute this model's attention in single precision.
  The weights are otherwise genmai's.
- The file is not in the repository: `Tools/build_genmai_gguf.sh` downloads it here from the Ogura-IME release
  `genmai-0.1.1-gguf` and checks its SHA-256 (`9a8cf1f263eae85ab78962c4c04c13c03a5112365094d46421576f2f8103213c`).
  The author's repository was later renamed to [genmai-310M](https://huggingface.co/subdiox/genmai-310M) with a
  rewritten history; its release v1.0.0 (revision 3d52f4f) has the same `model.safetensors` and tokenizer files as
  v0.1.1 (same SHA-256), and `--convert` rebuilds the identical GGUF from it.
