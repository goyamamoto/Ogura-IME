#!/bin/zsh
# Builds the supplementary dictionary (Ogura/Resources/Dictionary/supplement): the nouns of the mozc dictionary
# (BSD-3-Clause, https://github.com/google/mozc) that the converter's bundled dictionary lacks, in the converter's
# LOUDS format. Their values come from a line fitted on the words both dictionaries have.
#
# Usage: Tools/build_supplement_dictionary.sh <converter checkout> <work dir> [<out dir>]
#   <converter checkout>  a checkout of the converter fork (its CLI is built here; it needs `dict read` and `dict supplement`)
#   <work dir>            where the downloads and intermediate files go (the downloaded files are untrusted data: keep
#                         this directory for nothing else)
#   <out dir>             where supplement.louds and the files with it are written (default: Ogura/Resources/Dictionary/supplement)
set -e
converter=$1
work=$2
out=${3:-$(dirname $0)/../Ogura/Resources/Dictionary/supplement}
tools=$(dirname $0)
dictionary=$converter/Sources/KanaKanjiConverterModuleWithDefaultDictionary/azooKey_dictionary_storage/Dictionary
mkdir -p $work/build
# The mozc dictionary, pinned to one revision of the repository (MOZC_REVISION overrides it). A download is kept only
# when it completed with success, and the files are fetched again for another revision
revision=${MOZC_REVISION:-c4b2aef7c65e61be394bacadaec200eb5b97f91c}
base=https://raw.githubusercontent.com/google/mozc/$revision/src/data/dictionary_oss
if [[ "$(cat $work/mozc/REVISION 2> /dev/null)" != "$revision" ]]; then
  rm -rf $work/mozc
fi
mkdir -p $work/mozc
fetch() {
  [[ -s $2 ]] && return
  curl -sS -f -L -o $2.part $1
  mv $2.part $2
}
for i in 00 01 02 03 04 05 06 07 08 09; do
  fetch $base/dictionary$i.txt $work/mozc/dictionary$i.txt
done
fetch $base/id.def $work/mozc/id.def
fetch https://raw.githubusercontent.com/google/mozc/$revision/LICENSE $work/mozc/LICENSE
# The dictionary's own notice: most of its words come from IPAdic (NAIST) and the Okinawa dictionary, whose licenses it
# carries and which must go with any copy
fetch $base/README.txt $work/mozc/README.txt
echo $revision > $work/mozc/REVISION
# The converter's CLI
swift build -c release --product CliTool --package-path $converter --build-path $work/build
cli=$work/build/release/CliTool
# What the bundled dictionary has, the words to add, and the LOUDS files
python3 -I $tools/supplement/dump_vocab.py $cli $dictionary $work/bundled_vocab.tsv
python3 -I $tools/supplement/mozc_supplement.py $work/mozc $work/bundled_vocab.tsv $work/supplement.tsv
mkdir -p $out
$cli dict supplement $work/supplement.tsv --out $out --char_id $dictionary/louds/charID.chid
cp $work/mozc/LICENSE $out/LICENSE-mozc.txt
cp $work/mozc/README.txt $out/LICENSE-mozc-dictionary.txt
echo "built $out"
