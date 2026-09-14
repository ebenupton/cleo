#!/usr/bin/env python3
"""Prove that a source edit did not retarget any anonymous branch it does not own.

NOTE: this works on source text, so it is blind to macro expansion -- `ringup` and
`spnext` each emit a `:` of their own, and a caller branch can count into one.  Use
branchcheck.py, which reads the assembled listing, as the actual gate; this stays as a
cheap source-level explanation of WHICH label moved when that gate fires.

    python3 tools/anoncheck.py <old.s> <new.s>

ca65's `:+` / `:--` are *counted* references: they name the n-th `:` label forward or
back from the branch, so inserting or deleting a line that begins with `:` silently
repoints every counted branch that spans it.  This session has already shipped one such
edit -- deleting `:       sta gridw` retargeted a `beq :++` -- and it built clean, matched
15/15 scenes and ran 200 frames pixel-identical, because the branch only fires when
gridsh == 0.  No amount of testing finds that class of bug; it is a scope question, and
the answer is a proof, not a sample.

So: resolve every anonymous reference in both files to the line it actually lands on,
map old lines to new ones through the diff, and report any branch whose target moved.
Exit 0 if none did.
"""
import sys, re, difflib

REF = re.compile(r'(?<![A-Za-z0-9_]):([+-]+)(?![A-Za-z0-9_])')

def parse(path):
    lines = open(path).read().split('\n')
    labels, refs = [], []
    inmac = False
    for i, raw in enumerate(lines):
        l = raw.split(';')[0]
        # A macro BODY emits nothing where it is written; its labels and references
        # belong to each expansion instead.  Counting them here reports the caller's
        # branches as retargeted when nothing moved.  branchcheck.py sees the expansions.
        if re.match(r'^\s*\.macro\b', l, re.I): inmac = True; continue
        if re.match(r'^\s*\.endmacro\b', l, re.I): inmac = False; continue
        if inmac: continue
        if re.match(r'^\s*:(?![A-Za-z0-9_=])', l): labels.append(i)
        # a reference only counts in operand position, i.e. after a mnemonic
        body = re.sub(r'^\s*:(?![A-Za-z0-9_=])', '', l)
        for m in REF.finditer(body): refs.append((i, m.group(1)))
    return lines, labels, refs

def resolve(labels, i, sign):
    n = len(sign)
    if sign[0] == '+':
        c = [x for x in labels if x > i]
    else:
        c = [x for x in labels if x < i][::-1]
    return c[n - 1] if len(c) >= n else None

def linemap(a, b):
    """old line index -> new line index, for lines the diff left alone."""
    m = {}
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == 'equal':
            for k in range(i2 - i1): m[i1 + k] = j1 + k
    return m

def check(old, new, verbose=False, span=None):
    la, A, ra = parse(old)
    lb, B, rb = parse(new)
    m = linemap(la, lb)
    rbmap = {i: s for i, s in rb}
    bad, owned = [], []
    def add(rec):
        # a branch inside the edited span belongs to the patch: retargeting it may be the
        # whole point.  One outside it is collateral, and is what this tool exists to find.
        (owned if span and span[0] <= rec[0] + 1 <= span[1] else bad).append(rec)
    for i, sign in ra:
        if i not in m: continue                     # the branch itself was edited: owned
        j = m[i]
        if rbmap.get(j) != sign: add((i, sign, 'reference itself changed')); continue
        ta, tb = resolve(A, i, sign), resolve(B, j, sign)
        if ta is None or tb is None:
            add((i, sign, f'unresolved ({ta} -> {tb})')); continue
        want = m.get(ta)
        if want is None:
            add((i, sign, f'old target line {ta+1} was edited: branch now lands in the patch'))
        elif want != tb:
            add((i, sign, f'target moved: old line {ta+1} (now line {want+1}, '
                                 f'{lb[want].strip()!r}) but the branch now lands on new '
                                 f'line {tb+1} ({lb[tb].strip()!r})'))
        elif verbose:
            print(f'  ok line {i+1} :{sign} -> {lb[tb].strip()!r}')
    return bad, owned

if __name__ == '__main__':
    if len(sys.argv) < 3: sys.exit(__doc__)
    sp = next((a.split('=')[1] for a in sys.argv if a.startswith('--span=')), None)
    span = tuple(int(x) for x in sp.split(':')) if sp else None
    bad, owned = check(sys.argv[1], sys.argv[2], '-v' in sys.argv, span)
    for i, sign, why in bad:   print(f'RETARGET {sys.argv[1]}:{i+1} `:{sign}` -- {why}')
    for i, sign, why in owned: print(f'  (in-patch) {sys.argv[1]}:{i+1} `:{sign}` -- {why}')
    print(f'{len(bad)} retargeted branch(es) outside the patch'
          + (f'; {len(owned)} inside it' if owned else ''))
    sys.exit(1 if bad else 0)
