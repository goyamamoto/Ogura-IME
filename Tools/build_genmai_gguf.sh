#!/bin/sh
# Put the GGUF of genmai that Ogura's Zenzai loads into Ogura/Resources/genmai (it is not in the repository).
#
# genmai (https://huggingface.co/subdiox/genmai-310M, CC BY-SA 4.0) is a kana-kanji conversion model fine-tuned from
# zenz-v2.5-medium. Ogura runs it converted and quantized with the llama.cpp the converter runs (azooKey/llama.cpp b4846)
# as described under --convert below. By default this script downloads the converted GGUF from this project's release
# genmai-0.1.1-gguf on GitHub and checks its SHA-256, which needs no Python and no Hugging Face access.
# The GGUF was first built from the author's repository subdiox/genmai at v0.1.1 (revision 06b60eb). That repository
# was renamed to genmai-310M and its history rewritten; its release v1.0.0 (revision 3d52f4f) has byte-identical
# model.safetensors and tokenizer files (only README.md and the token ids in config.json differ), and the GGUF built
# from it is byte-identical too, so the two names mean the same model.
#
# Usage: Tools/build_genmai_gguf.sh [output folder]             download the released GGUF (default: Ogura/Resources/genmai)
#        Tools/build_genmai_gguf.sh --convert [output folder]   convert from the author's weights instead (see below)
#
# --convert is the record of how the GGUF was made, and the way to try another revision of the model:
#   OGURA_GENMAI_REPO (default subdiox/genmai-310M) and OGURA_GENMAI_REVISION (default 3d52f4f…, v1.0.0) pick the
#   weights. With the defaults the files are checked against their SHA-256; with other values the hashes are printed
#   instead. Needs git, cmake, curl and python3.12 (the conversion's torch 2.2 has no wheels for newer Pythons). The
#   downloads and the work (about 5 GB) go in $OGURA_GENMAI_WORK, by default $TMPDIR/ogura-genmai.
#   The conversion writes GPT-2's tied output layer as a tensor of its own, as that llama.cpp version needs to load the
#   model. One metadata key is added on the way: zenzai.attention.precision = f32. genmai's attention scores exceed half
#   precision's range, so the converter computes this model's attention in single precision; without it the conversions
#   come out wrong, without an error.
#   The prompt starts without <s>, as the converter runs the zenz models, although genmai was trained with it: with
#   tokenizer.ggml.add_bos_token = true, Ogura converted 174 of the 200 AJIMEE-Bench items against 176, and 1,227 of 2,507
#   Aozora sentences against 1,217, mostly in notation, on sentences of the kind genmai was trained on.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
convert=false
if [ "${1:-}" = "--convert" ]; then
    convert=true
    shift
fi
out="${1:-$root/Ogura/Resources/genmai}"
mkdir -p "$out"
target="$out/ggml-model-Q5_K_M.gguf"
# The build Ogura was measured with (the conversion and the quantization give the same bytes each time)
expected=9a8cf1f263eae85ab78962c4c04c13c03a5112365094d46421576f2f8103213c

sha256() {
    shasum -a 256 "$1" | cut -d ' ' -f 1
}

if [ "$convert" = false ]; then
    if [ -f "$target" ] && [ "$(sha256 "$target")" = "$expected" ]; then
        echo "すでにあります: $target"
        exit 0
    fi
    url="https://github.com/goyamamoto/Ogura-IME/releases/download/genmai-0.1.1-gguf/ggml-model-Q5_K_M.gguf"
    curl -fL --retry 5 --retry-delay 3 --retry-all-errors --progress-bar "$url" -o "$target.download"
    if [ "$(sha256 "$target.download")" != "$expected" ]; then
        echo "ダウンロードした GGUF の内容が想定と違います（SHA-256 が一致しません）" >&2
        rm -f "$target.download"
        exit 1
    fi
    mv "$target.download" "$target"
    echo "取得しました: $target"
    exit 0
fi

