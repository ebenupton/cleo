#!/usr/bin/env python3
"""Dump each surviving proposal as a diff plus the agent's reasoning, for reading.

    python3 tools/review.py [status] > build/review.txt

Testing cannot screen these.  statediff compares object state and a wrong sprite frame
leaves it identical; pixdiff compares pixels and cannot reach a path the scripted run
never takes.  Both are samples.  The flag bugs this session has already seen -- `bit`
setting Z from A AND operand, `ldx #n` clobbering a Z about to be branched on, a carry
that looked redundant and was load-bearing at -1 -- are caught by reading, or not at all.
"""
import json, os, sys, subprocess, shutil, difflib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tryproposal import apply_one

want = sys.argv[1] if len(sys.argv) > 1 else 'built'
scr = {x['id']: x for x in json.load(open('build/screen.json'))}
props = [p for p in json.load(open('opt/proposals.json'))
         if scr.get(p['id'], {}).get('status') == want]
subprocess.run(['git', 'checkout', '--', 'src/'], check=True)
for n, p in enumerate(props):
    path = os.path.join('src', p['file'])
    before = open(path).read().split('\n')
    if apply_one(p, backup=False): continue
    after = open(path).read().split('\n')
    s = scr[p['id']]
    print('=' * 78)
    print(f"[{n}] {p['id']}  {p['file']}:{p['lo']}-{p['hi']}  {p['routine']}  "
          f"{p['weighted']} cy/frm = {p['saving_cycles']}cy x {p['execs_per_frame']}/frm  "
          f"bytes {s['delta']}  {p.get('confidence')}  {p['batch']}"
          + (f"  OVERLAPS {','.join(p['conflicts'])}" if p['conflicts'] else ''))
    for l in difflib.unified_diff(before, after, n=2, lineterm=''):
        if not l.startswith(('---', '+++')): print(l)
    print(f"ARG: {p['argument']}")
    if p.get('assumption'): print(f"ASSUMES: {p['assumption']}")
    subprocess.run(['git', 'checkout', '--', 'src/'], check=True)
