#!/bin/sh
# Move settings and learning data from azooKey on macOS (or an older Ogura that used a shared container) to Ogura.
# Run this once, in the account that uses Ogura, after you install Ogura and select it
# as an input source at least once (so that its container exists).
set -eu

bundle_id="org.if0.inputmethod.ogura"
container="$HOME/Library/Containers/$bundle_id/Data"
new_data="$container/Library/Application Support/Ogura"
new_prefs="$container/Library/Preferences/$bundle_id"   # defaults also accepts a file path as the domain
new_prefix="org.if0.inputmethod.ogura.preference."

azookey_group="group.dev.ensan.inputmethod.azooKeyMac"
azookey_data="$HOME/Library/Group Containers/$azookey_group/Library/Application Support/azooKey"
azookey_prefs="$HOME/Library/Preferences/$azookey_group.plist"
azookey_prefix="dev.ensan.inputmethod.azooKeyMac.preference."

old_ogura_group="group.org.if0.inputmethod.ogura"
old_ogura_data="$HOME/Library/Group Containers/$old_ogura_group/Library/Application Support/Ogura"
old_ogura_prefs="$HOME/Library/Preferences/$old_ogura_group.plist"

if [ ! -d "$container" ]; then
    echo "Ogura のコンテナがまだ作成されていません: $container"
    echo "先に Ogura を入力ソースに追加して一度選択してから、もう一度実行してください。"
    exit 1
fi

# Stop the running Ogura so it does not overwrite the data with old data (it restarts when you select the input source again)
pkill -x Ogura 2>/dev/null || true

# Learning data and user dictionary (prefer the older Ogura's shared container; otherwise use azooKey's)
if [ -d "$old_ogura_data" ]; then
    src_data="$old_ogura_data"; src_prefs="$old_ogura_prefs"; src_prefix="$new_prefix"
elif [ -d "$azookey_data" ]; then
    src_data="$azookey_data"; src_prefs="$azookey_prefs"; src_prefix="$azookey_prefix"
else
    src_data=""; src_prefs="$azookey_prefs"; src_prefix="$azookey_prefix"
fi

if [ -n "$src_data" ]; then
    if [ -e "$new_data" ]; then
        echo "skip: $new_data already exists"
    else
        mkdir -p "$(dirname "$new_data")"
        cp -R "$src_data" "$new_data"
        echo "copied learning data: $src_data -> $new_data"
    fi
else
    echo "no learning data to migrate"
fi

# Settings (replace the key prefix and write them to the preferences file in the container)
if [ -f "$src_prefs" ]; then
    mkdir -p "$(dirname "$new_prefs")"
    python3 - "$src_prefs" "$src_prefix" "$new_prefix" <<'PY' | defaults import "$new_prefs" -
import plistlib, sys
path, old_prefix, new_prefix = sys.argv[1:4]
with open(path, "rb") as f:
    prefs = plistlib.load(f)
migrated = {
    (new_prefix + key[len(old_prefix):] if key.startswith(old_prefix) else key): value
    for key, value in prefs.items()
    if "PromptHistory" not in key and "OpenAi" not in key
}
sys.stdout.buffer.write(plistlib.dumps(migrated))
PY
    echo "imported preferences: $src_prefs -> $new_prefs.plist"
else
    echo "no preferences to migrate"
fi

echo "完了しました。入力ソースで Ogura を選び直してください。"
echo "不要になった共有コンテナは削除して構いません: $HOME/Library/Group Containers/$old_ogura_group"
