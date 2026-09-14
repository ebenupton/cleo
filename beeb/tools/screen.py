#!/usr/bin/env python3
"""Static screen of the whole proposal corpus: apply each one alone and see what happens.

    python3 tools/screen.py            screen every proposal -> build/screen.json
    python3 tools/screen.py <id>...    screen just these

Three things are decidable without an emulator, and all three kill proposals:

  match     the agent's `original` must appear exactly once in its own window.  Agents
            paraphrase; a patch that does not match is a patch against imagined code.
  assemble  ca65/ld65 must accept it, and the segment must still fit.  Free space is
            365 bytes in CODE and 884 in LOGIC, so a corpus of +12-byte "wins" runs out
            of room long before it runs out of proposals.
  anon      no anonymous branch outside the patch may change target (see anoncheck.py).

Everything that survives still has to be read, then tested.  This only removes the
proposals that were never going to work.
"""
import json, os, sys, subprocess, shutil, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tryproposal import apply_one
import anoncheck, branchcheck

SEG_LIMIT = {'CODE': 0x2200, 'LOGIC': 0x2700, 'LOW': 0xED, 'LOW2': 0x1FA,
             'TABLES': 0x900, 'ZEROPAGE': 0xA8}

def segs():
    out = {}
    for l in open('build/map.txt'):
        m = re.match(r'^(\w+)\s+([0-9A-F]{6})\s+([0-9A-F]{6})\s+([0-9A-F]{6})', l)
        if m and m.group(1) in SEG_LIMIT: out[m.group(1)] = int(m.group(4), 16)
    return out

def build():
    r = subprocess.run(['./build.sh'], capture_output=True, text=True)
    return (r.returncode == 0), (r.stderr + r.stdout)

def linemap(a, b):
    import difflib
    m = {}
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == 'equal':
            for k in range(i2 - i1): m[i1 + k + 1] = j1 + k + 1
    return m

def ownership(dbg='build/cleo.dbg'):
    """(segname, offset) -> (file, line) for the baseline build.

    A retarget only means something if the patch did not cause it, and the patch is a
    range of source lines.  The debug file is what connects the two: it attributes every
    assembled address to the line that produced it, macro expansions included."""
    import re as _re
    from annotate_profile import parse_dbg
    files, segs, spans, lines = parse_dbg(dbg)
    name = {}
    for l in open(dbg):
        m = _re.match(r'^seg\tid=(\d+),name="(\w+)",start=0x([0-9A-Fa-f]+)', l)
        if m: name[m.group(2)] = (int(m.group(1)), int(m.group(3), 16))
    a2l = {}
    for fid, ln, sp in lines:
        if sp not in spans: continue
        seg, start, size = spans[sp]
        if seg not in segs: continue
        for a in range(segs[seg] + start, segs[seg] + start + size): a2l[a] = (fid, ln)
    base = {n: b for n, (i, b) in name.items()}
    fname = {i: os.path.basename(v) for i, v in files.items()}
    def at(seg, off):
        r = a2l.get(base.get(seg, -1 << 20) + off)
        return (fname[r[0]], r[1]) if r else None
    return at

def owned_lines(path, span):
    """The source lines a patch at `span` is responsible for.

    Code inside a .macro body is attributed by the debug file to every line that INVOKES
    the macro, not to the body, so a patch in SPRLINE shows up as changing code at the
    `l0: SPRLINE 0, ...` lines instead.  Walk the invocation chain so those count as the
    patch's own."""
    src = open(path).read().split('\n')
    bodies, stack = {}, []            # macro name -> (first, last) body line, 1-based
    for i, l in enumerate(src, 1):
        m = re.match(r'\s*\.macro\s+(\w+)', l, re.I)
        if m: stack.append((m.group(1), i)); continue
        if re.match(r'\s*\.endmacro\b', l, re.I) and stack:
            n, a = stack.pop(); bodies[n] = (a, i)
    out = set(range(span[0], span[1] + 1))
    seen = set()
    frontier = [n for n, (a, b) in bodies.items() if a <= span[0] <= b]
    while frontier:
        n = frontier.pop()
        if n in seen: continue
        seen.add(n)
        for i, l in enumerate(src, 1):
            if re.match(rf'\s*(?:\w+:\s*)?{re.escape(n)}\b', l):
                out.add(i)
                for m2, (a, b) in bodies.items():
                    if a <= i <= b: frontier.append(m2)
    return out

