#!/usr/bin/env python3
"""Apply the cycle grind's candidate edits to the tree, keeping only what is faster.

The surveyors' candidates (a workflow journal, JSON lines, each entry's result holding a
region and its candidates: file, lo, original, proposal, saving_modelb, saving_master,
bytes_modelb) are sorted by claimed saving (the Model B's weighted double) and tried in
batches of BATCH non-overlapping edits.  A batch is kept when the tree builds, behaves
exactly as the base did (gate(): statecmp on the Master, bwincmp on the Model B -- game
state and the visible window frame by frame -- on levels 2, 8 and 13) and is faster by
better(): 2 dB + dM < 0 with neither machine more than 15 cycles a frame slower, from
test/linecyc.mjs's frame totals.  A failing batch is bisected.  An edit that moves bank 4
or 5's code end is built again with the end stepped until the asserts pass (build()).
Every attempt is recorded in <work>/applied.json (outcome: kept, build, behaviour, slower,
stale, anon).

REPLAY=1 in the environment first puts both repositories back to HEAD, re-applies the
record's kept candidates in order, and forgets its build rejections so they are tried again
(an interrupted run leaves a batch half tested).

Usage (from beeb/):
    python3 tools/cycgrind/apply.py <journal.jsonl> <work> <base_dir> [batch=10]
<base_dir> holds the base build: base.ssd, base_master/labels.txt, base_modelb/labels.txt.
The tree is left built, with the kept edits applied; tools/assets.py may have new code ends.
"""
import json, os, re, subprocess, sys, time
BEEB = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
journal, WORK, BASE = sys.argv[1:4]
BATCH = int(sys.argv[4]) if len(sys.argv) > 4 else 10
LEVELS = [2, 8, 13]
os.makedirs(WORK, exist_ok=True)
LOG = os.path.join(WORK, 'applied.json')
record = json.load(open(LOG)) if os.path.exists(LOG) else []

def say(*a):
    """Print with a time stamp, unbuffered."""
    print(time.strftime('%H:%M:%S'), *a, flush=True)

# ---- the candidates: each given id '<region>:<index>'; those recorded are skipped (under
# REPLAY, the build rejections are not)
cands = []
for line in open(journal):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    r = e.get('result') if isinstance(e, dict) else None
    if not isinstance(r, dict) or 'candidates' not in r:
        continue
    for k, c in enumerate(r['candidates']):
        c['id'] = '%s:%d' % (r.get('region', '?'), k)
        cands.append(c)
done = {x['id'] for x in record if not (os.environ.get('REPLAY') and x['outcome'] == 'build')}
cands = [c for c in cands if c['id'] not in done]
score = lambda c: 2 * max(0, c.get('saving_modelb', 0)) + max(0, c.get('saving_master', 0))
cands.sort(key=lambda c: -score(c))
say('%d candidates to try (%d already recorded)' % (len(cands), len(done)))

# a line that defines an anonymous label
ANON = re.compile(r'^:(\s|$)')
def lines_of(t):
    """A candidate's text as lines, without a trailing newline."""
    return t.rstrip('\n').split('\n')
def locate(c):
    """Where the candidate's original text is in its file now: (path, lo, hi), 1-based and
    inclusive, trailing whitespace ignored -- at its claimed line, or at its one match in
    the file.  The file is looked for as named and under src/.  None if the file is missing
    or the text matches nowhere or more than once (stale)."""
    path = os.path.join(BEEB, c['file'])
    if not os.path.exists(path):
        path = os.path.join(BEEB, 'src', c['file'])
    if not os.path.exists(path):
        return None
    src = open(path).read().split('\n')
    orig = [l.rstrip() for l in lines_of(c['original'])]
    n = len(orig)
    lo = c['lo']
    if [l.rstrip() for l in src[lo - 1:lo - 1 + n]] == orig:
        return path, lo, lo + n - 1
    hits = [i for i in range(len(src) - n + 1) if [l.rstrip() for l in src[i:i + n]] == orig]
    if len(hits) == 1:
        return path, hits[0] + 1, hits[0] + n
    return None
def anon_ok(c):
    """True if the proposal defines as many anonymous labels as the original: a change in
    their count would retarget every :+/:- branch around the edit."""
    a = sum(1 for l in lines_of(c['original']) if ANON.match(l))
    b = sum(1 for l in lines_of(c['proposal']) if ANON.match(l))
    return a == b

