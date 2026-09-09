#!/usr/bin/env python3
"""Annotate the assembly sources with a per-line cycle bar chart.

Input:  build/cleo.dbg   (ld65 --dbgfile: line -> span -> segment offset)
        build/profile.json {"cycles": {"<pc>": cycles, ...}, "count": {...}}  from tools/profile.mjs
Output: profile/<file>.s  : each source line gets an aligned comment on the right with
        up to 20 '|' characters proportional to the cycles spent on the code generated
        by that line (20 = the hottest line in the program).

Run from beeb/:  python3 tools/annotate_profile.py [--inplace]
"""
import os
import re
import sys
import json
import math
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..'))
DBG = os.path.join(ROOT, 'build', 'cleo.dbg')
PROF = os.path.join(ROOT, 'build', 'profile.json')
OUTDIR = os.path.join(ROOT, 'profile')
COL = 56          # column where the bar comment starts (or line length + 2 if longer)
MAXBAR = 20

def parse_dbg(path):
    files, segs, spans, lines = {}, {}, {}, []
    for raw in open(path):
        kind, _, rest = raw.strip().partition('\t')
        if not rest:
            continue
        kv = {}
        for item in rest.split(','):
            k, _, v = item.partition('=')
            kv[k] = v.strip('"')
        if kind == 'file':
            files[int(kv['id'])] = kv['name']
        elif kind == 'seg':
            segs[int(kv['id'])] = int(kv['start'], 16)
        elif kind == 'span':
            spans[int(kv['id'])] = (int(kv['seg']), int(kv['start']), int(kv['size']))
        elif kind == 'line':
            if 'span' not in kv:
                continue
            for sp in kv['span'].split('+'):
                lines.append((int(kv['file']), int(kv['line']), int(sp)))
    return files, segs, spans, lines

def main():
    inplace = '--inplace' in sys.argv
    files, segs, spans, lines = parse_dbg(DBG)
    prof = json.load(open(PROF))
    cyc = {int(k): v for k, v in prof['cycles'].items()}
    # cycles per (file, line): sum of cycles of every pc inside the line's spans
    per_line = defaultdict(int)
    for fid, ln, sp in lines:
        seg, start, size = spans[sp]
        base = segs.get(seg)
        if base is None or seg not in segs:
            continue
        a0 = base + start
        c = 0
        for a in range(a0, a0 + size):
            c += cyc.get(a, 0)
        if c:
            per_line[(files[fid], ln)] += c
    if not per_line:
        print('no cycles attributed; is build/profile.json from the current build?')
        return
    mx = max(per_line.values())
    total = sum(cyc.values())
    print('hottest line: %d cycles; total profiled: %d' % (mx, total))
    os.makedirs(OUTDIR, exist_ok=True)
    all_files = sorted(set(files.values()) | {f for f, _ in per_line})
    for fname in all_files:
        src = os.path.join(ROOT, fname)
        if not os.path.exists(src) or not fname.endswith('.s'):
            continue
        out_lines = []
        for i, text in enumerate(open(src).read().split('\n'), 1):
            c = per_line.get((fname, i), 0)
            if c:
                n = max(1, int(round(MAXBAR * c / mx)))
                pad = max(COL, len(text.rstrip()) + 2)
                text = text.rstrip().ljust(pad) + '; ' + '|' * n
            out_lines.append(text)
        dst = src if inplace else os.path.join(OUTDIR, os.path.basename(fname))
        open(dst, 'w').write('\n'.join(out_lines))
        hot = sorted(((c, ln) for (f, ln), c in per_line.items() if f == fname), reverse=True)[:5]
        print('%s -> %s  (top lines: %s)' % (fname, dst, ', '.join('%d:%.1f%%' % (ln, 100.0 * c / total) for c, ln in hot)))

if __name__ == '__main__':
    main()
