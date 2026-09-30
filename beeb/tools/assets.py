#!/usr/bin/env python3
"""Pack every level, and the sprites, for both machines.

   python3 tools/assets.py            (run from beeb/, as build.sh does, once per
                                       machine: TARGET=modelb|master, BD=build/...)

convert.py is imported for its tables (and writes the tile set's files).  Those
go on the disc as convert.py wrote them, and the sprites as this packer writes them:
SPRC, the sprites every level draws (Cleo, the boomerang, the stars, the trampoline),
at fixed addresses in banks 4 and 5, and SPRX, everything else, from which each level
takes its subset.  The game's own loader (ldprog.s) stages one file at a time in
display RAM and copies the pieces a level needs into the banks, where the packer here
decided they go.  The level files are shared, so the two machines' runs must write
them identically (build.sh checks).  What this writes to $BD:

   L0..L15        per level: a table of section offsets, then the header, objects,
                  attr/altcls, the level's tile lists (convert.py pack_tiles), the
                  sprite placement list, the RLE map, the finished sprite directory,
                  and last the Master's LV_PAGE0 in two whole sectors
   SPRC, SPRX     the sprites, as above
   imgtab.bin     per image and box: which shared file holds it and where (ldprog.s)
   digits.bin     the HUD's digits packed, digtab.bin their decode (bank 7, banks.s);
                  font.bin (the menus' glyphs); alt.bin (the altitude classes);
                  music.bin (build/MUSIC, midi2snd.py's: the menus' tune); title.bin
                  and title.inc, the title pieces' run-length streams and their
                  directory (the menus' image, banks.s)
   BAR            the bar template, 1280 bytes, read to BARADDR as each game starts
   assets.inc     the bounds every level fits: MAXSPR, BINMAX, the solid ids, the
                  sprite blocks' places and sizes, the banks' code ends
"""
import os, sys, io, contextlib, importlib.util, json
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
BEEB = os.path.dirname(HERE)
os.chdir(BEEB)
spec = importlib.util.spec_from_file_location('conv', 'tools/convert.py')
m = importlib.util.module_from_spec(spec)
with contextlib.redirect_stdout(io.StringIO()):
    spec.loader.exec_module(m)
TARGET = os.environ.get('TARGET', 'modelb')     # or 'master' (build.sh): where to write
OUT = os.path.join(BEEB, os.environ.get('BD', 'build/' + TARGET))
os.makedirs(OUT, exist_ok=True)

def out(name, data):
    open(os.path.join(OUT, name), 'wb').write(bytes(data))

SOLID_CYAN, SOLID_BLACK = m.SOLID_CYAN, m.SOLID_BLACK   # (convert.py's: the top two ids)
VISLINES_ALL = (240, 168)           # the windows' lines, the Master's and the Model B's: VISROWS 30 / 21 (engine.s)

# ---------------------------------------------------------------- the banks' fixed shape
# Code sits at the bottom of banks 4, 5 and 6 (each entered at $8000) and the mask
# tables at the top of 4 and 5; bank 6's tiles run from its code's next page to the
# end; bank 5's map is a fixed 8K below its mask tables.  These are the bounds the
# linker configs (cfg/) and defs.inc share.
# The sprites start exactly where the Model B's code ends in each bank: every byte its
# code does not take is sprite room.  One disc serves both machines, so the level files
# -- the sprites' addresses -- are one layout: the Master's code, a little shorter,
# leaves a gap below them.  The ends are the linker's (build/modelb/map.txt), set here
# by hand because the packer runs before the assembler; engine.s asserts them (exactly
# on the Model B, at most on the Master), so the build stops if they move.
SPRGEOM = os.environ.get('SPRGEOM') == '1'   # the split directory (beebgame's option)
B4_CODE_END = 0x83E5                        # the row loop and blitters (SPR4CODE)
B5_CODE_END = 0x844C                        # the same, the gather and its shape (MAP5BSS)
B4_DATA = (B4_CODE_END, 0xBC00)             # bank 4: images, between the row loop and the
                                            #   expansion tables and SWAPTAB ($BC00-$BFFF)
B5_DATA = (B5_CODE_END, 0x9C00)                  # bank 5: all its sprites, one run, between the row
                                            #   loop + gather and the map: the resident part
                                            #   (SPRC's bank-5 part) at the bottom, the level's above it
MAP5 = 0x9C00                               # the map: a fixed 8K below the tables ($BC00)
B5_TOP = MAP5                               #   (the end of bank 5's sprites)
TILES_BASE, B6X = m.B_TILES, m.B_TILES_END  # bank 6: the tiles from here (page aligned),
                                            #   above the code (the cfgs' B6X), to the end

# ---------------------------------------------------------------- Cleo's sprites
# The sprite ids (the engine's directory: BOXID0 images, then BOXN boxes; ids from
# BOXID0 + BOXN are the engine's "still" aliases of the boxes, BOXN below them):
# images 0..102 (the entries of the original's dim), then the boxes -- screen bytes,
# copied: the twelve box stars on sky and on black, then TRMAX slots for the level's
# trampolines at rest and NSTAR slots of six for its baked stars, each slot the
# level's own art, baked by the loader (below).
TRMAX, NSTAR = 13, 8
BOXID0, BOXN = 103, 12 + TRMAX + 6 * NSTAR
NDIR = BOXID0 + BOXN                        # directory entries
NBOXART = 12                                # the box stars' images
# The split between resident and staged, which is the game's to choose: the resident
# sprites (SPRC) are loaded once, to fixed places in banks 4 and 5 (assets.inc
# SPRC_BASE, SPRC5_BASE); the staged ones (SPRX) are staged at each level load and
# the level's own subset copied to where its placement list says.  Cleo's resident
# set: what (nearly) every level draws.
RESIDENT_IDS = list(range(46))              # Cleo, the boomerang, the stars and their
                                            # collect animation (0..42), 43..45
