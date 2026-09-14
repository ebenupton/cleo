#!/usr/bin/env python3
"""Cut the sources into N-instruction windows for review, ranked by measured cost.

    python3 tools/windows.py [WIN] [STRIDE] [outdir] [batchsize]
                                        -> <outdir>/batch_NN.md, index.json, all.json

A window never spans a routine: a run of instructions straddling two unrelated routines
has no shared meaning and any "improvement" across the join would be nonsense.  Stride is
8, so every pair of adjacent windows overlaps by half and an opportunity sitting on a
boundary is still seen whole by one of them.  Cost comes from build/linecost.json
(tools/profile.mjs through the .dbg line spans); it is only used to order the work, and
double-counts macro expansions, so treat it as a ranking not a measurement.
"""
import json, os, re, glob

import sys
WIN     = int(sys.argv[1]) if len(sys.argv) > 1 else 16
STRIDE  = int(sys.argv[2]) if len(sys.argv) > 2 else WIN // 2
OUT     = sys.argv[3] if len(sys.argv) > 3 else 'build/windows'
PERBATCH= int(sys.argv[4]) if len(sys.argv) > 4 else 28
DIRECTIVES = {'res','byte','word','segment','include','import','export','macro','endmacro',
 'ifdef','ifndef','endif','else','proc','endproc','code','assert','if','out','error','addr',
 'def','ident','repeat','endrep','local','elseif','feature','setcpu','org','align','bss',
 'data','rodata','zeropage','charmap','asciiz','concat','list','dbyt','fopt','autoimport'}
LABEL = re.compile(r'^([a-zA-Z_][\w]*):')

def instructions(path):
    out, routine = [], '(file start)'
    for i, raw in enumerate(open(path), 1):
        code = raw.split(';')[0].rstrip()
        if not code.strip(): continue
        m = LABEL.match(code)
        if m: routine = m.group(1)
        body = code.strip()
        body = re.sub(r'^[@:.\w]+:\s*', '', body)          # drop a leading label
        if not body or body.startswith('.'): continue
        mn = re.match(r'([a-zA-Z_][\w]*)', body)
        if not mn or mn.group(1).lower() in DIRECTIVES: continue
        out.append((i, routine, raw.rstrip('\n')))
    return out

cost = json.load(open('build/linecost.json')) if os.path.exists('build/linecost.json') else {}
os.makedirs(OUT, exist_ok=True)
wins = []
for path in sorted(glob.glob('src/*.s')):
    base, ins = os.path.basename(path), instructions(path)
    src = open(path).read().split('\n')
    i = 0
    while i < len(ins):
        grp = [ins[i]]
        for j in range(i + 1, min(i + WIN, len(ins))):
            if ins[j][1] != ins[i][1]: break                # never cross a routine
            grp.append(ins[j])
        if len(grp) >= 6:                                   # too short to be worth asking about
            lo, hi = grp[0][0], grp[-1][0]
            wins.append({'id': f'{base.split(".")[0]}_{lo}', 'file': base, 'routine': grp[0][1],
                         'lo': lo, 'hi': hi, 'n': len(grp),
                         'cost': sum(cost.get(f'{base}:{l}', 0) for l, _, _ in grp),
                         'text': '\n'.join(src[lo - 1:hi])})
        i += STRIDE
wins.sort(key=lambda w: -w['cost'])
json.dump([{k: v for k, v in w.items() if k != 'text'} for w in wins],
          open(f'{OUT}/index.json', 'w'), indent=1)
json.dump(wins, open(f'{OUT}/all.json', 'w'))

# Deal the windows round-robin so every batch gets a mix of hot and cold: a batch of
# nothing but cold code gets a bored agent, and a batch of nothing but the inner loops
# gets one that has to reject almost everything.
nb = (len(wins) + PERBATCH - 1) // PERBATCH
batches = [wins[i::nb] for i in range(nb)]
for n, b in enumerate(batches):
    with open(f'{OUT}/batch_{n:02d}.md', 'w') as fh:
        fh.write(f'# Batch {n:02d}: {len(b)} windows\n\n'
                 f'Macro definitions used by the code below are in {OUT}/macros.txt.\n\n')
        for w in b:
            fh.write(f"\n## {w['id']}  ({w['file']} lines {w['lo']}-{w['hi']}, routine "
                     f"`{w['routine']}`, {w['n']} instructions, cost rank {w['cost']})\n"
                     f"```\n{w['text']}\n```\n")
# macros.txt has to be regenerated with the windows: the macros themselves get edited
# (CHARPER's jump became optional this round), and an agent reasoning from a stale copy
# is costing instructions the code no longer has.
with open(f'{OUT}/macros.txt', 'w') as fh:
    for path in sorted(glob.glob('src/*.s')) + sorted(glob.glob('src/*.inc')):
        keep, depth = [], 0
        for l in open(path):
            if re.match(r'\s*\.macro\b', l, re.I): depth += 1
            if depth: keep.append(l.rstrip('\n'))
            if re.match(r'\s*\.endmacro\b', l, re.I) and depth:
                depth -= 1
                if not depth: keep.append('')
        if keep: fh.write(f'; ===== {os.path.basename(path)} =====\n' + '\n'.join(keep) + '\n')

print(f'{len(wins)} windows of <={WIN} instructions, stride {STRIDE}, into {nb} batches '
      f'in {OUT}; hottest {wins[0]["id"]} ({wins[0]["cost"]}), coldest {wins[-1]["cost"]}')
