#!/usr/bin/env python3
"""Apply the byte grind's candidate edits to the tree, keeping only what pays.

The surveyors' candidates (a workflow journal, JSON lines, each result holding a region and
its candidates: file, lo, original, proposal, confidence, bytes_modelb, bytes_master) are
sorted by confidence then claimed saving and tried in batches of BATCH non-overlapping
edits.  A batch is kept when the tree builds, is smaller (the code and data segments of
both machines plus LDPROG and the boot loader: smaller on one and larger on neither),
behaves exactly as the base did (gate(): statecmp, bwincmp, wincmp, menusync on levels 2,
8 and 13) and is no slower in play (test/linecyc.mjs's frame totals: at most TOL cycles a
frame above the last kept state and CAP above the base).  A failing batch is bisected.
A candidate that moves bank 4 or 5's code end is built again with the ends re-read
(build()).  Every attempt is recorded in <work>/applied.json (outcome: kept, build,
behaviour, slower, no smaller, grows, stale, anon, sweep).

At the end the whole sweep (the checks in SWEEP, against <work>/ref) runs; a failure is
bisected over the kept edits replayed from HEAD, the edit that breaks it is dropped, and
the sweep runs again, up to 12 rounds.

Usage (from beeb/):
    python3 tools/bytegrind/apply.py <journal.jsonl> <work> [batch=8]
<work> holds the base build: base.ssd, base_master/ and base_modelb/ (labels.txt each),
and ref/ (test/snapshot.sh's snapshot of the base).  The tree is left built, with the kept
edits applied; tools/assets.py may have new code ends.
"""
import json, os, re, subprocess, sys, time
BEEB = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
journal, WORK = sys.argv[1:3]
WORK = os.path.abspath(WORK)
BATCH = int(sys.argv[3]) if len(sys.argv) > 3 else 8
LEVELS = [2, 8, 13]
# cycles a frame: the most a kept batch may add over the last kept state, and over the base
TOL, CAP = 4, 8
LOG = os.path.join(WORK, 'applied.json')
record = json.load(open(LOG)) if os.path.exists(LOG) else []

def say(*a):
    """Print with a time stamp, unbuffered."""
    print(time.strftime('%H:%M:%S'), *a, flush=True)

# ---- the candidates (the workflow's journal: each surveyor's {region, candidates})
def load_cands():
    """Every candidate in the journal, each given id '<region>:<index>', the first of a
    duplicated id kept.  A result may sit at any depth of a journal entry: the entry is
    walked for a dict with 'region' and a 'candidates' list."""
    out = []
    for line in open(journal):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        stack = [e]
        while stack:
            x = stack.pop()
            if isinstance(x, dict):
                if 'candidates' in x and 'region' in x and isinstance(x['candidates'], list):
                    for k, c in enumerate(x['candidates']):
                        if isinstance(c, dict) and 'original' in c and 'proposal' in c:
                            c = dict(c); c['id'] = '%s:%d' % (x['region'], k); out.append(c)
                else:
                    stack.extend(x.values())
            elif isinstance(x, list):
                stack.extend(x)
    seen, uniq = set(), []
    for c in out:
        if c['id'] not in seen:
            seen.add(c['id']); uniq.append(c)
    return uniq
allc = load_cands()
done = {x['id'] for x in record}
CONF = {'high': 0, 'medium': 1, 'low': 2}
def SAVED(c, k):
    """The candidate's claimed saving under key k as an int, 0 if missing or unreadable."""
    try:
        return int(c.get(k, 0) or 0)
    except (TypeError, ValueError):
        return 0
cands = [c for c in allc if c['id'] not in done]
# high confidence first, then the claimed saving, the Model B's weighted double
cands.sort(key=lambda c: (CONF.get(str(c.get('confidence', 'low')).lower(), 2), -(2 * SAVED(c, 'bytes_modelb') + SAVED(c, 'bytes_master'))))
say('%d candidates (%d already recorded)' % (len(cands), len(done)))

# a line that defines an anonymous label
ANON = re.compile(r'^:(\s|$)')
def lines_of(t):
    """A candidate's text as lines, without a trailing newline."""
    return t.rstrip('\n').split('\n')
def fpath(f):
    """The file a candidate names, looked for as given and under src/, beebgame/src/ and
    beebgame/src/engine/; None if nowhere."""
    for c in (f, 'src/' + f, 'beebgame/src/' + f, 'beebgame/src/engine/' + f):
        if os.path.exists(os.path.join(BEEB, c)):
            return os.path.join(BEEB, c)
    return None
