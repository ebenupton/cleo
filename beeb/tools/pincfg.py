"""The Master's linker configuration with every segment the Model B also has pinned
to the Model B's start address (ld65's segment `start`), so the Master's shorter
65C02 code leaves a gap rather than moving what follows it: the data lies alike on
both machines (test/layoutcheck.py checks it).  The start-up pieces, the Master's own
main-RAM segments and the NMI stubs' load image are left to the linker.
    python3 tools/pincfg.py <master cfg> <Model B cleo.dbg> > <pinned cfg>"""
import re, sys

FREE = {'BOOT', 'BOOTHDR', 'BANKFIX', 'WRFIX', 'CODE', 'TABLES', 'NMISTUB'}
cfg, dbg = open(sys.argv[1]).read(), open(sys.argv[2]).read()
start = {m.group(1): int(m.group(2), 16)
         for m in re.finditer(r'^seg\tid=\d+,name="(\w+)",start=0x([0-9A-F]+),size=0x([0-9A-F]+)', dbg, re.M)
         if int(m.group(3), 16)}


def pin(m):
    lead, name, rest = m.groups()
    if name in FREE or name not in start or re.search(r"\b(start|offset)\s*=", rest):
        return m.group(0)
    rest = re.sub(r',\s*align\s*=\s*\$?\w+', '', rest)   # (the Model B's start is aligned)
    return '%s%s: start = $%04X, %s' % (lead, name, start[name], rest)


seg = cfg.index('SEGMENTS')
sys.stdout.write(cfg[:seg] + re.sub(r'^(\s*)(\w+):\s*(load\b[^\n]*)', pin, cfg[seg:], flags=re.M))
