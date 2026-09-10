#!/usr/bin/env python3
"""zpliveness — conservative interprocedural zero-page liveness, for overlaying.

Ported from the DOOM BBC Micro port's tools/zpliveness.py; the analysis is
unchanged, the front end is Cleo's (src/*.s, build/labels.txt).

    python3 tools/zpliveness.py            the overlay report
    python3 tools/zpliveness.py --fn NAME  one routine's sets
    python3 tools/zpliveness.py --free     the bytes nothing references

THE SAFETY CONDITION.  Two routines may share a byte iff neither can be on
the call stack while the other runs, i.e. neither is reachable from the
other.  So:

  1. call graph, with computed/patched dispatch edges included
     CONSERVATIVELY (a dispatcher reaches every one of its known targets);
  2. per-routine zero-page reference set, from the source;
  3. subtree(f) = f and everything it can reach;
  4. byte b is PRIVATE to f iff every routine referencing b is in
     subtree(f) — nobody outside f's subtree can observe it.

WHY STATIC AND NOT A TRACE.  A dynamic corpus proves what IS touched, never
what CAN be.  Overlay allocation has to be sound for paths the corpus never
takes, so every input here comes from the source.

CONSERVATISM, deliberately in this direction:
  - a symbol referenced ANYWHERE outside a subtree disqualifies the byte;
  - a routine whose callers cannot all be identified is treated as a root
    (reachable from anywhere), so nothing overlays it;
  - literal $xx operands count as references to that byte;
  - the interrupt handlers are roots: they can run between any two
    instructions, so anything they touch is live everywhere.
"""
import re, os, sys, glob, argparse, collections

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(ROOT)

FILES = sorted(glob.glob('src/*.s'))
LABEL = re.compile(r'^(?:::)?([A-Za-z_][A-Za-z0-9_]*):(.*)$')
EQU = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]{1,2})\s*$')
CALL = re.compile(r'\b(?:jsr|jmp|bra)\s+([A-Za-z_][A-Za-z0-9_]*)\b', re.I)
OPS = (r'lda|sta|ldx|stx|ldy|sty|adc|sbc|and|ora|eor|cmp|cpx|cpy|bit|inc|dec|'
       r'asl|lsr|rol|ror|stz|trb|tsb')
SYMOP = re.compile(r'\b(?:' + OPS + r')\s+'
                   r'(?:#?<|#?>)?\(?\s*([A-Za-z_][A-Za-z0-9_]*|\$[0-9A-Fa-f]{1,2})\b',
                   re.I)
# (zp),y / (zp,x) / (zp) reference the pointer's two bytes
INDOP = re.compile(r'\((\s*[A-Za-z_][A-Za-z0-9_]*|\s*\$[0-9A-Fa-f]{1,2})\s*[,)]')
# a macro call passes symbols as operands; treat every bare identifier in a
# macro invocation line as a reference (macros are all 16-bit helpers here)
MACROCALL = re.compile(r'^\s*(mov16i?|add16i?|sub16i?|dif16|asr16|asl16|neg16|'
                       r'sx16|submin0|bgt16i?|blt16i?|bge16i?|ble16i?|bmi16|'
                       r'bpl16|beq16|bne16|setbank|SPRLINE\d?|CPY1|FIL1)\b(.*)$')
IDENT = re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*)\b')


def zp_symbols():
    """Every symbol that lands in $00-$FF: linker labels plus source equates."""
    zp = {}
    for ln in open('build/labels.txt'):
        p = ln.split()
        if len(p) == 3 and p[0] == 'al':
            a = int(p[1], 16)
            n = p[2].lstrip('.')
            if a < 0x100 and not n.startswith('__'):
                zp[n] = a
    for f in FILES:
        for ln in open(f, errors='ignore'):
            m = EQU.match(ln.split(';')[0].strip())
            if m:
                zp[m.group(1)] = int(m.group(2), 16)
    return zp


def zp_sizes(zp):
    """Bytes each symbol covers: `.res n` where the source says so; for the
    manual equates (ox = $A8 ...) the gap to the next equate, since they are
    hand-packed and the 16-bit ones are referenced as `name+1`."""
    size = {n: 1 for n in zp}
    res = set()
    for f in FILES:
        for ln in open(f, errors='ignore'):
            code = ln.split(';')[0]
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):\s*\.res\s+(\d+)', code.strip())
            if m and m.group(1) in size:
                size[m.group(1)] = int(m.group(2)); res.add(m.group(1))
    equ = sorted(((a, n) for n, a in zp.items() if n not in res), key=lambda x: x[0])
    for i, (a, n) in enumerate(equ):
        nxt = equ[i + 1][0] if i + 1 < len(equ) else a + 1
        size[n] = max(1, min(nxt - a, 4))
    return size


# entry points that are never the target of a jsr/jmp: the interrupt handlers
# (installed in IRQ1V / the NMI page) and the program entry
ROOTS = ('irq_handler', 'nmi_handler', 'start')

def call_targets():
    tg = set(ROOTS)
    for f in FILES:
        for ln in open(f, errors='ignore'):
            tg.update(CALL.findall(ln.split(';')[0]))
    return tg


