"""Bank 7's pads (beebgame/src/pads.inc: PADB_xx, PADM_xx), chosen together over a
profile.  All of bank 7's code moves with the kernel's start, so when that moves
(the driver slot's size, the kernel's code) the pads that kept the hot loops in a
page are wrong.  ENGCODE is cut at the pads into regions; a pad moves every region
before it on the Model B (its bank 7 code ends at the kernel) and every region after
it on the Master (pinned to the Model B's start, so it also moves with the Model B's
pads).  Each region's cost -- the page crossings of its taken branches and of the
indexed reads of its data -- is tabulated for every move, then the best pads are
found for each change in the Model B's bytes (the Master's pads cost it nothing).
    for m in master modelb; do PHASEDUMP=build/pd_$m.json node test/cycprof.mjs $m build/cleo.ssd build/$m/labels.txt; done
    python3 test/padopt.py [bytes_lo=-8] [bytes_hi=8]"""
import json, re, sys

LO, HI = (int(sys.argv[1]), int(sys.argv[2])) if len(sys.argv) > 2 else (-8, 8)
LIM = 64                                    # the largest pad tried
# the pads in ENGCODE's order, each before its routine (BB: before render_frame, the
# Model B's only; the code after it is render_frame)
NAMES = [('MS', 'match_sprites'), ('SP', 'draw_sprites'), ('EO', 'erase_old'),
         ('DS', 'drawsprite'), ('CP', 'copy_partial'), ('BB', 'render_frame')]


def labels(m):
    d = {}
    for l in open('build/%s/labels.txt' % m):
        p = l.split()
        d[p[2].lstrip('.')] = int(p[1], 16)
    return d


PADS = {}
for l in open('beebgame/src/pads.inc'):
    mm = re.match(r'(PAD[BM]_\w+) = (\d+)', l)
    if mm:
        PADS[mm.group(1)] = int(mm.group(2))
LB, LM = labels('modelb'), labels('master')
NAMES.sort(key=lambda kl: LB[kl[1]] - (PADS['PADB_' + kl[0]] if kl[0] != 'BB' else 0))
assert NAMES[-1][0] == 'BB', 'the Model B pad before render_frame must be the last'
assert [k for k, _ in sorted(NAMES[:-1], key=lambda kl: LM[kl[1]])] == [k for k, _ in NAMES[:-1]], 'the machines order ENGCODE alike'
n = len(NAMES)
curB = [None] + [PADS['PADB_' + k] for k, _ in NAMES]
curM = [None] + [PADS.get('PADM_' + k, 0) for k, _ in NAMES[:-1]]
BB = [LB['__B7_START__']] + [LB[l] - PADS['PADB_' + k] for k, l in NAMES]
MEND = [int(x.split()[1], 16) + int(x.split()[3], 16) for x in open('build/master/map.txt') if x.startswith('ENGCODE ')][0]
BM = [LM['__B7_START__']] + [LM[l] - PADS.get('PADM_' + k, 0) for k, l in NAMES[:-1]] + [MEND]


def region(a, bd):
    for i in range(len(bd) - 1):
        if bd[i] <= a < bd[i + 1]:
            return i
    return -1


def tables(m, bd, L):
    """f[r][s]: region r's crossings a frame when it moves up s bytes (mod 256)"""
    spins = [L[x] for x in ('wait_flip', 'fl_wait') if x in L]      # idle, not cost
    d = json.load(open('build/pd_%s.json' % m))
    F = d['frames']
    f = [[0.0] * 256 for _ in range(len(bd) - 1)]
    other = 0.0
    for k, c in d['ev']:
        p = k.split()
        c /= F
        if p[0] == 'b':
            a, t = int(p[1]), int(p[2])
            if any(s <= t <= s + 6 and s <= a <= s + 8 for s in spins):
                continue
            r = region(a, bd)
            if r < 0 or region(t, bd) != r:
                other += c * (((a + 2) >> 8) != (t >> 8))
                continue
            for s in range(256):
                f[r][s] += c * ((((a + 2 + s) & 0xFFFF) >> 8) != (((t + s) & 0xFFFF) >> 8))
        else:
            pc, b, i = int(p[1]), int(p[2]), int(p[3])
            r = region(b, bd) if pc >= 0 else -1
            if r < 0:
                other += c * (((b + i) >> 8) != (b >> 8))
                continue
            for s in range(256):
                bb = (b + s) & 0xFFFF
                f[r][s] += c * (((bb + i) >> 8) != (bb >> 8))
    return f, other


fB, oB = tables('modelb', BB, LB)
fM, oM = tables('master', BM, LM)
g = lambda f, r, e: f[r][e % 256]
print('now: Model B %.1f, Master %.1f cycles a frame in bank 7 crossings' % (
    sum(g(fB, r, 0) for r in range(n)) + oB, sum(g(fM, r, 0) for r in range(n - 1)) + oM))
# the Model B, from the kernel down: e_n = 0, e_{r-1} = e_r - d_r (e: the move up)
best = {n: {0: (0.0, [])}}
for r in range(n - 1, -1, -1):
    best[r] = {}
    for e1, (v1, path) in best[r + 1].items():
        for d in sorted(range(-curB[r + 1], LIM + 1), key=abs):   # (ties: the least change)
            e = e1 - d
            v = v1 + g(fB, r, e)
            if e not in best[r] or v < best[r][e][0] - 1e-9:
                best[r][e] = (v, [d] + path)


def master(e0):                     # from the game's move, which the Master's shares
    cur = {e0: (g(fM, 0, e0), [])}
    for r in range(1, n):
        nxt = {}
        for t0, (v0, path) in cur.items():
            for m in sorted(range(-curM[r], LIM + 1), key=abs):
                t = t0 + m
                v = v0 + g(fM, r, t)
                if t not in nxt or v < nxt[t][0] - 1e-9:
                    nxt[t] = (v, path + [m])
        cur = nxt
    return min(cur.values())


for e0, (vb, path) in sorted(best[0].items(), key=lambda x: -x[0]):
    if not LO <= -e0 <= HI:
        continue
    vm, mp = master(e0)
    print('Model B bytes %+3d: Model B %6.1f  Master %6.1f   %s' % (-e0, vb + oB, vm + oM, '  '.join(
        '%s %d/%s' % (k, curB[i + 1] + path[i], curM[i + 1] + mp[i] if i < n - 1 else '-') for i, (k, _) in enumerate(NAMES))))
