#!/usr/bin/env python3
"""Audit an object handler before converting it to direct field access.

    python3 tools/objaudit.py ob_tramp [ob_snake ...]

For each handler: which of ox/oy/fa..fe it reads and writes, whether it or anything it
calls touches Y (the object index has to survive), and whether anything switches bank
before the last field write (the arrays live in bank 7).  Following the calls one level
down is the point -- ob_star was safe only because none of its five helpers touched Y.
"""
import re, sys, os
SRC = {f: open(os.path.join(os.path.dirname(__file__), "..", "src", f)).read().splitlines()
       for f in ("logic.s", "engine.s")}
LBL = re.compile(r'^([a-z_][a-z_0-9]*):')
def body(name):
    for f, lines in SRC.items():
        for i, ln in enumerate(lines):
            m = LBL.match(ln)
            if m and m.group(1) == name:
                out = [ln]
                for j in range(i + 1, len(lines)):
                    if LBL.match(lines[j]): break
                    out.append(lines[j])
                return out
    return None
FIELDS = ("ox", "oy", "fa", "fb", "fc", "fd", "fe")
def audit(name, seen=None, depth=0):
    seen = seen or set()
    if name in seen: return set(), set(), False, False, []
    seen.add(name)
    b = body(name)
    if b is None: return set(), set(), False, False, []
    rd, wr, ty, bank, calls = set(), set(), False, False, []
    for ln in b:
        c = ln.split(';')[0]
        for f in FIELDS:
            if re.search(r'\b(sta|stz|stza|inc|dec)\s+' + f + r'\b', c): wr.add(f)
            elif re.search(r'\b' + f + r'\b', c): rd.add(f)
        if re.search(r'^\s+(ldy|tay|iny|dey|tya)\b', c): ty = True
        if re.search(r'setbank|ROMSEL', c): bank = True
        calls += re.findall(r'\bjsr\s+([a-z_][a-z_0-9]*)', c)
    for cal in set(calls):
        r2, w2, t2, b2, _ = audit(cal, seen, depth + 1)
        rd |= r2; wr |= w2; ty |= t2; bank |= b2
    return rd, wr, ty, bank, sorted(set(calls))
for n in sys.argv[1:]:
    rd, wr, ty, bank, calls = audit(n)
    rd -= wr
    print(f"{n}:")
    print(f"   reads  {' '.join(sorted(rd)) or '-'}")
    print(f"   writes {' '.join(sorted(wr)) or '-'}")
    print(f"   Y touched by it or a callee: {'YES -- must reload ldy obj' if ty else 'no'}")
    print(f"   bank switched: {'YES -- check it is after the last write' if bank else 'no'}")
    print(f"   calls: {' '.join(calls) or '-'}")
