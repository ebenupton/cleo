#!/usr/bin/env python3
"""Cycles and executions per source line, per frame, from the current profile.

    python3 tools/linecost.py [file.s:lo-hi ...]     ranges, or the top 25 lines
    python3 tools/linecost.py --write               -> build/linecost.json, which
                                                       windows.py and proposals.py read

Exists because the catalogue's per-window exec count is an upper bound, not the number
that matters.  `pagelogic` executes 54 times a frame and only 3 of those are the TOBANK
entries a proposal to inline it would speed up; ranked on the window, it looked like the
fourth most valuable change in the corpus, and it is worth 38 cycles a frame.
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from annotate_profile import parse_dbg

prof = json.load(open('build/profile.json'))
cyc = {int(k): v for k, v in prof['cycles'].items()}
cnt = {int(k): v for k, v in prof['count'].items()}
files, segs, spans, lines = parse_dbg('build/cleo.dbg')
per = {}
for fid, ln, sp in lines:
    if sp not in spans: continue
    seg, start, size = spans[sp]
    if seg not in segs: continue
    a0 = segs[seg] + start
    k = f'{os.path.basename(files[fid])}:{ln}'
    c = sum(cyc.get(a, 0) for a in range(a0, a0 + size))
    x = max((cnt.get(a, 0) for a in range(a0, a0 + size)), default=0)
    o = per.setdefault(k, [0, 0]); o[0] += c; o[1] = max(o[1], x)
import re as _re
F = max((cnt.get(int(m.group(1), 16), 0) for m in
         (_re.match(r'^al ([0-9A-F]+) \.render_frame$', l) for l in open('build/labels.txt'))
         if m), default=1)
def show(k):
    c, x = per.get(k, (0, 0))
    src = open('src/' + k.split(':')[0]).read().split('\n')[int(k.split(':')[1]) - 1]
    print(f'  {c/F:9.1f} cy/frm {x/F:8.2f} x/frm  {k:18} {src.strip()[:60]}')
if '--write' in sys.argv:
    json.dump({k: c for k, (c, x) in per.items()}, open('build/linecost.json', 'w'))
    print(f'build/linecost.json: {len(per)} lines, {F} rendered frames in the profile')
elif len(sys.argv) > 1:
    for a in sys.argv[1:]:
        f, r = a.split(':'); lo, hi = (r.split('-') + [r.split('-')[0]])[:2]
        tc = sum(per.get(f'{f}:{i}', (0, 0))[0] for i in range(int(lo), int(hi) + 1))
        print(f'{a}: {tc/F:.1f} cy/frame total')
        for i in range(int(lo), int(hi) + 1):
            if per.get(f'{f}:{i}', (0, 0))[1]: show(f'{f}:{i}')
else:
    for k, (c, x) in sorted(per.items(), key=lambda kv: -kv[1][0])[:25]: show(k)
