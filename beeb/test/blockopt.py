"""The order of ENGCODE's blocks (each `.segment "ENGCODE"` in beebgame's engine/frame.s,
then mirror.s and banks.s), chosen over a profile: every block ends in a jump, a
return or data, so any order works, and all of bank 7's code moves with the kernel's
start.  A block's cost -- the page crossings of its taken branches and of the indexed
reads of its data -- is tabulated for every start, both machines (the Model B's
blocks run on from ENGCODE's start as the Master's do, the total being fixed), then
orders are searched from random starts, with a small charge for every block moved.
drawsprite and draw_dirty stay in order, and the other files' three blocks stay last.  The pads
come after (test/padopt.py).
    for m in master modelb; do PHASEDUMP=build/pd_$m.json node test/cycprof.mjs $m build/cleo.ssd build/$m/labels.txt; done
    python3 test/blockopt.py"""
import json, re, itertools
def labels(m):
    d = {}
    for l in open('build/%s/labels.txt' % m):
        p = l.split(); d[p[2].lstrip('.')] = int(p[1], 16)
    return d
PADS = {}
for l in open('beebgame/src/pads.inc'):
    mm = re.match(r'(PAD[BM]_\w+) = (\d+)', l)
    if mm: PADS[mm.group(1)] = int(mm.group(2))
CH = [('match_sprites', 'MS'), ('addsprite', None), ('draw_sprites', 'SP'), ('erase_old', 'EO'), ('drawsprite', 'DS'),
      ('copy_partial', 'CP'), ('blank_below', None), ('render_frame', None), ('render_core', None), ('mark_dirty', None),
      ('draw_dirty', None), ('mirror_copy', None), ('mirdirty', None), ('lvreset', None)]
_LB = labels('modelb')
CH.sort(key=lambda c: _LB.get(c[0], 1 << 20))     # as they lie now
def extents(m):
    L = labels(m); pre = 'PADB_' if m == 'modelb' else 'PADM_'
    end = [int(x.split()[1], 16) + int(x.split()[3], 16) for x in open('build/%s/map.txt' % m) if x.startswith('ENGCODE ')][0]
    st = []
    for lab, pk in CH:
        if lab not in L: st.append(None); continue
        st.append(L[lab] - (PADS.get(pre + pk, 0) if pk else 0))
    ex = []
    for i, s in enumerate(st):
        if s is None: ex.append((None, 0)); continue
        nx = next((t for t in st[i + 1:] if t is not None), end)
        ex.append((s, nx - s))
    return L, ex, end
def tables(m, ex, L):
    spins = [L[x] for x in ('wait_flip', 'fl_wait') if x in L]
    d = json.load(open('build/pd_%s.json' % m)); F = d['frames']
    def ch(a):
        for i, (s, n) in enumerate(ex):
            if s is not None and s <= a < s + n: return i
        return -1
    f = [[0.0] * 256 for _ in ex]; other = 0.0
    for k, c in d['ev']:
        p = k.split(); c /= F
        if p[0] == 'b':
            a, t = int(p[1]), int(p[2])
            if any(s <= t <= s + 6 and s <= a <= s + 8 for s in spins): continue
            r = ch(a)
            if r < 0 or ch(t) != r:
                other += c * (((a + 2) >> 8) != (t >> 8)); continue
            for s in range(256):
                f[r][s] += c * ((((a + 2 + s) & 0xFFFF) >> 8) != (((t + s) & 0xFFFF) >> 8))
        else:
            pc, b, i = int(p[1]), int(p[2]), int(p[3])
            r = ch(b) if pc >= 0 else -1
            if r < 0:
                other += c * (((b + i) >> 8) != (b >> 8)); continue
            for s in range(256):
                bb = (b + s) & 0xFFFF
                f[r][s] += c * (((bb + i) >> 8) != (bb >> 8))
    return f, other
LB, exB, endB = extents('modelb'); LM, exM, endM = extents('master')
fB, oB = tables('modelb', exB, LB); fM, oM = tables('master', exM, LM)
n = len(CH)
startB = min(s for s, _ in exB if s is not None); startM = min(s for s, _ in exM if s is not None)
def cost(order):
    # the Model B: laid from startB (its total is fixed); the Master from startM
    a, b, cb, cm = startB, startM, 0.0, 0.0
    for i in order:
        s, z = exB[i]
        if s is not None: cb += fB[i][(a - s) % 256]; a += z
        s, z = exM[i]
        if s is not None: cm += fM[i][(b - s) % 256]; b += z
    return cb + oB, cm + oM
cur = list(range(n))
print('now: Model B %.1f, Master %.1f' % cost(cur))
W = 1.0     # the Master's weight
def score(o):
    b, m = cost(o); return b + W * m
best = cur[:]; bs = score(best)
improved = True
while improved:
    improved = False
    for i in range(n):
        for j in range(n):
            if i == j: continue
            o = best[:]; x = o.pop(i); o.insert(j, x)
            s = score(o)
            if s < bs - 1e-6: best, bs, improved = o, s, True
    for i, j in itertools.combinations(range(n), 2):
        o = best[:]; o[i], o[j] = o[j], o[i]
        s = score(o)
        if s < bs - 1e-6: best, bs, improved = o, s, True
#print('best', ['%.1f' % x for x in cost(best)], [CH[i][0] for i in best])

import random
random.seed(2)
K = n - 3                                   # the last three: other files, kept last
assert [c[0] for c in CH[K:]] == ['mirror_copy', 'mirdirty', 'lvreset']
def disp(o): return sum(1 for i in range(n - 1) if o[i + 1] != o[i] + 1) + (o[0] != 0)
FIX = [[c[0] for c in CH].index(x) for x in ('drawsprite', 'draw_dirty', 'mirror_copy', 'mirdirty', 'lvreset')]
def ok(o): p = [o.index(i) for i in FIX]; return p == sorted(p)
def sc(o):
    if not ok(o): return 1e9
    b, m = cost(o); return b + m + 0.3 * disp(o)
def local(o):
    s0 = sc(o); improved = True
    while improved:
        improved = False
        for i in range(K):
            for j in range(K):
                if i == j: continue
                p = o[:K]; x = p.pop(i); p.insert(j, x); p += o[K:]
                s = sc(p)
                if s < s0 - 1e-6: o, s0, improved = p, s, True
    return o, s0
res = [local(list(range(n)))[::-1]]
for k in range(400):
    h = list(range(K)); random.shuffle(h)
    o, s = local(h + list(range(K, n)))
    res.append((s, o))
res.sort()
seen = set()
print('outside the blocks: Model B %.1f, Master %.1f' % (oB, oM))
for s, o in res:
    if tuple(o) in seen: continue
    seen.add(tuple(o)); b, m = cost(o)
    print('%.1f  B %.1f  M %.1f  breaks %d  %s' % (s, b, m, disp(o), ' '.join(CH[i][0] for i in o)))
    if len(seen) > 6: break