def run(cmd, timeout=1800):
    """Run a shell command in beeb/: (return code, its output, stdout and stderr together)."""
    p = subprocess.run(cmd, shell=True, cwd=BEEB, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout + p.stderr

def git_snapshot():
    """The texts of the files in `tracked` (unused: tracked stays empty)."""
    return {p: open(os.path.join(BEEB, p)).read() for p in tracked}
tracked = set()
def apply(batch):
    """Replace each candidate's lines (its '_at') with its proposal, a file's edits applied
    bottom up so the line numbers hold.  Returns {path: the file's text before}, for
    restore()."""
    prev, by = {}, {}
    for c in batch:
        path, lo, hi = c['_at']
        by.setdefault(path, []).append((lo, hi, c))
    for path, edits in by.items():
        prev[path] = open(path).read()
        src = prev[path].split('\n')
        for lo, hi, c in sorted(edits, key=lambda e: -e[0]):
            src[lo - 1:hi] = lines_of(c['proposal'])
        open(path, 'w').write('\n'.join(src))
    return prev
def restore(prev):
    """Write the files' previous texts back."""
    for path, text in prev.items():
        open(path, 'w').write(text)

ASSETS = os.path.join(BEEB, 'tools', 'assets.py')
def build(batch):
    """Build the tree.  The Model B's sprite banks' code must end exactly at B4_CODE_END and
    B5_CODE_END (tools/assets.py; sprloops.s asserts bank 4's, gather.s bank 5's -- the
    sprite loops are in both banks, the gather in bank 5): while either assert fails, that
    bank's constant is stepped through the batch's claimed byte change for sprloops.s,
    gather.s and macros.s edits, then outward from it by 1, 2, ... 47 either way,
    rebuilding each time, 120 builds at most.  Returns (ok, assets.py's text before, to
    restore on rejection)."""
    before = open(ASSETS).read()
    claim = sum(c.get('bytes_modelb', 0) for c in batch if c['file'].endswith(('sprloops.s', 'gather.s', 'macros.s')))
    tries = {4: [claim] + [x for k in range(1, 48) for x in (claim + k, claim - k)],
             5: [claim] + [x for k in range(1, 48) for x in (claim + k, claim - k)]}
    v0 = {b: int(re.search(r'B%d_CODE_END = 0x([0-9A-Fa-f]+)' % b, before).group(1), 16) for b in (4, 5)}
    step = {4: 0, 5: 0}
    for _ in range(120):
        rc, out = run('./build.sh')
        if rc == 0:
            if open(ASSETS).read() != before:
                say('  code ends: B4 %+d, B5 %+d' % tuple(int(re.search(r'B%d_CODE_END = 0x([0-9A-Fa-f]+)' % b, open(ASSETS).read()).group(1), 16) - v0[b] for b in (4, 5)))
            return True, before
        bad = [b for b in (4, 5) if ("bank %d's code must end" % b) in out or ("bank %d's code runs into" % b) in out]
        if not bad:
            return False, before
        s = open(ASSETS).read()
        for b in bad:
            if step[b] >= len(tries[b]):
                return False, before
            s = re.sub(r'B%d_CODE_END = 0x[0-9A-Fa-f]+' % b, 'B%d_CODE_END = 0x%04X' % (b, v0[b] + tries[b][step[b]]), s)
            step[b] += 1
        open(ASSETS, 'w').write(s)
    return False, before

def gate():
    """Run the behaviour checks (statecmp on the Master, bwincmp on the Model B, each LEVELS
    level) and both machines' linecyc profiles at once.  Returns (True if every check passed
    and reported identical, {machine: cycles a frame, or None without a profile})."""
    procs = []
    for lv in LEVELS:
        procs.append(subprocess.Popen('node test/statecmp.mjs %s/base.ssd %s/base_master/labels.txt build/cleo.ssd build/master/labels.txt 300 1 %d' % (BASE, BASE, lv),
                                      shell=True, cwd=BEEB, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True))
        procs.append(subprocess.Popen('node test/bwincmp.mjs %s/base.ssd %s/base_modelb/labels.txt build/cleo.ssd build/modelb/labels.txt %d 300' % (BASE, BASE, lv),
                                      shell=True, cwd=BEEB, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True))
    tot = {}
    lp = []
    for m in ('modelb', 'master'):
        f = os.path.join(WORK, 'lc_%s.json' % m)
        lp.append((m, f, subprocess.Popen('node test/linecyc.mjs %s build/cleo.ssd build/%s/labels.txt %s %s 100' % (m, m, f, ','.join(map(str, LEVELS))),
                                          shell=True, cwd=BEEB, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)))
    same = True
    for p in procs:
        out = p.communicate()[0]
        if p.returncode != 0 or ('identical' not in out and 'IDENTICAL' not in out) or 'differ' in out.lower():
            same = False
            say('  behaviour: ' + ' | '.join(l for l in out.split('\n') if l and not l.startswith(('Load', 'Run')))[-300:])
    for m, f, p in lp:
        p.communicate()
        tot[m] = json.load(open(f))['total'] if os.path.exists(f) else None
    return same, tot

# ---- REPLAY=1: the tree back to HEAD (both repositories), then the record's kept
# candidates re-applied in order, and the build rejections forgotten
if os.environ.get('REPLAY'):
    run('git checkout -- tools/assets.py src')
    run('git -C beebgame checkout -- .')
    allc = {}
    for line in open(journal):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        r = e.get('result') if isinstance(e, dict) else None
        if isinstance(r, dict) and 'candidates' in r:
            for k, c in enumerate(r['candidates']):
                c['id'] = '%s:%d' % (r.get('region', '?'), k); allc[c['id']] = c
    keptc = [allc[x['id']] for x in record if x['outcome'] == 'kept']
    for c in keptc:
        c['_at'] = locate(c)
        assert c['_at'], ('replay: cannot place', c['id'])
        apply([c])
    record = [x for x in record if x['outcome'] not in ('build',)]
    say('replayed %d kept candidates; the build rejections will be tried again' % len(keptc))
    json.dump(record, open(LOG, 'w'), indent=1)

# ---- the reference: the tree as it stands, built and gated (it must match the base)
ok, _ = build([])
assert ok, 'the tree does not build'
same, ref = gate()
assert same, 'the tree does not match the base'
say('reference: Model B %s, Master %s cycles a frame' % (ref['modelb'], ref['master']))

def better(t):
    """Compare a gated batch's cycles t with the reference: (faster, dB, dM), faster when
    2 dB + dM < 0 and neither machine is more than 15 cycles a frame slower."""
    dB, dM = t['modelb'] - ref['modelb'], t['master'] - ref['master']
    return 2 * dB + dM < 0 and dB <= 15 and dM <= 15, dB, dM

def try_batch(batch, depth=0):
    """Apply, build and gate a batch; keep it (the reference moves to it) or restore the
    tree and bisect.  A single rejected candidate is recorded with its reason.  Returns the
    number of candidates kept."""
    global ref
    for c in batch:
        c['_at'] = locate(c)
    batch = [c for c in batch if c['_at']]
    if not batch:
        return 0
    prev = apply(batch)
    ok, assets_before = build(batch)
    why = None
    if ok:
        same, t = gate()
        if same:
            good, dB, dM = better(t)
            if good:
                ref = t
                for c in batch:
                    record.append(dict(id=c['id'], outcome='kept', file=c['file'], lo=c['_at'][1], batch=len(batch), dB=dB, dM=dM))
                json.dump(record, open(LOG, 'w'), indent=1)
                say('  kept %d (%s): Model B %+d, Master %+d -> %d / %d' % (len(batch), ' '.join(c['id'] for c in batch), dB, dM, ref['modelb'], ref['master']))
                return len(batch)
            why = 'slower (Model B %+d, Master %+d)' % (dB, dM)
        else:
            why = 'behaviour'
    else:
        why = 'build'
    restore(prev)
    open(ASSETS, 'w').write(assets_before)
    if len(batch) == 1:
        record.append(dict(id=batch[0]['id'], outcome=why, file=batch[0]['file'], lo=batch[0]['_at'][1]))
        json.dump(record, open(LOG, 'w'), indent=1)
        say('  rejected %s: %s' % (batch[0]['id'], why))
        run('./build.sh')
        return 0
    h = len(batch) // 2
    return try_batch(batch[:h], depth + 1) + try_batch(batch[h:], depth + 1)

# ---- the grind: a stale candidate or one that changes the anonymous label count is
# recorded and skipped; up to BATCH candidates whose edits are at least two lines apart in
# a file go in a batch, the rest wait for the next
kept = 0
queue = cands[:]
while queue:
    batch, rest, used = [], [], {}
    for c in queue:
        at = locate(c)
        if at is None:
            record.append(dict(id=c['id'], outcome='stale', file=c['file'], lo=c['lo']))
            continue
        if not anon_ok(c):
            record.append(dict(id=c['id'], outcome='anon', file=c['file'], lo=c['lo']))
            continue
        path, lo, hi = at
        clash = any(p == path and not (hi < a - 2 or lo > b + 2) for p, a, b in used.values())
        if len(batch) < BATCH and not clash:
            batch.append(c); used[c['id']] = at
        else:
            rest.append(c)
    json.dump(record, open(LOG, 'w'), indent=1)
    if not batch:
        break
    say('batch of %d (%d left after it)' % (len(batch), len(rest)))
    kept += try_batch(batch)
    queue = rest
run('./build.sh')
say('done: %d kept; reference Model B %s, Master %s' % (kept, ref['modelb'], ref['master']))