ALWAYS_IDS = range(43)                      # the ids a level draws whatever its objects

# ---------------------------------------------------------------- the shared files
# The resident sprites are one file (SPRC), everything else -- the enemies, the box
# stars -- another (SPRX), which a load stages and copies from: the level's subset, to
# the addresses placed below.  (The Master keeps SPRX resident after its first read:
# ldprog.s.)  imgtab says where in SPRX each item is.
NIMG = len(m.images)
# item keys: ('img', j) | ('box', k) | ('tr', k) | ('sb', k) -> a small integer the placement
# lists and the directory template use
def item_index(kind, j):
    return {'img': 0, 'box': NIMG, 'tr': NIMG + NBOXART, 'sb': NIMG + NBOXART + TRMAX}[kind] + j
# The level's baked boxes: every trampoline's rest state, and the stars the
# plan names (tools/starbake.json: by level file, the stars' tiles, best first -- the
# frames that miss their peg draw them: test/starplan.mjs), each composited over its
# own backdrop (convert.py bake_box).  A slot for each, as long as the level has ids
# for it and the placement can fit it.
try:
    STARPLAN = json.load(open(os.path.join(HERE, 'starbake.json')))
except OSError:
    STARPLAN = {}
_bakes = {}
CHOSEN = {}                                 # (level, sub) -> the stars it bakes, in order (chosen below)
def level_bakes(lv, sub):
    if (lv, sub) in _bakes:
        return _bakes[(lv, sub)]
    L, cm = m.levels[(lv, sub)], m.maps[(lv, sub)]
    tr, st, by, at = {}, {}, {}, {}
    slot = {}                           # (trampolines whose boxes come out the same share one)
    for oi, (t, x, y, e) in enumerate(L['objs']):
        if t == 1:
            b = m.bake_tramp_rest(cm, x, y)
            if b is not None and (b in slot or len(slot) < TRMAX):
                if b not in slot:
                    slot[b] = len(slot); by[('tr', slot[b])] = b; at[('tr', slot[b])] = (x, y)
                tr[oi] = slot[b]
    want = CHOSEN.get((lv, sub), [])
    pos = {(x, y): oi for oi, (t, x, y, e) in enumerate(L['objs']) if t == 0}
    for xy in want:                     # (in the plan's order: the costliest first)
        oi = pos.get(xy)
        if oi is None or m.star_class(cm, *xy) != 0 or len(st) >= NSTAR:
            continue
        fr = m.bake_star(cm, *xy)
        if fr is not None:
            st[oi] = len(st)
            for f, b in enumerate(fr):
                by[('sb', st[oi] * 6 + f)] = b; at[('sb', st[oi] * 6 + f)] = xy
    _bakes[(lv, sub)] = (tr, st, by, at)
    return _bakes[(lv, sub)]
CUR = [None]                                # the level being placed (its baked items' bytes)
BAKEAT = {}                                 # (level, sub) -> its baked items' (bank, address)
def item_bytes(kind, j):
    if kind in ('tr', 'sb'):
        return level_bakes(*CUR[0])[2][(kind, j)]
    return m.img_bytes[j] if kind == 'img' else m.box_bytes[j]
COMMON = sorted(set(m.entry[i][0] for i in RESIDENT_IDS if m.entry[i] is not None))
# The mirrored ones go in bank 4 (from when only bank 4 could mirror: kept, as moving
# them would move every level's layout); bank 4 cannot also hold all the plain ones
# beside the biggest levels' mirrored enemies, so the rest go to the bottom of bank
# 5's sprite run.
_mirrored_all = set(m.entry[i][0] for i in range(BOXID0) if m.entry[i] is not None and m.entry[i][1])
common_addr, common_bank = {}, {}
def _pack(js, base):
    blk = bytearray()
    for j in js:
        common_addr[j] = base + len(blk); blk += m.img_bytes[j]
    return blk
c4 = [j for j in COMMON if j in _mirrored_all]
# the plain ones: bank 4 takes what it can spare beside the biggest level's mirrored
# enemies (largest first), bank 5 the rest
_sz = lambda j: len(m.img_bytes[j])
_maxmir = 0
for (_lv, _sub), _L in m.levels.items():
    _js = set()
    for _t in set(o[0] for o in _L['objs']):
        if _t in m.TYPE_IDS:
            _lo, _hi = m.TYPE_IDS[_t]
            _js |= set(m.entry[i][0] for i in range(_lo, _hi + 1) if m.entry[i] is not None)
    _maxmir = max(_maxmir, sum(_sz(j) for j in _js - set(COMMON) if j in _mirrored_all))
_room4 = (B4_DATA[1] - B4_DATA[0]) - sum(_sz(j) for j in c4) - _maxmir
c6 = []
for j in sorted((j for j in COMMON if j not in _mirrored_all), key=lambda j: -_sz(j)):
    if _sz(j) <= _room4:
        c4.append(j); _room4 -= _sz(j)
    else:
        c6.append(j)