def parse(zp):
    """-> routines: name -> dict(file, line, calls:set, refs:set(symbol))"""
    TARGETS = call_targets()
    routines, cur = {}, None
    for f in FILES:
        for lno, ln in enumerate(open(f, errors='ignore'), 1):
            code = ln.split(';')[0].rstrip()
            if not code.strip():
                continue
            m = LABEL.match(code.strip())
            if m:
                if m.group(1) in TARGETS:
                    cur = m.group(1)
                    routines.setdefault(cur, dict(file=f, line=lno, calls=set(),
                                                  refs=set()))
                code = m.group(2)
            if cur is None:
                continue
            r = routines[cur]
            r['calls'].update(CALL.findall(code))
            for op in SYMOP.findall(code):
                r['refs'].add(op)
            for op in INDOP.findall(code):
                r['refs'].add(op.strip())
            mc = MACROCALL.match(code)
            if mc:
                for ident in IDENT.findall(mc.group(2)):
                    if ident in zp:
                        r['refs'].add(ident)
    # normalise: literal $xx -> the symbol at that address if there is one
    byaddr = {}
    for n, a in zp.items():
        byaddr.setdefault(a, n)
    for r in routines.values():
        out = set()
        for x in r['refs']:
            if x.startswith('$'):
                a = int(x[1:], 16)
                out.add(byaddr.get(a, f'${a:02X}'))
            elif x in zp:
                out.add(x)
        r['refs'] = out
    return routines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--fn')
    ap.add_argument('--free', action='store_true')
    args = ap.parse_args()
    zp = zp_symbols()
    size = zp_sizes(zp)
    routines = parse(zp)

    # bytes covered by each symbol
    bytes_of = {}
    for n, a in zp.items():
        bytes_of[n] = set(range(a, min(a + size.get(n, 1), 0x100)))

    if args.free:
        used = set()
        for r in routines.values():
            for s in r['refs']:
                used |= bytes_of.get(s, set())
        # MOS and hardware reservations on the Master
        mos = set(range(0xF0, 0x100)) | {0xFC, 0xFD, 0xFE, 0xFF}
        free = [b for b in range(0x100) if b not in used and b not in mos]
        runs, start = [], None
        for b in range(0x100):
            if b in free and start is None:
                start = b
            elif b not in free and start is not None:
                runs.append((start, b - 1)); start = None
        if start is not None:
            runs.append((start, 0xFF))
        print(f"{len(free)} zero-page bytes referenced by nothing "
              f"(MOS $F0-$FF excluded):")
        for lo, hi in runs:
            print(f"  ${lo:02X}-${hi:02X}  ({hi - lo + 1})")
        return

    # reachability
    succ = {n: {c for c in r['calls'] if c in routines} for n, r in routines.items()}
    def subtree(f):
        seen, wl = set(), [f]
        while wl:
            x = wl.pop()
            if x in seen:
                continue
            seen.add(x)
            wl.extend(succ.get(x, ()))
        return seen
    sub = {f: subtree(f) for f in routines}

    called_by = collections.defaultdict(set)
    for n, ss in succ.items():
        for s in ss:
            called_by[s].add(n)

    # interrupt handlers (and anything they reach) are live everywhere
    isr = set()
    for e in ('irq_handler', 'nmi_handler'):
        if e in routines:
            isr |= sub[e]
    isr_refs = set()
    for f in isr:
        isr_refs |= routines[f]['refs']

    if args.fn:
        f = args.fn
        if f not in routines:
            print(f"no routine {f}; known: {len(routines)}")
            return
        print(f"{f} ({routines[f]['file']}:{routines[f]['line']})")
        print(f"  calls    : {' '.join(sorted(succ[f])) or '-'}")
        print(f"  subtree  : {len(sub[f])} routines")
        own = sorted(routines[f]['refs'])
        print(f"  refs     : {' '.join(own) or '-'}")
        deep = set()
        for g in sub[f]:
            deep |= routines[g]['refs']
        print(f"  subtree refs ({len(deep)}): {' '.join(sorted(deep))}")
        return

    # a byte is private to f if every routine referencing it is in subtree(f)
    users = collections.defaultdict(set)
    for n, r in routines.items():
        for s in r['refs']:
            users[s].add(n)
    priv = collections.defaultdict(list)
    for s, us in users.items():
        if s in isr_refs:
            continue
        for f in routines:
            if us <= sub[f] and f not in us:
                # f itself does not touch it: private to a proper descendant
                continue
            if us <= sub[f] and len(sub[f]) < len(routines):
                priv[f].append(s)
    print(f"{len(routines)} routines parsed from {', '.join(FILES)}; "
          f"{len(zp)} zero-page symbols; {len(isr_refs)} touched by interrupts")
    print("\nBytes private to a subtree (candidates for overlaying with any "
          "routine on a disjoint branch):")
    rows = []
    for f, ss in priv.items():
        n = sum(len(bytes_of.get(s, {0})) for s in ss)
        rows.append((n, f, ss))
    for n, f, ss in sorted(rows, reverse=True)[:25]:
        print(f"  {f:22} {n:3} bytes  {' '.join(sorted(ss)[:12])}"
              + (' ...' if len(ss) > 12 else ''))
    if not rows:
        print("  (none: every zero-page symbol is referenced from more than "
              "one subtree)")


if __name__ == '__main__':
    main()
