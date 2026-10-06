#!/usr/bin/env python3
"""Cut the dataflow grind's windows: the code in 32-instruction pieces, annotated.

Every source file the range analysis annotated (beebgame/tools/dataflow/annotate.py, run on
both machines' builds, for the game's sources and the engine's) is cut into windows of about
WIN instructions (a macro line counts its expansions), a cut moved back to a global label
when there is one in the window's last third, so a window seldom spans two routines.  Each
line of a window carries its measured cycles and executions a frame on both machines
(test/linecyc.mjs's two profiles: blank where it never ran in play), its source, and the
Model B's annotation (the state before it: ranges, flags, liveness); the Master's follows on
a line of its own where it says something else (Master-only code, or other facts).  Windows
are dealt into batches of BATCH consecutive windows of one file.

Output: <outdir>/w<nnn>.txt (a batch each) and <outdir>/index.json (id, file, windows
[lo, hi], hot, path).

Usage (from beeb/):
    python3 tools/dfgrind/windows.py <ann_b> <ann_m> <lc_modelb.json> <lc_master.json> <outdir> [win=32] [batch=4]
<ann_b>/<ann_m>: directories holding the annotated copies (src/... and beebgame/src/...),
the game's and the engine's runs merged.
"""
import json, os, re, sys
from collections import defaultdict
BEEB = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
annb, annm, lb, lm, out = sys.argv[1:6]
WIN = int(sys.argv[6]) if len(sys.argv) > 6 else 32
BATCH = int(sys.argv[7]) if len(sys.argv) > 7 else 4
FILES = ['src/logic.s', 'src/game.s', 'src/menu.s', 'beebgame/src/engine/frame.s', 'beebgame/src/engine/tiles.s',
         'beebgame/src/engine/kernel.s', 'beebgame/src/engine/sprloops.s', 'beebgame/src/engine/gather.s',
         'beebgame/src/engine/scrollv.s', 'beebgame/src/engine/menus.s', 'beebgame/src/engine/lowram.s',
         'beebgame/src/engine/boot.s', 'beebgame/src/mirror.s', 'beebgame/src/init.s', 'beebgame/src/banks.s',
         'beebgame/src/low.s', 'beebgame/src/disc.s']
# DFG_FILES (comma-separated): cut only these
if os.environ.get('DFG_FILES'):
    ONLY = os.environ['DFG_FILES'].split(',')
else:
    ONLY = FILES
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

def ann(d, f):
    """line -> the annotation after ';| ' in the annotated copy, if any"""
    p = os.path.join(d, f)
    a = {}
    if os.path.exists(p):
        for n, t in enumerate(open(p).read().split('\n'), 1):
            i = t.find(';| ')
            if i >= 0:
                a[n] = t[i + 3:]
    return a
BIG = 24
def trim(s):
    """an annotation of a macro line expanding to more than BIG instructions: its first BIG,
    then a note (the rest is the macro's body; read its definition)"""
    parts = s.split(' ‖ ')
    if len(parts) <= BIG:
        return s
    return ' ‖ '.join(parts[:BIG]) + ' ‖ ... (%d more instructions: the macro body, not annotated here)' % (len(parts) - BIG)
def gist(s):
    """an annotation without its disassembly and addresses, for comparing the machines"""
    return re.sub(r'\[[^\]]*\]|\$[0-9A-F]{4}', '', s)

os.makedirs(out, exist_ok=True)
index = []
for f in ONLY:
    src = open(os.path.join(BEEB, f)).read().split('\n')
    A, M = ann(annb, f), ann(annm, f)
    lines = sorted(set(A) | set(M))
    if not lines:
        continue
    nins = {n: min(BIG, (A.get(n) or M.get(n)).count(' ‖ ') + 1) for n in lines}
    A = {n: trim(x) for n, x in A.items()}
    M = {n: trim(x) for n, x in M.items()}
    # windows: runs of instruction lines, about WIN instructions each
    wins, cur, cnt = [], [], 0
    for n in lines:
        cur.append(n); cnt += nins[n]
        if cnt >= WIN:
            # back off to a global label in the last third
            cut = None
            for j in range(len(cur) - 1, len(cur) // 3 * 2, -1):
                if re.match(r'^[A-Za-z_]\w*:', src[cur[j] - 1]):
                    cut = j; break
            if cut:
                wins.append(cur[:cut]); cur = cur[cut:]; cnt = sum(nins[x] for x in cur)
            else:
                wins.append(cur); cur, cnt = [], 0
    if cur:
        wins.append(cur)
    # window line ranges: from after the previous window to its last instruction line
    rng, prev = [], 0
    for w in wins:
        lo = prev + 1 if prev else max(1, w[0] - 6)
        rng.append((lo, w[-1])); prev = w[-1]
    for b in range(0, len(rng), BATCH):
        grp = rng[b:b + BATCH]
        bid = 'w%03d' % len(index)
        body = ['# batch %s: %s, windows %s' % (bid, f, ', '.join('%d-%d' % g for g in grp)),
                '# columns: line | Model B cycles/frame execs/frame | Master cycles/frame execs/frame | source  ;| Model B state before',
                '#          (an "M:" line below: the Master\'s state where it differs, or the Master\'s own code)',
                '# blank cost columns: never ran in the profile (menus, loads, level starts, rare paths) -- not proof of dead code']
        hot = 0.0
        for k, (lo, hi) in enumerate(grp):
            body += ['', '## window %d: lines %d-%d' % (k + 1, lo, hi)]
            for n in range(lo, hi + 1):
                c = cost.get((f, n))
                hot += (c[0] + c[2]) if c else 0
                cs = '%7.1f %6.1f | %7.1f %6.1f' % tuple(c) if c and (c[1] or c[3]) else ' ' * 14 + ' | ' + ' ' * 14
                s = src[n - 1].rstrip()
                if n in A:
                    body.append('%5d | %s | %-90s ;| %s' % (n, cs, s, A[n]))
                    if n in M and gist(M[n]) != gist(A[n]):
                        body.append('      %s M: %s' % (' ' * 33, M[n]))
                elif n in M:
                    body.append('%5d | %s | %-90s ;| M: %s' % (n, cs, s, M[n]))
                else:
                    body.append('%5d | %s | %s' % (n, cs, s))
        p = os.path.join(out, bid + '.txt')
        open(p, 'w').write('\n'.join(body) + '\n')
        index.append(dict(id=bid, file=f, windows=grp, hot=round(hot, 1), path=os.path.abspath(p)))
json.dump(index, open(os.path.join(out, 'index.json'), 'w'), indent=1)
from collections import Counter
print('%d batches, %d windows' % (len(index), sum(len(x['windows']) for x in index)))
print(Counter(r['file'] for r in index))
