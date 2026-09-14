#!/usr/bin/env python3
"""Apply the screened corpus greedily, in value order, gating every step.

    python3 tools/apply_all.py [--only id,id,...] [--skip id,id,...] [--max N]

Greedy is the right shape here.  76 of the 127 clusters hold more than one proposal for
the same lines, and picking a "cluster winner" up front assumes they conflict; often they
do not.  engine_2199 rewrites mirror_run's copy and engine_2208 rewrites the pointer
advance just below it -- the windows overlap, the edits do not.  So: take them best-first,
and let a proposal whose `original` no longer matches simply fall out.  Whatever the
earlier, more valuable edit left behind is the truth.

Every accepted step is snapshotted to build/accum/NNN so a later behavioural failure can
be bisected to the proposal that caused it.
"""
import json, os, sys, shutil, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tryproposal import apply_one
import branchcheck, screen

ACC = 'build/accum'
LST_A, LST_B = '/tmp/aa_a.lst', '/tmp/aa_b.lst'

def build():
    r = subprocess.run(['./build.sh'], capture_output=True, text=True)
    return r.returncode == 0, r.stdout + r.stderr

def main():
    args = sys.argv[1:]
    def opt(n):
        return args[args.index(n) + 1] if n in args else None
    only = set((opt('--only') or '').split(',')) - {''}
    skip = set((opt('--skip') or '').split(',')) - {''}
    lim = int(opt('--max') or 10 ** 9)

    props = [p for p in json.load(open('opt/proposals.json'))]
    scr = {x['id']: x for x in json.load(open('build/screen.json'))}
    props = [p for p in props if scr.get(p['id'], {}).get('status') == 'built'
             and p['id'] not in skip and (not only or p['id'] in only)]
    props.sort(key=lambda p: -p['weighted'])

    subprocess.run(['git', 'checkout', '--', 'src/'], check=True)
    shutil.rmtree(ACC, ignore_errors=True); os.makedirs(ACC)
    ok, log = build()
    assert ok, log
    branchcheck.emit(LST_A)
    at = screen.ownership()
    base_seg = screen.segs()

    # Every accepted edit moves the lines below it, and the proposals still carry the
    # coordinates of the pristine file.  Without this, a proposal in scan_keys is looked
    # for at its old line number, is not there, and is written off as "superseded" by an
    # edit hundreds of lines away that has nothing to do with it.
    shift = {f: {i: i for i in range(1, len(open(f'src/{f}').read().split(chr(10))) + 2)}
             for f in {p['file'] for p in props}}

    def cur(f, ln, up):
        m = shift[f]
        for d in range(0, 400):
            v = m.get(ln + (d if up else -d))
            if v is not None: return v
        return ln

    accepted, log_rows = [], []
    for p in props:
        if len(accepted) >= lim: break
        path = os.path.join('src', p['file'])
        old = '/tmp/aa_old.s'; shutil.copy(path, old)
        why = None
        olo, ohi = p['lo'], p['hi']
        p['lo'], p['hi'] = cur(p['file'], olo, False), cur(p['file'], ohi, True)
        err = apply_one(p, backup=False)
        if err:
            why = f'superseded: {err}'
        else:
            ok, blog = build()
            if not ok:
                why = 'noasm: ' + next((l for l in blog.split('\n') if 'Error' in l), '')[:120]
            else:
                s = screen.segs()
                over = {k: s[k] - screen.SEG_LIMIT[k] for k in s if s[k] > screen.SEG_LIMIT[k]}
                if over: why = f'overflow {over}'
                else:
                    branchcheck.emit(LST_B)
                    at2 = screen.ownership()
                    ol = screen.owned_lines(path, p['_span'])
                    own = lambda a: (lambda q: q is not None and q[0] == p['file']
                                     and q[1] in ol)(at(*a))
                    hits, _ = branchcheck.check(LST_A, LST_B, own)
                    lm = screen.linemap(open(old).read().split('\n'),
                                        open(path).read().split('\n'))
                    rt = [h for h in hits
                          if not (at(*h[1]) and at2(*h[2]) and at(*h[1])[0] == at2(*h[2])[0]
                                  and lm.get(at(*h[1])[1]) == at2(*h[2])[1])]
                    if rt:
                        why = f'retarget {at(*rt[0][0])} -> {at2(*rt[0][2])}'
        if why:
            shutil.copy(old, path)
            p['lo'], p['hi'] = olo, ohi
            log_rows.append({**{k: p[k] for k in ('id', 'file', 'routine', 'weighted')},
                             'result': 'rejected', 'why': why})
            print(f'  --  {p["id"]:16} {p["weighted"]:>8}  {why[:90]}')
        else:
            accepted.append(p['id'])
            n = len(accepted)
            os.makedirs(f'{ACC}/{n:03d}')
            for f in os.listdir('src'): shutil.copy(f'src/{f}', f'{ACC}/{n:03d}/{f}')
            shutil.copy(LST_B, LST_A); at = at2
            lm2 = screen.linemap(open(old).read().split('\n'), open(path).read().split('\n'))
            shift[p['file']] = {o: lm2[c] for o, c in shift[p['file']].items() if c in lm2}
            p['lo'], p['hi'] = olo, ohi
            log_rows.append({**{k: p[k] for k in ('id', 'file', 'routine', 'weighted')},
                             'result': 'applied', 'n': n})
            print(f'  {n:3d} {p["id"]:16} {p["weighted"]:>8}  {p["routine"]}')
        sys.stdout.flush()
    s = screen.segs()
    print('\nfree after:', {k: screen.SEG_LIMIT[k] - v for k, v in sorted(s.items())})
    print('was:       ', {k: screen.SEG_LIMIT[k] - v for k, v in sorted(base_seg.items())})
    json.dump({'accepted': accepted, 'log': log_rows}, open('build/applied.json', 'w'), indent=1)
    print(f'{len(accepted)} applied of {len(props)} screened')

if __name__ == '__main__': main()