sprc4 = _pack(c4, B4_DATA[0])
C5_LEN = sum(len(m.img_bytes[j]) for j in c6)
C5_BASE = B5_DATA[0]
sprc5 = _pack(c6, C5_BASE)
for j in c4: common_bank[j] = 4
for j in c6: common_bank[j] = 5
COMMON_END = B4_DATA[0] + len(sprc4)
assert COMMON_END <= B4_DATA[1] and C5_BASE + C5_LEN <= B5_DATA[1] and MAP5 + 0x2000 <= 0xBC00
sprc = sprc4 + sprc5
out('SPRC', sprc)
sprx, imgtab = bytearray(), bytearray()
for j in range(NIMG):
    if j in common_addr:
        imgtab += bytes(5); continue        # (never placed: resident)
    o, n = len(sprx), len(m.img_bytes[j]); sprx += m.img_bytes[j]
    imgtab += bytes([0, o & 255, o >> 8, n & 255, n >> 8])   # file 0 (SPRX), offset, length
for k in range(NBOXART):                    # the box stars' boxes
    o, n = len(sprx), len(m.box_bytes[k]); sprx += m.box_bytes[k]
    imgtab += bytes([0, o & 255, o >> 8, n & 255, n >> 8])
BAKEITEM0 = NIMG + NBOXART                  # the baked slots: made by the loader (ldprog.s bake)
bakegeom = bytearray()                  # tiles where the object stands (its tile in the
for wc, lines, dx, dty, ov in m.BAKE_KINDS:   # placement entry's mask field)
    o = len(sprx); sprx += ov
    assert lines <= 32 and len(ov) == 2 * wc * lines
    bakegeom += bytes([wc, lines, dx & 255, (dx >> 8) & 255, dty & 255, o & 255, o >> 8, 0])
bakekind = bytes([0] * TRMAX + [1 + k % 6 for k in range(NSTAR * 6)])
# (no imgtab entries: placewalk bakes them before it looks)
assert len(sprx) <= 0x4000                  # STAGE's 16K
out('SPRX', sprx)
out('imgtab.bin', imgtab)
print('sprites: SPRC %d bytes (bank 4 $%04X-$%04X, bank 5 $%04X-$%04X), SPRX %d bytes'
      % (len(sprc), B4_DATA[0], COMMON_END, C5_BASE, B5_TOP, len(sprx)))

# the directory template: a directory entry less its pointer, which holds the item
# index and its kind until the level's placement fills in the pointer and the bank-5
# flag (pack_level)
sprdir = bytearray()
for i in range(BOXID0):
    e = m.entry[i]
    if e is None:
        sprdir += bytes([0xFF] + [0] * 7); continue
    j, mirror, rx, ry = e
    im, full, src = m.images[j]
    hh, ww = im.shape
    W = m.img_wbytes[j]
    rx += m.img_shift[j]
    if mirror:
        rx = (2 * W - 1) - rx
    if i < 27 and not rx & 1:               # convert.py: Cleo's refx parity rule
        rx -= 1
    sprdir += bytes([item_index('img', j), 0, W, hh, rx & 255, ry & 255, 1 if mirror else 0, hh])   # (a byte a row)
for k in range(NBOXART):
    lo, wc = m.box_geom[k % 6]
    sprdir += bytes([item_index('box', k), 1, wc, m.BOX_H, (6 - 2 * lo) & 255, 8, 2 | 8, m.BOX_H * 2])
for k in range(TRMAX):
    sprdir += bytes([item_index('tr', k), 3, m.TRAMP_REST_WC, m.TRAMP_H, (m.TRAMP_HOT - 2 * m.TRAMP_REST_LO) & 255,
                     (-8) & 255, 2 | 8, m.TRAMP_H * 2])
for k in range(NSTAR * 6):
    lo, wc = m.box_geom[k % 6]
    sprdir += bytes([item_index('sb', k), 4, wc, m.BOX_H, (6 - 2 * lo) & 255, 8, 2 | 8, m.BOX_H * 2])
assert len(sprdir) == NDIR * 8

# ---------------------------------------------------------------- placing for the loops
# Each item's shape (columns, lines: the directory's), and how often a level draws it
# (tools/drawfreq.json, test/drawfreq.mjs's: draws a frame by sprite id, both
# machines averaged), for the placement that costs the sprite loops least (sprpack.py)
import json
sys.path.insert(0, os.path.join(BEEB, 'beebgame', 'tools'))   # (the engine's sprite placer
import sprpack                                                  #  and level file writer)
import levelfile as lf
GEOM = {}                                   # item index -> (columns, lines)
for i in range(NDIR):
    t = sprdir[i * 8:i * 8 + 8]
    if t[0] != 0xFF:
        GEOM[t[0]] = (t[2], t[7])
try:
    _freq = json.load(open(os.path.join(HERE, 'drawfreq.json')))
except OSError:
    _freq = {}
ITEM_OF = {i: sprdir[i * 8] for i in range(NDIR) if sprdir[i * 8] != 0xFF}
MIRRORED_ID = {i for i in range(BOXID0) if m.entry[i] is not None and m.entry[i][1]}
def weights(level):
    """draws a frame by item index, forward and mirrored, for a level (None: the mean
    over the levels)"""
    ws = {}
    for lk, per in _freq.items():
        if level is not None and int(lk) != level:
            continue
        for sid, n in per.items():
            sid = int(sid)
            sid = sid - BOXN if sid >= NDIR else sid    # the "still" aliases
            it = ITEM_OF.get(sid)
            if it is not None:
                w = ws.setdefault(it, [0.0, 0.0])
                w[1 if sid in MIRRORED_ID else 0] += n / (1 if level is not None else max(1, len(_freq)))
    return ws
