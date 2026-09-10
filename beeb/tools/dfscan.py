#!/usr/bin/env python3
"""dfscan — dataflow redundancy scanner for the Cleo 6502 engine.

Ported from the DOOM BBC Micro port's tools/dfscan.py (same author, same
house rules); the analysis is unchanged, the front end is Cleo's: the
trace and the code image come from tools/dftrace.mjs (jsbeeb), symbols
from build/labels.txt, code regions from build/map.txt.

Reads the executed instruction set (with per-PC counts for ranking),
augments it with statically-reachable successors inside the code
regions, builds a CFG, and runs:

  * FORWARD abstract interpretation per basic block to a fixpoint:
      - register constants        (A/X/Y = known byte)
      - register-memory mirrors   (A currently equals ZP/abs slot $xx)
      - memory constants          (stores of known values, killed on
                                   indexed/indirect writes and JSR)
      - flag constants            (C/Z/N/V = 0/1/unknown)
      - Z/N provenance            (zn_src: flags currently reflect reg r)
      - CMP provenance            (Z from CMP reg,#imm — BEQ edge learns
                                   reg == imm)
      - branch-edge refinement    (BCS-taken edge knows C=1, etc.)
      - ROMSEL bank, across calls via interprocedural summaries
  * BACKWARD local liveness within each block (dead register writes,
    dead flag writes, flag-consumption checks for removals).

JSR is full havoc (registers, flags, memory), so findings are sound
under any callee behaviour. Self-modified instructions (operand bytes
that are the target of a store into a code region) are excluded from
findings and treated as unknown loads.

INTERRUPTS.  Cleo runs a vsync/T1 IRQ chain and a disc NMI throughout.
Both preserve A/X/Y and P, but they write memory, so every address the
handlers can write is treated as never-constant (--isr-audit lists the
set). Without that, memory findings would be unsound at any instruction
boundary.

Findings (each = provably redundant on every modeled path):
  imm_load    LDr #v when r already == v          (flags-safety checked)
  reload      LDr addr when r already mirrors it  (flags-safety checked)
  clc_sec     CLC with C==0 / SEC with C==1
  dead_flag   CLC/SEC overwritten before any C-reader in the block
  dead_write  register written then rewritten, value+flags unconsumed
  cmp_zero    CMP #0 when Z/N already reflect A   (C-safety checked)
  identity    AND #$FF / ORA #0 / EOR #0          (flags-safety checked)
  page_same   STA $FE30 with that bank already paged on every path
  known_store STr addr when addr provably already holds that value
              (LOW CONFIDENCE: check no interrupt or hardware reads it)

Every finding still needs applying, verifying bit-exact (tools/fbdiff.mjs)
and measuring. This tool only points.

Usage:  python3 tools/dfscan.py [--trace build/dftrace.json] [--isr-audit]
"""
import os, sys, json, argparse, bisect, base64

# ── opcode table (65C02: Cleo assembles with --cpu 65C02) ────────────────
_SPEC = """
00 BRK imp|01 ORA inx|04 TSB zp|05 ORA zp|06 ASL zp|08 PHP imp|09 ORA imm
0A ASL acc|0C TSB abs|0D ORA abs|0E ASL abs|10 BPL rel|11 ORA iny|12 ORA izp
14 TRB zp|15 ORA zpx|16 ASL zpx|18 CLC imp|19 ORA aby|1A INC acc|1C TRB abs
1D ORA abx|1E ASL abx|20 JSR abs|21 AND inx|24 BIT zp|25 AND zp|26 ROL zp
28 PLP imp|29 AND imm|2A ROL acc|2C BIT abs|2D AND abs|2E ROL abs|30 BMI rel
31 AND iny|32 AND izp|34 BIT zpx|35 AND zpx|36 ROL zpx|38 SEC imp|39 AND aby
3A DEC acc|3C BIT abx|3D AND abx|3E ROL abx|40 RTI imp|41 EOR inx|45 EOR zp
46 LSR zp|48 PHA imp|49 EOR imm|4A LSR acc|4C JMP abs|4D EOR abs|4E LSR abs
50 BVC rel|51 EOR iny|52 EOR izp|55 EOR zpx|56 LSR zpx|58 CLI imp|59 EOR aby
5A PHY imp|5D EOR abx|5E LSR abx|60 RTS imp|61 ADC inx|64 STZ zp|65 ADC zp
66 ROR zp|68 PLA imp|69 ADC imm|6A ROR acc|6C JMP ind|6D ADC abs|6E ROR abs
70 BVS rel|71 ADC iny|72 ADC izp|74 STZ zpx|75 ADC zpx|76 ROR zpx|78 SEI imp
79 ADC aby|7A PLY imp|7C JMP iax|7D ADC abx|7E ROR abx|80 BRA rel|81 STA inx
84 STY zp|85 STA zp|86 STX zp|88 DEY imp|89 BIT imm|8A TXA imp|8C STY abs
8D STA abs|8E STX abs|90 BCC rel|91 STA iny|92 STA izp|94 STY zpx|95 STA zpx
96 STX zpy|98 TYA imp|99 STA aby|9A TXS imp|9C STZ abs|9D STA abx|9E STZ abx
A0 LDY imm|A1 LDA inx|A2 LDX imm|A4 LDY zp|A5 LDA zp|A6 LDX zp|A8 TAY imp
A9 LDA imm|AA TAX imp|AC LDY abs|AD LDA abs|AE LDX abs|B0 BCS rel|B1 LDA iny
B2 LDA izp|B4 LDY zpx|B5 LDA zpx|B6 LDX zpy|B8 CLV imp|B9 LDA aby|BA TSX imp
BC LDY abx|BD LDA abx|BE LDX aby|C0 CPY imm|C1 CMP inx|C4 CPY zp|C5 CMP zp
C6 DEC zp|C8 INY imp|C9 CMP imm|CA DEX imp|CC CPY abs|CD CMP abs|CE DEC abs
D0 BNE rel|D1 CMP iny|D2 CMP izp|D5 CMP zpx|D6 DEC zpx|D8 CLD imp|D9 CMP aby
DA PHX imp|DD CMP abx|DE DEC abx|E0 CPX imm|E1 SBC inx|E4 CPX zp|E5 SBC zp
E6 INC zp|E8 INX imp|E9 SBC imm|EA NOP imp|EC CPX abs|ED SBC abs|EE INC abs
F0 BEQ rel|F1 SBC iny|F2 SBC izp|F5 SBC zpx|F6 INC zpx|F8 SED imp|F9 SBC aby
FA PLX imp|FD SBC abx|FE INC abx
"""
_LEN = {'imp': 1, 'acc': 1, 'imm': 2, 'zp': 2, 'zpx': 2, 'zpy': 2, 'izp': 2,
        'inx': 2, 'iny': 2, 'rel': 2, 'abs': 3, 'abx': 3, 'aby': 3,
        'ind': 3, 'iax': 3}
