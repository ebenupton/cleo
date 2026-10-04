#!/usr/bin/env python3
"""The byte grind's applier: the surveyors' candidates, applied in batches to the tree
and kept only when the batch builds, is smaller (code and data on both machines, the
load-time program and the boot loader: smaller on one, larger on neither), behaves
exactly as the base did (gate()) and is no slower in play (test/linecyc.mjs's frame
totals: at most TOL cycles a frame above the last kept state, CAP above the base).
A failing batch is bisected.  At the end the whole sweep runs against the base; a
failure is bisected over the kept edits (replayed from HEAD) and the edit that breaks
it dropped, until the sweep passes.  Every attempt is recorded in <work>/applied.json.
    python3 tools/bytegrind/apply.py <journal.jsonl> <work> [batch=8]
<work> holds the base build: base.ssd, base_master/, base_modelb/, ref/ (test/snapshot.sh)."""
import json, os, re, subprocess, sys, time
BEEB = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
journal, WORK = sys.argv[1:3]
WORK = os.path.abspath(WORK)
BATCH = int(sys.argv[3]) if len(sys.argv) > 3 else 8
LEVELS = [2, 8, 13]
TOL, CAP = 4, 8
LOG = os.path.join(WORK, 'applied.json')
record = json.load(open(LOG)) if os.path.exists(LOG) else []

def say(*a):
    print(time.strftime('%H:%M:%S'), *a, flush=True)

# ---- the candidates (the workflow's journal: each surveyor's {region, candidates})
def load_cands():
    out = []
    for line in open(journal):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        stack = [e]
        while stack:            # the result may sit at any depth of the journal entry
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
    try:
        return int(c.get(k, 0) or 0)
    except (TypeError, ValueError):
        return 0
cands = [c for c in allc if c['id'] not in done]
cands.sort(key=lambda c: (CONF.get(str(c.get('confidence', 'low')).lower(), 2), -(2 * SAVED(c, 'bytes_modelb') + SAVED(c, 'bytes_master'))))
say('%d candidates (%d already recorded)' % (len(cands), len(done)))

ANON = re.compile(r'^:(\s|$)')
def lines_of(t):
    return t.rstrip('\n').split('\n')
def fpath(f):
    for c in (f, 'src/' + f, 'beebgame/src/' + f, 'beebgame/src/engine/' + f):
        if os.path.exists(os.path.join(BEEB, c)):
            return os.path.join(BEEB, c)
    return None
def locate(c):
    """The candidate's line range in the file now, or None if stale."""
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
    a = sum(1 for l in lines_of(c['original']) if ANON.match(l))
    b = sum(1 for l in lines_of(c['proposal']) if ANON.match(l))
    return a == b

def run(cmd, timeout=3600):
    p = subprocess.run(cmd, shell=True, cwd=BEEB, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout + p.stderr

def apply(batch):
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
    for path, text in prev.items():
        open(path, 'w').write(text)

ASSETS = os.path.join(BEEB, 'tools', 'assets.py')
BANKFILES = {4: os.path.join(BEEB, 'beebgame/src/engine/sprloops.s'), 5: os.path.join(BEEB, 'beebgame/src/engine/gather.s')}
def bank_ends():
    """The Model B's bank 4 and 5 code ends from the last link (SPR4CODE; MAP5BSS)."""
    a = {}
    for l in open(os.path.join(BEEB, 'build', 'modelb', 'labels.txt')):
        p = l.split()
        if len(p) >= 3 and p[0] == 'al':
            a[p[2].lstrip('.')] = int(p[1], 16)
    return {4: a['__SPR4CODE_RUN__'] + a['__SPR4CODE_SIZE__'], 5: a['__MAP5BSS_RUN__'] + a['__MAP5BSS_SIZE__']}
def build(batch):
    """Build.  The Model B's sprite banks' code must end exactly at B4/B5_CODE_END
    (assets.py): when an edit moves either, probe -- one build with those two asserts
    made warnings, the true ends read from its labels -- then set them and build again.
    Returns (ok, the assets.py text to restore on rejection)."""
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
    for _ in range(3):          # (the packer's placement can move nothing else, but check)
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
        'TIL6ENT', 'SPR4CODE', 'SPR5CODE', 'MAP5CODE', 'LOWCODE', 'BOOT', 'DRV1770', 'DRV8271', 'CODE', 'TABLES')
def sizes():
    """Bytes per machine: the code and data segments, LDPROG, and the shared LOADER."""
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
    """Behaviour identical to the base on both machines; the frame totals."""
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

# ---- the reference: the tree as it stands (built, gated: it must match the base)
ok, _ = build([])
assert ok, 'the tree does not build'
same, ref = gate()
assert same, 'the tree does not match the base'
base_cyc = dict(ref)
ref_sz = sizes()
base_sz = dict(ref_sz)
say('reference: Model B %s / Master %s cycles a frame; %d / %d bytes' % (ref['modelb'], ref['master'], ref_sz['modelb'], ref_sz['master']))

def judge(t, sz):
    dB, dM = t['modelb'] - ref['modelb'], t['master'] - ref['master']
    sB, sM = ref_sz['modelb'] - sz['modelb'], ref_sz['master'] - sz['master']
    fast = dB <= TOL and dM <= TOL and t['modelb'] <= base_cyc['modelb'] + CAP and t['master'] <= base_cyc['master'] + CAP
    small = sB >= 0 and sM >= 0 and sB + sM > 0
    return fast, small, dB, dM, sB, sM

def try_batch(batch):
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
PASS = ('window identical; scene identical', 'windows identical', 'menus: identical', ' 0 irregular', 'every store to the bank paged')
def checks(names):
    """Run the named sweep checks on the build as it stands; the names that fail."""
    R = os.path.join(WORK, 'ref')
    procs = [(n, subprocess.Popen(SWEEP[n].replace('{R}', R), shell=True, cwd=BEEB, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)) for n in names]
    bad = []
    for n, p in procs:   # (17 at a time would swamp the machine: the Popen list runs all)
        out = p.communicate()[0]
        rl = [l for l in out.split('\n') if re.match(r'^L[0-9]|^B L|.*menus:|.*frames from|^board |.*Error', l)]
        r = rl[-1] if rl else ''
        if not any(s in r for s in PASS):
            bad.append(n); say('  %s: %s' % (n, (r or 'no result')[-160:]))
    return bad
def checks_all(names):
    bad = []
    for i in range(0, len(names), 8):
        bad += checks(names[i:i + 8])
    return bad
def replay(k, final=False):
    """HEAD (both repos) plus the first k kept edits, built.  An edit that no longer
    places (it leaned on a dropped one) is skipped -- and, on the final replay, recorded
    as dropped with it."""
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
    lo, hi = 0, len(keptc)          # prefix lo passes (HEAD), prefix hi fails
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
