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
# Rendered frames in the profile, so everything below is per frame -- the unit every
# other measurement in this project uses.  Without it, code that runs twice per LEVEL
# outranks the inner loop of drawrect, because the profile covers level loads too.
labels = {}
for line in open('build/labels.txt'):
    m = re.match(r'^al ([0-9A-F]+) \.(\w+)$', line)
    if m: labels[m.group(2)] = int(m.group(1), 16)
FRAMES = max(cnt.get(labels.get('render_frame', -1), 0), 1)
# cycles measured in each window, also per frame: an upper bound on any saving
lcost = json.load(open('build/linecost.json'))
out, bad = [], []
for f in sorted(glob.glob('build/windows/out_*.json')):
    try: items = json.load(open(f))
    except Exception as e: bad.append(f'{f}: {e}'); continue
    for it in items:
        if it.get('verdict') != 'improve': continue
        w = wins.get(it.get('id'))
        if not w: bad.append(f"{f}: unknown window {it.get('id')}"); continue
        execs = max((per_line.get(f"{w['file']}:{l}", 0) for l in range(w['lo'], w['hi'] + 1)), default=0)
        wcost = sum(lcost.get(f"{w['file']}:{l}", 0) for l in range(w['lo'], w['hi'] + 1))
        it['batch'] = os.path.basename(f)
        it['file'], it['lo'], it['hi'], it['routine'] = w['file'], w['lo'], w['hi'], w['routine']
        it['execs_per_frame'] = round(execs / FRAMES, 2)
        it['window_cy_per_frame'] = round(wcost / FRAMES, 1)
        raw = int(it.get('saving_cycles', 0)) * execs / FRAMES
        # agents mixed units -- some costed a whole loop per call, some one pass -- so cap
        # the claim at the cycles actually measured in the window.  A claim above that is
        # a units mismatch, not a saving, and is marked rather than silently believed.
        it['overclaim'] = raw > wcost / FRAMES * 1.05 and wcost > 0
        it['weighted'] = round(min(raw, wcost / FRAMES), 1)
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
print(f'profile covers {FRAMES} rendered frames; savings below are cycles per frame')
print(f'{"rank":>4} {"cy/frm":>8} {"claim":>6} {"win cy/frm":>11} {"x/frm":>7}  {"conf":6} where')
for i, p in enumerate(out[:25]):
    print(f'{i:>4} {p["weighted"]:>8} {p.get("saving_cycles",0):>6} {p["window_cy_per_frame"]:>11} '
          f'{p["execs_per_frame"]:>7}  {p.get("confidence","?"):6} '
          f'{p["file"]}:{p["lo"]}-{p["hi"]} {p["routine"]}'
          + ('  OVERCLAIM' if p['overclaim'] else '')
          + (f'  CONFLICTS {len(p["conflicts"])}' if p['conflicts'] else ''))

# ---- opt/CATALOGUE.md: the human-readable index, regenerated with the JSON ----------
import collections
par = {a['id']: a['id'] for a in out}
def _find(a):
    while par[a] != a: par[a] = par[par[a]]; a = par[a]
    return a
for a in out:
    for c in a['conflicts']:
        ra, rc = _find(a['id']), _find(c)
        if ra != rc: par[ra] = rc
cl = collections.defaultdict(list)
for a in out: cl[_find(a['id'])].append(a)
groups = sorted(cl.values(), key=lambda g: -max(y['weighted'] for y in g))
raw = sum(len(json.load(open(f))) for f in sorted(glob.glob('build/windows/out_*.json')))

with open('opt/CATALOGUE.md', 'w') as fh:
    w = fh.write
    w('# Peephole proposal catalogue\n\n')
    w(f'{raw} windows of 16 instructions were put to a farm of agents; {len(out)} came '
      f'back with a rewrite and {raw - len(out)} were judged already optimal '
      f'({100 * (raw - len(out)) // raw}% rejected).\n\n')
    w('Savings are **cycles per frame**, the unit the rest of this project measures in: '
      'the claimed per-execution saving times the window\'s executions per frame, capped '
      'at the cycles the profile actually attributes to those lines. A claim above that '
      'cap is a units mismatch (an agent costing a whole loop as one execution), flagged '
      '`OVERCLAIM` and worth less than it says.\n\n')
    w('**Nothing here is verified.** Each entry is one agent\'s reasoning about 16 '
      'instructions in isolation, with no assembler and no emulator. Apply one at a time '
      'and gate it on `statediff` + `pixdiff` per `opt/README.md`.\n\n')
    w(f'{len([g for g in groups if len(g) == 1])} of the {len(groups)} clusters are '
      'single proposals that can be taken on their own merits. The rest overlap: two or '
      'more agents rewrote the same lines, so at most one applies, and the disagreement '
      'itself is evidence.\n\n## Ranked\n\n')
    w('| cy/frm | per exec | bytes | x/frm | conf | where | agents |\n')
    w('|---:|---:|---:|---:|:--|:--|---:|\n')
    for g in groups[:40]:
        b = max(g, key=lambda y: y['weighted'])
        w(f'| {b["weighted"]:.0f}{" !" if b["overclaim"] else ""} | {b["saving_cycles"]} '
          f'| {b["saving_bytes"]:+} | {b["execs_per_frame"]:.0f} | '
          f'{b.get("confidence","?")} | `{b["file"]}:{b["lo"]}-{b["hi"]}` {b["routine"]} '
          f'| {len(g)} |\n')
    w('\n`!` = OVERCLAIM. The `agents` column is how many proposals landed on those '
      'lines; >1 means the top entry is one option among several, not a consensus.\n')
print(f'wrote opt/CATALOGUE.md ({len(groups)} clusters)')
