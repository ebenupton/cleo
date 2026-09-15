#!/usr/bin/env python3
"""flagscan -- audit the 65C02 spellings the Model B build expands as 6502 macros.

Each macro has side effects its 65C02 form does not:

  stz / stza      the 6502 form goes through A (lda #0 / sta, or pha / lda / sta /
                  pla), so N and Z are those of A afterwards -- a branch on the
                  flags that were live BEFORE the store reads the wrong ones
  inca / deca     clc / adc #1 and sec / sbc #1: the carry is destroyed
  ldaz/staz/andz  ldy #0 / op (zp),y: Y is destroyed

For every site the scanner walks forward through the source (following branches
both ways, jmp by label, stopping at jsr and at any instruction that redefines the
flag) and reports a HAZARD when a consumer of the flag is reached first, and a
RETURN when an rts is reached with the flag still live (the caller may test it).
It is a text scanner over ca65 source: conservative, and meant to be read.

    python3 tools/flagscan.py src/engine.s src/logic.s src/main.s
"""
import re, sys

ZN_DEF = set('''lda ldx ldy adc sbc and ora eor cmp cpx cpy inc dec inx dex iny dey asl
lsr rol ror tax tay txa tya pla plp bit tsx plx ply tsb trb ldaz andz inca deca
cmpz'''.split())
ZN_USE = set('beq bne bmi bpl php'.split())
C_DEF = set('adc sbc cmp cpx cpy asl lsr rol ror clc sec plp cmpz'.split())
C_USE = set('bcc bcs adc sbc rol ror php'.split())
Y_DEF = set('ldy tay dey iny ply'.split())
Y_USE = set('sty tya cpy dey iny phy'.split())   # plus any ,y operand
BRANCH = set('bcc bcs beq bne bmi bpl bvc bvs bra'.split())
STOP = set('jsr rts rti jmpx'.split())
A_DEF = set('lda pla txa tya ldaz'.split())
A_USE = set('sta tax tay pha adc sbc cmp and ora eor staz andz cmpz inca deca bit jsr jmpx'.split())


def parse(path):
    lines = open(path).read().split('\n')
    prog = []                                   # (lineno, label, op, arg)
    for i, raw in enumerate(lines, 1):
        s = raw.split(';', 1)[0].rstrip()
        if not s.strip():
            continue
        m = re.match(r'^(\S+):\s*(.*)$', s)
        label, rest = (m.group(1), m.group(2)) if m else (None, s.strip())
        if s.startswith(':'):
            label, rest = ':', s[1:].strip()
        rest = rest.strip()
        op, arg = (rest.split(None, 1) + [''])[:2] if rest else ('', '')
        prog.append((i, label, op.lower(), arg.strip()))
    return prog


def resolve(prog, idx, target):
    """index of the instruction a branch at prog[idx] goes to, or None"""
    if target.startswith(':'):
        n = target.count('+') or -target.count('-')
        step = 1 if n > 0 else -1
        j, seen = idx + step, 0
        while 0 <= j < len(prog):
            if prog[j][1] == ':':
                seen += 1
                if seen == abs(n):
                    return j
            j += step
        return None
    for j, (_, lab, _, _) in enumerate(prog):
        if lab == target:
            return j
    return None


def walk(prog, start, use, define, extra_stop=()):
    """forward from prog[start+1]: 'hazard' (consumer first), 'return' (rts with the
    flag live), 'safe' or 'unknown'"""
    worst = 'safe'
    seen = set()
    stack = [start + 1]
    steps = 0
    while stack:
        j = stack.pop()
        while 0 <= j < len(prog) and j not in seen and steps < 400:
            seen.add(j); steps += 1
            _, lab, op, arg = prog[j]
            if op.startswith('.') or op == '':
                if op in ('.endmacro', '.endproc'):
                    break
                j += 1
                continue
            if use is A_USE and op in ('asl', 'lsr', 'rol', 'ror', 'inc', 'dec') and arg.lower() in ('a', ''):
                return 'hazard'
            if op in use or (op in ('sta', 'lda', 'cmp', 'and', 'ora', 'eor', 'adc', 'sbc', 'ldx', 'stx')
                             and use is Y_USE and arg.endswith(',y')):
                return 'hazard'
            if op in define:
                break
            if op in BRANCH:
                t = resolve(prog, j, arg)
                if t is not None:
                    stack.append(t)
                if op == 'bra':
                    break
                j += 1
                continue
            if op == 'jmp':
                if arg.startswith('('):
                    worst = 'unknown'; break
                t = resolve(prog, j, arg)
                if t is None:
                    worst = 'unknown'; break
                j = t
                continue
            if op in ('rts', 'rti'):
                worst = 'return' if worst == 'safe' else worst
                break
            if op in STOP:
                break
            j += 1
    return worst


def main():
    total = 0
    for path in sys.argv[1:]:
        prog = parse(path)
        for i, (ln, lab, op, arg) in enumerate(prog):
            checks = []
            if op in ('stz', 'stza'):
                checks.append(('NZ', ZN_USE, ZN_DEF))
                checks.append(('A', A_USE, A_DEF))
            if op in ('inca', 'deca') or (op in ('inc', 'dec') and arg.lower() == 'a'):
                checks.append(('C', C_USE, C_DEF))
            if op in ('ldaz', 'staz', 'andz', 'cmpz'):
                checks.append(('Y', Y_USE, Y_DEF))
            for name, use, define in checks:
                r = walk(prog, i, use, define)
                if r != 'safe':
                    total += 1
                    print('%s:%d: %s %s -- %s %s' % (path, ln, op, arg, name, r.upper()))
    print('%d sites to look at' % total)


if __name__ == '__main__':
    main()
