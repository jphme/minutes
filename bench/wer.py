#!/usr/bin/env python3
"""Word error rate for minutes-cli JSONL output against FLEURS reference transcripts.

usage: bench/wer.py bench/out/*.jsonl
Reference files are looked up as bench/data/fleurs/<lang>/<lang>.trans.txt, where <lang> is
the second-to-last dot-separated part of the JSONL filename (e.g. parakeet-v3.de_de.jsonl).
Normalization is deliberately simple (lowercase, strip punctuation), so absolute numbers are
higher than published ones; use them to compare models against each other.
"""
import json
import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def norm(text: str) -> list[str]:
    text = unicodedata.normalize("NFC", text.lower())
    text = text.replace("-", " ")
    text = re.sub(r"[^\w\s']", " ", text)
    return text.split()


def edit_distance(ref: list[str], hyp: list[str]) -> int:
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h))
        prev = cur
    return prev[-1]


def main(paths: list[str]) -> None:
    print(f"{'run':40} {'files':>5} {'WER%':>6} {'RTFx':>6}")
    for p in paths:
        path = Path(p)
        lang = path.name.split(".")[-2]
        refs = {}
        for line in (ROOT / "data" / "fleurs" / lang / f"{lang}.trans.txt").read_text().splitlines():
            key, _, txt = line.partition(" ")
            refs[key] = txt
        errors = words = 0
        audio = proc = 0.0
        for line in path.read_text().splitlines():
            row = json.loads(line)
            key = row["file"].rsplit(".", 1)[0]
            ref = norm(refs[key])
            errors += edit_distance(ref, norm(row["text"]))
            words += len(ref)
            audio += row["duration"]
            proc += row["proc"]
        print(f"{path.stem:40} {len(path.read_text().splitlines()):5} {100 * errors / words:6.2f} {audio / proc:6.0f}")


if __name__ == "__main__":
    main(sys.argv[1:])
