#!/usr/bin/env python3
"""Per-line cycle counts for a range of source lines.
   python3 tools/hotlines.py src/logic.s 900 1100 [build/profile.json]  -> 'cycles  count  source'"""
import sys, json, os
sys.path.insert(0, os.path.dirname(__file__))
from annotate_profile import parse_dbg, DBG, PROF
from collections import defaultdict
fname, lo, hi = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
prof = json.load(open(sys.argv[4] if len(sys.argv) > 4 else PROF))
cyc = {int(k): v for k, v in prof['cycles'].items()}; cnt = {int(k): v for k, v in prof['count'].items()}
files, segs, spans, lines = parse_dbg(DBG)
pl = defaultdict(int); pc_ = defaultdict(int)
for fid, ln, sp in lines:
    if files[fid] != fname or not (lo <= ln <= hi): continue
    seg, start, size = spans[sp]
    if seg not in segs: continue
    a0 = segs[seg] + start
    first = True
    for a in range(a0, a0 + size):
        pl[ln] += cyc.get(a, 0)
        if a in cnt and first: pc_[ln] = max(pc_[ln], cnt[a]); first = False
src = open(fname).read().split('\n')
tot = 0
for ln in range(lo, hi + 1):
    c = pl.get(ln, 0); tot += c
    print('%8d %7d  %s' % (c, pc_.get(ln, 0), src[ln - 1]) if c else ' ' * 17 + '  ' + src[ln - 1])
print('total %d cycles (%.2f%% of profile)' % (tot, 100.0 * tot / prof['total']))