def locate(c):
    """Where the candidate's original text is in its file now: (path, lo, hi), 1-based and
    inclusive, trailing whitespace ignored -- at its claimed line, or at its one match in
    the file.  None if the file is missing, the original is empty, or it matches nowhere or
    more than once (stale)."""
    path = fpath(c.get('file', ''))
    if not path:
        return None
    src = open(path).read().split('\n')
    orig = [l.rstrip() for l in lines_of(c['original'])]
    n = len(orig)
    if not n or not any(orig):
        return None
    lo = int(c.get('lo', 0) or 0)
    if lo >= 1 and [l.rstrip() for l in src[lo - 1:lo - 1 + n]] == orig:
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

def run(cmd, timeout=3600):
    """Run a shell command in beeb/: (return code, its output, stdout and stderr together)."""
    p = subprocess.run(cmd, shell=True, cwd=BEEB, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout + p.stderr

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
# the files that hold each sprite bank's code-end assert
BANKFILES = {4: os.path.join(BEEB, 'beebgame/src/engine/sprloops.s'), 5: os.path.join(BEEB, 'beebgame/src/engine/gather.s')}
def bank_ends():
    """The Model B's bank 4 and 5 code ends from the last link's labels.txt: the end of
    SPR4CODE, and of MAP5BSS."""
    a = {}
    for l in open(os.path.join(BEEB, 'build', 'modelb', 'labels.txt')):
        p = l.split()
        if len(p) >= 3 and p[0] == 'al':
            a[p[2].lstrip('.')] = int(p[1], 16)
    return {4: a['__SPR4CODE_RUN__'] + a['__SPR4CODE_SIZE__'], 5: a['__MAP5BSS_RUN__'] + a['__MAP5BSS_SIZE__']}
def build(batch):
    """Build the tree.  The Model B's sprite banks' code must end exactly at B4_CODE_END and
    B5_CODE_END (tools/assets.py; sprloops.s and gather.s assert it): when the build fails
    with that message, it is probed -- one build with the two asserts made warnings, the
    true ends read from its labels -- then assets.py is given those ends and built again,
    up to three more times (the packer's placement should move nothing else, but it is
    checked).  Returns (ok, assets.py's text before, to restore on rejection)."""
    before = open(ASSETS).read()
    rc, out = run('./build.sh')
    if rc == 0:
        return True, before
    if "code must end where its sprites start" not in out:
        return False, before
    saved_src = {b: open(f).read() for b, f in BANKFILES.items()}
    try:
        for b, f in BANKFILES.items():
            t = saved_src[b].replace('.assert * = B%d_CODE_END, error,' % b, '.assert * = B%d_CODE_END, warning,' % b)
            open(f, 'w').write(t)
        rc, out = run('./build.sh')
        if rc != 0 and not os.path.exists(os.path.join(BEEB, 'build', 'modelb', 'labels.txt')):
            return False, before
        ends = bank_ends()
    finally:
        for b, f in BANKFILES.items():
            open(f, 'w').write(saved_src[b])
    s = before
    for b in (4, 5):
        s = re.sub(r'B%d_CODE_END = 0x[0-9A-Fa-f]+' % b, 'B%d_CODE_END = 0x%04X' % (b, ends[b]), s)
    open(ASSETS, 'w').write(s)
    for _ in range(3):
        rc, out = run('./build.sh')
        if rc == 0:
            return True, before
        if "code must end where its sprites start" not in out:
            break
        s = open(ASSETS).read()
        for b, f in BANKFILES.items():
            open(f, 'w').write(saved_src[b].replace('.assert * = B%d_CODE_END, error,' % b, '.assert * = B%d_CODE_END, warning,' % b))
        run('./build.sh'); ends = bank_ends()
        for b, f in BANKFILES.items():
            open(f, 'w').write(saved_src[b])
        for b in (4, 5):
            s = re.sub(r'B%d_CODE_END = 0x[0-9A-Fa-f]+' % b, 'B%d_CODE_END = 0x%04X' % (b, ends[b]), s)
        open(ASSETS, 'w').write(s)
    return False, before

SEGS = ('GAMECODE', 'GAMEDATA', 'ENGCODE', 'KRNCODE', 'KRNDATA', 'MNUCODE', 'MNUDATA', 'MUSCODE', 'TILCODE',
        'TIL6ENT', 'SPR4CODE', 'SPR5CODE', 'MAP5CODE', 'LOWCODE', 'BOOT', 'DRV1770', 'DRV8271', 'CODE', 'MRAMBSS')
def sizes():
    """Bytes per machine from the last build: the SEGS segments' sizes (labels.txt's
    __<seg>_SIZE__), plus LDPROG's file and the shared LOADER's."""
    out = {}
    loader = os.path.getsize(os.path.join(BEEB, 'build', 'LOADER'))
    for m in ('modelb', 'master'):
        n = 0
        for l in open(os.path.join(BEEB, 'build', m, 'labels.txt')):
            p = l.split()
            if len(p) >= 3 and p[0] == 'al':
                nm = p[2].lstrip('.')
                if nm.startswith('__') and nm.endswith('_SIZE__') and nm[2:-7] in SEGS:
                    n += int(p[1], 16)
        out[m] = n + os.path.getsize(os.path.join(BEEB, 'build', m, 'LDPROG')) + loader
    return out

B = WORK
GATE = (['node test/statecmp.mjs %s/base.ssd %s/base_master/labels.txt build/cleo.ssd build/master/labels.txt 300 1 %d' % (B, B, lv) for lv in LEVELS] +
        ['node test/bwincmp.mjs %s/base.ssd %s/base_modelb/labels.txt build/cleo.ssd build/modelb/labels.txt %d 300' % (B, B, lv) for lv in LEVELS] +
        ['RELOAD=1 node test/wincmp.mjs %s/base.ssd %s/base_master/labels.txt build/cleo.ssd build/master/labels.txt 2 200' % (B, B),
         'BBOARD=watford node test/bwincmp.mjs %s/base.ssd %s/base_modelb/labels.txt build/cleo.ssd build/modelb/labels.txt 8 300' % (B, B),
         'node test/menusync.mjs master %s/base.ssd %s/base_master/labels.txt build/cleo.ssd build/master/labels.txt' % (B, B),
         'node test/menusync.mjs modelb %s/base.ssd %s/base_modelb/labels.txt build/cleo.ssd build/modelb/labels.txt' % (B, B)])
def gate():
    """Run the GATE checks and both machines' linecyc profiles at once.  Returns (True if
    every check passed and reported identical, {machine: cycles a frame}); a missing
    profile counts as 1e9."""
    procs = [(cmd, subprocess.Popen(cmd, shell=True, cwd=BEEB, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)) for cmd in GATE]
    lp = []
    for m in ('modelb', 'master'):
        f = os.path.join(WORK, 'lc_gate_%s.json' % m)
        if os.path.exists(f):
            os.remove(f)
        lp.append((m, f, subprocess.Popen('node test/linecyc.mjs %s build/cleo.ssd build/%s/labels.txt %s %s 100' % (m, m, f, ','.join(map(str, LEVELS))),
                                          shell=True, cwd=BEEB, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)))
    same = True
    for cmd, p in procs:
        out = p.communicate()[0]
        res = [l for l in out.split('\n') if l and not l.startswith(('Load', 'Run'))]
        last = res[-1] if res else ''
        ok = p.returncode == 0 and ('identical' in out or 'IDENTICAL' in out) and 'differ' not in out.lower() and 'DIFFER' not in out
        if not ok:
            same = False
            say('  behaviour: %s -> %s' % (cmd.split(' build/')[0][-60:], last[-200:]))
    tot = {}
    for m, f, p in lp:
        p.communicate()
        tot[m] = json.load(open(f))['total'] if os.path.exists(f) else 1e9
    return same, tot

# ---- the reference: the tree as it stands, built and gated (it must match the base)
ok, _ = build([])
assert ok, 'the tree does not build'
same, ref = gate()
assert same, 'the tree does not match the base'
base_cyc = dict(ref)
ref_sz = sizes()
base_sz = dict(ref_sz)
say('reference: Model B %s / Master %s cycles a frame; %d / %d bytes' % (ref['modelb'], ref['master'], ref_sz['modelb'], ref_sz['master']))

def judge(t, sz):
    """Compare a gated batch's cycles t and sizes sz with the reference: (fast, small, the
    cycle deltas dB and dM, the bytes saved sB and sM).  fast: within TOL of the reference
    and CAP of the base on both machines; small: no larger on either and smaller on one."""
    dB, dM = t['modelb'] - ref['modelb'], t['master'] - ref['master']
    sB, sM = ref_sz['modelb'] - sz['modelb'], ref_sz['master'] - sz['master']
    fast = dB <= TOL and dM <= TOL and t['modelb'] <= base_cyc['modelb'] + CAP and t['master'] <= base_cyc['master'] + CAP
    small = sB >= 0 and sM >= 0 and sB + sM > 0
    return fast, small, dB, dM, sB, sM

def try_batch(batch):
    """Apply, build, size and gate a batch; keep it (the reference moves to it) or restore
    the tree and bisect.  A single rejected candidate is recorded with its reason; a batch
    that is not smaller and whose every candidate claimed no saving is recorded whole.
    Returns the number of candidates kept."""
    global ref, ref_sz
    for c in batch:
        c['_at'] = locate(c)
    batch = [c for c in batch if c['_at']]
    if not batch:
        return 0
    prev = apply(batch)
    ok, assets_before = build(batch)
    why = None
    if ok:
        sz = sizes()
        pre_small = (ref_sz['modelb'] - sz['modelb']) >= 0 and (ref_sz['master'] - sz['master']) >= 0 and sz != ref_sz
        if not pre_small:
            why = 'no smaller (Model B %+d, Master %+d bytes)' % (sz['modelb'] - ref_sz['modelb'], sz['master'] - ref_sz['master'])
        else:
            same, t = gate()
            if same:
                fast, small, dB, dM, sB, sM = judge(t, sz)
                if fast and small:
                    ref, ref_sz = t, sz
                    for c in batch:
                        path, lo, hi = c['_at']
                        record.append(dict(id=c['id'], outcome='kept', file=c['file'], lo=lo, batch=len(batch), dB=dB, dM=dM,
                                           sB=sB, sM=sM, original=c['original'], proposal=c['proposal']))
                    json.dump(record, open(LOG, 'w'), indent=1)
                    say('  kept %d (%s): %d / %d bytes SAVED, cycles %+d / %+d -> %d / %d bytes' % (len(batch), ' '.join(c['id'] for c in batch), sB, sM, dB, dM, sz['modelb'], sz['master']))
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
    if why.startswith('no smaller') and all(SAVED(c, 'bytes_modelb') <= 0 and SAVED(c, 'bytes_master') <= 0 for c in batch):
        for c in batch:
            record.append(dict(id=c['id'], outcome=why, file=c['file'], lo=c['_at'][1]))
        json.dump(record, open(LOG, 'w'), indent=1)
        run('./build.sh')
        return 0
    h = len(batch) // 2
    return try_batch(batch[:h]) + try_batch(batch[h:])

def grind(queue):
    """Work through the queue in batches: a candidate that claims growth, is stale, or changes
    the anonymous label count is recorded and skipped; up to BATCH candidates whose edits
    are at least two lines apart in a file go in a batch, the rest wait for the next.
    Returns the number kept."""
    kept = 0
    while queue:
        batch, rest, used = [], [], {}
        for c in queue:
            if SAVED(c, 'bytes_modelb') < 0 or SAVED(c, 'bytes_master') < 0:
                record.append(dict(id=c['id'], outcome='grows', file=c.get('file'), lo=c.get('lo'))); continue
            at = locate(c)
            if at is None:
                record.append(dict(id=c['id'], outcome='stale', file=c.get('file'), lo=c.get('lo'))); continue
            if not anon_ok(c) or str(c.get('anon_change', '')).strip():
                record.append(dict(id=c['id'], outcome='anon', file=c['file'], lo=c.get('lo'))); continue
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
    return kept

kept = grind(cands)
run('./build.sh')
say('grind done: %d kept; Model B %d -> %d bytes, Master %d -> %d; cycles %s -> %s' % (kept, base_sz['modelb'], ref_sz['modelb'], base_sz['master'], ref_sz['master'], base_cyc, ref))

# ---- the sweep, and a bisection over the kept edits when it fails
SWEEP = {}
for l in range(16):
    SWEEP['master_L%d' % l] = 'node test/wincmp.mjs {R}/cleo.ssd {R}/master/labels.txt build/cleo.ssd build/master/labels.txt %d 400' % l
    SWEEP['master_reload_L%d' % l] = 'RELOAD=1 node test/wincmp.mjs {R}/cleo.ssd {R}/master/labels.txt build/cleo.ssd build/master/labels.txt %d 200' % l
    SWEEP['modelb_L%d' % l] = 'node test/bwincmp.mjs {R}/cleo.ssd {R}/modelb/labels.txt build/cleo.ssd build/modelb/labels.txt %d 300' % l
for b in ('watford', 'solidisk'):
    SWEEP['modelb_%s' % b] = 'BBOARD=%s node test/bwincmp.mjs {R}/cleo.ssd {R}/modelb/labels.txt build/cleo.ssd build/modelb/labels.txt 8 300' % b
    SWEEP['boardstores_%s' % b] = 'node test/boardcheck.mjs %s build/cleo.ssd build/modelb/labels.txt' % b
SWEEP['menus_master'] = 'node test/menusync.mjs master {R}/cleo.ssd {R}/master/labels.txt build/cleo.ssd build/master/labels.txt'
SWEEP['menus_modelb'] = 'node test/menusync.mjs modelb {R}/cleo.ssd {R}/modelb/labels.txt build/cleo.ssd build/modelb/labels.txt'
SWEEP['load_master'] = 'node test/loadsync2.mjs master build/cleo.ssd build/master/labels.txt'
SWEEP['load_8271'] = 'node test/loadsync2.mjs modelb build/cleo.ssd build/modelb/labels.txt'
SWEEP['load_1770'] = 'BMODEL=B1770 node test/loadsync2.mjs modelb build/cleo.ssd build/modelb/labels.txt'
# the result lines the checks print when they pass
PASS = ('window identical; scene identical', 'windows identical', 'menus: identical', ' 0 irregular', 'every store to the bank paged')
def checks(names):
    """Run the named sweep checks against <work>/ref, all at once; returns the names whose
    last result line is not a PASS line."""
    R = os.path.join(WORK, 'ref')
    procs = [(n, subprocess.Popen(SWEEP[n].replace('{R}', R), shell=True, cwd=BEEB, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)) for n in names]
    bad = []
    for n, p in procs:
        out = p.communicate()[0]
        rl = [l for l in out.split('\n') if re.match(r'^L[0-9]|^B L|.*menus:|.*frames from|^board |.*Error', l)]
        r = rl[-1] if rl else ''
        if not any(s in r for s in PASS):
            bad.append(n); say('  %s: %s' % (n, (r or 'no result')[-160:]))
    return bad
def checks_all(names):
    """checks() in groups of eight (the whole sweep at once would swamp the machine)."""
    bad = []
    for i in range(0, len(names), 8):
        bad += checks(names[i:i + 8])
    return bad
def replay(k, final=False):
    """Both repositories back to HEAD (tools/assets.py and src/ here; all of beebgame), then
    the first k kept edits applied and the tree built.  An edit that no longer places (it
    leaned on a dropped one) is skipped -- and, on the final replay, recorded as dropped
    with it.  Returns whether the build succeeded."""
    run('git checkout -- tools/assets.py src')
    run('git -C beebgame checkout -- .')
    keptc = [x for x in record if x['outcome'] == 'kept']
    for x in keptc[:k]:
        c = dict(x); c['_at'] = locate(c)
        if not c['_at']:
            if final:
                x['outcome'] = 'stale after a drop'
            continue
        apply([c])
    ok, _ = build([c for c in keptc[:k]])
    return ok

for rnd in range(12):
    say('sweep, round %d' % rnd)
    bad = checks_all(list(SWEEP))
    if not bad:
        say('sweep: all %d checks pass' % len(SWEEP))
        break
    keptc = [x for x in record if x['outcome'] == 'kept']
    # bisect over the kept edits: the prefix of lo passes (HEAD does), the prefix of hi fails
    lo, hi = 0, len(keptc)
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if not replay(mid):
            say('  replay %d does not build' % mid); hi = mid; continue
        if checks_all(bad):
            hi = mid
        else:
            lo = mid
    culprit = keptc[hi - 1]
    say('  sweep failure from %s (%s:%s): dropped' % (culprit['id'], culprit['file'], culprit['lo']))
    culprit['outcome'] = 'sweep'
    json.dump(record, open(LOG, 'w'), indent=1)
    n = len([x for x in record if x['outcome'] == 'kept'])
    assert replay(n, final=True), 'the kept edits no longer build without the culprit'
    json.dump(record, open(LOG, 'w'), indent=1)
    ref_sz = sizes()
else:
    say('sweep: still failing after 12 rounds')
ref_sz = sizes()
say('final: %d kept; Model B %d -> %d bytes (%+d), Master %d -> %d (%+d)' % (len([x for x in record if x['outcome'] == 'kept']),
    base_sz['modelb'], ref_sz['modelb'], ref_sz['modelb'] - base_sz['modelb'], base_sz['master'], ref_sz['master'], ref_sz['master'] - base_sz['master']))