SPRPACK_CACHE = os.path.join(BEEB, 'build', 'sprpack.cache')
_cache = sprpack.load_cache(SPRPACK_CACHE)
def chunk_items(keys_img, ws):
    """sprpack items: each image, sized, weighted, costed"""
    out_ = []
    for key in keys_img:                    # (one table: the directions' tables, weighed)
        W, Lh = GEOM[item_index(*key)]
        f, r = ws.get(item_index(*key), (0.0, 0.0))
        tf, tr = sprpack.image_table(W, Lh), sprpack.image_table(W, Lh, True)
        tot = f + r
        out_.append(dict(key=('i',) + key, size=len(item_bytes(*key)), w=tot or 0.001,
                         table=[(f * a + r * b) / tot for a, b in zip(tf, tr)] if tot else tf))
    return out_

# The HUD's digits, 8 x 8 game px each (16 lines of 4 bytes, convert.py), are drawn
# from four game-pixel patterns (the dither's two lines of one colour): a byte column
# at one game row is two game px, a nibble (left << 2 | right).  A digit is 32 nibbles,
# 16 bytes: for each of its two char rows, each byte column, its game rows 0-1 then
# 2-3, one byte (the first row's nibble high).  DIGTAB gives a nibble's top and
# bottom scanline bytes (logic.s bar_digit).
def _digits():
    LM = 0xCC                               # the left game px's dots: bits 7, 6, 3, 2
    pats, packed = [], bytearray()
    def code(t, b, right):
        key = (((t << 2) if right else t) & LM, ((b << 2) if right else b) & LM)
        if key not in pats: pats.append(key)
        return pats.index(key)
    g = m.digits
    for n in range(10):
        for crow in range(2):
            for cx in range(4):
                for j in range(2):
                    nib = []
                    for k in (2 * j, 2 * j + 1):
                        o = n * 64 + crow * 32 + cx * 8 + 2 * k
                        t, b = g[o], g[o + 1]
                        nib.append(code(t, b, False) << 2 | code(t, b, True))
                    packed.append(nib[0] << 4 | nib[1])
    assert len(pats) <= 4, pats
    top = bytes(pats[a][0] | pats[b][0] >> 2 if a < len(pats) and b < len(pats) else 0 for a in range(4) for b in range(4))
    bot = bytes(pats[a][1] | pats[b][1] >> 2 if a < len(pats) and b < len(pats) else 0 for a in range(4) for b in range(4))
    # the decode, as bar_digit does it, must give back every byte
    for n in range(10):
        for crow in range(2):
            for p in range(8):
                v = packed[n * 16 + crow * 8 + p]
                o = n * 64 + crow * 32 + 4 * p
                assert bytes([top[v >> 4], bot[v >> 4], top[v & 15], bot[v & 15]]) == g[o:o + 4], (n, crow, p)
    return bytes(packed), top + bot
_dpk, _dtab = _digits()
out('digits.bin', _dpk)
out('digtab.bin', _dtab)
out('font.bin', m.font)
out('alt.bin', m.altfile)
out('BAR', m.barbytes)
MUS = os.path.join(BEEB, 'build', 'MUSIC')
if not os.path.exists(MUS):
    os.system('python3 %s %s %s' % (os.path.join(BEEB, 'beebgame', 'tools', 'midi2snd.py'), os.path.join(BEEB, 'assets', 'v500', 'thm.mid'), MUS))
out('music.bin', open(MUS, 'rb').read())
# the title pieces (convert.py: run-length streams of screen-order bytes) for the
# menus' image: the streams, and their directory with the stream addresses as symbols
_tofs, _tbin = [], bytearray()
for _t in m.title_streams:
    _tofs.append(len(_tbin))
    _tbin += _t
out('title.bin', bytes(_tbin))
with open(os.path.join(OUT, 'title.inc'), 'w') as f:
    f.write('; generated by tools/assets.py: the title pieces\n')
    f.write('tp_lo:   .byte %s\n' % ', '.join('<(title_art+%d)' % o for o in _tofs))
    f.write('tp_hi:   .byte %s\n' % ', '.join('>(title_art+%d)' % o for o in _tofs))
    f.write('tp_cols: .byte %s\n' % ', '.join(str(p[1]) for p in m.title_pieces))
    f.write('tp_rows: .byte %s\n' % ', '.join(str(p[2]) for p in m.title_pieces))

# ---------------------------------------------------------------- per-level helpers

SPRITES_OF = {0: 1, 1: 1, 2: 1, 3: 2, 4: 1, 5: 1, 6: 1, 7: 1, 8: 0, 9: 1, 10: 1, 11: 0, 12: 1}
def cellbox(t, x, y, e):                    # level_init's gx0, gx1, gy, gy1, in cells
    m0 = lambda v: max(v, 0)
    gx0, gx1, gy, gy1 = m0(x - 1) >> 3, x >> 3, y >> 3, (y + 1) >> 3
    if t == 0: gy, gy1 = m0(y - 1) >> 3, y >> 3
    elif t == 1: gx0, gx1, gy = m0(x - 2) >> 3, (x + 1) >> 3, (y + 1) >> 3; gy1 = gy
    elif t in (2, 5, 6): gx1 = (x + e[0]) >> 3
    elif t == 3: gy = m0(y - 4) >> 3
    elif t == 4: gy, gx1, gy1 = m0(y - 1) >> 3, (x + e[0]) >> 3, (y + e[1]) >> 3
    elif t == 9: gy, gy1 = m0(y - 2) >> 3, y >> 3
    elif t == 11: gy1 = gy
    return gx0, gx1, gy, gy1

