#!/bin/sh
# Download an MLX model for "Continue writing" from Hugging Face into Ogura's model folder.
# Ogura itself never uses the network, so this script (outside the IME) does the download.
#
# Usage:
#   Tools/download_continuation_model.sh                       # default model
#   Tools/download_continuation_model.sh mlx-community/Qwen3.5-2B-4bit
#
# Destination: ~/Library/Containers/org.if0.inputmethod.ogura/Data/Library/Application Support/Ogura/models/<repository name>
set -eu

repo="${1:-mlx-community/LFM2.5-1.2B-JP-202606-OptiQ-4bit}"
name="$(basename "$repo")"
base="${OGURA_MODELS_DIR:-$HOME/Library/Containers/org.if0.inputmethod.ogura/Data/Library/Application Support/Ogura/models}"
dest="$base/$name"
mkdir -p "$dest"

if command -v hf >/dev/null 2>&1; then
    hf download "$repo" --local-dir "$dest"
elif command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli download "$repo" --local-dir "$dest"
else
    # Without a CLI, get the file list from the API and download each file with curl
    files=$(curl -fsSL "https://huggingface.co/api/models/$repo" | python3 -c 'import sys, json
for s in json.load(sys.stdin)["siblings"]:
    print(s["rfilename"])')
    for f in $files; do
        case "$f" in
            *.md|*.gitattributes|LICENSE*|*.png) continue ;;
        esac
        mkdir -p "$dest/$(dirname "$f")"
        echo "$f"
        curl -fL --retry 5 --retry-delay 3 --retry-all-errors --progress-bar "https://huggingface.co/$repo/resolve/main/$f" -o "$dest/$f"
    done
fi

if [ ! -f "$dest/config.json" ]; then
    echo "ダウンロードに失敗しました（config.json が見つかりません）: $dest" >&2
    exit 1
fi
echo "ダウンロードしました: $dest"
echo "Ogura の設定 > 詳細 > 続きを書く で「Mac 内の MLX モデル」を選び、モデル「${name}」を選んでください。"