# --convert: from the author's weights
work="${OGURA_GENMAI_WORK:-${TMPDIR:-/tmp}/ogura-genmai}"
repo="${OGURA_GENMAI_REPO:-subdiox/genmai-310M}"
revision="${OGURA_GENMAI_REVISION:-3d52f4fe739c42e00801cc5646cd5bc79913dc4e}"
pinned=false
if [ "$repo" = subdiox/genmai-310M ] && [ "$revision" = 3d52f4fe739c42e00801cc5646cd5bc79913dc4e ]; then
    pinned=true
fi
model="$work/genmai"
mkdir -p "$model"

# fetch <file> <SHA-256 of the file at v1.0.0>
fetch() {
    if [ ! -f "$model/$1" ] || { [ "$pinned" = true ] && [ "$(sha256 "$model/$1")" != "$2" ]; }; then
        curl -fL --retry 5 --retry-delay 3 --retry-all-errors --progress-bar \
            "https://huggingface.co/$repo/resolve/$revision/$1" -o "$model/$1"
    fi
    if [ "$pinned" = true ]; then
        if [ "$(sha256 "$model/$1")" != "$2" ]; then
            echo "ダウンロードした $1 の内容が想定と違います（SHA-256 が一致しません）" >&2
            exit 1
        fi
    else
        echo "$1 $(sha256 "$model/$1")"
    fi
}
# The model card's license and base model go in the GGUF's metadata
fetch README.md 72b1c1bcd4913d138c02303a77fde223db74b9c25f12883f89ce2c4499fc2b16
fetch config.json 542911d6856c3e6fb7ee884158d8d32b3ad41cc48fe2dff2dbfc68185b0d3e10
fetch tokenizer.json 5f47a842d17ec6211bf243fc2f32b6ee12c9cbc00e68f9bbfdfd550b584c1838
fetch tokenizer_config.json b0c7081eebd7d34b1e9cff3c2d107bffff1273b39cfc21785786f309a86a173f
fetch model.safetensors d44679bed94faf1e8baa4edf7a4d0bc57c5664d8094afb7688feed98fc0f279b

llama="$work/llama.cpp"
if [ ! -d "$llama/.git" ]; then
    git clone --quiet --depth 1 --branch b4846 https://github.com/azooKey/llama.cpp "$llama"
fi
if [ "$(git -C "$llama" rev-parse HEAD)" != 10131b23ee0dbd9d03dfc618cec9fe3402919277 ]; then
    echo "llama.cpp が b4846 ではありません: $llama" >&2
    exit 1
fi

failed() {
    echo "$1に失敗しました。$2 を見てください" >&2
    exit 1
}

venv="$work/venv"
if ! "$venv/bin/python" -c "import torch, transformers, sentencepiece" 2> /dev/null; then
    python3.12 -m venv "$venv"
    "$venv/bin/pip" install --quiet -r "$llama/requirements/requirements-convert_hf_to_gguf.txt"
fi

# In single precision, as the weights are, then quantized to Q5_K_M as the zenz models are
f32="$work/genmai-f32.gguf"
"$venv/bin/python" "$llama/convert_hf_to_gguf.py" "$model" --outtype f32 --model-name genmai --outfile "$f32" \
    > "$work/convert.log" 2>&1 || failed "GGUF への変換" "$work/convert.log"
{
    cmake -S "$llama" -B "$work/build" -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=OFF -DLLAMA_CURL=OFF \
        -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF && cmake --build "$work/build" --target llama-quantize -j
} > "$work/cmake.log" 2>&1 || failed "llama-quantize のビルド" "$work/cmake.log"
"$work/build/bin/llama-quantize" --override-kv zenzai.attention.precision=str:f32 \
    "$f32" "$target" Q5_K_M > "$work/quantize.log" 2>&1 || failed "量子化" "$work/quantize.log"

actual="$(sha256 "$target")"
if [ "$pinned" = true ] && [ "$actual" != "$expected" ]; then
    echo "作りましたが、評価に使ったものと SHA-256 が違います: $target ($actual)" >&2
else
    echo "作りました: $target ($actual)"
fi
