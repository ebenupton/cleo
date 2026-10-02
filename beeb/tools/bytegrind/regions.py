#!/usr/bin/env python3
"""The byte grind's regions: every code file of both machines cut into regions of at
most MAXLINES lines (at a global label or a blank line where one is near the limit),
each line annotated with its cycles and executions a frame on the Model B and the
Master from test/linecyc.mjs's profiles (0 = not run in play: menus, loads, cold
paths).  A macro's body line ("file:a > macros.s:b") counts at both its call and its
definition.
    python3 tools/bytegrind/regions.py <lc_modelb.json> <lc_master.json> <outdir> [maxlines=110]"""
import json, os, re, sys
from collections import defaultdict
BEEB = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
lb, lm, out = sys.argv[1:4]
MAXL = int(sys.argv[4]) if len(sys.argv) > 4 else 110
FILES = ['src/logic.s', 'src/game.s', 'src/menu.s', 'beebgame/src/engine/frame.s', 'beebgame/src/engine/tiles.s',
         'beebgame/src/engine/kernel.s', 'beebgame/src/engine/sprloops.s', 'beebgame/src/engine/gather.s',
         'beebgame/src/engine/macros.s', 'beebgame/src/engine/menus.s', 'beebgame/src/engine/lowram.s',
         'beebgame/src/engine/boot.s', 'beebgame/src/engine.s', 'beebgame/src/ldprog.s', 'beebgame/src/loader.s',
         'beebgame/src/disc.s', 'beebgame/src/low.s', 'beebgame/src/mirror.s', 'beebgame/src/init.s']
cost = defaultdict(lambda: [0.0, 0.0, 0.0, 0.0])
for k, path in enumerate((lb, lm)):
    for loc, r in json.load(open(path))['lines'].items():
        for part in loc.split(' > '):
            m = re.match(r'(.+):(\d+)$', part)
            if m:
                f = m.group(1)
                f = next((c for c in (f, 'src/' + f, 'beebgame/src/' + f, 'beebgame/src/engine/' + f) if c in FILES), f)
                c = cost[(f, int(m.group(2)))]
                c[2 * k] += r['cy']; c[2 * k + 1] += r['ex']
os.makedirs(out, exist_ok=True)
CODE = re.compile(r'^\s+[a-z]{3}\b|^\s+\.(byte|word|res|lobytes|hibytes)|^[A-Za-z_@:]')
index = []
for f in FILES:
    src = open(os.path.join(BEEB, f)).read().split('\n')
    n = len(src)
    cuts, a = [], 1
    while a <= n:
        b = min(n, a + MAXL - 1)
        if b < n:   # back off to a global label (or a blank line) in the last third
            for ln in range(b, a + 2 * MAXL // 3, -1):
                if re.match(r'^[A-Za-z_][A-Za-z0-9_]*:', src[ln - 1]):
                    b = ln - 1; break
            else:
                for ln in range(b, a + 2 * MAXL // 3, -1):
                    if not src[ln - 1].strip():
                        b = ln; break
        cuts.append((a, b)); a = b + 1
    for (a, b) in cuts:
        if not any(CODE.match(src[ln - 1]) for ln in range(a, b + 1)):
            continue
        hot = sum(cost[(f, ln)][0] + cost[(f, ln)][2] for ln in range(a, b + 1))
        rid = 'b%03d' % len(index)
        body = ['# region %s: %s lines %d-%d -- %.0f cycles a frame in play (Model B + Master)' % (rid, f, a, b, hot),
                '# columns: line | Model B cycles/frame, executions/frame | Master cycles/frame, executions/frame | source',
                '# (blank columns: never ran in the profile -- menus, loads, level starts or rare paths; NOT proof the line is dead)', '']
        for ln in range(a, b + 1):
            c = cost.get((f, ln))
            ann = '%7.1f %7.1f | %7.1f %7.1f' % tuple(c) if c and (c[1] or c[3]) else ' ' * 15 + ' | ' + ' ' * 15
            body.append('%5d | %s | %s' % (ln, ann, src[ln - 1]))
        p = os.path.join(out, rid + '.txt')
        open(p, 'w').write('\n'.join(body) + '\n')
        index.append(dict(id=rid, file=f, lo=a, hi=b, hot=round(hot, 1), path=os.path.abspath(p)))
json.dump(index, open(os.path.join(out, 'index.json'), 'w'), indent=1)
print('%d regions' % len(index))
from collections import Counter
print(Counter(r['file'] for r in index))
