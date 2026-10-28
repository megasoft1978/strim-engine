#!/usr/bin/env python3
# usage: agg.py RAWDIR   -> per-cell values per session, medians A vs B, delta %, peak footprint, swap growth
import re,glob,sys,statistics as st,os
raw=sys.argv[1]; cells={}; mem={}
for d in sorted(glob.glob(raw+'/srv-*-[AB]')):
    arm=d[-1]; sess=os.path.basename(d)
    for f in glob.glob(d+'/strim/pass1/*/summary.md'):
        for l in open(f):
            m=re.match(r'\| (W\d) \| (\S+) \| (\S+) \| ([\d.]+) cv',l)
            if m: cells.setdefault((m[2],m[3]),{'A':[],'B':[]})[arm].append(float(m[4]))
    csv=d+'/strim/pass1/watch.csv'
    if os.path.exists(csv):
        rows=[l.split(',') for l in open(csv) if not l.startswith('#')]
        fp=max(int(r[4]) for r in rows); sw=[int(r[2]) for r in rows]
        mem.setdefault(arm,[]).append((fp,max(sw)-sw[0]))
print('| cell | A (wired off) | B (wired on) | median A | median B | delta |'); print('|---|---|---|---|---|---|')
for k in sorted(cells):
    a,b=cells[k]['A'],cells[k]['B']
    if not a or not b: continue
    ma,mb=st.median(a),st.median(b); worse_is_up=k[1].startswith('ttft')
    d=(mb-ma)/ma*100
    print(f'| {k[0]} {k[1]} | {" / ".join(map(str,a))} | {" / ".join(map(str,b))} | {ma:.2f} | {mb:.2f} | {d:+.1f}% |')
for arm in 'AB': print(arm,'peak footprint MB, swap growth MB per session:',mem.get(arm))
