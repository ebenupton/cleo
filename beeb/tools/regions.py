#!/usr/bin/env python3
"""Cut every source file of both targets into regions for the byte grind.

    python3 tools/regions.py [WIN] [STARTS]  -> build/grind/regions/rNNN.md, index.json

Every WIN-instruction contiguous block (stride 1) is a window.  A region holds STARTS
consecutive window starts, so its text is STARTS+WIN-1 instructions and every window
lies wholly inside exactly one region's start range.  Windows run across routine
boundaries: a tail call, a shared exit or a fall-through is exactly where bytes hide.
Each instruction line carries a marker [iNNNN] (the file's instruction index) so an
agent can say which windows it examined.
"""
import json, os, re, sys, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
WIN = int(sys.argv[1]) if len(sys.argv) > 1 else 32
STARTS = int(sys.argv[2]) if len(sys.argv) > 2 else 128
OUT = 'build/grind/regions'
DIRECTIVES = {'res','byte','word','segment','include','import','export','macro','endmacro',
 'ifdef','ifndef','endif','else','proc','endproc','code','assert','if','out','error','addr',
 'def','ident','repeat','endrep','local','elseif','feature','setcpu','org','align','bss',
 'data','rodata','zeropage','charmap','asciiz','concat','list','dbyt','fopt','autoimport'}
LABEL = re.compile(r'^([a-zA-Z_]\w*):')
SEGDIR = re.compile(r'^\s*(PLACE\s+"\w+"\s*,\s*"\w+"|\.segment\s+"\w+"|\.code\b)')
FILES = ['src/engine.s', 'src/logic.s', 'src/game.s', 'src/menu.s', 'src/main.s',
         'modelb/src/display.s', 'modelb/src/disc.s', 'modelb/src/low.s', 'modelb/src/banks.s',
         'modelb/src/init.s', 'modelb/src/ldprog.s', 'modelb/src/loader.s']
TARGET = {'src/main.s': 'Master only (65C02)', 'modelb/src/ldprog.s': 'Model B only, 6502, disc-loaded to $0E00 at every load',
          'modelb/src/loader.s': 'Model B only, 6502, the boot loader'}
def instructions(lines):
    out = []
    for i, raw in enumerate(lines, 1):
        code = raw.split(';')[0].rstrip()
        if not code.strip(): continue
        body = re.sub(r'^[@:.\w]+:\s*', '', code.strip())
        if not body or body.startswith('.'): continue
        mn = re.match(r'([a-zA-Z_]\w*)', body)
        if not mn or mn.group(1).lower() in DIRECTIVES: continue
        out.append(i)
    return out
os.makedirs(OUT, exist_ok=True)
for f in glob.glob(f'{OUT}/r*.md'): os.remove(f)
idx, n = [], 0
for path in FILES:
    lines = open(path).read().split('\n')
    ins = instructions(lines)
    mark = {l: k for k, l in enumerate(ins)}
    tgt = TARGET.get(path, 'BOTH targets: Master 65C02 and Model B 6502 (-D MODELB=1)' if path.startswith('src/')
                     else 'Model B only, 6502 (included by modelb/src/main.s with -D MODELB=1)')
    for s0 in range(0, max(1, len(ins) - WIN + 1), STARTS):
        s1 = min(s0 + STARTS, max(1, len(ins) - WIN + 1))       # window starts [s0, s1)
        e = min(s1 - 1 + WIN, len(ins))                          # instructions [s0, e)
        lo, hi = ins[s0], ins[e - 1]
        seg = '(none seen)'
        for l in lines[:lo - 1]:
            m = SEGDIR.match(l)
            if m: seg = m.group(1)
        routine = '(file start)'
        for l in lines[:lo - 1]:
            m = LABEL.match(l)
            if m: routine = m.group(1)
        body = []
        for i in range(lo, hi + 1):
            tag = f'[i{mark[i]:04d}]' if i in mark else '       '
            body.append(f'{i:5d} {tag} {lines[i-1]}')
        rid = f'r{n:03d}'
        with open(f'{OUT}/{rid}.md', 'w') as fh:
            fh.write(f'# Region {rid}: {path} lines {lo}-{hi}\n\n'
                     f'- Assembled for: {tgt}\n'
                     f'- Segment in force at line {lo} (the last placement above it): `{seg}`\n'
                     f'- Routine in force at line {lo}: `{routine}`\n'
                     f'- Windows: every {WIN}-instruction block starting at instruction i{s0:04d} through '
                     f'i{s1-1:04d} ({s1-s0} windows, stride 1); the text below is instructions '
                     f'i{s0:04d}..i{e-1:04d}.\n'
                     f'- Columns: source line number, instruction index, source text.\n\n```\n'
                     + '\n'.join(body) + '\n```\n')
        idx.append({'id': rid, 'file': path, 'lo': lo, 'hi': hi, 'starts': [s0, s1 - 1], 'n': e - s0})
        n += 1
json.dump(idx, open('build/grind/index.json', 'w'), indent=1)
print(f'{n} regions, {sum(r["starts"][1]-r["starts"][0]+1 for r in idx)} windows of {WIN}')
