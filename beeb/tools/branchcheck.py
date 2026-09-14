#!/usr/bin/env python3
"""Prove no branch outside the edit changed which instruction it lands on.

    python3 tools/branchcheck.py <old.lst> <new.lst>
    python3 tools/branchcheck.py --emit <out.lst>      assemble the tree into a listing

anoncheck.py answers this at source level, and that is not enough: `ringup` and `spnext`
each emit a `:` label of their own, so a counted branch in the caller can resolve INTO a
macro, and a source-level count cannot see it.  ca65 can.  With --list-bytes 0 the
listing carries every expanded byte with branch displacements already resolved, so:
decode the instruction stream, align old against new, and check that every branch the
diff left alone still targets the same instruction.  Macros, .if bodies and all.
"""
import sys, re, subprocess, difflib

# 65C02 instruction lengths, 16 per row.  The rows are near-identical by design of the
# opcode map; the irregular entries are the 65C02 additions (STZ, TRB/TSB, BRA, INC A).
LEN = bytes(int(c) for c in (
    "1221222212113333" "2221222213113333" "3221222212113333" "2221222213113333"
    "1221222212113333" "2221222213113333" "1221222212113333" "2221222213113333"
    "2221222212113333" "2221222213113333" "2221222212113333" "2221222213113333"
    "2221222212113333" "2221222213113333" "2221222212113333" "2221222213113333"))
REL = {0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0, 0x80}
RELBIT = {o for o in range(0x0F, 0x100, 0x10)}          # BBR0-7 / BBS0-7, rel in byte 3
ROW = re.compile(r'^([0-9A-F]{6})r?\s+\d+\s{2}((?:[0-9A-Frx]{2} )+)')
# Listing addresses are per-segment offsets, and every segment restarts at zero, so an
# address alone is ambiguous: CODE $0030 and LOGIC $0030 are different instructions.
SEG = re.compile(r'^\s*(?:\.segment\s+"(\w+)"|\.(code|zeropage|bss|rodata|data)\b)')

def emit(path):
    subprocess.run(['ca65', '-g', '--cpu', '65C02', '--list-bytes', '0', '-I', 'src',
                    '-I', 'build', '-o', '/tmp/bc.o', 'src/main.s', '-l', path],
                   check=True, capture_output=True)

def decode(path):
    """-> [(addr, key, target_addr|None)] in address order, per assembly segment."""
    mem, seg = {}, 'CODE'
    for line in open(path):
        t = line[line.find('  ', 9):] if len(line) > 11 else line
        ms = SEG.search(t)
        if ms: seg = (ms.group(1) or ms.group(2)).upper()
        m = ROW.match(line)
        if not m: continue
        a = (seg, int(m.group(1), 16))
        for i, b in enumerate(m.group(2).split()):
            # 'rr'/'xx' mark an operand the linker fills in; the byte is unknown but its
            # position is not, and no branch displacement is ever relocatable.
            mem[(a[0], a[1] + i)] = None if not re.fullmatch(r'[0-9A-F]{2}', b) else int(b, 16)
    ins = []
    addrs = sorted(mem)
    i = 0
    while i < len(addrs):
        sg, a = addrs[i]
        op = mem[(sg, a)]
        if op is None: i += 1; continue
        n = LEN[op]
        if any((sg, a + k) not in mem for k in range(n)): i += 1; continue
        tgt = None
        if op in REL:
            d = mem[(sg, a + 1)]
            if d is not None: tgt = (sg, (a + 2 + (d - 256 if d > 127 else d)) & 0xFFFF)
        elif op in RELBIT and n == 3:
            d = mem[(sg, a + 2)]
            if d is not None: tgt = (sg, (a + 3 + (d - 256 if d > 127 else d)) & 0xFFFF)
        key = (op,) + tuple(mem[(sg, a + k)] for k in range(1, n))
        if op in REL: key = (op,)                  # the displacement is what may change
        ins.append(((sg, a), key, tgt))
        i += n
        while i < len(addrs) and addrs[i] < (sg, a + n): i += 1
    return ins

def branches(path):
    """[(seg, off, target_seg, target_off)] for every relative branch in the listing."""
    return [(a[0], a[1], t[0], t[1]) for a, k, t in decode(path) if t is not None]

def check(old, new, owned=None):
    A, B = decode(old), decode(new)
    ia = {a: i for i, (a, _, _) in enumerate(A)}
    ib = {a: i for i, (a, _, _) in enumerate(B)}
    m = {}
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(
            None, [k for _, k, _ in A], [k for _, k, _ in B], autojunk=False).get_opcodes():
        if tag == 'equal':
            for k in range(i2 - i1): m[i1 + k] = j1 + k
    bad, mine = [], []
    for i, (a, k, t) in enumerate(A):
        if t is None or i not in m: continue        # branch itself was edited: owned
        j = m[i]
        ta, tb = ia.get(t), ib.get(B[j][2])
        if ta is None or tb is None: continue       # target not an instruction start
        if m.get(ta) != tb:
            # A branch the patch itself rewrote -- `bcc :+ / jmp x / : / bra y` collapsed
            # to `bcc y / jmp x` -- retargets by design.  Only a branch the edit did not
            # touch is evidence of a miscount, so the caller supplies the ownership test.
            # Owned at either end: a branch the patch rewrote, or one aimed INTO the
            # patch, whose target instruction is bound to realign when the patch changes
            # the instruction count there.  Only outside-to-outside is evidence.
            (mine if owned and (owned(a) or owned(t)) else bad).append(
                (a, t, B[j][2], A[ta][1], B[tb][1]))
    return bad, mine

if __name__ == '__main__':
    if sys.argv[1] == '--emit': emit(sys.argv[2]); sys.exit()
    bad, mine = check(sys.argv[1], sys.argv[2])
    for a, t, t2, ka, kb in bad:
        print(f'RETARGET branch at {a[0]}+${a[1]:04X}: was +${t[1]:04X} (op {ka[0]:02X}), '
              f'now +${t2[1]:04X} (op {kb[0]:02X})')
    print(f'{len(bad)} branch(es) retargeted'
          + (f'; {len(mine)} inside the patch' if mine else ''))
    sys.exit(1 if bad else 0)