def place_sprites(lv, sub):
    """The level's sprites: which images and boxes, each one's bank and a first
    placement that fits (greedy, in regions after the resident block) -- the fill of
    each region, the addresses, the banks, the items."""
    L = m.levels[(lv, sub)]
    name = m.name_of(lv, sub)
    cm = m.maps[(lv, sub)]
    types = sorted(set(t for (t, x, y, e) in L['objs']))
    ids = set(ALWAYS_IDS)
    for t in types:
        if t in m.TYPE_IDS:
            lo, hi = m.TYPE_IDS[t]
            ids |= set(range(lo, hi + 1))
    imgs = sorted(set(m.entry[i][0] for i in ids if m.entry[i] is not None) - set(COMMON))   # (placed per level)
    # the box stars' art by each star's class (convert.py star_class: 1 on sky, the
    # first six boxes; 2 on black, the second six -- logic.s boxbase), not by the set
    classes = set(m.star_class(cm, x, y) for (t, x, y, e) in L['objs'] if t == 0)
    bxs = (list(range(0, 6)) if 1 in classes else []) + (list(range(6, 12)) if 2 in classes else [])
    R5BASE = C5_BASE + C5_LEN               # above the resident part, up to the map
    regions = {'r4': [COMMON_END, B4_DATA[1]], 'r6': [R5BASE, B5_DATA[1]]}   # (r6: bank 5's)
    mirrored = set(m.entry[i][0] for i in ids if m.entry[i] is not None and m.entry[i][1])
    items0 = [('img', j, len(m.img_bytes[j])) for j in imgs]
    items0 += [('box', k, len(m.box_bytes[k])) for k in bxs]
    CUR[0] = (lv, sub)
    _tr, _st, _by, _at = level_bakes(lv, sub)
    items0 += [(k[0], k[1], len(b)) for k, b in sorted(_by.items())]
    def canmirror(it):
        return it[0] == 'img' and it[1] in mirrored
    def attempt(items, prefer4):
        """One greedy placement in this order; None if something does not fit."""
        fill = {r: 0 for r in regions}
        img_addr, img_bank = {}, {}
        def fits(key, r, n, bank):
            if regions[r][1] - regions[r][0] - fill[r] < n:
                return False
            img_addr[key] = regions[r][0] + fill[r]; fill[r] += n; img_bank[key] = bank
            return True
        for kind, j, n in items:            # (either bank takes any image, mirrored or not)
            key = (kind, j)
            ok = (fits(key, 'r4', n, 4) or fits(key, 'r6', n, 5)) if prefer4 else \
                 (fits(key, 'r6', n, 5) or fits(key, 'r4', n, 4))
            if not ok:
                return None
        return fill, img_addr, img_bank
    # the boxes and the mirrored images first, then the rest largest first; when that
    # greedy order leaves a hole too small, other orders of the rest, deterministically,
    # until one fits
    base_order = sorted(items0, key=lambda it: (0 if it[0] != 'img' else (1 if canmirror(it) else 2), -it[2]))
    fixed = [it for it in base_order if it[0] != 'img' or canmirror(it)]
    rest = [it for it in base_order if not (it[0] != 'img' or canmirror(it))]
    import random
    got = None
    for trial in range(400):
        order = rest if trial < 2 else random.Random(trial).sample(rest, len(rest))
        got = attempt(fixed + order, trial % 2 == 1)
        if got:
            break
    if got is None:
        raise SystemExit('%s: sprites do not fit in any order tried' % name)
    fill, img_addr, img_bank = got
    return fill, img_addr, img_bank, items0, regions, imgs

def settle_level(level, img_addr, img_bank, regions):
    """The placed items, reordered and padded within each region for the loops."""
    ws = weights(level)
    c0 = c1 = 0.0
    for r, (lo, hi) in regions.items():
        if hi <= lo:
            continue
        bank = 4 if r.endswith('4') else 5      # (a region is one bank's: the address alone
        inr = lambda k, a: lo <= a < hi and img_bank[k] == bank   #  can be the other bank's)
        keys_i = [k for k, a in img_addr.items() if inr(k, a) and (k[0], k[1]) not in RESIDENT]
        if not keys_i:
            continue
        addr, b, a_, end = sprpack.optimise(chunk_items(keys_i, ws), lo, hi, _cache)
        c0 += b; c1 += a_
        for k in keys_i: img_addr[k] = addr[('i',) + k]
    return img_addr, c0, c1

