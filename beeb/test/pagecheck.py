"""Every branch in a build's code that crosses a page when taken (+1 cycle), with its
source line (and the line inside a macro) -- to place PADs by.  Static: how often each
is taken is test/cycprof.mjs's to say.
    python3 test/pagecheck.py <build dir> [segments=SPR4CODE,SPR5CODE,MAP5CODE,TIL6ENT,TILCODE,LGCCODE,ENGCODE,KRNCODE]"""
import os, re, sys

ALL = os.environ.get('ALL') == '1'          # every branch, crossing or not (for tools/padtune)

bd = sys.argv[1]
want = (sys.argv[2] if len(sys.argv) > 2 else 'SPR4CODE,SPR5CODE,MAP5CODE,TIL6ENT,TILCODE,LGCCODE,ENGCODE,KRNCODE').split(',')
dbg = open(bd + '/cleo.dbg').read()
files = {m.group(1): m.group(2) for m in re.finditer(r'^file\tid=(\d+),name="([^"]+)"', dbg, re.M)}
segs = {}
for m in re.finditer(r'^seg\tid=(\d+),name="(\w+)",start=0x([0-9A-F]+),size=0x([0-9A-F]+)[^\n]*?(?:oname="([^"]+)",ooffs=(\d+))?$', dbg, re.M):
    segs[m.group(1)] = dict(name=m.group(2), start=int(m.group(3), 16), size=int(m.group(4), 16),
                            oname=m.group(5), ooffs=int(m.group(6)) if m.group(6) else None)
spans = {m.group(1): (m.group(2), int(m.group(3)), int(m.group(4)))
         for m in re.finditer(r'^span\tid=(\d+),seg=(\d+),start=(\d+),size=(\d+)', dbg, re.M)}
src, mac = {}, {}
for m in re.finditer(r'^line\tid=\d+,file=(\d+),line=(\d+)(,type=\d+)?(,count=\d+)?,span=([\d+]+)', dbg, re.M):
    loc = '%s:%s' % (files[m.group(1)].replace('src/', ''), m.group(2))
    t = mac if m.group(3) else src
    for sid in m.group(5).split('+'):
        sg, st, sz = spans[sid]
        for a in range(st, st + sz):
            k = (sg, a)
            if k not in t or sz < t[k][1]:
                t[k] = (loc, sz)
BR = {0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0, 0x80}
out = []
for sid, sg in segs.items():
    if sg['name'] not in want or not sg['oname'] or sg['ooffs'] is None:
        continue
    img = open(sg['oname'], 'rb').read()[sg['ooffs']:sg['ooffs'] + sg['size']]
    # walk the instructions by the line spans' starts (every instruction starts a span)
    starts = sorted({a for (s_, a) in src if s_ == sid} | {a for (s_, a) in mac if s_ == sid})
    for off in range(len(img) - 1):
        op = img[off]
        if op not in BR or (sid, off) not in src:
            continue
        s0 = src.get((sid, off)); m0 = mac.get((sid, off))
        if s0 and s0[1] != 2 and not (m0 and m0[1] == 2):
            continue                                        # a branch is 2 bytes: its span is
        d = img[off + 1] - 256 if img[off + 1] > 127 else img[off + 1]
        pc = sg['start'] + off + 2
        tgt = (pc + d) & 0xFFFF
        if pc >> 8 != tgt >> 8 or ALL:
            loc = s0[0] + (' > ' + m0[0] if m0 else '')
            out.append((sg['name'], sg['start'] + off, tgt, loc))
for n, a, t, loc in sorted(out):
    print('%-8s $%04X -> $%04X  %s' % (n, a, t, loc))
print('%d crossing branches' % len(out))