OPTAB = {}
for ent in _SPEC.replace('\n', '|').split('|'):
    ent = ent.strip()
    if not ent:
        continue
    p = ent.split()
    OPTAB[int(p[0], 16)] = (p[1], p[2], _LEN[p[2]])

_CYC = {('imm', 'r'): 2, ('zp', 'r'): 3, ('zpx', 'r'): 4, ('zpy', 'r'): 4,
        ('abs', 'r'): 4, ('abx', 'r'): 4, ('aby', 'r'): 4,
        ('zp', 'w'): 3, ('zpx', 'w'): 4, ('abs', 'w'): 4, ('imp', 'r'): 2}
def icost(mn, mode):
    kind = 'w' if mn in ('STA', 'STX', 'STY', 'STZ') else 'r'
    return _CYC.get((mode, kind), 2)

U = ('u',)
def C(v): return ('c', v & 0xFF)
def M(a): return ('m', a)

VOLMEM = set()          # addresses an interrupt handler can write

class St:
    __slots__ = ('r', 'f', 'mem', 'zn', 'cmpm', 'bank')
    def __init__(s):
        s.r = {'A': U, 'X': U, 'Y': U}
        s.f = {'C': None, 'Z': None, 'N': None, 'V': None}
        s.mem = {}
        s.zn = None
        s.cmpm = None
        s.bank = None
    def clone(s):
        t = St.__new__(St)
        t.r = dict(s.r); t.f = dict(s.f); t.mem = dict(s.mem)
        t.zn = s.zn; t.cmpm = s.cmpm; t.bank = s.bank
        return t
    def havoc(s):
        s.r = {'A': U, 'X': U, 'Y': U}
        s.f = {'C': None, 'Z': None, 'N': None, 'V': None}
        s.mem = {}; s.zn = None; s.cmpm = None
    def join(s, o):
        ch = False
        for k in 'AXY':
            if s.r[k] != o.r[k] and s.r[k] != U:
                s.r[k] = U; ch = True
        for k in 'CZNV':
            if s.f[k] != o.f[k] and s.f[k] is not None:
                s.f[k] = None; ch = True
        for a in list(s.mem):
            if o.mem.get(a) != s.mem[a]:
                del s.mem[a]; ch = True
        if s.zn != o.zn and s.zn is not None:
            s.zn = None; ch = True
        if s.cmpm != o.cmpm and s.cmpm is not None:
            s.cmpm = None; ch = True
        if s.bank != o.bank and s.bank is not None:
            s.bank = None; ch = True
        return ch

def setZN(st, val, src):
    if val != U and val[0] == 'c':
        st.f['Z'] = 1 if val[1] == 0 else 0
        st.f['N'] = 1 if val[1] & 0x80 else 0
    else:
        st.f['Z'] = st.f['N'] = None
    st.zn = src
    st.cmpm = None

def kill_mirrors(st, addr):
    for k in 'AXY':
        if st.r[k] == ('m', addr):
            st.r[k] = U

def eff_addr(mode, opnd):
    return opnd if mode in ('zp', 'abs') else None

ROMSEL = 0xFE30

