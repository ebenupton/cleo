#!/usr/bin/env python3
"""Merge the byte-grind farm's journals into build/grind/merged.json (every candidate,
with its reviewer's verdict) and build/grind/CANDIDATES.md (the readable record).

    python3 tools/grind_merge.py <journal.jsonl>...
"""
import json, sys
surv, rev = {}, {}
for j in sys.argv[1:]:
    for l in open(j):
        e = json.loads(l)
        if e['type'] != 'result' or not isinstance(e.get('result'), dict): continue
        r = e['result']
        if 'candidates' in r: surv[r['region']] = r
        elif 'verdicts' in r: rev[r['region']] = r
out = []
for reg in sorted(surv):
    vs = {v['index']: v for v in rev.get(reg, {}).get('verdicts', [])}
    for i, c in enumerate(surv[reg]['candidates']):
        v = vs.get(i, {'verdict': 'unreviewed', 'reason': '', 'fixed_proposal': '', 'bytes_master': c['bytes_master'], 'bytes_modelb': c['bytes_modelb']})
        out.append({**c, 'key': f'{reg}:{i}', 'region': reg, 'verdict': v['verdict'], 'review': v['reason'],
                    'fixed_proposal': v.get('fixed_proposal', ''),
                    'rev_bytes_master': v['bytes_master'], 'rev_bytes_modelb': v['bytes_modelb']})
json.dump(out, open('build/grind/merged.json', 'w'), indent=1)
with open('build/grind/CANDIDATES.md', 'w') as f:
    f.write(f'# Byte grind: {len(out)} candidates from {len(surv)} regions\n\n')
    for c in out:
        f.write(f"## {c['key']}  {c['file']}:{c['lo']}-{c['hi']}  (window {c['window']})  "
                f"M -{c['bytes_master']} B -{c['bytes_modelb']}  [{c['confidence']}]  review: {c['verdict']}\n\n"
                f"Cycles: {c['cycles']}\n\nAssumption: {c['assumption']}\n\n"
                f"```\n{c['original']}\n```\n->\n```\n{c['proposal']}\n```\n\n{c['argument']}\n\n"
                + (f"Review: {c['review']}\n\n" if c['review'] else '')
                + (f"Fixed:\n```\n{c['fixed_proposal']}\n```\n\n" if c['fixed_proposal'] else ''))
import collections
print(len(out), 'candidates;', dict(collections.Counter(c['verdict'] for c in out)),
      '| claimed after review: M', sum(max(0, c['rev_bytes_master']) for c in out if c['verdict'] != 'reject'),
      'B', sum(max(0, c['rev_bytes_modelb']) for c in out if c['verdict'] != 'reject'))
