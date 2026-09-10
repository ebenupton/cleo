#!/usr/bin/env python3
"""Map addresses to source lines via build/cleo.dbg.  python3 tools/addr2src.py 2250 1556 ..."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from annotate_profile import parse_dbg, DBG
files, segs, spans, lines = parse_dbg(DBG)
amap = {}
for fid, ln, sp in lines:
    seg, start, size = spans[sp]
    if seg not in segs:
        continue
    a0 = segs[seg] + start
    for a in range(a0, a0 + size):
        amap.setdefault(a, (files[fid], ln))
for arg in sys.argv[1:]:
    a = int(arg, 16)
    f, ln = amap.get(a, ('?', 0))
    src = open(f).read().split('\n')[ln - 1] if f != '?' else ''
    print(f"${a:04X}  {f}:{ln}  {src.strip()}")
