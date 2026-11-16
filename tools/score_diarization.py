#!/usr/bin/env python3
"""Duration-weighted speaker accuracy: share of reference speech time whose hypothesis
label (after the best one-to-one label mapping) equals the reference speaker.
ref: TSV start<TAB>end<TAB>speaker. hyp: same format. Usage: score ref.tsv hyp.tsv"""
import sys, itertools
def load(p):
    out=[]
    for line in open(p):
        parts=line.split()
        if len(parts)>=3: out.append((float(parts[0]),float(parts[1]),parts[2]))
    return out
ref, hyp = load(sys.argv[1]), load(sys.argv[2])
step=0.01
def label_at(segs,t):
    for s,e,l in segs:
        if s<=t<e: return l
    return None
rl=sorted({l for *_,l in ref}); hl=sorted({l for *_,l in hyp})
pairs={}; total=0.0
for s,e,l in ref:
    t=s
    while t<e:
        total+=step; h=label_at(hyp,t)
        pairs[(l,h)]=pairs.get((l,h),0)+step; t+=step
best=0; bestmap={}
for perm in itertools.permutations(hl+[None]*len(rl), len(rl)):
    m=dict(zip(rl,perm)); sc=sum(pairs.get((r,m[r]),0) for r in rl if m[r] is not None)
    if sc>best: best, bestmap = sc, m
print(f"reference speech: {total:.1f}s  correctly labelled: {best:.1f}s  accuracy: {100*best/total:.1f}%  mapping: {bestmap}  hyp speakers: {len(hl)}")
