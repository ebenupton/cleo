#!/usr/bin/env python3
"""The cycle grind's regions: contiguous runs of hot source lines, from test/linecyc.mjs's
profiles of both machines, each annotated line by line with its cycles and executions
a frame on the Model B and the Master.  A macro's body line ("file:a > macros.s:b")
counts at both its call and its definition.
    python3 tools/cycgrind/regions.py <lc_modelb.json> <lc_master.json> <outdir> [cover=0.97] [maxlines=150]"""
import json, os, re, sys
from collections import defaultdict
BEEB = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
lb, lm, out = sys.argv[1:4]
cover = float(sys.argv[4]) if len(sys.argv) > 4 else 0.97
maxlines = int(sys.argv[5]) if len(sys.argv) > 5 else 150
cost = defaultdict(lambda: [0.0, 0.0, 0.0, 0.0])          # (file, line) -> [cyB, exB, cyM, exM]
tot = [0.0, 0.0]
for k, path in enumerate((lb, lm)):
    d = json.load(open(path))
    for loc, r in d['lines'].items():
        if loc.startswith('?'):
            continue
        tot[k] += r['cy']
        for part in loc.split(' > '):
            m = re.match(r'(.+):(\d+)$', part)
            if not m:
                continue
            c = cost[(m.group(1), int(m.group(2)))]
            c[2 * k] += r['cy']; c[2 * k + 1] += r['ex']
def real(f):                                      # (the debug info drops Cleo's "src/")
    for c in (f, 'src/' + f):
        if os.path.exists(os.path.join(BEEB, c)):
            return c
    return None
by_file = defaultdict(dict)
for (f, ln), c in cost.items():
    if real(f):
        by_file[real(f)][ln] = c
    else:
        print('no such file: %s' % f, file=sys.stderr)
regions = []
for f, lines in by_file.items():
    hot = sorted(ln for ln, c in lines.items() if c[0] + c[2] >= 2.0)
    if not hot:
        continue
    groups, cur = [], [hot[0]]
    for ln in hot[1:]:
        if ln - cur[-1] <= 25:
            cur.append(ln)
        else:
            groups.append(cur); cur = [ln]
    groups.append(cur)
    path = os.path.join(BEEB, f)
    try:
        src = open(path).read().split('\n')
    except OSError:
        continue
    for g in groups:
        lo, hi = max(1, g[0] - 12), min(len(src), g[-1] + 12)
        for a in range(lo, hi + 1, maxlines):           # split long runs
            b = min(hi, a + maxlines - 1)
            cyc = sum(lines.get(ln, [0, 0, 0, 0])[0] + lines.get(ln, [0, 0, 0, 0])[2] for ln in range(a, b + 1))
            regions.append(dict(file=f, lo=a, hi=b, cyc=cyc))
regions.sort(key=lambda r: -r['cyc'])
total = sum(r['cyc'] for r in regions)
keep, acc = [], 0.0
for r in regions:
    if acc >= cover * total:
        break
    keep.append(r); acc += r['cyc']
os.makedirs(out, exist_ok=True)
index = []
for i, r in enumerate(keep):
    f, lo, hi = r['file'], r['lo'], r['hi']
    src = open(os.path.join(BEEB, f)).read().split('\n')
    lines = by_file[f]
    body = ['# region r%02d: %s lines %d-%d -- %.0f cycles a frame (Model B + Master), %.1f%% of the profiled total'
            % (i, f, lo, hi, r['cyc'], 100 * r['cyc'] / (tot[0] + tot[1])),
            '# columns: line | Model B cycles/frame, executions/frame | Master cycles/frame, executions/frame | source', '']
    for ln in range(lo, hi + 1):
        c = lines.get(ln)
        ann = '%7.1f %7.1f | %7.1f %7.1f' % (c[0], c[1], c[2], c[3]) if c and (c[1] or c[3]) else ' ' * 15 + ' | ' + ' ' * 15
        body.append('%5d | %s | %s' % (ln, ann, src[ln - 1] if ln - 1 < len(src) else ''))
    name = 'r%02d.txt' % i
    open(os.path.join(out, name), 'w').write('\n'.join(body) + '\n')
    index.append(dict(id='r%02d' % i, file=f, lo=lo, hi=hi, cyc=round(r['cyc'], 1), path=os.path.join(out, name)))
json.dump(dict(total_modelb=tot[0], total_master=tot[1], regions=index), open(os.path.join(out, 'index.json'), 'w'), indent=1)
print('%d regions cover %.1f%% of %.0f (Model B %.0f + Master %.0f cycles a frame)' % (len(keep), 100 * acc / total, total, tot[0], tot[1]))
for r in index[:60]:
    print('  %s %8.0f  %s:%d-%d' % (r['id'], r['cyc'], r['file'], r['lo'], r['hi']))
