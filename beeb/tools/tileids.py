"""Write what each tile id of each level should draw, for test/tilecheck.mjs and
test/btilecheck.mjs.

Runs convert.py (quietly) and pack_tiles for every level.  Per level file L0..L15 (index =
level * 2 + sub, as the harness numbers them) writes <outdir>/L<n>.bin: 256 ids x 64 bytes,
each id's tile bytes in the bank's layout, the two solids as their fill ($0F cyan, $00
black) and the unused ids zero.

Usage (from beeb/):
    python3 tools/tileids.py [outdir=build/tileids]
"""
import os, sys, io, contextlib, importlib.util
os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location('conv', 'tools/convert.py')
m = importlib.util.module_from_spec(spec)
with contextlib.redirect_stdout(io.StringIO()):
    spec.loader.exec_module(m)
out = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.abspath('build/tileids'); os.makedirs(out, exist_ok=True)
for i in range(16):
    lv, sub = i >> 1, i & 1
    T = m.pack_tiles(lv, sub)
    b = bytearray(256 * 64)
    for c, t in T['local'].items():
        tb = bytes([0x0F] * 64) if m.tile_solid.get(c) == 1 else bytes(64) if c in m.tile_solid else bytes(m.tiles_bytes[c])
        b[t * 64:t * 64 + 64] = tb
    open(os.path.join(out, 'L%d.bin' % i), 'wb').write(b)
print("ok")
