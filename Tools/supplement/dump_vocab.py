"""Writes every entry of the converter's bundled dictionary (ruby, word, value, lcid, rcid, mid) with the converter's
CLI, one shard (first character) at a time. Usage: dump_vocab.py <CliTool> <Dictionary dir> <out.tsv>"""
import os, re, subprocess, sys

cli, dictionary, out = sys.argv[1:4]
louds = f"{dictionary}/louds"
shards = sorted({name[:-6] for name in os.listdir(louds) if name.endswith(".louds")})
entry = re.compile(r"Ruby: (\S+) Word: (\S+) Value: (\S+) CID: \((\d+), (\d+)\) MID: (\d+)")
total = 0
with open(out, "w", encoding="utf-8") as o:
    for shard in shards:
        match = re.fullmatch(r"\[([0-9A-F]+)\]", shard)
        character = chr(int(match.group(1), 16)) if match else shard
        if character in ("user", "memory"):
            continue
        result = subprocess.run([cli, "dict", "read", character, "-d", dictionary, "--ruby", ".*"], capture_output=True, text=True)
        count = 0
        for line in result.stdout.splitlines():
            found = entry.search(re.sub(r"\x1b\[[0-9;]*m", "", line))
            if found:
                o.write("\t".join(found.groups()) + "\n")
                count += 1
        total += count
        print(f"{shard} {character!r}: {count}", flush=True)
print(f"{total} entries")
