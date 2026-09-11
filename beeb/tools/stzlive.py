#!/usr/bin/env python3
"""Which stz sites may have A live across them?

The 6502 has no stz, so the Model B build spells it lda #0 / sta, which lands
on A.  This walks forward from each stz in the source: a site is safe only if
A is provably redefined before any use, along a single straight-line path.
Anything that branches, calls or returns first counts as unsafe, so the answer
is conservative: a site reported safe really is.
"""
import re, sys, os

DEFS = {'lda', 'pla', 'txa', 'tya', 'ldaz'}
USES = {'sta', 'pha', 'tax', 'tay', 'adc', 'sbc', 'and', 'ora', 'eor', 'cmp',
        'bit', 'asl', 'lsr', 'rol', 'ror', 'inca', 'deca', 'staz', 'andz',
        'trb', 'tsb', 'jsr'}
STOP = {'rts', 'rti', 'jmp', 'bra', 'jmpx'} | {'b' + c for c in
        ('eq', 'ne', 'cc', 'cs', 'mi', 'pl', 'vc', 'vs')}

def insns(lines, i):
    """yield (index, mnemonic) from line i onward, skipping labels and comments"""
    for j in range(i, len(lines)):
        s = lines[j].split(';')[0].strip()
        if not s:
            continue
        m = re.match(r'^(?:[A-Za-z_@:][\w@]*:)?\s*([A-Za-z_][\w]*)', s)
        if not m:
            continue
        yield j, m.group(1).lower()

def classify(lines, i):
    first = True
    for j, op in insns(lines, i):
        if first:                     # the stz itself
            first = False
            continue
        if op in DEFS:
            return 'safe', j
        if op in USES:
            return 'live', j
        if op in STOP:
            return 'flow', j
        if op.startswith('.') or op.isupper():
            return 'macro', j         # a macro: unknown, treat as live
    return 'end', len(lines)

total = {}
for f in sys.argv[1:]:
    lines = open(f).read().split('\n')
    for i, l in enumerate(lines):
        s = l.split(';')[0]
        if not re.search(r'(^|:)\s*stz\s', s):
            continue
        verdict, j = classify(lines, i)
        total.setdefault(verdict, []).append((f, i + 1, l.strip(), lines[j].strip() if j < len(lines) else ''))
for k in ('safe', 'live', 'flow', 'macro', 'end'):
    v = total.get(k, [])
    print('%-6s %d' % (k, len(v)))
if '-v' in os.environ.get('STZ', ''):
    pass
for k in ('live', 'macro'):
    for f, n, l, nxt in total.get(k, []):
        print('  %s %s:%d  %-28s -> %s' % (k, os.path.basename(f), n, l, nxt))
