#!/usr/bin/env python3
"""Find instances of the macro idioms the agent farm kept rediscovering.

    python3 tools/idioms.py

The farm was given 16-instruction windows, so it could only report an idiom where one
happened to fall inside a window it was handed.  Several agents independently reported
the same two, which says they are classes rather than incidents -- so find every
instance, including the ones no window covered.

  fuse   mov16 D,S  immediately followed by  add16i D,n / add16 D,z / sub16i D,n
         The copy is dead: the add can read S directly.  ~12-16 cycles each.
  stz    mov16i D,imm  where a half of imm is zero
         The macro emits lda #0 / sta; stz does it in one.  2 cycles and a byte each.
"""
import re, glob, os

fuse, stzable = [], []
for path in sorted(glob.glob('src/*.s')):
    lines = open(path).read().split('\n')
    code = [(i + 1, l.split(';')[0].strip()) for i, l in enumerate(lines)]
    body = [(n, c) for n, c in code if c]
    for k in range(len(body) - 1):
        n1, c1 = body[k]; n2, c2 = body[k + 1]
        m1 = re.match(r'^mov16\s+(\w+)\s*,\s*(\w+)$', c1)
        m2 = re.match(r'^(add16i|sub16i)\s+(\w+)\s*,\s*(-?\w+)$', c2) or \
             re.match(r'^(add16|sub16)\s+(\w+)\s*,\s*(\w+)$', c2)
        if m1 and m2 and m1.group(1) == m2.group(2) and n2 == n1 + 1:
            fuse.append((os.path.basename(path), n1, c1, c2))
    for n, c in body:
        m = re.match(r'^mov16i\s+(\w+)\s*,\s*(-?\$?[0-9A-Fa-fx]+)$', c)
        if not m: continue
        v = m.group(2)
        try: val = int(v[1:], 16) if v.startswith('$') else int(v, 0)
        except ValueError: continue
        val &= 0xFFFF
        if (val & 0xFF) == 0 or (val >> 8) == 0:
            stzable.append((os.path.basename(path), n, c, 'low' if (val & 0xFF) == 0 else 'high'))

print(f'mov16 + add/sub on the same destination -- the copy is dead ({len(fuse)}):')
for f, n, a, b in fuse: print(f'  {f}:{n}  {a}   /   {b}')
print(f'\nmov16i with a zero half -- stz serves ({len(stzable)}):')
for f, n, c, half in stzable: print(f'  {f}:{n}  {c}   ({half} byte is zero)')
print(f'\ntotals: {len(fuse)} fusions, {len(stzable)} stz opportunities')
