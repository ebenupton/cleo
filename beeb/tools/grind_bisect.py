#!/usr/bin/env python3
"""Rebuild the tree with the first N applied grind edits, in another checkout.

    python3 tools/grind_bisect.py <dir> <N>      <dir>/beeb/src and modelb/src from git
                                                 HEAD, then applied edits 1..N replayed
                                                 exactly where the applier made them
"""
import json, os, subprocess, sys
here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
dst = sys.argv[1]
skip = set(sys.argv[sys.argv.index('--skip') + 1].split(',')) if '--skip' in sys.argv else set()
m = {c['key']: c for c in json.load(open(f'{here}/build/grind/merged.json'))}
applied = [e for e in json.load(open(f'{here}/build/grind/applied.json')) if e['result'] == 'applied']
N = len(applied) if sys.argv[2] == 'all' else int(sys.argv[2])
for f in {e['file'] for e in applied} | {'src/engine.s'}:
    txt = subprocess.run(['git', 'show', f'{os.environ.get("GRIND_BASE", "HEAD")}:beeb/{f}'], cwd=here, capture_output=True, text=True, check=True).stdout
    open(f'{dst}/beeb/{f}', 'w').write(txt)
gone = []                                   # (file, line_now, delta) of skipped edits
for e in applied[:N]:
    c = m[e['key']]
    if e['key'] in skip:
        gone.append((e['file'], e['line_now'], e['delta_lines'])); continue
    p = f"{dst}/beeb/{e['file']}"
    t = open(p).read().split('\n')
    orig = c['original'].rstrip('\n').split('\n')
    prop = (c['fixed_proposal'] if c['verdict'] == 'fix' and c['fixed_proposal'].strip() else c['proposal']).rstrip('\n').split('\n')
    at = e['line_now'] - 1 - sum(d for f, l, d in gone if f == e['file'] and l < e['line_now'])
    assert [l.rstrip() for l in t[at:at + len(orig)]] == [l.rstrip() for l in orig], (e['key'], 'does not replay')
    open(p, 'w').write('\n'.join(t[:at] + prop + t[at + len(orig):]))
print(f'{N} of {len(applied)} edits, {len(gone)} skipped; last {applied[N-1]["key"] if N else "-"}')

# ---- replay with exclusions:  grind_bisect.py <dir> all --skip k1,k2   (line_now of later
# edits in the same file shift by the excluded edits' deltas above them)
