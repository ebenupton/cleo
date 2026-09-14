#!/usr/bin/env python3
"""Apply one proposal from the catalogue, build, and leave the tree ready to verify.

    python3 tools/tryproposal.py <rank|id>        apply it
    python3 tools/tryproposal.py --revert         put the source back

The proposal's `original` text must appear exactly once inside the window's own line
range -- not merely somewhere in the file, which is how a plausible-looking patch lands
in the wrong routine.  The line range is the check that makes this safe to automate.

After applying, the caller is expected to run, at minimum:
    ./build.sh
    node tools/statediff.mjs <ref> <reflabels> build/cleo.ssd build/labels.txt <lv> 300
    node tools/pixdiff.mjs   <ref> <reflabels> build/cleo.ssd build/labels.txt <lv> 300
An agent's cycle arithmetic is a claim; only those two make it a fact.
"""
import json, sys, os, shutil, re

SRC = 'src'
BACKUP = 'build/proposal_backup'

def revert():
    if not os.path.isdir(BACKUP): sys.exit('nothing to revert')
    for f in os.listdir(BACKUP): shutil.copy(os.path.join(BACKUP, f), os.path.join(SRC, f))
    shutil.rmtree(BACKUP); print('source restored')

if len(sys.argv) < 2: sys.exit(__doc__)
if sys.argv[1] == '--revert': revert(); sys.exit()

props = json.load(open('opt/proposals.json'))
sel = sys.argv[1]
p = props[int(sel)] if sel.isdigit() else next((x for x in props if x['id'] == sel), None)
if p is None: sys.exit(f'no proposal {sel}')

path = os.path.join(SRC, p['file'])
src = open(path).read().split('\n')
lo, hi = p['lo'], p['hi']
region = '\n'.join(src[lo - 1:hi])
orig, new = p['original'].strip('\n'), p['proposal'].strip('\n')

# normalise leading whitespace so an agent's re-indentation does not defeat the match
def norm(t): return '\n'.join(l.strip() for l in t.split('\n') if l.strip())
if norm(orig) not in norm(region):
    print('ORIGINAL NOT FOUND in the window; not applying.')
    print('--- window ---'); print(region); print('--- expected ---'); print(orig)
    sys.exit(2)

# rebuild the region with the replacement, keeping the file's indentation style
lines_o, lines_n = [l for l in orig.split('\n') if l.strip()], [l for l in new.split('\n') if l.strip()]
ri = [i for i, l in enumerate(src[lo - 1:hi]) if l.strip()]
starts = [i for i in range(len(ri) - len(lines_o) + 1)
          if [src[lo - 1 + ri[i + k]].strip() for k in range(len(lines_o))] == [l.strip() for l in lines_o]]
if len(starts) != 1: sys.exit(f'matched {len(starts)} times in the window; refusing to guess')
s0 = ri[starts[0]]; s1 = ri[starts[0] + len(lines_o) - 1]
os.makedirs(BACKUP, exist_ok=True)
shutil.copy(path, os.path.join(BACKUP, p['file']))
indent = re.match(r'\s*', src[lo - 1 + s0]).group(0) or '        '
body = [(indent + l.strip()) if not l.strip().startswith((':', '@')) else l for l in lines_n]
src[lo - 1 + s0: lo + s1] = body
open(path, 'w').write('\n'.join(src))
print(f"applied {p['id']}  {p['file']}:{lo}-{hi} ({p['routine']})")
print(f"  claim: -{p.get('saving_cycles',0)} cycles x {p['execs']} execs = {p['weighted']} weighted")
print(f"  assumption: {p.get('assumption') or '(none stated)'}")
print(f"  confidence: {p.get('confidence','?')}")
