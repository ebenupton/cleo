#!/usr/bin/env python3
"""Build a behaviour-neutral variant of the current source, to test that a measurement
is invariant to code size and placement.

    python3 tools/perturb.py <variant> <outdir>

Every variant is either dead bytes that nothing references, or a pure relocation: if a
variant changed what the code DOES it would invalidate the comparison instead of
testing it.  The source tree is restored with 'git checkout -- src' afterwards, so it
refuses to run on a dirty tree.

    base            unmodified, for the reference measurement
    codepadN        N dead bytes at the very start of CODE, so every byte of CODE moves.
                    N=256 (or any multiple) moves it by whole pages, which preserves
                    every branch's page relationship -- cycles must then be IDENTICAL,
                    and that is the sharpest test in the set.
    lowpadN         pads the LOW segment (the NMI page helpers), moving calc_ring
    tablepadN       pads TABLES, moving every data table (max ~78: LOW follows it)
    logicpadN       pads the LOGIC bank, moving the logic and the level-load code
    clipold         NOT a perturbation: restores the pre-36c74b1 negate-and-subtract
                    left clip.  Same behaviour (tools/cliptest.mjs proves it over
                    198432 cases), 18 bytes bigger, 27 cycles slower on that path --
                    a real change small enough that the old benchmark could not see it.
"""
import os, re, shutil, subprocess, sys

def patch(f, old, new):
    s = open(f).read()
    if old not in s:
        raise SystemExit(f"{f}: pattern not found -- has the source moved on?\n  {old.splitlines()[0][:70]}")
    open(f, "w").write(s.replace(old, new, 1))

CODE_TOP = "        .code\n        jmp start\n"
CLIP_NEW = """        lda w16
        clc
        adc rc_w
        sta rc_w
        lda w16+1
        adc #0
        bne @none
        lda rc_w
        beq @none
"""
CLIP_OLD = """        lda w16
        eor #$FF
        sta tmp
        lda w16+1
        eor #$FF
        sta tmp2
        inc tmp
        bne :+
        inc tmp2
:       lda tmp2
        bne @none
        lda tmp
        cmp rc_w
        bcs @none
        lda rc_w
        sec
        sbc tmp
        sta rc_w
"""

def apply(name):
    if name == "base":
        return
    m = re.fullmatch(r"(codepad|lowpad|tablepad|logicpad)(\d+)", name)
    if m:
        kind, n = m.group(1), int(m.group(2))
        if kind == "codepad":
            patch("src/main.s", CODE_TOP, CODE_TOP + f"        .res {n}                ; perturbation\n")
        else:
            seg = {"lowpad": "LOW", "tablepad": "TABLES", "logicpad": "LOGIC"}[kind]
            # re-open the segment, pad, and re-open it again so the original line and
            # everything that follows it are untouched
            anchor = [l for l in open("src/engine.s") if l.strip().startswith(f'.segment "{seg}"')][0]
            patch("src/engine.s", anchor, f'        .segment "{seg}"\n        .res {n}                ; perturbation\n' + anchor)
        return
    if name == "clipold":
        patch("src/engine.s", CLIP_NEW, CLIP_OLD)
        return
    raise SystemExit(f"unknown variant {name!r} -- see the docstring")

def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    name, outdir = sys.argv[1], sys.argv[2]
    dirty = subprocess.run(["git", "status", "--porcelain", "src"], capture_output=True, text=True).stdout.strip()
    if dirty:
        raise SystemExit("src/ has uncommitted changes; this script restores it with\n"
                         "'git checkout -- src' and will not risk your work:\n" + dirty)
    try:
        apply(name)
        subprocess.run(["./build.sh"], check=True, capture_output=True)
        os.makedirs(outdir, exist_ok=True)
        for f in ("cleo.ssd", "labels.txt"):
            shutil.copy(f"build/{f}", f"{outdir}/{f}")
        seg = {}
        for line in open("build/map.txt"):
            m = re.match(r"^(ZEROPAGE|LOW2|TABLES|LOW|CODE|LOGIC)\s+([0-9A-F]+)\s+[0-9A-F]+\s+([0-9A-F]+)", line)
            if m:
                seg[m.group(1)] = (m.group(2), m.group(3))
        print(f"{name:12s} " + " ".join(f"{k}@{v[0]}+{v[1]}" for k, v in seg.items()))
    finally:
        subprocess.run(["git", "checkout", "--", "src"], check=True)
        subprocess.run(["./build.sh"], check=True, capture_output=True)

main()
