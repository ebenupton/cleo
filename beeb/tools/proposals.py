#!/usr/bin/env python3
"""Merge the agent farm's findings into one ranked catalogue.

    python3 tools/proposals.py   -> opt/proposals.json  (and a summary on stdout)

A saving of N cycles is worth nothing if the sequence runs once a level, so each
proposal is ranked by N x (executions per frame), taken from the profile's per-PC
counts through the .dbg line spans.  That ordering is what decides which ones are worth
the verification cost; the raw saving on its own is close to meaningless.
"""
import json, os, sys, glob, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from annotate_profile import parse_dbg, DBG

prof = json.load(open('build/profile.json'))
cnt = {int(k): v for k, v in prof['count'].items()}
files, segs, spans, lines = parse_dbg(DBG)
# executions per source line: the highest count of any address the line generated
per_line = {}
for fid, ln, sp in lines:
    if sp not in spans: continue
    seg, start, size = spans[sp]
    if seg not in segs: continue
    a0 = segs[seg] + start
    c = max((cnt.get(a, 0) for a in range(a0, a0 + size)), default=0)
    k = f'{os.path.basename(files[fid])}:{ln}'
    per_line[k] = max(per_line.get(k, 0), c)

wins = {w['id']: w for w in json.load(open('build/windows/all.json'))}
FRAMES = prof.get('frames') or 1
out, bad = [], []
for f in sorted(glob.glob('build/windows/out_*.json')):
    try: items = json.load(open(f))
    except Exception as e: bad.append(f'{f}: {e}'); continue
    for it in items:
        if it.get('verdict') != 'improve': continue
        w = wins.get(it.get('id'))
        if not w: bad.append(f"{f}: unknown window {it.get('id')}"); continue
        execs = max((per_line.get(f"{w['file']}:{l}", 0) for l in range(w['lo'], w['hi'] + 1)), default=0)
        it['batch'] = os.path.basename(f)
        it['file'], it['lo'], it['hi'], it['routine'] = w['file'], w['lo'], w['hi'], w['routine']
        it['execs'] = execs
        it['weighted'] = int(it.get('saving_cycles', 0)) * execs
        out.append(it)
out.sort(key=lambda x: -x['weighted'])
# Overlapping proposals: two agents rewriting the same lines.  They cannot both be
# applied, and where one agent proposed a change another explicitly rejected, the
# rejection is evidence -- batch 05 caught batch 00 costing copy_partial's dispatch as
# one-time when it is the loop back-edge, which turns a 13-cycle win into a 240-cycle loss.
for a in out:
    a['conflicts'] = sorted({b['id'] for b in out if b is not a and b['file'] == a['file']
                             and not (b['hi'] < a['lo'] or b['lo'] > a['hi'])})
nconf = sum(1 for a in out if a['conflicts'])
os.makedirs('opt', exist_ok=True)
json.dump(out, open('opt/proposals.json', 'w'), indent=1)
print(f'{len(out)} proposals from {len(glob.glob("build/windows/out_*.json"))} batches; '
      f'{nconf} overlap another proposal and cannot be applied blind')
for b in bad: print('  PROBLEM', b)
print(f'{"rank":>4} {"weighted":>10} {"cy":>4} {"execs":>8}  {"conf":6} where')
for i, p in enumerate(out[:25]):
    print(f'{i:>4} {p["weighted"]:>10} {p.get("saving_cycles",0):>4} {p["execs"]:>8}  '
          f'{p.get("confidence","?"):6} {p["file"]}:{p["lo"]}-{p["hi"]} {p["routine"]} [{p["id"]}]'
          + (f'  CONFLICTS {",".join(p["conflicts"])}' if p['conflicts'] else ''))