def transfer(st, ins, volatile):
    pc, mn, mode, opnd = ins['pc'], ins['mn'], ins['mode'], ins['opnd']
    vol = pc in volatile

    def read_val():
        if vol:
            return U
        if mode == 'imm':
            return C(opnd)
        a = eff_addr(mode, opnd)
        if a is not None and a not in VOLMEM:
            if a in st.mem:
                return st.mem[a]
            if a < 0xFC00:                  # not hardware
                return M(a)
        return U

    if mn in ('STA', 'STX', 'STY') and mode == 'abs' and opnd == ROMSEL:
        v = st.r[mn[2]]
        st.bank = v[1] if (v != U and v[0] == 'c') else None
        return st
    if mn in ('LDA', 'LDX', 'LDY'):
        reg = mn[2]
        v = read_val()
        st.r[reg] = v
        setZN(st, v, reg)
    elif mn in ('STA', 'STX', 'STY', 'STZ'):
        reg = mn[2] if mn != 'STZ' else None
        a = eff_addr(mode, opnd)
        if a is not None:
            kill_mirrors(st, a)
            v = C(0) if reg is None else st.r[reg]
            if a in VOLMEM or a >= 0xFC00:
                st.mem.pop(a, None)
            elif v != U and v[0] == 'c':
                st.mem[a] = v
            else:
                st.mem.pop(a, None)
                if v == U and reg is not None:
                    st.r[reg] = M(a)        # reg now mirrors what it stored
        else:
            base_safe = mode in ('abx', 'aby') and opnd >= 0x0200
            for k in list(st.mem):
                if not (base_safe and k < 0x100):
                    del st.mem[k]
            for k in 'AXY':
                if st.r[k] != U and st.r[k][0] == 'm':
                    if not (base_safe and st.r[k][1] < 0x100):
                        st.r[k] = U
    elif mn in ('TAX', 'TAY'):
        st.r[mn[2]] = st.r['A']; setZN(st, st.r['A'], mn[2])
    elif mn in ('TXA', 'TYA'):
        st.r['A'] = st.r[mn[1]]; setZN(st, st.r['A'], 'A')
    elif mn == 'TSX':
        st.r['X'] = U; setZN(st, U, 'X')
    elif mn == 'TXS':
        pass
    elif mn == 'CLC':
        st.f['C'] = 0
    elif mn == 'SEC':
        st.f['C'] = 1
    elif mn == 'CLV':
        st.f['V'] = 0
    elif mn in ('CLI', 'SEI', 'CLD', 'SED', 'NOP'):
        pass
    elif mn in ('INX', 'INY', 'DEX', 'DEY'):
        reg = mn[2]
        v = st.r[reg]
        if v != U and v[0] == 'c':
            nv = C(v[1] + (1 if mn[0] == 'I' else -1))
            st.r[reg] = nv; setZN(st, nv, reg)
        else:
            st.r[reg] = U; setZN(st, U, reg)
    elif mn in ('INC', 'DEC') and mode == 'acc':        # 65C02 INA/DEA
        v = st.r['A']
        if v != U and v[0] == 'c':
            nv = C(v[1] + (1 if mn == 'INC' else -1))
            st.r['A'] = nv; setZN(st, nv, 'A')
        else:
            st.r['A'] = U; setZN(st, U, 'A')
    elif mn in ('INC', 'DEC'):
        a = eff_addr(mode, opnd)
        if a is not None:
            kill_mirrors(st, a)
            v = st.mem.get(a)
            if v is not None and a not in VOLMEM:
                nv = C(v[1] + (1 if mn == 'INC' else -1))
                st.mem[a] = nv; setZN(st, nv, None)
            else:
                st.mem.pop(a, None); setZN(st, U, None)
        else:
            base_safe = mode == 'abx' and opnd >= 0x0200
            for k in list(st.mem):
                if not (base_safe and k < 0x100):
                    del st.mem[k]
            for k in 'AXY':
                if st.r[k] != U and st.r[k][0] == 'm':
                    st.r[k] = U
            setZN(st, U, None)
    elif mn in ('TSB', 'TRB'):
        a = eff_addr(mode, opnd)
        if a is not None:
            kill_mirrors(st, a); st.mem.pop(a, None)
        else:
            st.mem.clear()
        st.f['Z'] = None; st.zn = None; st.cmpm = None
    elif mn in ('AND', 'ORA', 'EOR'):
        v = read_val(); a = st.r['A']
        if v != U and v[0] == 'c' and a != U and a[0] == 'c':
            st.r['A'] = C({'AND': a[1] & v[1], 'ORA': a[1] | v[1],
                           'EOR': a[1] ^ v[1]}[mn])
        elif mn == 'AND' and v == C(0):
            st.r['A'] = C(0)
        elif mn == 'ORA' and v == C(0xFF):
            st.r['A'] = C(0xFF)
        else:
            st.r['A'] = U
        setZN(st, st.r['A'], 'A')
    elif mn in ('ADC', 'SBC'):
        v = read_val(); a = st.r['A']; c = st.f['C']
        if (v != U and v[0] == 'c' and a != U and a[0] == 'c'
                and c is not None):
            if mn == 'ADC':
                t = a[1] + v[1] + c
                st.f['V'] = 1 if (~(a[1] ^ v[1]) & (a[1] ^ t) & 0x80) else 0
            else:
                t = a[1] + (v[1] ^ 0xFF) + c
                st.f['V'] = 1 if ((a[1] ^ v[1]) & (a[1] ^ t) & 0x80) else 0
            st.f['C'] = 1 if t > 0xFF else 0
            st.r['A'] = C(t)
        else:
            st.r['A'] = U; st.f['C'] = st.f['V'] = None
        setZN(st, st.r['A'], 'A')
    elif mn in ('ASL', 'LSR', 'ROL', 'ROR'):
        if mode == 'acc':
            a = st.r['A']; c = st.f['C']
            if a != U and a[0] == 'c' and (mn in ('ASL', 'LSR')
                                           or c is not None):
                v = a[1]
                if mn == 'ASL':
                    st.f['C'] = (v >> 7) & 1; nv = (v << 1) & 0xFF
                elif mn == 'LSR':
                    st.f['C'] = v & 1; nv = v >> 1
                elif mn == 'ROL':
                    st.f['C'] = (v >> 7) & 1; nv = ((v << 1) | c) & 0xFF
                else:
                    st.f['C'] = v & 1; nv = (v >> 1) | (c << 7)
                st.r['A'] = C(nv)
            else:
                st.r['A'] = U; st.f['C'] = None
            setZN(st, st.r['A'], 'A')
        else:
            a = eff_addr(mode, opnd)
            if a is not None:
                kill_mirrors(st, a); st.mem.pop(a, None)
            else:
                st.mem.clear()
                for k in 'AXY':
                    if st.r[k] != U and st.r[k][0] == 'm':
                        st.r[k] = U
            st.f['C'] = None; setZN(st, U, None)
    elif mn in ('CMP', 'CPX', 'CPY'):
        reg = {'CMP': 'A', 'CPX': 'X', 'CPY': 'Y'}[mn]
        v = read_val(); rv = st.r[reg]
        if v != U and v[0] == 'c' and rv != U and rv[0] == 'c':
            d = (rv[1] - v[1]) & 0x1FF
            st.f['C'] = 1 if rv[1] >= v[1] else 0
            st.f['Z'] = 1 if rv[1] == v[1] else 0
            st.f['N'] = 1 if d & 0x80 else 0
            st.zn = None; st.cmpm = None
        else:
            st.f['C'] = st.f['Z'] = st.f['N'] = None
            st.zn = None
            st.cmpm = (reg, opnd) if (mode == 'imm' and not vol) else None
    elif mn == 'BIT':
        st.f['Z'] = st.f['N'] = st.f['V'] = None
        if mode == 'imm':
            st.f['N'] = st.f['V'] = None    # 65C02 BIT #imm sets only Z
        st.zn = None; st.cmpm = None
    elif mn in ('PLA', 'PLX', 'PLY'):
        reg = {'PLA': 'A', 'PLX': 'X', 'PLY': 'Y'}[mn]
        st.r[reg] = U; setZN(st, U, reg)
    elif mn in ('PHA', 'PHX', 'PHY', 'PHP'):
        pass
    elif mn == 'PLP':
        st.f = {'C': None, 'Z': None, 'N': None, 'V': None}
        st.zn = None; st.cmpm = None
    elif mn == 'JSR':
        st.havoc()
        eff = _BANK_SUM.get(opnd)
        if eff == ('id',):
            pass
        elif eff is not None and eff[0] == 'const':
            st.bank = eff[1]
        else:
            st.bank = None
    return st