# ---------------------------------------------------------------- one level
# Cleo's fields in the level header (logic.s level_init): the start and exit, in tiles,
# and the special tiles' ids (the vanishing blocks, the flowers)
HDR_STARTX, HDR_STARTY, HDR_EXITX, HDR_EXITY, HDR_SPECIAL = 2, 3, 4, 5, 8
def pack_level(lv, sub):
    L = m.levels[(lv, sub)]
    name = m.name_of(lv, sub)
    cm = m.maps[(lv, sub)]
    assert cm.min() >= 0
    gset = m.tileset_of(lv, sub)
    # the level's tiles: convert.py pack_tiles
    T = m.pack_tiles(lv, sub)
    local = T['local']
    lut = np.zeros(len(m.compact), dtype=np.uint8)
    for c, t in local.items():
        lut[c] = t
    mapb = lut[cm].tobytes()
    h, w = cm.shape
    specials = [m.special['VANISH0'] + i for i in range(8)] + [m.special['FLOWER0'] + i for i in range(4)]

    # ---- tables: the header's game fields (the rest is the engine's: levelfile), as
    # logic.s level_init reads them
    ghdr = {HDR_STARTX: L['start'][0], HDR_STARTY: L['start'][1], HDR_EXITX: L['exit'][0],
            HDR_EXITY: L['exit'][1], 7: 1}          # (+7: unread, kept as it was)
    for i, cid in enumerate(specials):
        ghdr[HDR_SPECIAL + i] = local.get(cid, 255)
    objs = []
    reach = m.enemy_reach(L['objs'])
    _tr, _st, _by, _at = level_bakes(lv, sub)
    for oi, (t, x, y, ex) in enumerate(L['objs']):
        e = (list(ex) + [0, 0, 0])[:3]
        if t == 0:
            e[0] = m.star_class(cm, x, y)
            e[0] = {0: 0, 1: BOXID0, 2: BOXID0 + 6}[e[0]]   # its six boxes' first id: the sky's,
            if oi in _st:                   # the black's, or its own (baked)
                e[0] = BOXID0 + 12 + TRMAX + 6 * _st[oi]
            e[1] = 1 if m.star_reachable(x, y, reach) else 0
        elif t == 1:
            e[0] = BOXID0 + 12 + _tr[oi] if oi in _tr else 0
            b = m.TYPE_BOX[1]
            selfbox = (8 * x + b[0], 8 * x + b[1], 8 * y + b[2], 8 * y + b[3])
            e[1] = 1 if m.box_reachable(b, x, y, reach, skip=selfbox) else 0
        objs.append([t, x, y] + e)
    # a kept box must not be drawn over: any box-drawn object (a star or trampoline
    # with a box id) whose drawn area meets another static object's -- over every
    # frame either can show, a star's sparkle too -- is marked disturbable (e1), so
    # it is redrawn every frame (still a copy, never erased) rather than kept
    def area(t, x, y):
        ids = range(34, 43) if t == 0 else range(43, 46)
        bs = [m._SPRBOX[i] for i in ids if i in m._SPRBOX]
        ox = 8 * x + (4 if t == 1 else 0)
        r = (ox + min(b[0] for b in bs), ox + max(b[1] for b in bs), 8 * y + min(b[2] for b in bs), 8 * y + max(b[3] for b in bs))
        if t == 1:                      # (and the rest box itself)
            bx = ox - m.TRAMP_HOT + 2 * m.TRAMP_REST_LO
            r = (min(r[0], bx), max(r[1], bx + 2 * m.TRAMP_REST_WC), min(r[2], 8 * y + 8), max(r[3], 8 * y + 8 + m.TRAMP_H))
        else:
            r = (min(r[0], 8 * x - 6), max(r[1], 8 * x + 8), min(r[2], 8 * y - 8), max(r[3], 8 * y + 4))
        return r
    stat = [(i, area(o[0], o[1], o[2])) for i, o in enumerate(objs) if o[0] in (0, 1)]
    meet = lambda p, q: p[0] < q[1] and q[0] < p[1] and p[2] < q[3] and q[2] < p[3]
    for i, ri in stat:
        if objs[i][3] and any(j != i and meet(ri, rj) for j, rj in stat):
            objs[i][4] = 1
    objs = b''.join(bytes(o) for o in objs)
    attr = bytearray(256)
    acls = bytearray(256)
    for c in sorted(local):
        t = local[c]
        attr[t] = m.attr_of(c)
        acls[t] = 0 if c in m.tile_solid else m.alt_class[c]

    # ---- the sprite list's bounds: the objects whose cells the walk rectangle can
    # cover from any camera position
    boxes = []
    for (t, x, y, ex) in L['objs']:
        e = (list(ex) + [0, 0, 0])[:3]
        boxes.append((t, cellbox(t, x, y, e)))
    # (both machines' windows: one bound, so the tables it sizes lie alike on both)
    rects = set()
    for vl in VISLINES_ALL:
        maxwx, maxwy = w * 8 - 160, h * 8 - vl // 2
        for wx in range(0, maxwx + 1, 2):
            for wy in range(0, maxwy + 1):
                rects.add((wx >> 6, (wx + 159) >> 6, wy >> 6, (wy + vl // 2 - 1) >> 6))
    MAXSPR, BINMAX = 0, 0
    for (rx0, rx1, ry0, ry1) in rects:
        hit = [t for (t, (gx0, gx1, gy, gy1)) in boxes if gx0 <= rx1 and gx1 >= rx0 and gy <= ry1 and gy1 >= ry0]
        MAXSPR = max(MAXSPR, sum(SPRITES_OF[t] for t in hit) + 2)
        BINMAX = max(BINMAX, sum(1 for t in hit if t == 0), sum(1 for t in hit if t != 0))

    # ---- sprites: which images, and where each goes (place_sprites), then where in
    # each region: the order and padding that cost the sprite loops least (sprpack)
    fill, img_addr, img_bank, items0, regions, imgs = place_sprites(lv, sub)
    img_addr, cost0, cost1 = settle_level(lv * 2 + sub, img_addr, img_bank, regions)
    # a baked item's tile (x, y) rides in its placement entry's mask field (ldprog.s bake)
    BAKEAT[(lv, sub)] = {k: (img_bank[k], img_addr[k]) for k in _by}
    placement = lf.placement([(item_index(kind, j), img_bank[(kind, j)], a,
                               _at[(kind, j)][0] | _at[(kind, j)][1] << 8 if kind in ('tr', 'sb') else 0)
                              for (kind, j), a in sorted(img_addr.items(), key=lambda kv: item_index(*kv[0]))])
    for j in COMMON:                        # (the resident block, for the directory)
        img_addr[('img', j)] = common_addr[j]; img_bank[('img', j)] = common_bank[j]
    # the directory as the game reads it: the template's entries with each placed
    # item's address (and bank 5's flag)
    byitem = {item_index(*k): k for k in img_addr}
    entries = []
    for i in range(NDIR):
        t = sprdir[i * 8:i * 8 + 8]
        k = byitem.get(t[0]) if t[0] != 0xFF else None
        entries.append(None if k is None else (img_addr[k], img_bank[k], t[2:8]))
    directory = lf.directory(entries)
    if SPRGEOM:                             # the level's part: the addresses alone
        directory = lf.directory_split([None if e is None else (e[0], e[1]) for e in entries])

    # ---- the file (beebgame's levelfile: the engine's format)
    data = lf.encode(lf.Level(lw=L['lw'], lh=L['lh'], game_header=ghdr, shape=lf.Shape(**T['B']['shape']),
                              objects=bytes(objs), tile_tables=(bytes(attr), bytes(acls)),
                              tiles=T['B']['tiles'], placement=placement, map=mapb, flat=T['flat'],
                              halves=T['halves'], hpair=T['hpair'], mir=T['B']['mir'],
                              directory=directory, page0=T['B']['page0'],
                              boxid0=BOXID0, boxn=BOXN))
    back = lf.decode(data)
    assert back['map'] == mapb and back['objs'] == bytes(objs) and back['dir'] == directory
    maprle = lf.rle(mapb)                   # (for the report)
    out('L%d' % (lv * 2 + sub), data)
    stats = dict(name=name, ntiles=T['ntiles'], nflat=T['nflat'], nhalf=T['nhalf'], nmir=T['nmir'], w=w, h=h, nobj=len(L['objs']),
                 nimg=len(imgs), r4=fill['r4'], r6=fill['r6'],
                 maxspr=MAXSPR, binmax=BINMAX, maprle=len(maprle), size=len(data), cost0=cost0, cost1=cost1)
    return stats

# ---- the resident block, placed for the loops too: it may pad into the room the
# fullest level leaves in each bank (the levels' first fit, before it moves)
RESIDENT = set(('img', j) for j in COMMON)
if STARPLAN:
    # Which stars: the ones that save the most vsyncs a sector of disc.  The plan has
    # every frame that missed its peg (3 vsyncs of V usable cycles) with a masked star in
    # it; a frame's vsyncs are ceil(work / V), no fewer than the peg's, so a star saves
    # something only where taking its cycles out crosses a multiple of V -- summed over
    # every frame it is drawn in, a bonus level's (a small map: 32 x 32 tiles or less,
    # played far less often) at a quarter.  Greedy: the best star a byte of bank, its
    # frames updated, the next; each within its level's slots and its banks (the
    # placement must still fit).  (The loader bakes them: nothing on the disc.)
    played = lambda lv, sub: 0.25 if m.maps[(lv, sub)].size <= 32 * 32 else 1.0
    frames = {}                             # (lv, sub) -> [work, {(x, y): cycles}]
    for lv in range(8):
        for sub in (0, 1):
            P = STARPLAN.get(str(lv * 2 + sub))
            if P:
                frames[(lv, sub)] = (P['V'], [[w, {(x, y): c for x, y, c in st}] for w, st in P['frames']])
    vs = lambda w, V: max(3, -(-w // V))
    def gain(key, xy):
        V, fl = frames[key]
        return sum(vs(w, V) - vs(w - st[xy], V) for w, st in fl if xy in st) * played(*key)
    cand = {(key, xy) for key, (V, fl) in frames.items() for w, st in fl for xy in st
            if m.star_class(m.maps[key], *xy) == 0 and m.bake_star(m.maps[key], *xy) is not None}
    size = lambda key, xy: sum(len(b) for b in m.bake_star(m.maps[key], *xy))
    saved = [0.0]
    while cand:
        best = max(cand, key=lambda kx: (gain(*kx) / size(*kx), kx))
        key, xy = best
        cand.discard(best)
        if gain(key, xy) <= 0:
            break
        if len(CHOSEN.get(key, [])) >= NSTAR:
            continue
        CHOSEN.setdefault(key, []).append(xy); _bakes.pop(key, None)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                place_sprites(*key)
            ok = True
        except SystemExit:
            ok = False
        if not ok:
            CHOSEN[key].pop(); _bakes.pop(key, None)
            continue
        V, fl = frames[key]
        saved[0] += gain(key, xy) / played(*key)
        for f in fl:
            if xy in f[1]:
                f[0] -= f[1].pop(xy)
    print('stars chosen (the plan\'s frames: %d vsyncs saved): %s' % (saved[0], ', '.join('L%d: %d' % (k[0] * 2 + k[1], len(v)) for k, v in sorted(CHOSEN.items()) if v)))
_spare4 = _spare5 = 0x10000
for lv in range(8):
    for sub in (0, 1):
        fill, *_rest, regions, _i = place_sprites(lv, sub)
        _spare4 = min(_spare4, regions['r4'][1] - regions['r4'][0] - fill['r4'])
        _spare5 = min(_spare5, regions['r6'][1] - regions['r6'][0] - fill['r6'])
_wr = weights(None)
def _resident(keys_i, lo, budget):
    size = sum(len(item_bytes(*k)) for k in keys_i)
    if not keys_i:
        return {}, bytearray(), 0.0, 0.0
    addr, b, a_, end = sprpack.optimise(chunk_items(keys_i, _wr), lo, lo + size + budget, _cache)
    blk = bytearray(end - lo)
    for k in keys_i:
        d = item_bytes(*k); blk[addr[('i',) + k] - lo:addr[('i',) + k] - lo + len(d)] = d
    return addr, blk, b, a_
_a4, sprc4, _rb4, _ra4 = _resident([('img', j) for j in c4], B4_DATA[0], _spare4)
_a5, sprc5, _rb5, _ra5 = _resident([('img', j) for j in c6], C5_BASE, _spare5)
for j in c4 + c6:
    common_addr[j] = (_a4 if j in c4 else _a5)[('i', 'img', j)]
COMMON_END = B4_DATA[0] + len(sprc4)
C5_LEN = len(sprc5)
assert COMMON_END <= B4_DATA[1] and C5_BASE + C5_LEN <= B5_DATA[1]
sprc = sprc4 + sprc5
out('SPRC', sprc)
print('resident: bank 4 %d bytes (+%d padding), bank 5 %d (+%d); loops %.1f -> %.1f cycles a frame'
      % (len(sprc4), len(sprc4) - sum(len(m.img_bytes[j]) for j in c4),
         len(sprc5), len(sprc5) - sum(len(m.img_bytes[j]) for j in c6),
         _rb4 + _rb5, _ra4 + _ra5))

allstats = []
for lv in range(8):
    for sub in (0, 1):
        s = pack_level(lv, sub)
        allstats.append(s)
        print('%-4s %3d tiles +%2d half +%2d mirror +%d flat map %3dx%2d rle %5d  %3d obj %2d img  '
              'b4 %5d  b5 %5d  spr %2d bin %2d  file %5d  loops %.1f -> %.1f'
              % (s['name'], s['ntiles'], s['nhalf'], s['nmir'], s['nflat'], s['w'], s['h'], s['maprle'], s['nobj'], s['nimg'],
                 s['r4'], s['r6'], s['maxspr'], s['binmax'], s['size'], s['cost0'], s['cost1']))
sprpack.save_cache(_cache, SPRPACK_CACHE)

MAXSPR = max(s['maxspr'] for s in allstats)
BINMAX = max(s['binmax'] for s in allstats)
with open(os.path.join(OUT, 'assets.inc'), 'w') as f:
    f.write('; generated by tools/assets.py: the bounds every level fits\n')
    f.write('SOLID_CYAN = %d\nSOLID_BLACK = %d\nFLAT0 = %d\nNFLAT = %d\nMAXMIR = %d\n' % (SOLID_CYAN, SOLID_BLACK, m.FLAT0, m.NFLAT, m.MAXMIR))
    f.write('BOXID0 = %d\nBOXN = %d\n' % (BOXID0, BOXN))
    if SPRGEOM:
        f.write('SPRGFL = 1\n')            # the geometry carries flags by shape (engine.s)
    f.write('BAKEITEM0 = %d\n' % BAKEITEM0)   # the items the loader bakes (ldprog.s bake)
    f.write('SPRC_BASE = $%04X\nSPRC_LEN = %d\nSPRC5_BASE = $%04X\nSPRC5_LEN = %d\nSPRX_LEN = %d\n'
            % (B4_DATA[0], len(sprc4), C5_BASE, len(sprc5), len(sprx)))
    f.write('TOFF = %d\n' % m.TOFF)          # id k's tile slot is k + TOFF (convert.py)
    f.write('TP_LOGO = 0\nTP_YOU = 1\nTP_WIN = 2\nTP_LOSE = 3\nTP_CLEO0 = 4\n')   # the title pieces (convert.py)
    f.write('TBUF_LEN = %d\n' % max(len(p[3]) for p in m.title_pieces))   # the largest, unpacked (menu.s)
    f.write('MAXSPRDEF = %d\nBINMAXDEF = %d\n' % (MAXSPR, BINMAX))
    f.write('B4_DATA_END = $%04X\nB5_TOP = $%04X\nMAP5 = $%04X\n' % (B4_DATA[1], B5_TOP, MAP5))
    f.write('B4_CODE_END = $%04X\nB5_CODE_END = $%04X\n' % (B4_CODE_END, B5_CODE_END))
print('MAXSPR %d BINMAX %d; imgtab %d entries' % (MAXSPR, BINMAX, len(imgtab) // 5))
out('nibtab.bin', m.NIBTAB)             # the engine's L0TAB, L1TAB, NMASK (banks.s)
out('bakegeom.bin', bytes(bakegeom))   # the baker's tables (ldprog.s)
out('bakekind.bin', bakekind)
json.dump({'%d' % (lv * 2 + sub): [[k[0], k[1], list(_bk[3][k]), list(BAKEAT[(lv, sub)][k]), list(_bk[2][k])] for k in sorted(_bk[2])]
           for lv in range(8) for sub in (0, 1) for _bk in [level_bakes(lv, sub)]},
          open(os.path.join(OUT, 'bakes.json'), 'w'))   # (test/bakecheck.mjs: what the loader must make)
print('baked by the loader: trampolines %d, stars %d' % (
      sum(len(level_bakes(lv, sub)[0]) for lv in range(8) for sub in (0, 1)),
      sum(len(level_bakes(lv, sub)[1]) for lv in range(8) for sub in (0, 1))))
if SPRGEOM:                                 # the geometry every level shares, by shape
    shapes, six = [], []
    for i in range(NDIR):
        t = sprdir[i * 8:i * 8 + 8]
        g = (t[2], t[4], t[5], t[7], t[6]) if t[0] != 0xFF else None   # W, refx, refy, lines, flags
        if g is None:
            six.append(0); continue
        if g not in shapes:
            shapes.append(g)
        six.append(shapes.index(g))
    assert len(shapes) <= 256
    with open(os.path.join(OUT, 'sprgeom.inc'), 'w') as f:
        f.write('; generated by tools/assets.py: the sprites\' geometry by shape (SPRGEOM)\n')
        f.write('SPRG_IX: .byte %s\n' % ', '.join(map(str, six)))
        for name, k in (('SPRG_W', 0), ('SPRG_RX', 1), ('SPRG_RY', 2), ('SPRG_LN', 3), ('SPRG_FL', 4)):
            f.write('%s: .byte %s\n' % (name, ', '.join(str(sh[k]) for sh in shapes)))
    print('SPRGEOM: %d ids, %d shapes: %d bytes of geometry' % (NDIR, len(shapes), NDIR + 5 * len(shapes)))
