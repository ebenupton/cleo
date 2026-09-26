#!/usr/bin/env python3
"""Apply the byte-grind candidates one at a time, verifying each before the next.

    python3 tools/grind_apply.py            build/grind/merged.json -> the tree, with
                                            build/grind/applied.json the record of every
                                            attempt (resumable: attempts already recorded
                                            are skipped)

For each candidate that survived review (accept, or fix with its fixed proposal), best
Model B saving first:

  locate   the candidate's `original` must appear verbatim in the file as it is NOW;
           the occurrence nearest its pristine line (shifted by the edits already made
           above it in that file) is the one replaced.  Absent: superseded by an earlier
           edit, recorded as stale.
  anon     if the edit changes how many anonymous labels the text defines -- `:` lines
           or invocations of a macro that emits one -- both targets' listings are decoded
           before and after and no branch outside the edit may change its target.
  build    both targets must assemble and link (a segment overflow is a link error).
  bytes    measured from the maps and the stand-alone images: neither target may grow,
           at least one must shrink.  The measured figures are what is recorded.
  gate     tools/gate.sh: logic, pixels, damage and title on the Master against
           build/base; lock step, display and title on the Model B against
           modelb/build/base.  Any failure reverts the edit.

Cycle neutrality is not measured here: it is what the reviewer was asked to refute.
"""
import json, os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import branchcheck

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
MERGED, LOG = 'build/grind/merged.json', 'build/grind/applied.json'
ANON_MACROS = ['MIRDIRTY_BODY', 'SPRITE_LOOPS', 'SPRLINE', 'bge16', 'bge16i', 'bgt16', 'bgt16i',
               'ble16i', 'blt16', 'blt16i', 'ringdn', 'ringmod7', 'ringup', 'spnext', 'submin0', 'sx16']
ANON_RE = re.compile(r'^\s*(?:[A-Za-z_]\w*:\s*)?(' + '|'.join(ANON_MACROS) + r')\b')

def sh(cmd, cwd=ROOT):
    r = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr

def build():
    rc, out = sh('./build.sh')
    if rc: return 'master: ' + ' | '.join(l for l in out.splitlines() if 'rror' in l)[:300]
    rc, out = sh('SKIP_ASSETS=1 ./build.sh', cwd='modelb')
    if rc: return 'modelb: ' + ' | '.join(l for l in out.splitlines() if 'rror' in l or 'overflow' in l)[:300]
    return None

def mapsize(path):
    tot, on = 0, False
    for l in open(path):
        if l.startswith('Segment list'): on = True
        elif l.startswith('Exports') or l.startswith('Imports'): on = False
        m = re.match(r'^(\w+)\s+([0-9A-F]{6})\s+([0-9A-F]{6})\s+([0-9A-F]{6})', l)
        if on and m and m.group(1) not in ('BANKFIX', 'WRFIX'): tot += int(m.group(4), 16)
    return tot

def sizes():
    b = mapsize('modelb/build/map.txt') + sum(os.path.getsize(f'modelb/build/{f}') for f in ('LDPROG', 'LOADER'))
    return mapsize('build/map.txt'), b

def anon_count(text):
    n = 0
    for l in text.split('\n'):
        code = l.split(';')[0]
        if re.match(r'^\s*:', code): n += 1
        if ANON_RE.match(code): n += 1
    return n

def listings(tag):
    os.makedirs('build/grind/lst', exist_ok=True)
    m = f'build/grind/lst/{tag}_m.lst'
    b = f'build/grind/lst/{tag}_b.lst'
    branchcheck.emit(m)
    subprocess.run(['ca65', '-g', '--cpu', '6502', '-D', 'MODELB=1', '--list-bytes', '0', '-I', 'build', '-I', 'src',
                    '-I', '../src', '-o', '/tmp/bcb.o', 'src/main.s', '-l', '../' + b],
                   cwd='modelb', check=True, capture_output=True)
    return m, b