_BANK_SUM = {}
_SUMWHY = {}

_BR = {'BPL': ('N', 0), 'BMI': ('N', 1), 'BVC': ('V', 0), 'BVS': ('V', 1),
       'BCC': ('C', 0), 'BCS': ('C', 1), 'BNE': ('Z', 0), 'BEQ': ('Z', 1)}

def refine(st, mn, taken):
    fl, tv = _BR[mn]
    val = tv if taken else 1 - tv
    st.f[fl] = val
    if fl == 'Z' and val == 1:
        if st.zn in ('A', 'X', 'Y') and st.r[st.zn] == U:
            st.r[st.zn] = C(0)
        if st.cmpm is not None:
            reg, imm = st.cmpm
            if st.r[reg] == U:
                st.r[reg] = C(imm)
    return st


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--trace', default='build/dftrace.json')
    ap.add_argument('--isr-audit', action='store_true',
                    help='list the addresses the interrupt handlers write')
    ap.add_argument('--json', default='build/dfscan.json')
    ap.add_argument('--min-execs', type=int, default=0)
    args = ap.parse_args()
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(here)

    tr = json.load(open(args.trace))
    count = {int(k): v for k, v in tr['counts'].items()}
    obs = {int(k): set(v) for k, v in tr.get('edges', {}).items()}
    MEM = bytearray(65536)
    segs = []
    for r in tr['mem']:
        b = base64.b64decode(r['bytes'])
        MEM[r['lo']:r['lo'] + len(b)] = b
        segs.append((r['lo'], r['hi']))
    def in_code(pc):
        return any(lo <= pc <= hi for lo, hi in segs)

    syms = {}
    for ln in open('build/labels.txt'):
        p = ln.split()
        if len(p) == 3 and p[0] == 'al':
            syms[p[2].lstrip('.')] = int(p[1], 16)
    code_syms = sorted((v, k) for k, v in syms.items() if in_code(v))
    def sym_near(pc):
        i = bisect.bisect_right(code_syms, (pc, '\xff')) - 1
        return (code_syms[i][1], pc - code_syms[i][0]) if i >= 0 else ('?', 0)
    def near(pc):
        s, off = sym_near(pc)
        return f"{s}+{off}" if off else s

    print(f"trace: {sum(count.values())} steps, {len(count)} distinct PCs",
          file=sys.stderr)

    # ── decode + static expansion ───────────────────────────────────────
    def decode(pc):
        b = (MEM[pc], MEM[(pc + 1) & 0xFFFF], MEM[(pc + 2) & 0xFFFF])
        if b[0] not in OPTAB:
            return None
        mn, mode, ln = OPTAB[b[0]]
        if mode in ('imm', 'zp', 'zpx', 'zpy', 'inx', 'iny', 'izp'):
            opnd = b[1]
        elif mode == 'rel':
            d = b[1]
            opnd = (pc + 2 + (d - 256 if d >= 128 else d)) & 0xFFFF
        elif ln == 3:
            opnd = b[1] | (b[2] << 8)
        else:
            opnd = None
        return {'pc': pc, 'mn': mn, 'mode': mode, 'len': ln, 'opnd': opnd}

    ins = {}
    smc_jumps = set()          # filled by the SMC pass below, used by succs()
    for pc in count:
        d = decode(pc)
        if d:
            ins[pc] = d
    def static_succs(i):
        mn, mode, pc, ln, op = i['mn'], i['mode'], i['pc'], i['len'], i['opnd']
        if mn in ('RTS', 'RTI', 'BRK'):
            return []
        if mn == 'JMP':
            return [op] if mode == 'abs' else []
        if mn == 'BRA':
            return [op]
        if mode == 'rel':
            return [pc + ln, op]
        return [pc + ln]

    def succs(i):
        """Static successors plus the ones the trace observed: Cleo dispatches
        through jmp (tab,x) and through jmp operands patched at run time, and
        neither target is in the static CFG. An RTS's observed successors are
        its callers' continuations, which the JSR fall-through edge already
        models, so they are not added."""
        pc, mn = i['pc'], i['mn']
        ss = static_succs(i)
        if pc in smc_jumps and mn == 'JMP':
            ss = []                     # the assembled operand is not the target
        if mn in ('RTS', 'RTI', 'BRK', 'JSR'):
            return ss
        extra = obs.get(pc)
        if extra:
            for tgt in extra:
                if tgt not in ss:
                    ss = ss + [tgt]
        return ss
    queue = list(ins)
    while queue:
        pc = queue.pop()
        i = ins.get(pc)
        if i is None:
            continue
        for s in succs(i):
            if s not in ins and in_code(s):
                d = decode(s)
                if d:
                    ins[s] = d
                    queue.append(s)

    def expand():
        q = list(ins)
        while q:
            pc = q.pop()
            i = ins.get(pc)
            if i is None:
                continue
            for s in succs(i):
                if s not in ins and in_code(s):
                    d = decode(s)
                    if d:
                        ins[s] = d
                        q.append(s)

    # ── SMC: stores whose target lands inside an instruction ────────────
    ibytes = set()
    for i in ins.values():
        for k in range(i['len']):
            ibytes.add(i['pc'] + k)
    volatile = set()
    smc_targets = set()
    smc_jumps.clear()
    for i in ins.values():
        if (i['mn'] in ('STA', 'STX', 'STY', 'STZ', 'INC', 'DEC')
                and i['mode'] in ('zp', 'abs') and i['opnd'] in ibytes):
            smc_targets.add(i['opnd'])
    for j in ins.values():
        if any(j['pc'] <= t < j['pc'] + j['len'] for t in smc_targets):
            volatile.add(j['pc'])
            if j['mn'] in ('JMP', 'JSR'):
                smc_jumps.add(j['pc'])
    expand()
    print(f"static: {len(ins)} instructions, {len(volatile)} SMC-volatile, "
          f"{len(smc_jumps)} patched jumps, {len(obs)} observed edge sources",
          file=sys.stderr)

    # ── interrupt write set -> never-constant memory ────────────────────
    def reachable_writes(entry):
        seen, wl, writes = set(), [entry], set()
        while wl:
            pc = wl.pop()
            if pc in seen or pc not in ins:
                continue
            seen.add(pc)
            i = ins[pc]
            if i['mn'] in ('STA', 'STX', 'STY', 'STZ', 'INC', 'DEC', 'ASL',
                           'LSR', 'ROL', 'ROR', 'TSB', 'TRB'):
                if i['mode'] in ('zp', 'abs'):
                    writes.add(i['opnd'])
                elif i['mode'] in ('abx', 'aby'):
                    writes.update(range(i['opnd'], i['opnd'] + 256))
                elif i['mode'] in ('zpx', 'zpy'):
                    writes.update(range(0, 256))
                else:
                    writes.add(None)        # indirect: unknown target
            if i['mn'] == 'JSR':
                wl.append(i['opnd'])
                wl.append(pc + i['len'])
            else:
                wl.extend(succs(i))
        return writes
    # The IRQ chain runs at all times; the NMI only while the disc driver is
    # transferring (loadfile, with its own SMC store whose target is the load
    # buffer), so its write set is applied but its indirect store is not
    # treated as global havoc.
    isr = set()
    for e in ('irq_handler', 'nmi_handler'):
        if e in syms:
            isr |= reachable_writes(syms[e])
    unknown_isr_store = None in isr
    isr.discard(None)
    VOLMEM.clear(); VOLMEM.update(isr)
    if args.isr_audit:
        print(f"\ninterrupt write set ({len(isr)} addresses"
              + (", plus indexed/indirect stores" if unknown_isr_store else "")
              + "):")
        for a in sorted(isr):
            print(f"  ${a:04X} {near(a) if a >= 0x200 else ''}")
        return
    print(f"interrupts write {len(isr)} addresses (treated as never-constant)",
          file=sys.stderr)

    # ── basic blocks ────────────────────────────────────────────────────
    leaders, has_pred, jsr_targets = set(), set(), set()
    for i in ins.values():
        ss = succs(i)
        if i['mn'] == 'JSR':
            jsr_targets.add(i['opnd'])
            if i['opnd'] in ins:
                leaders.add(i['opnd'])
            if i['pc'] + i['len'] in ins:
                leaders.add(i['pc'] + i['len'])
        if i['mode'] == 'rel' or i['mn'] in ('JMP', 'BRA'):
            for s in ss:
                leaders.add(s)
        if i['mode'] == 'rel':
            leaders.add(i['pc'] + i['len'])
        for s in ss:
            has_pred.add(s)
    for pc in ins:
        if pc not in has_pred:
            leaders.add(pc)
    blocks = {}
    for pc in sorted(ins):
        if pc not in leaders:
            continue
        blk, p = [], pc
        while p in ins:
            i = ins[p]
            blk.append(i)
            nx = p + i['len']
            if (i['mn'] in ('RTS', 'RTI', 'BRK', 'JMP', 'BRA', 'JSR')
                    or i['mode'] == 'rel' or nx in leaders):
                break
            p = nx
        blocks[pc] = blk
    blk_succ = {}
    for lead, blk in blocks.items():
        last = blk[-1]
        if last['mn'] == 'JSR':
            nx = last['pc'] + last['len']
            ss = [(nx, None)] if nx in ins else []
        elif last['mn'] == 'BRA':
            ss = [(last['opnd'], None)]
        elif last['mode'] == 'rel':
            ss = [(last['pc'] + last['len'], (last['mn'], False)),
                  (last['opnd'], (last['mn'], True))]
        elif last['mn'] == 'JMP' and last['mode'] == 'abs':
            ss = [(last['opnd'], None)]
        elif last['mn'] in ('RTS', 'RTI', 'BRK'):
            ss = []
        else:
            nx = last['pc'] + last['len']
            ss = [(nx, None)] if nx in ins else []
        if last['pc'] in smc_jumps and last['mn'] == 'JMP':
            ss = []
        # observed edges (computed and patched jumps) carry no branch refinement
        known = {t for t, _e in ss}
        for tgt in obs.get(last['pc'], ()):
            if tgt not in known:
                ss = ss + [(tgt, None)]
        blk_succ[lead] = [(t, e) for (t, e) in ss if t in blocks]

    # ── forward fixpoint ────────────────────────────────────────────────
    entries = set(jsr_targets & set(blocks))
    for nm in ('irq_handler', 'nmi_handler', 'start'):
        if nm in syms and syms[nm] in blocks:
            entries.add(syms[nm])
    for lead in blocks:
        if lead not in has_pred:
            entries.add(lead)

    def run_fixpoint():
        IN, wl = {}, []
        for e in entries:
            if e in blocks:
                IN[e] = St(); wl.append(e)
        it = 0
        while wl:
            it += 1
            if it > 400000:
                print("fixpoint budget exceeded", file=sys.stderr)
                break
            lead = wl.pop()
            st = IN[lead].clone()
            for i in blocks[lead]:
                transfer(st, i, volatile)
            for (t, edge) in blk_succ[lead]:
                ts = st.clone()
                if edge is not None:
                    refine(ts, edge[0], edge[1])
                if t not in IN:
                    IN[t] = ts; wl.append(t)
                elif IN[t].join(ts):
                    wl.append(t)
        return IN

    _BANK_SUM.clear()
    IN = run_fixpoint()

    # ── interprocedural ROMSEL summaries ────────────────────────────────
    def _eval(entry, sums):
        """('id',) | ('const', k) | None for one subroutine."""
        EFF = {entry: 'id'}
        wl = [entry]
        res = 'bot'
        seen_blocks = set()
        while wl:
            lead = wl.pop()
            if lead not in blocks:
                return None
            seen_blocks.add(lead)
            eff = EFF[lead]
            st = St()
            for i in blocks[lead]:
                mn, mode, opnd = i['mn'], i['mode'], i['opnd']
                if mn in ('PHA', 'PHX', 'PHY', 'PHP', 'PLA', 'PLX', 'PLY',
                          'PLP', 'TXS', 'TSX'):
                    return None                  # stack games: refuse
                if mn in ('RTI', 'BRK'):
                    return None
                if mn == 'JSR':
                    sub = sums.get(opnd)
                    if sub is None:
                        eff = None
                    elif sub[0] == 'const':
                        eff = ('const', sub[1])
                    st.havoc()
                    continue
                if mn in ('STA', 'STX', 'STY') and mode == 'abs' and opnd == ROMSEL:
                    v = st.r[mn[2]]
                    eff = ('const', v[1]) if (v != U and v[0] == 'c') else None
                    continue
                if mode in ('ind', 'iax'):
                    return None
                transfer(st, i, volatile)
            last = blocks[lead][-1]
            if last['mn'] == 'RTS':
                if res == 'bot':
                    res = eff
                elif res != eff:
                    return None
                continue
            for (t, _e) in blk_succ[lead]:
                if t not in EFF:
                    EFF[t] = eff; wl.append(t)
                elif EFF[t] != eff:
                    return None
        if res == 'bot':
            _SUMWHY[entry] = 'no RTS reached'
            return None
        if res is None:
            _SUMWHY[entry] = 'conflicting/unknown paths'
        return ('id',) if res == 'id' else res

    subs = sorted(jsr_targets & set(blocks))
    sums = {e: ('id',) for e in subs}
    for _round in range(30):
        new = {}
        for e in subs:
            try:
                new[e] = _eval(e, sums)
            except RecursionError:
                new[e] = None
        if new == sums:
            break
        sums = new
    _BANK_SUM.update({e: v for e, v in sums.items() if v is not None})
    n_id = sum(1 for v in _BANK_SUM.values() if v == ('id',))
    print(f"bank summaries: {len(subs)} subroutines -> {n_id} id, "
          f"{len(_BANK_SUM)-n_id} const-exit, {len(subs)-len(_BANK_SUM)} unknown",
          file=sys.stderr)

    IN = run_fixpoint()

    # ── findings ────────────────────────────────────────────────────────
    findings = []
    READS = {'C': {'ADC', 'SBC', 'ROL', 'ROR', 'BCC', 'BCS'},
             'Z': {'BNE', 'BEQ'}, 'N': {'BPL', 'BMI'},
             'V': {'BVC', 'BVS'}}
    WRITES = {'C': {'ADC', 'SBC', 'ASL', 'LSR', 'ROL', 'ROR', 'CMP',
                    'CPX', 'CPY', 'CLC', 'SEC'},
              'Z': {'LDA', 'LDX', 'LDY', 'ADC', 'SBC', 'AND', 'ORA', 'EOR',
                    'ASL', 'LSR', 'ROL', 'ROR', 'CMP', 'CPX', 'CPY', 'INC',
                    'DEC', 'INX', 'INY', 'DEX', 'DEY', 'TAX', 'TAY', 'TXA',
                    'TYA', 'TSX', 'PLA', 'PLX', 'PLY', 'BIT', 'TSB', 'TRB'},
              'V': {'ADC', 'SBC', 'CLV', 'BIT'}}
    WRITES['N'] = WRITES['Z'] | {'BIT'}

    def flags_dead_after(blk, k, flags):
        live = set(flags)
        for j in range(k + 1, len(blk)):
            mnj = blk[j]['mn']
            if mnj in ('JSR', 'RTS', 'RTI', 'PHP', 'BRK'):
                return False
            for fl in list(live):
                if mnj in READS[fl]:
                    return False
                if mnj in WRITES[fl]:
                    live.discard(fl)
            if not live:
                return True
        return False

    def reg_reads(i, reg):
        mn, mode = i['mn'], i['mode']
        if reg == 'A':
            return (mn in ('STA', 'TAX', 'TAY', 'PHA', 'CMP', 'ADC', 'SBC',
                           'AND', 'ORA', 'EOR', 'BIT')
                    or (mn in ('ASL', 'LSR', 'ROL', 'ROR', 'INC', 'DEC')
                        and mode == 'acc'))
        if reg == 'X':
            return (mn in ('STX', 'TXA', 'TXS', 'CPX', 'INX', 'DEX', 'PHX')
                    or mode in ('zpx', 'abx', 'inx'))
        if reg == 'Y':
            return (mn in ('STY', 'TYA', 'CPY', 'INY', 'DEY', 'PHY')
                    or mode in ('zpy', 'aby', 'iny'))
        return False

    def reg_writes(i, reg):
        mn, mode = i['mn'], i['mode']
        return ((mn in ('LDA', 'TXA', 'TYA', 'PLA', 'ADC', 'SBC', 'AND',
                        'ORA', 'EOR') and reg == 'A')
                or (mn in ('ASL', 'LSR', 'ROL', 'ROR', 'INC', 'DEC')
                    and mode == 'acc' and reg == 'A')
                or (mn in ('LDX', 'TAX', 'TSX', 'INX', 'DEX', 'PLX')
                    and reg == 'X')
                or (mn in ('LDY', 'TAY', 'INY', 'DEY', 'PLY') and reg == 'Y'))

    for lead, blk in blocks.items():
        if lead not in IN:
            continue
        st = IN[lead].clone()
        for k, i in enumerate(blk):
            pc, mn, mode, opnd = i['pc'], i['mn'], i['mode'], i['opnd']
            n = count.get(pc, 0)
            if pc not in volatile:
                if mn in ('LDA', 'LDX', 'LDY') and mode == 'imm':
                    reg = mn[2]
                    if st.r[reg] == C(opnd):
                        zok = (st.f['Z'] == (1 if opnd == 0 else 0)
                               and st.f['N'] == (1 if opnd & 0x80 else 0))
                        if zok or flags_dead_after(blk, k, 'ZN') or st.zn == reg:
                            findings.append(dict(
                                cat='imm_load', pc=pc, n=n,
                                save=icost(mn, mode) * n,
                                txt=f"{mn} #${opnd:02X} — {reg} already ${opnd:02X}"))
                if mn in ('LDA', 'LDX', 'LDY') and mode in ('zp', 'abs'):
                    reg = mn[2]
                    same = (st.r[reg] == M(opnd) or
                            (opnd in st.mem and st.r[reg] != U
                             and st.r[reg] == st.mem[opnd]))
                    if same and opnd not in VOLMEM:
                        zok = st.zn == reg
                        if not zok and st.r[reg] != U and st.r[reg][0] == 'c':
                            v = st.r[reg][1]
                            zok = (st.f['Z'] == (1 if v == 0 else 0)
                                   and st.f['N'] == (1 if v & 0x80 else 0))
                        if zok or flags_dead_after(blk, k, 'ZN'):
                            findings.append(dict(
                                cat='reload', pc=pc, n=n,
                                save=icost(mn, mode) * n,
                                txt=f"{mn} ${opnd:04X} — {reg} already holds it"))
                if mn == 'CLC' and st.f['C'] == 0:
                    findings.append(dict(cat='clc_sec', pc=pc, n=n, save=2 * n,
                                         txt="CLC — C already 0"))
                if mn == 'SEC' and st.f['C'] == 1:
                    findings.append(dict(cat='clc_sec', pc=pc, n=n, save=2 * n,
                                         txt="SEC — C already 1"))
                if mn in ('CLC', 'SEC') and st.f['C'] != (0 if mn == 'CLC' else 1):
                    if flags_dead_after(blk, k, 'C'):
                        findings.append(dict(cat='dead_flag', pc=pc, n=n,
                                             save=2 * n,
                                             txt=f"{mn} — C rewritten before any reader"))
                if mn == 'CMP' and mode == 'imm' and opnd == 0 and st.zn == 'A':
                    if st.f['C'] == 1 or flags_dead_after(blk, k, 'C'):
                        findings.append(dict(cat='cmp_zero', pc=pc, n=n, save=2 * n,
                                             txt="CMP #0 — Z/N already from A"))
                if ((mn == 'AND' and mode == 'imm' and opnd == 0xFF) or
                        (mn in ('ORA', 'EOR') and mode == 'imm' and opnd == 0)):
                    if st.zn == 'A' or flags_dead_after(blk, k, 'ZN'):
                        findings.append(dict(cat='identity', pc=pc, n=n, save=2 * n,
                                             txt=f"{mn} #${opnd:02X} — identity"))
                if mn in ('STA', 'STX', 'STY') and mode in ('zp', 'abs'):
                    reg = mn[2]
                    if (opnd in st.mem and st.r[reg] != U and st.r[reg][0] == 'c'
                            and st.mem[opnd] == st.r[reg] and opnd not in VOLMEM
                            and opnd < 0xFC00 and n > 0):
                        findings.append(dict(cat='known_store', pc=pc, n=n,
                                             save=icost(mn, mode) * n,
                                             txt=f"{mn} ${opnd:04X} — slot already holds "
                                                 f"${st.r[reg][1]:02X}"))
                if mn in ('STA', 'STX', 'STY') and mode == 'abs' and opnd == ROMSEL:
                    v = st.r[mn[2]]
                    if v != U and v[0] == 'c' and st.bank == v[1]:
                        findings.append(dict(cat='page_same', pc=pc, n=n, save=6 * n,
                                             txt=f"ROMSEL {v[1]} — bank already {v[1]}"))
                # a load from I/O has side effects (clearing a VIA/CRTC/FDC
                # flag), so it is never a dead write however unread A is
                hw = (mode in ('abs', 'abx', 'aby') and opnd is not None
                      and 0xFC00 <= opnd <= 0xFEFF)
                if mn in ('LDA', 'LDX', 'LDY', 'TXA', 'TYA', 'TAX', 'TAY') \
                        and not hw \
                        and mode in ('imm', 'zp', 'abs', 'imp', 'zpx', 'abx', 'aby'):
                    reg = mn[2] if mn in ('TAX', 'TAY') else \
                          ('A' if mn in ('LDA', 'TXA', 'TYA') else mn[2])
                    dead = None
                    for j in range(k + 1, len(blk)):
                        nj = blk[j]
                        if nj['mn'] in ('JSR', 'RTS', 'RTI', 'BRK'):
                            break
                        if reg_reads(nj, reg):
                            break
                        if reg_writes(nj, reg):
                            dead = j
                            break
                    if dead is not None and flags_dead_after(blk, k, 'ZN'):
                        findings.append(dict(cat='dead_write', pc=pc, n=n,
                                             save=icost(mn, mode) * n,
                                             txt=f"{mn} — {reg} rewritten at "
                                                 f"${blk[dead]['pc']:04X} unread"))
            transfer(st, i, volatile)

    best = {}
    for f in findings:
        key = (f['pc'], f['cat'])
        if key not in best or f['save'] > best[key]['save']:
            best[key] = f
    findings = sorted(best.values(), key=lambda f: -f['save'])

    total = sum(f['save'] for f in findings if f['cat'] != 'known_store')
    print(f"\n{len(findings)} findings; est. cycle saving on the traced "
          f"session (excl. known_store): {total}\n")
    print(f"{'addr':6} {'symbol':30} {'cat':11} {'execs':>8} {'save':>8}  detail")
    shown = 0
    for f in findings:
        if f['n'] < args.min_execs or (f['n'] == 0 and f['save'] == 0):
            continue
        shown += 1
        print(f"${f['pc']:04X} {near(f['pc']):30} {f['cat']:11} "
              f"{f['n']:8} {f['save']:8}  {f['txt']}")
    cold = [f for f in findings if f['n'] == 0]
    if cold:
        print(f"\n({len(cold)} findings on never-executed static paths — in the JSON)")
    with open(args.json, 'w') as fh:
        json.dump([dict(f, sym=near(f['pc'])) for f in findings], fh, indent=1)
    print(f"\nJSON: {args.json}")


if __name__ == '__main__':
    main()
