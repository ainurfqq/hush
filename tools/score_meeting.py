#!/usr/bin/env python3
"""Scores a processed Hush meeting against a fixture.
Usage: score_meeting.py <fixture.tsv> <fixture.ref.tsv> <meeting.json>
Prints: speaker accuracy by duration (best label mapping), word error rate (WER) on normalised text,
and the share of reference turns whose transcript is in the right language (catches translation)."""
import sys, json, re, itertools, unicodedata
tsv, ref_tsv, mj = sys.argv[1:4]
ref_text = [l.rstrip("\n").split("\t", 1) for l in open(tsv) if l.strip()]
ref = [l.split() for l in open(ref_tsv) if l.strip()]
ref = [(float(a), float(b), c) for a, b, c in ref]
m = json.load(open(mj))
segs = m["segments"]
# speaker accuracy
step = 0.01
def lab(t):
    for s in segs:
        if s["start"] <= t < s["end"]: return s["speaker"]
    return None
pairs = {}; total = 0
for a, b, spk in ref:
    t = a
    while t < b:
        total += step; k = (spk, lab(t)); pairs[k] = pairs.get(k, 0) + step; t += step
rl = sorted({r[2] for r in ref}); hl = sorted({s["speaker"] for s in segs})
best, bm = 0, {}
for perm in itertools.permutations(hl + [None] * len(rl), len(rl)):
    mp = dict(zip(rl, perm)); sc = sum(pairs.get((r, mp[r]), 0) for r in rl if mp[r])
    if sc > best: best, bm = sc, mp
print(f"speaker accuracy: {100*best/total:.1f}% of {total:.0f}s reference speech (mapping {bm}, {len(hl)} hyp speakers)")
# WER
def norm(s):
    s = unicodedata.normalize("NFKC", s.lower())
    s = re.sub(r"[^\w\s]", " ", s)
    return s.split()
R = norm(" ".join(t for _, t in ref_text)); H = norm(" ".join(s["text"] for s in sorted(segs, key=lambda x: x["start"])))
d = list(range(len(H) + 1))
for i in range(1, len(R) + 1):
    prev, d[0] = d[0], i
    for j in range(1, len(H) + 1):
        cur = d[j]; d[j] = min(d[j] + 1, d[j-1] + 1, prev + (R[i-1] != H[j-1])); prev = cur
print(f"WER: {100*d[len(H)]/len(R):.1f}% ({d[len(H)]} edits / {len(R)} reference words; numbers written as digits count as errors)")
# language per turn: speaker A lines are Indonesian, B lines English in meeting1
EN = {"the","and","is","we","you","that","to","of","for","our","this","with","can","will","be","it","a","in","on","what","how"}
ID = {"yang","dan","kita","untuk","di","ke","ini","itu","bisa","akan","saya","dari","dengan","kami","juga","sudah","tidak","ada","jadi","nanti"}
def lang(words):
    e = sum(w in EN for w in words); i = sum(w in ID for w in words)
    return "en" if e > i else "id" if i > e else "?"
ok = n = 0
for (a, b, spk), (_, text) in zip(ref, ref_text):
    want = lang(norm(text))
    got_words = [w for s in segs if s["start"] < b and a < s["end"] for w in norm(s["text"])]
    if want == "?" or not got_words: continue
    n += 1; ok += lang(got_words) == want
print(f"language kept (no translation): {ok}/{n} turns")
