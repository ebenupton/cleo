#!/usr/bin/env python3
"""Every branch and jump still lands where it did: an edit's check against retargeting.

Deleting or adding a line with an anonymous label (`:`) retargets every :+ / :- that counts
past it -- anywhere in the assembly unit, macro expansions included -- and a cold path
escapes every replay.  This compares two builds' code through their debug files (beebgame's
tools/dataflow model): for each relative branch, JMP and JSR, the source line it is on and
the source line of the instruction it reaches.  The old build's sources are its commit's (the
model takes a file from git when the disc copy no longer matches the debug file); the new
build's are the tree's; lines are matched between the two by a diff.  An instruction of a
macro's expansion is placed by its line in the macro's body as well as the call's.  Every branch on an
unchanged line must reach the same (matched) line, the same instruction of it.  A branch whose
target line was itself edited is listed for a look; one whose target moved to another
unchanged line is an error.

Usage (from beeb/):
    python3 tools/dfgrind/branchcmp.py <old build dir> [new build dir = build]
Each holds master/ and modelb/ (game.dbg and the images).  Exit 1 on any error.
"""
import os, sys, difflib, collections
sys.dont_write_bytecode = True
BEEB = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(BEEB, 'beebgame', 'tools', 'dataflow'))
import model, gamecfg

def edges(P):
    """{(seg, file, line, ifile, iline, k): (file, line, ifile, iline, k) of the target}: a
    line is the instruction's outer source line and its inner one (the macro body's line
    for an expansion, else the same), k numbers the instructions of one (seg, outer, inner)
    by address"""
    def where(i):
        return (P.src.short(i.outer['file']), i.outer['line'], P.src.short(i.inner['file']), i.inner['line'])
    by = collections.defaultdict(list)
    for i in P.insns.values():
        by[(i.seg,) + where(i)].append(i)
    kof = {}
    for key, L in by.items():
        for k, i in enumerate(sorted(L, key=lambda i: i.addr)):
            kof[i.key] = k
    out = {}
    for i in P.insns.values():
        if i.mode == 'rel' or (i.mn in ('JMP', 'JSR') and i.mode == 'abs'):
            if i.opnd is None:
                continue
            t = P.resolve(i.opnd, i.seg)
            if t is None:
                continue
            out[(i.seg,) + where(i) + (kof[i.key],)] = where(t) + (kof[t.key],)
    return out

def linemap(P0, P1):
    """{file: {old line: new line}} over the lines a diff finds unchanged"""
    new = {P1.src.short(f): L for f, L in P1.src.lines.items()}
    m = {}
    for f, L in P0.src.lines.items():
        n = P0.src.short(f)
        if n not in new:
            continue
        sm = difflib.SequenceMatcher(None, L, new[n], autojunk=False)
        d = {}
        for a, b, size in sm.get_matching_blocks():
            for j in range(size):
                d[a + j + 1] = b + j + 1
        m[n] = d
    return m

old, new = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else os.path.join(BEEB, 'build'))
gamecfg.load(None)
bad = 0
for mach in ('modelb', 'master'):
    P0 = model.Program(BEEB, os.path.join(old, mach))
    P1 = model.Program(BEEB, os.path.join(new, mach))
    E0, E1 = edges(P0), edges(P1)
    M = linemap(P0, P1)
    look = 0
    for (seg, f, ln, jf, jl, k), (tf, tl, uf, ul, tk) in E0.items():
        nl, njl = M.get(f, {}).get(ln), M.get(jf, {}).get(jl)
        if nl is None or njl is None:
            continue                            # the branch's own line was edited
        e1 = E1.get((seg, f, nl, jf, njl, k))
        if e1 is None:
            print(f'{mach}: {f}:{ln} ({jf}:{jl}, now {nl}/{njl}) {seg}: the branch is gone or not decoded')
            bad += 1
            continue
        ntl, nul = M.get(tf, {}).get(tl), M.get(uf, {}).get(ul)
        if ntl is None or nul is None:
            look += 1
            print(f'{mach}: {f}:{ln} -> {uf}:{ul} (an edited line): now -> {e1[2]}:{e1[3]}  (look)')
        elif (tf, ntl, uf, nul, tk) != e1:
            print(f'{mach}: ERROR {f}:{ln} ({jf}:{jl}) went to {uf}:{ul} (now {nul}), now goes to {e1[2]}:{e1[3]}#{e1[4]}')
            bad += 1
    print(f'{mach}: {len(E0)} branches and jumps; {look} into edited lines; {bad} errors so far')
sys.exit(1 if bad else 0)
