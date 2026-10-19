# 補助辞書（supplement）

変換エンジンの内蔵辞書にない語を補う辞書です。`supplement.louds`、`supplement.loudschars2`、`supplement<n>.loudstxt3` が内蔵辞書と同じ形式の本体で、変換時に内蔵辞書と並べて引かれます（変換器フォークの `ConvertRequestOptions.supplementaryDictionaryURL`）。

## 出どころ

[Mozc](https://github.com/google/mozc) のオープンソース辞書（`src/data/dictionary_oss`）の名詞のうち、内蔵辞書に同じ表記と読みの組がないものです。値（出やすさ）は、両方の辞書にある語で Mozc のコストと内蔵辞書の値を直線で結んで決めています。動詞や形容詞など活用する語、数、接尾語は入れていません。

`Tools/build_supplement_dictionary.sh` で作り直せます。Mozc の辞書を取得し、変換器の CLI で内蔵辞書の語彙を書き出し、差分を選んで LOUDS 形式に組みます。

## ライセンス

- Mozc 本体は BSD 3-Clause License です（`LICENSE-mozc.txt`）。
- 辞書の語彙の大半は IPAdic（奈良先端科学技術大学院大学）に由来し、固有名詞の一部は沖縄辞書（o-dic）に由来します。IPAdic のライセンスは、複製や改変物に著作権表示と免責の段落を含めることを求めています。これらの表示は Mozc の辞書の README をそのまま収めた `LICENSE-mozc-dictionary.txt` にあり、この辞書を配る場合はこのファイルを一緒に配ってください。
