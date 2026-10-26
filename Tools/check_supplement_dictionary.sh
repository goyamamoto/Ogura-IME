#!/bin/bash
# Checks that the supplementary dictionary in the tree is the one this version is built with: every file listed in
# Ogura/Resources/Dictionary/supplement/supplement.sha256 is there with that SHA-256, and there is no dictionary file
# besides them.
#
# The dictionary is built, not committed (Tools/build_supplement_dictionary.sh; README.md in its folder), so a new
# worktree does not have it, and the app converts without it and says nothing. The list is committed: it says what the
# built dictionary must be.
#
# Usage: Tools/check_supplement_dictionary.sh [--write] [<folder>]
#   <folder>  where the dictionary is (default: Ogura/Resources/Dictionary/supplement)
#   --write   write the list from the dictionary in the folder (after building it from another revision of the
#             mozc dictionary or of the converter, on purpose): commit the list with the change that causes it
# Exit: 0 the dictionary is the listed one · 1 it differs (a file changed, missing or too many) · 2 it is not there
set -uo pipefail
cd "$(dirname "$0")/.."

WRITE=false
FOLDER="Ogura/Resources/Dictionary/supplement"
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --write) WRITE=true ;;
        *) FOLDER="$1" ;;
    esac
    shift
done
LIST="$(pwd)/Ogura/Resources/Dictionary/supplement/supplement.sha256"

# The dictionary's files: the LOUDS tree, its characters, and the entries in numbered files
files() {
    ls "${FOLDER}" 2>/dev/null | grep -E '^supplement[0-9]*\.(louds|loudschars2|loudstxt3)$' | LC_ALL=C sort
}

if [ "$WRITE" = true ]; then
    if [ ! -s "${FOLDER}/supplement.louds" ]; then
        echo "no dictionary in ${FOLDER}: nothing to list"
        exit 2
    fi
    NAMES=()
    while IFS= read -r name; do NAMES+=("$name"); done < <(files)
    (cd "${FOLDER}" && shasum -a 256 "${NAMES[@]}") > "${LIST}.new" || { rm -f "${LIST}.new"; echo "could not read the dictionary"; exit 1; }
    mv "${LIST}.new" "${LIST}"
    echo "wrote ${LIST}: ${#NAMES[@]} files"
    exit 0
fi

if [ ! -s "${FOLDER}/supplement.louds" ]; then
    echo "補助辞書がありません（${FOLDER}/supplement.louds）。Tools/build_supplement_dictionary.sh で作ってください。"
    exit 2
fi
if [ ! -s "${LIST}" ]; then
    echo "補助辞書の一覧（${LIST}）がありません。"
    exit 1
fi
PROBLEMS="$(cd "${FOLDER}" && shasum -a 256 -c "${LIST}" 2>&1 | grep -v ': OK$')"
EXTRA="$(comm -23 <(files) <(sed -E 's/^[0-9a-f]{64}  //' "${LIST}" | LC_ALL=C sort))"
if [ -n "${PROBLEMS}" ] || [ -n "${EXTRA}" ]; then
    echo "補助辞書（${FOLDER}）が、この版の一覧（${LIST}）と違います。"
    [ -n "${PROBLEMS}" ] && echo "${PROBLEMS}" | head -5
    [ -n "${EXTRA}" ] && echo "一覧に無いファイル: $(echo "${EXTRA}" | head -5 | tr '\n' ' ')"
    echo "Tools/build_supplement_dictionary.sh で作り直してください。mozc の辞書や変換器の版を変えたためなら、作り直した後に"
    echo "Tools/check_supplement_dictionary.sh --write で一覧を書き直し、その変更と一緒にコミットしてください。"
    exit 1
fi
echo "補助辞書は一覧と同じです（$(wc -l < "${LIST}" | tr -d ' ') ファイル）。"