BASE_LST = '/tmp/screen_base.lst'
NEW_LST = '/tmp/screen_new.lst'

def clean():
    subprocess.run(['git', 'checkout', '--', 'src/'], check=True)

def main():
    props = json.load(open('opt/proposals.json'))
    want = set(sys.argv[1:])
    clean()
    ok, _ = build()
    assert ok, 'baseline does not build'
    branchcheck.emit(BASE_LST)
    at = ownership()
    base_seg = segs()
    base_bin = open('build/CLEO', 'rb').read(), open('build/LOGIC', 'rb').read()
    print('baseline free:', {k: SEG_LIMIT[k] - v for k, v in sorted(base_seg.items())})
    res = []
    for p in props:
        if want and p['id'] not in want: continue
        clean()
        path = os.path.join('src', p['file'])
        old = '/tmp/screen_old.s'; shutil.copy(path, old)
        r = {'id': p['id'], 'file': p['file'], 'lo': p['lo'], 'hi': p['hi'],
             'routine': p['routine'], 'weighted': p['weighted'],
             'saving_cycles': p['saving_cycles'], 'saving_bytes': p['saving_bytes'],
             'confidence': p.get('confidence'), 'batch': p['batch']}
        err = apply_one(p, backup=False)
        if err:
            r['status'] = 'nomatch'; r['why'] = err; res.append(r); continue
        span = p['_span']
        bad, owned = anoncheck.check(old, path, span=span)
        r['anon_bad'] = [f'{i+1} :{s} {w}' for i, s, w in bad]
        r['anon_owned'] = len(owned)
        ok, log = build()
        if not ok:
            r['status'] = 'noasm'
            r['why'] = next((l for l in log.split('\n') if 'Error' in l), log.strip()[-200:])
            res.append(r); continue
        # THE GATE, in two independent passes because each has a blind spot.
        #
        # Instruction level: decode both listings, align them, and flag any branch whose
        # target instruction moved.  This sees inside macro expansions, which source-level
        # counting cannot -- ringup and spnext each emit a ':' of their own, so a caller's
        # counted branch can resolve into one.  Its weakness is that relocatable operands
        # are masked, which makes bgt16 and bge16 expand to identical bytes, so the aligner
        # can pair one routine's branch with another's.
        #
        # So every hit is then confirmed at source-line granularity through the debug
        # file: if the old target line maps through the edit onto the new target line, the
        # branch did not actually move and the hit was an alignment artifact.
        try:
            branchcheck.emit(NEW_LST)
            ol = owned_lines(path, span)
            own = lambda a: (lambda q: q is not None and q[0] == p['file'] and q[1] in ol)(at(*a))
            hits, mine = branchcheck.check(BASE_LST, NEW_LST, own)
            at2 = ownership()
            lm = linemap(open(old).read().split('\n'), open(path).read().split('\n'))
            rt = []
            for a, t, c, _, _ in hits:
                qa, qb = at(*t), at2(*c)
                if qa and qb and qa[0] == qb[0] and lm.get(qa[1]) == qb[1]: continue
                rt.append(f'{a[0]}+${a[1]:04X} -> +${c[1]:04X}'
                          + (f' branch@{at(*a)[0]}:{at(*a)[1]}' if at(*a) else '')
                          + (f' target {qa[0]}:{qa[1]}->{qb[0]}:{qb[1]}' if qa and qb else ''))
        except Exception as e:
            rt, mine = [f'branchcheck failed: {e}'], []
        r['retarget'] = rt
        r['retarget_own'] = len(mine)
        s = segs()
        r['delta'] = {k: s[k] - base_seg[k] for k in s if s[k] != base_seg[k]}
        r['over'] = {k: s[k] - SEG_LIMIT[k] for k in s if s[k] > SEG_LIMIT[k]}
        now = open('build/CLEO', 'rb').read(), open('build/LOGIC', 'rb').read()
        r['status'] = ('overflow' if r['over'] else
                       'noop' if now == base_bin else
                       'retarget' if rt else 'built')
        res.append(r)
        print(f"{r['status']:9} {p['id']:16} {str(r['delta']):28} {p['weighted']:>8} cy/frm"
              + (f"  RETARGET {rt[0]}" if rt else '')
              + (f"  anon:{len(bad)}" if bad else ''))
        sys.stdout.flush()
    clean(); build()
    json.dump(res, open('build/screen.json', 'w'), indent=1)
    import collections
    print('\n', collections.Counter(x['status'] for x in res))

if __name__ == '__main__': main()

