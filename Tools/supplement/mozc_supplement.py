"""Picks the nouns of the mozc dictionary that the converter's bundled dictionary lacks, as entries for a supplementary
dictionary: ruby (katakana) <TAB> word <TAB> cid <TAB> mid <TAB> value. The value comes from a line fitted on the words
both dictionaries have (mozc cost against the bundled value).
Usage: mozc_supplement.py <mozc dir> <bundled vocab.tsv (dump_vocab.py)> <out.tsv> [--report n]"""
import sys
from collections import defaultdict

mozc_dir, vocab_file, out = sys.argv[1:4]
report = int(sys.argv[sys.argv.index("--report") + 1]) if "--report" in sys.argv else 0

# mozc part-of-speech ids (id.def) to the converter's cids and mids
pos_names = {}
for line in open(f"{mozc_dir}/id.def", encoding="utf-8"):
    number, name = line.rstrip("\n").split(" ", 1)
    pos_names[int(number)] = name
CID = {"一般名詞": 1285, "固有名詞": 1288, "人名一般": 1289, "人名姓": 1290, "人名名": 1291, "固有名詞組織": 1292, "地名一般": 1293}
MID_一般 = 501  # MIDData.一般.mid


def classify(name):
    """The converter's cid for a mozc noun class, or None for words not taken"""
    parts = name.split(",")
    if parts[0] != "名詞":
        return None
    kind = parts[1]
    if kind in ("一般", "サ変接続", "形容動詞語幹", "副詞可能", "ナイ形容詞語幹"):
        return CID["一般名詞"]
    if kind == "固有名詞":
        sub = parts[2] if len(parts) > 2 else "*"
        if sub == "人名":
            detail = parts[3] if len(parts) > 3 else "*"
            return CID["人名姓"] if detail == "姓" else CID["人名名"] if detail == "名" else CID["人名一般"]
        if sub == "地域":
            return CID["地名一般"]
        if sub == "組織":
            return CID["固有名詞組織"]
        return CID["固有名詞"]
    # 数, 接尾, 非自立, 代名詞, 特殊, 動詞非自立的, 引用文字列, 接続詞的, 副詞可能 handled above: not taken
    return None


katakana = lambda s: "".join(chr(ord(c) + 0x60) if "ぁ" <= c <= "ゖ" else c for c in s)
is_kana = lambda s: all(("ぁ" <= c <= "ゖ") or ("ァ" <= c <= "ヺ") or c in "ーゝゞヽヾ" for c in s)

# The bundled dictionary: (ruby, word) -> best value, and readings known
bundled = {}
for line in open(vocab_file, encoding="utf-8"):
    ruby, word, value = line.rstrip("\n").split("\t")[:3]
    key = (ruby, word)
    value = float(value)
    if key not in bundled or value > bundled[key]:
        bundled[key] = value

# mozc: (ruby, word) -> (min cost, cid)
candidates = {}
seen_pos = defaultdict(int)
total = 0
for i in range(10):
    for line in open(f"{mozc_dir}/dictionary{i:02d}.txt", encoding="utf-8"):
        fields = line.rstrip("\n").split("\t")
        if len(fields) < 5:
            continue
        reading, lid, rid, cost, word = fields[0], int(fields[1]), int(fields[2]), int(fields[3]), fields[4]
        total += 1
        name = pos_names.get(lid, "")
        cid = classify(name)
        if cid is None:
            continue
        seen_pos[name.split(",")[1]] += 1
        if is_kana(word) or not reading:
            continue
        ruby = katakana(reading)
        key = (ruby, word)
        if key not in candidates or cost < candidates[key][0]:
            candidates[key] = (cost, cid)

# Fit value = a * cost + b on the words in both
xs, ys = [], []
for key, (cost, _) in candidates.items():
    if key in bundled and bundled[key] > -29:
        xs.append(cost)
        ys.append(bundled[key])
n = len(xs)
mean_x, mean_y = sum(xs) / n, sum(ys) / n
a = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys)) / sum((x - mean_x) ** 2 for x in xs)
b = mean_y - a * mean_x
residual = (sum((y - (a * x + b)) ** 2 for x, y in zip(xs, ys)) / n) ** 0.5
print(f"mozc entries {total}; noun candidates {len(candidates)}; in both {n}; value = {a:.6f} * cost + {b:.3f} (residual {residual:.2f})")
print("noun classes taken: " + ", ".join(f"{k} {v}" for k, v in sorted(seen_pos.items(), key=lambda kv: -kv[1])))

count = 0
with open(out, "w", encoding="utf-8") as o:
    for (ruby, word), (cost, cid) in sorted(candidates.items()):
        if (ruby, word) in bundled:
            continue
        value = min(-5.0, a * cost + b)
        # The converter ignores entries near or below its threshold (-17), so they would only take space
        if value < -16.5:
            continue
        o.write(f"{ruby}\t{word}\t{cid}\t{MID_一般}\t{value:.3f}\n")
        count += 1
print(f"supplement entries {count}")
if report:
    import random
    random.seed(1)
    new = [k for k in candidates if k not in bundled]
    for ruby, word in random.sample(new, min(report, len(new))):
        cost, cid = candidates[(ruby, word)]
        print(f"  {word} ({ruby}) cost {cost} cid {cid} value {a * cost + b:.2f}")