def outside_retargets(old, new):
    """branches outside the edit, aimed at an instruction outside it, that now land
    elsewhere (branchcheck.check, with ownership = 'not matched by the diff')"""
    import difflib
    A, B = branchcheck.decode(old), branchcheck.decode(new)
    ia = {a: i for i, (a, _, _) in enumerate(A)}
    ib = {a: i for i, (a, _, _) in enumerate(B)}
    m = {}
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, [k for _, k, _ in A], [k for _, k, _ in B],
                                                       autojunk=False).get_opcodes():
        if tag == 'equal':
            for k in range(i2 - i1): m[i1 + k] = j1 + k
    bad = 0
    for i, (a, k, t) in enumerate(A):
        if t is None or i not in m: continue
        ta, tb = ia.get(t), ib.get(B[m[i]][2])
        if ta is None or tb is None or ta not in m: continue
        if m[ta] != tb: bad += 1
    return bad

def main():
    cands = json.load(open(MERGED))
    log = json.load(open(LOG)) if os.path.exists(LOG) else []
    done = {e['key'] for e in log}
    shift = {}                                  # file -> [(pristine line, delta)]
    for e in log:
        if e['result'] == 'applied': shift.setdefault(e['file'], []).append((e['lo'], e['delta_lines']))
    queue = [c for c in cands if c['verdict'] in ('accept', 'fix')]
    queue.sort(key=lambda c: (-max(c['rev_bytes_modelb'], 0), -max(c['rev_bytes_master'], 0), c['key']))
    if build(): sys.exit('the tree does not build before the grind')
    m0, b0 = sizes()
    print(f'{len(queue)} candidates to try, {len(done)} already recorded; start sizes Master {m0} Model B {b0}')
    for c in queue:
        if c['key'] in done: continue
        rec = {'key': c['key'], 'file': c['file'], 'lo': c['lo'], 'hi': c['hi']}
        path = c['file']
        text = open(path).read().split('\n')
        orig = [l.rstrip() for l in c['original'].rstrip('\n').split('\n')]
        prop = (c['fixed_proposal'] if c['verdict'] == 'fix' and c['fixed_proposal'].strip() else c['proposal'])
        prop = prop.rstrip('\n').split('\n')
        want = c['lo'] + sum(d for lo, d in shift.get(path, []) if lo < c['lo'])
        hits = [i for i in range(len(text) - len(orig) + 1)
                if [l.rstrip() for l in text[i:i + len(orig)]] == orig]
        if not hits:
            rec['result'] = 'stale'; log.append(rec); json.dump(log, open(LOG, 'w'), indent=1)
            print(f"{c['key']}: stale (original not found)"); continue
        at = min(hits, key=lambda i: abs(i + 1 - want))
        new = text[:at] + prop + text[at + len(orig):]
        anon = anon_count('\n'.join(orig)) != anon_count('\n'.join(prop))
        if anon: before = listings('before')
        open(path, 'w').write('\n'.join(new))
        def revert(why):
            open(path, 'w').write('\n'.join(text))
            rec['result'] = why; log.append(rec); json.dump(log, open(LOG, 'w'), indent=1)
            print(f"{c['key']}: {why}")
        err = build()
        if err: revert('noasm ' + err); build(); continue
        if anon:
            after = listings('after')
            bad = outside_retargets(before[0], after[0]) + outside_retargets(before[1], after[1])
            if bad: revert(f'anon: {bad} outside branch(es) retargeted'); build(); continue
        m1, b1 = sizes()
        rec['saved_master'], rec['saved_modelb'] = m0 - m1, b0 - b1
        if m1 > m0 or b1 > b0 or (m1 == m0 and b1 == b0):
            revert(f'bytes: Master {m0 - m1:+d}, Model B {b0 - b1:+d}'); build(); continue
        rc, out = sh('tools/gate.sh 200')
        if 'GATE ok' not in out:
            revert('gate: ' + ' / '.join(l for l in out.splitlines() if l and 'GATE' not in l)); build(); continue
        rec['result'] = 'applied'; rec['delta_lines'] = len(prop) - len(orig); rec['line_now'] = at + 1
        shift.setdefault(path, []).append((c['lo'], rec['delta_lines']))
        m0, b0 = m1, b1
        log.append(rec); json.dump(log, open(LOG, 'w'), indent=1)
        print(f"{c['key']}: APPLIED  Master -{rec['saved_master']}  Model B -{rec['saved_modelb']}  "
              f"(now {m0} / {b0})", flush=True)
    a = [e for e in log if e['result'] == 'applied']
    print(f"done: {len(a)} applied, Master -{sum(e['saved_master'] for e in a)}, "
          f"Model B -{sum(e['saved_modelb'] for e in a)}")

if __name__ == '__main__':
    main()
