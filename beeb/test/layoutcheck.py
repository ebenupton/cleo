"""The two machines' layouts, compared: every segment both builds have must start at
the same address, and every variable or table (a label in a segment that is not
code) both builds have must sit at the same address -- the Master's shorter 65C02
code is padded out to the Model B's, so nothing after it moves.  Code labels may
differ (a CMOS instruction is shorter); so may the pieces that only run once at
start-up, and each machine's own data, which the segments ZPHW, LOWHW and LGCHW put
after the shared (the Master's handler keeps its state in TABLES, main RAM).  Exit 1
on any difference.
    python3 test/layoutcheck.py [modelb_dir=build/modelb] [master_dir=build/master]"""
import re, sys

CODE = {'CODE', 'TILCODE', 'LGCCODE', 'SPR4CODE', 'SPR5CODE', 'MAP5CODE',
        'TIL6ENT', 'MNUCODE', 'LOWCODE', 'NMISTUB', 'KRNCODE', 'ENGCODE'}
STARTUP = {'BOOT', 'BOOTHDR', 'BANKFIX', 'WRFIX'}      # run once, then overwritten
OWN = {'ZPHW', 'LOWHW', 'LGCHW', 'TABLES'}              # one machine's own, after the shared


def load(d):
    dbg = open(d + '/cleo.dbg').read()
    segs = {}
    for m in re.finditer(r'^seg\tid=(\d+),name="(\w+)",start=0x([0-9A-F]+),size=0x([0-9A-F]+)', dbg, re.M):
        segs[m.group(1)] = (m.group(2), int(m.group(3), 16), int(m.group(4), 16))
    syms = {}
    for m in re.finditer(r'^sym\tid=\d+,name="([\w@]+)",([^\n]*)', dbg, re.M):
        name, rest = m.groups()
        if name.startswith('__') or name.startswith('@') or 'type=lab' not in rest:
            continue
        seg = re.search(r'seg=(\d+)', rest)
        val = re.search(r'val=0x([0-9A-F]+)', rest)
        if seg and val and seg.group(1) in segs:
            syms[name] = (segs[seg.group(1)][0], int(val.group(1), 16))
    return {n: (s, z) for n, s, z in segs.values() if z}, syms


bd = sys.argv[1] if len(sys.argv) > 1 else 'build/modelb'
md = sys.argv[2] if len(sys.argv) > 2 else 'build/master'
bseg, bsym = load(bd)
mseg, msym = load(md)
bad = 0
for n in sorted(set(bseg) & set(mseg)):
    if n in STARTUP:
        continue
    if bseg[n][0] != mseg[n][0]:
        bad += 1
        print('segment %-9s Model B $%04X, Master $%04X' % (n, bseg[n][0], mseg[n][0]))
moved = []
for n in sorted(set(bsym) & set(msym)):
    (sb, ab), (sm, am) = bsym[n], msym[n]
    if sb in CODE or {sb, sm} & (STARTUP | OWN):
        continue
    if ab != am:
        moved.append((sb, ab, n, am))
for sb, ab, n, am in sorted(moved):
    bad += 1
    if bad <= 40:
        print('%-9s %-14s Model B $%04X, Master $%04X' % (sb, n, ab, am))
print('layout: %s' % ('the data sits alike on both machines' if not bad else '%d differences' % bad))
sys.exit(1 if bad else 0)
