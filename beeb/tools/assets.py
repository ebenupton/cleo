#!/usr/bin/env python3
"""Pack every level, and the sprites, for both machines.

Usage (from beeb/, as build.sh does, once per machine):
    TARGET=modelb|master BD=build/<target> python3 tools/assets.py

convert.py is imported for its tables (and writes the tile set's files, TILES0-2, which go
on the disc as it wrote them).  The sprites are written here: SPRC, the resident sprites
every level draws (Cleo, the boomerang, the stars, the trampoline), at fixed addresses in
banks 4 and 5, and SPRX, everything else, from which each level takes its subset.  The
game's own loader (beebgame ldprog.s) stages one file at a time and copies the pieces a
level needs into the banks, where this packer decided they go.  The level files are shared
by the two machines, so the two runs must write them identically (build.sh checks).  The
sprite placement within each bank region is sprpack.py's (beebgame/tools), weighted by
tools/drawfreq.json (test/drawfreq.mjs) and cached in build/sprpack.cache; the stars to
bake come from tools/starbake.json (test/starplan.mjs).

Written to $BD:
   L0..L15        per level file (level * 2 + sub): a table of section offsets, then the
                  header (with the game's fields and RNGTAB as its tail), the objects, the
                  attribute and altitude-class tables, the tile lists (convert.py
                  pack_tiles), the sprite placement list, the RLE map, FLATTAB, the halves,
                  the half fill palette, the sprite directory, and last the Master's
                  LV_PAGE0 in two whole sectors (beebgame/tools/levelfile.py: the format)
   SPRC, SPRX     the sprites, as above
   img_tab.bin    per image and box star: which shared file holds it and where (ldprog.s)
   bake_geom.bin, bake_kind.bin   the loader's baked-box kinds and each baked slot's kind
   digits.bin     the HUD's digits packed; digtab.bin their decode (gamedata.s)
   font.bin       the menus' glyphs;  alt.bin  the altitude classes;  music.bin  the tune
                  (build/MUSIC, midi2snd.py's, made here if missing)
   title.bin, title.inc   the title pieces' run-length streams and their directory
   BAR            the bar template, 1280 bytes, read to BARADDR as each game starts
   assets.inc     the constants the sources read: the bounds every level fits (MAXSPRDEF,
                  BINMAXDEF), the sprite blocks' places and sizes, the banks' code ends and
                  layout, the game's header fields, RNGTAB's quads, the object types and
                  sprite ids, the HUD's columns, the run-length code
   sprgeom.inc    the sprites' geometry by shape (frame.s)
   bakes.json     every baked item (test/bakecheck.mjs: what the loader must make)
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
# where to write: build.sh sets TARGET (modelb or master) and BD
TARGET = os.environ.get('TARGET', 'modelb')
OUT = os.path.join(BEEB, os.environ.get('BD', 'build/' + TARGET))
os.makedirs(OUT, exist_ok=True)

def out(name, data):
    """Write data to $BD/name."""
    open(os.path.join(OUT, name), 'wb').write(bytes(data))

# the windows' lines, the Master's and the Model B's: VISROWS 30 / 21 x 8 (engine/defs.s
# VISLINES: the packer runs before the assembler, so the values are repeated here)
VISLINES_ALL = (240, 168)

# ---------------------------------------------------------------- the banks' fixed shape
# Code sits at the bottom of banks 4, 5 and 6 (each entered at $8000) and the expansion
# tables at the top of 4 and 5; bank 6's tiles run from its code's next page to the end;
# bank 5's map is a fixed 8K below its tables.  These are the bounds the linker config
# (beebgame/cfg/banks.cfg) and defs.inc share.
# The sprites start exactly where the Model B's code ends in each bank: every byte its code
# does not take is sprite room.  One disc serves both machines, so the level files -- the
# sprites' addresses -- are one layout: the Master's code, a little shorter, leaves a gap
# below them.  The ends are the linker's (build/modelb/map.txt), set here by hand because
# the packer runs before the assembler; sprloops.s and gather.s assert them (exactly on the
# Model B, at most on the Master), so the build stops if they move.
# bank 4: the row loop and blitters (SPR4CODE)
B4_CODE_END = 0x838A
# bank 5: the same, the gather and its variables (MAP5BSS)
B5_CODE_END = 0x8451
# the top 1K of banks 4 and 5: the expansion tables and SWAPTAB (defs.inc L0TAB; the cfg's
# B4T, B5T)
B4_DATA_END = 0xBC00
# the map: a fixed 8K below the tables ($9C00; defs.inc LV_MAP)
MAP_LEN = 0x2000
MAP5 = B4_DATA_END - MAP_LEN
# bank 4: images, between the row loop and the tables
B4_DATA = (B4_CODE_END, B4_DATA_END)
# bank 5: all its sprites, one run, between the row loop + gather and the map: the resident
# part (SPRC's bank-5 part) at the bottom, the level's above it
B5_DATA = (B5_CODE_END, MAP5)
# (the end of bank 5's sprites)
B5_TOP = MAP5
# bank 6: the tiles from here (page aligned), above the code (the cfg's B6X), to the end
TILES_BASE, B6X = m.B_TILES, m.B_TILES_END
# a shared file's stage: 16K on either machine, a page less on the Model B with LDBIG
# (defs.inc STAGE: the load-time program's room)
STAGE_LEN = 0x4000 - (0x100 if os.environ.get('LDBIG') == '1' else 0)
for k in range(3):
    assert os.path.getsize(os.path.join(BEEB, 'build', 'TILES%d' % k)) <= STAGE_LEN, 'TILES%d: past the stage' % k
# img_tab's entry: file, offset (2), length (2)
IMGTAB_LEN = 5
# the window's width in game px (engine/defs.s WINPX); the collision grid's cell (logic.s
# BINPX: 8 tiles)
WINPX, BINPX = 160, 64
# the object types and the sprite ids (convert.py)
OT, SPR, SPR_N = m.OT, m.SPR, m.SPR_N
# a star's spin frames: a baked star is a box each
NSTARF = SPR_N['STAR0']

# ---------------------------------------------------------------- Cleo's sprites
# The sprite ids (the engine's directory: BOXID0 images, then BOXN boxes; ids from
# BOXID0 + BOXN are the engine's "still" aliases of the boxes, BOXN below them): images
# 0..102 (the entries of the original's dim), then the boxes -- screen bytes, copied: the
# twelve box stars on sky and on black, then TRMAX slots for the level's trampolines at
# rest, NSTAR slots of six for its baked stars and PWMAX for its health powerups, each slot
# the level's own art, baked by the loader (below).
TRMAX, NSTAR, PWMAX = 13, 8, 2
# the box stars' images: six frames on sky, six on black
NBOXART = 2 * NSTARF
BOXID0, BOXN = m.NSPRITE, NBOXART + TRMAX + NSTARF * NSTAR + PWMAX
# (the boxes' "still" aliases are ids too)
assert BOXID0 + 2 * BOXN <= 256
# directory entries
NDIR = BOXID0 + BOXN
# The split between resident and staged, which is the game's to choose: the resident
# sprites (SPRC) are loaded once, to fixed places in banks 4 and 5 (assets.inc SPRC_BASE,
# SPRC5_BASE); the staged ones (SPRX) are staged at each level load and the level's own
# subset copied to where its placement list says.  Cleo's resident set: what (nearly) every
# level draws -- Cleo, the boomerang, the stars and their collect animation (0..42), the
# trampoline (43..45); ALWAYS_IDS are the ids a level draws whatever its objects.
RESIDENT_IDS = list(range(SPR['TRAMP0'] + SPR_N['TRAMP0']))
ALWAYS_IDS = range(SPR['TRAMP0'])

# ---------------------------------------------------------------- the shared files
# The resident sprites are one file (SPRC), everything else -- the enemies, the box stars
# -- another (SPRX), which a load stages and copies from: the level's subset, to the
# addresses placed below.  (The Master keeps SPRX in HAZEL and ANDY after its first read:
# ldprog.s SPRXKEEP.)  img_tab says where in SPRX each item is.
NIMG = len(m.images)
# item keys: ('img', j) | ('box', k) | ('tr', k) | ('sb', k) | ('pw', k) -> a small integer
# the placement lists and the directory template use
def item_index(kind, j):
    """The item index of (kind, j): the images first, then the box stars, the trampoline
    slots, the baked star slots and the powerup slots."""
    return {'img': 0, 'box': NIMG, 'tr': NIMG + NBOXART, 'sb': NIMG + NBOXART + TRMAX,
            'pw': NIMG + NBOXART + TRMAX + NSTARF * NSTAR}[kind] + j
BAKED = ('tr', 'sb', 'pw')
# the powerup's box about (8x, 8y)
PW_RECT = (-m.PW_LEFT, 2 * m.PW_WC - m.PW_LEFT, m.PW_TOP, m.PW_TOP + m.PW_H)
# The level's baked boxes: every trampoline's rest state, every health powerup, and the
# stars the plan names (tools/starbake.json: by level file, the stars' tiles, best first --
# the frames that miss their peg draw them: test/starplan.mjs), each composited over its own
# backdrop (convert.py bake_box).  A slot for each, as long as the level has ids for it and
# the placement can fit it.
try:
    STARPLAN = json.load(open(os.path.join(HERE, 'starbake.json')))
except OSError:
    STARPLAN = {}
_bakes = {}
# (level, sub) -> {object index: its powerup slot}
PWOF = {}
# (level, sub) -> the stars it bakes, in order (chosen below)
CHOSEN = {}
def level_bakes(lv, sub):
    """The level's baked items (memoised in _bakes): (tr: {trampoline object index: slot},
    st: {star object index: slot}, by: {(kind, slot): bytes}, at: {(kind, slot): tile
    (x, y)}).  Trampolines whose boxes come out the same share a slot, TRMAX slots at most;
    every powerup is baked (PWMAX slots, shared alike); the stars are CHOSEN's, in its
    order, those on a mixed backdrop (star_class 0) that bake, NSTAR at most."""
    if (lv, sub) in _bakes:
        return _bakes[(lv, sub)]
    L, cm = m.levels[(lv, sub)], m.maps[(lv, sub)]
    tr, st, by, at = {}, {}, {}, {}
    slot = {}
    for oi, (t, x, y, e) in enumerate(L['objs']):
        if t == OT['TRAMP']:
            b = m.bake_tramp_rest(cm, x, y)
            if b is not None and (b in slot or len(slot) < TRMAX):
                if b not in slot:
                    slot[b] = len(slot); by[('tr', slot[b])] = b; at[('tr', slot[b])] = (x, y)
                tr[oi] = slot[b]
    pw, pslot = {}, {}
    for oi, (t, x, y, e) in enumerate(L['objs']):
        if t == OT['POWERUP']:
            b = m.bake_powerup(cm, x, y)
            assert b is not None, ('%s: a powerup the baker cannot make' % m.name_of(lv, sub), x, y)
            if b not in pslot:
                pslot[b] = len(pslot); by[('pw', pslot[b])] = b; at[('pw', pslot[b])] = (x, y)
            pw[oi] = pslot[b]
    assert len(pslot) <= PWMAX, (lv, sub, len(pslot))
    PWOF[(lv, sub)] = pw
    want = CHOSEN.get((lv, sub), [])
    pos = {(x, y): oi for oi, (t, x, y, e) in enumerate(L['objs']) if t == OT['STAR']}
    for xy in want:
        oi = pos.get(xy)
        if oi is None or m.star_class(cm, *xy) != 0 or len(st) >= NSTAR:
            continue
        fr = m.bake_star(cm, *xy)
        if fr is not None:
            st[oi] = len(st)
            for f, b in enumerate(fr):
                by[('sb', st[oi] * NSTARF + f)] = b; at[('sb', st[oi] * NSTARF + f)] = xy
    _bakes[(lv, sub)] = (tr, st, by, at)
    return _bakes[(lv, sub)]
# the level being placed (its baked items' bytes)
CUR = [None]
# (level, sub) -> its baked items' (bank, address)
BAKEAT = {}
def item_bytes(kind, j):
    """The bytes of item (kind, j): a baked item's from the level being placed (CUR), an
    image's or box star's from convert.py."""
    if kind in BAKED:
        return level_bakes(*CUR[0])[2][(kind, j)]
    return m.img_bytes[j] if kind == 'img' else m.box_bytes[j]
COMMON = sorted(set(m.entry[i][0] for i in RESIDENT_IDS if m.entry[i] is not None))
# The mirrored ones go in bank 4 (from when only bank 4 could mirror: kept, as moving them
# would move every level's layout); bank 4 cannot also hold all the plain ones beside the
# biggest levels' mirrored enemies, so the rest go to the bottom of bank 5's sprite run.
_mirrored_all = set(m.entry[i][0] for i in range(BOXID0) if m.entry[i] is not None and m.entry[i][1])
common_addr, common_bank = {}, {}
def _pack(js, base):
    """The images js laid end to end from base: their bytes, each one's address noted in
    common_addr."""
    blk = bytearray()
    for j in js:
        common_addr[j] = base + len(blk); blk += m.img_bytes[j]
    return blk
c4 = [j for j in COMMON if j in _mirrored_all]
# the plain ones: bank 4 takes what it can spare beside the biggest level's mirrored enemies
# (largest first), bank 5 the rest
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
assert COMMON_END <= B4_DATA[1] and C5_BASE + C5_LEN <= B5_DATA[1] and MAP5 + MAP_LEN <= B4_DATA_END
sprc = sprc4 + sprc5
out('SPRC', sprc)
# SPRX and img_tab: each staged image, then the box stars, then the bake overlays; a
# resident image's entry is zeros (never placed)
sprx, img_tab = bytearray(), bytearray()
for j in range(NIMG):
    if j in common_addr:
        img_tab += bytes(IMGTAB_LEN); continue
    o, n = len(sprx), len(m.img_bytes[j]); sprx += m.img_bytes[j]
    # file 0 (SPRX), offset, length
    img_tab += bytes([0, o & 255, o >> 8, n & 255, n >> 8])
for k in range(NBOXART):
    o, n = len(sprx), len(m.box_bytes[k]); sprx += m.box_bytes[k]
    img_tab += bytes([0, o & 255, o >> 8, n & 255, n >> 8])
assert len(img_tab) == IMGTAB_LEN * (NIMG + NBOXART)
# the baked slots' first item: made by the loader (ldprog.s bake), no img_tab entries
# (place_walk bakes them before it looks)
BAKEITEM0 = NIMG + NBOXART
# bake_geom (ldprog.s bake): a kind's shape, BG_LEN bytes -- byte columns, lines, dx (16
# bit, from 8x in game px), dty (from y in tile rows), its overlay's offset in SPRX (16
# bit), skip (start the first tile row at its bottom char row).  The tile where the object
# stands rides in its placement entry's extra field.
BG_WC, BG_LINES, BG_DX, BG_DTY, BG_OV, BG_SKIP, BG_LEN = 0, 1, 2, 4, 5, 7, 8
bake_geom = bytearray()
for k_ in m.BAKE_KINDS:
    wc, lines, dx, dty, ov = k_[:5]
    skip = k_[5] if len(k_) > 5 else 0
    o = len(sprx); sprx += ov
    assert lines <= 32 and len(ov) == 2 * wc * lines
    bake_geom += bytes([wc, lines, dx & 255, (dx >> 8) & 255, dty & 255, o & 255, o >> 8, skip])
assert len(bake_geom) == BG_LEN * len(m.BAKE_KINDS)
# each baked slot's kind: the trampolines 0, the star slots 1..6 by frame, the powerups
bake_kind = bytes([0] * TRMAX + [1 + k % NSTARF for k in range(NSTAR * NSTARF)] + [m.PW_KIND] * PWMAX)
assert len(sprx) <= STAGE_LEN
out('SPRX', sprx)
out('img_tab.bin', img_tab)
print('sprites: SPRC %d bytes (bank 4 $%04X-$%04X, bank 5 $%04X-$%04X), SPRX %d bytes'
      % (len(sprc), B4_DATA[0], COMMON_END, C5_BASE, B5_TOP, len(sprx)))

# The directory template, 8 bytes an id: item index, kind (0 image, 1 box star, 3
# trampoline, 4 baked star, 5 powerup), W (byte columns), height (game px), refx, refy,
# flags, lines -- or $FF and zeros for an id with no sprite.  The item index and kind stand
# where the level's placement will put the pointer and the bank-5 flag (pack_level).  The
# flags are the engine's (engine/defs.s SPF_*): mirrored, every scanline stored, the copy
# blitter.
SPF_MIRROR, SPF_FULLRES, SPF_COPY = 1, 2, 8
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
    # Cleo's frames (ids below BOOM0) take an odd refx: an even one moves left a pixel
    if i < SPR['BOOM0'] and not rx & 1:
        rx -= 1
    # (lines: a byte a row)
    sprdir += bytes([item_index('img', j), 0, W, hh, rx & 255, ry & 255, SPF_MIRROR if mirror else 0, hh])
for k in range(NBOXART):
    lo, wc = m.box_geom[k % NSTARF]
    sprdir += bytes([item_index('box', k), 1, wc, m.BOX_H, (6 - 2 * lo) & 255, 8, SPF_FULLRES | SPF_COPY, m.BOX_H * 2])
for k in range(TRMAX):
    sprdir += bytes([item_index('tr', k), 3, m.TRAMP_REST_WC, m.TRAMP_H, (m.TRAMP_HOT - 2 * m.TRAMP_REST_LO) & 255,
                     (-8) & 255, SPF_FULLRES | SPF_COPY, m.TRAMP_H * 2])
for k in range(NSTAR * NSTARF):
    lo, wc = m.box_geom[k % NSTARF]
    sprdir += bytes([item_index('sb', k), 4, wc, m.BOX_H, (6 - 2 * lo) & 255, 8, SPF_FULLRES | SPF_COPY, m.BOX_H * 2])
# the powerup at rest: the box from (8x - PW_LEFT, 8y)
for k in range(PWMAX):
    sprdir += bytes([item_index('pw', k), 5, m.PW_WC, m.PW_H, m.PW_LEFT, (-m.PW_TOP) & 255, SPF_FULLRES | SPF_COPY, m.PW_H * 2])
assert len(sprdir) == NDIR * 8

# ---------------------------------------------------------------- placing for the loops
# Each item's shape (columns, lines: the directory's), and how often a level draws it
# (tools/drawfreq.json, test/drawfreq.mjs's: draws a frame by sprite id, both machines
# averaged), for the placement that costs the sprite loops least (sprpack.py)
import json
# the engine's sprite placer and level file writer
sys.path.insert(0, os.path.join(BEEB, 'beebgame', 'tools'))
import sprpack
import levelfile as lf
# item index -> (columns, lines)
GEOM = {}
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
    """Draws a frame by item index, [forward, mirrored], for a level file (None: the mean
    over the levels in drawfreq.json).  A "still" alias id counts for its box."""
    ws = {}
    for lk, per in _freq.items():
        if level is not None and int(lk) != level:
            continue
        for sid, n in per.items():
            sid = int(sid)
            sid = sid - BOXN if sid >= NDIR else sid
            it = ITEM_OF.get(sid)
            if it is not None:
                w = ws.setdefault(it, [0.0, 0.0])
                w[1 if sid in MIRRORED_ID else 0] += n / (1 if level is not None else max(1, len(_freq)))
    return ws
SPRPACK_CACHE = os.path.join(BEEB, 'build', 'sprpack.cache')
_cache = sprpack.load_cache(SPRPACK_CACHE)
def chunk_items(keys_img, ws):
    """sprpack items for the keys: each sized, weighted by ws (0.001 for an item never
    drawn) and costed by one table -- the forward and mirrored tables mixed by the two
    directions' draws."""
    out_ = []
    for key in keys_img:
        W, Lh = GEOM[item_index(*key)]
        f, r = ws.get(item_index(*key), (0.0, 0.0))
        tf, tr = sprpack.image_table(W, Lh), sprpack.image_table(W, Lh, True)
        tot = f + r
        out_.append(dict(key=('i',) + key, size=len(item_bytes(*key)), w=tot or 0.001,
                         table=[(f * a + r * b) / tot for a, b in zip(tf, tr)] if tot else tf))
    return out_

# The HUD's digits, 8 x 8 game px each (16 lines of 4 bytes, convert.py), are drawn from
# four game-pixel patterns (the dither's two lines of one colour): a byte column at one game
# row is two game px, a nibble (left << 2 | right).  A digit is 32 nibbles, 16 bytes: for
# each of its two char rows, each byte column, its game rows 0-1 then 2-3, one byte (the
# first row's nibble high).  DIGTAB gives a nibble's top and bottom scanline bytes (logic.s
# bar_digit; gamedata.s digtop, digbot).
def _digits():
    """(the ten digits packed, 16 bytes each; DIGTAB: 16 top bytes then 16 bottom bytes by
    nibble).  Asserts that the digits use at most four patterns and that bar_digit's decode
    gives every byte back."""
    # the left game px's dots: bits 7, 6, 3, 2 (hw.inc MODE1_DOTS_L)
    LM = 0xCC
    pats, packed = [], bytearray()
    def code(t, b, right):
        """The pattern number (0..3) of a game px from its top and bottom screen bytes, the
        left px's bits, or the right px's shifted into them."""
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
# logic.s get_altitude relies on every alt byte being nonzero (a bne for a jmp) and on
# its low nibble, the ground's height in the tile, being at most TILEPX = 8 (a cmp's carry)
assert all(b != 0 and (b & 15) <= 8 for b in m.altfile), 'alt.bin: an alt byte is 0 or its low nibble is above 8'
out('alt.bin', m.altfile)
out('BAR', m.barbytes)
MUS = os.path.join(BEEB, 'build', 'MUSIC')
if not os.path.exists(MUS):
    os.system('python3 %s %s%s %s' % (os.path.join(BEEB, 'beebgame', 'tools', 'midi2snd.py'), '--fx ' if os.environ.get('TUNEFX') == '1' else '',
                                      os.path.join(BEEB, 'assets', 'v500', 'thm.mid'), MUS))
out('music.bin', open(MUS, 'rb').read())
# the title pieces (convert.py: run-length streams of screen-order bytes) for the menus'
# image: the streams, and their directory with the stream addresses as symbols (gamedata.s
# title_art; menu.s unpack)
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

# the sprites a type draws at most
SPRITES_OF = {OT['STAR']: 1, OT['TRAMP']: 1, OT['SNAKE']: 1, OT['RSNAKE']: 2, OT['BAT']: 1, OT['MASK']: 1,
              OT['MUMMY']: 1, OT['SPIKE']: 1, OT['NONE']: 0, OT['FLAME']: 1, OT['POWERUP']: 1,
              OT['VANISH']: 0, OT['SWITCH']: 1}
def cellbox(t, x, y, e):
    """The collision grid cells an object of type t at tile (x, y) with extras e is listed
    in, as level_init computes them: (gx0, gx1, gy, gy1), BINPX cells of 8 tiles."""
    m0 = lambda v: max(v, 0)
    gx0, gx1, gy, gy1 = m0(x - 1) >> 3, x >> 3, y >> 3, (y + 1) >> 3
    if t == OT['STAR']: gy, gy1 = m0(y - 1) >> 3, y >> 3
    elif t == OT['TRAMP']: gx0, gx1, gy = m0(x - 2) >> 3, (x + 1) >> 3, (y + 1) >> 3; gy1 = gy
    elif t in (OT['SNAKE'], OT['MASK'], OT['MUMMY']): gx1 = (x + e[0]) >> 3
    elif t == OT['RSNAKE']: gy = m0(y - 4) >> 3
    elif t == OT['BAT']: gy, gx1, gy1 = m0(y - 1) >> 3, (x + e[0]) >> 3, (y + e[1]) >> 3
    elif t == OT['FLAME']: gy, gy1 = m0(y - 2) >> 3, y >> 3
    elif t == OT['VANISH']: gy1 = gy
    return gx0, gx1, gy, gy1

def place_sprites(lv, sub):
    """The level's sprites: which images and boxes, each one's bank and a first placement
    that fits (greedy, in the regions after the resident block).  Returns (the fill of each
    region, {item key: address}, {item key: bank}, the items (kind, j, size), the regions,
    the staged image indices).  Raises SystemExit when no order tried fits."""
    L = m.levels[(lv, sub)]
    name = m.name_of(lv, sub)
    cm = m.maps[(lv, sub)]
    types = sorted(set(t for (t, x, y, e) in L['objs']))
    ids = set(ALWAYS_IDS)
    for t in types:
        if t in m.TYPE_IDS:
            lo, hi = m.TYPE_IDS[t]
            ids |= set(range(lo, hi + 1))
    # (the powerup draws its baked box, never 97)
    ids.discard(m.PW_ID)
    # the images placed per level: the ids' less the resident ones
    imgs = sorted(set(m.entry[i][0] for i in ids if m.entry[i] is not None) - set(COMMON))
    # the box stars' art by each star's class (convert.py star_class: 1 on sky, the first six
    # boxes; 2 on black, the second six -- logic.s ob_star reads a star's first box id), not
    # by the set
    classes = set(m.star_class(cm, x, y) for (t, x, y, e) in L['objs'] if t == OT['STAR'])
    bxs = (list(range(0, NSTARF)) if 1 in classes else []) + (list(range(NSTARF, NBOXART)) if 2 in classes else [])
    # above the resident part, up to the map
    R5BASE = C5_BASE + C5_LEN
    # (r6 is bank 5's region: the name is historical)
    regions = {'r4': [COMMON_END, B4_DATA[1]], 'r6': [R5BASE, B5_DATA[1]]}
    mirrored = set(m.entry[i][0] for i in ids if m.entry[i] is not None and m.entry[i][1])
    items0 = [('img', j, len(m.img_bytes[j])) for j in imgs]
    items0 += [('box', k, len(m.box_bytes[k])) for k in bxs]
    CUR[0] = (lv, sub)
    _tr, _st, _by, _at = level_bakes(lv, sub)
    items0 += [(k[0], k[1], len(b)) for k, b in sorted(_by.items())]
    def canmirror(it):
        """True for an image item that some id draws mirrored."""
        return it[0] == 'img' and it[1] in mirrored
    def attempt(items, prefer4):
        """One greedy placement in this order, each item to the first region with room
        (bank 4 first with prefer4, else bank 5 first; either bank takes any image,
        mirrored or not); None if something does not fit."""
        fill = {r: 0 for r in regions}
        img_addr, img_bank = {}, {}
        def fits(key, r, n, bank):
            """Place key's n bytes in region r if it has room: True and noted, else False."""
            if regions[r][1] - regions[r][0] - fill[r] < n:
                return False
            img_addr[key] = regions[r][0] + fill[r]; fill[r] += n; img_bank[key] = bank
            return True
        for kind, j, n in items:
            key = (kind, j)
            ok = (fits(key, 'r4', n, 4) or fits(key, 'r6', n, 5)) if prefer4 else \
                 (fits(key, 'r6', n, 5) or fits(key, 'r4', n, 4))
            if not ok:
                return None
        return fill, img_addr, img_bank
    # the boxes and the mirrored images first, then the rest largest first; when that greedy
    # order leaves a hole too small, other orders of the rest, deterministically, until one
    # fits
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
    """The placed items reordered and padded within each region by sprpack for the loops,
    weighted by the level file's draws: (the addresses, the loops' cost before and after,
    cycles a frame).  Resident items are left where they are."""
    ws = weights(level)
    c0 = c1 = 0.0
    for r, (lo, hi) in regions.items():
        if hi <= lo:
            continue
        # a region is one bank's: the address alone can be the other bank's
        bank = 4 if r.endswith('4') else 5
        inr = lambda k, a: lo <= a < hi and img_bank[k] == bank
        keys_i = [k for k, a in img_addr.items() if inr(k, a) and (k[0], k[1]) not in RESIDENT]
        if not keys_i:
            continue
        addr, b, a_, end = sprpack.optimise(chunk_items(keys_i, ws), lo, hi, _cache)
        c0 += b; c1 += a_
        for k in keys_i: img_addr[k] = addr[('i',) + k]
    return img_addr, c0, c1

# ---------------------------------------------------------------- one level
# Cleo's fields in the level header (logic.s level_init; assets.inc HDR_*): the start and
# exit, in tiles, and the special tiles' ids (the vanishing blocks, the flowers)
HDR_STARTX, HDR_STARTY, HDR_EXITX, HDR_EXITY, HDR_SPECIAL = 2, 3, 4, 5, 8
# logic.s RNGTAB: in_range's limit quads (lo, hi, lo2, hi2, each + RQ_BIAS: rx > lo &&
# rx < hi && ry > lo2 && ry < hi2), every level's header tail -- the loader puts it at
# LV_HDR + HDR_LEN (logic.s asserts RNGTAB there), where in_range's hot reads need it.  Each
# quad's offset reaches logic.s as RQ_<name> (assets.inc), so a quad may be added anywhere;
# a guard band's boomerang quad follows its Cleo one (RQ_BOOMOFF: logic.s box_safe).
RQ_BIAS = 128
RQ_BOOMOFF = 4
# the room logic.s keeps for it
RNGTAB_LEN = 88
RNGTAB_QUADS = [
    # the collect
    ('STAR',        (-16, 16, -16, 20)),
    # the boomerang's on a star; and its catch
    ('BOOM_STAR',   (-8, 8, -8, 8)),
    ('TRAMP',       (-9, 17, 0, 8)),
    ('SNAKE',       (-16, 16, -24, 12)),
    # the boomerang's
    ('BOOM_SNAKE',  (-8, 8, -16, 4)),
    ('BOOM_RSNAKE', (-12, 12, -18, 2)),
    ('BOOM_BAT',    (-12, 12, -12, 12)),
    ('BAT_STOMP',   (-16, 16, -12, 16)),
    ('BAT',         (-12, 12, -128, 127)),
    ('BOOM_WALKER', (-10, 10, -16, 8)),
    # (+1: ob_spike sets the x limit by its height)
    ('SPIKE',       (-8, 0, -24, 8)),
    ('POWERUP',     (-16, 16, -24, 12)),
    ('VANISH',      (-16, 1, 15, 17)),
    ('SWITCH',      (-16, 16, -24, 12)),
    # The boomerang's hit bands (BOOM_*) are the original's: they are tested against the box
    # the boomerang crossed in its last move (logic.s bsweep), so it cannot fly through one
    # between frames.
    # Guard bands: not "close enough to collect" but "the drawn rectangles touch" this frame
    # -- where Cleo and the boomerang are when the objects run, grown by the most each moves
    # before it is drawn (the allowances used: Cleo 6 across and 14 up or down, the boomerang
    # 30 each way; a frame is two of the original's steps).
    # Cleo, then the boomerang
    ('GUARD_STAR',  (-29, 25, -29, 38)),
    ('GUARD_BSTAR', (-47, 46, -40, 45)),
    # trampoline guard bands (its box (-16..8, 8..16) grown by the disturber's box, which the
    # star bands imply is Cleo x(-15,13) y(-11,16), boomerang x(-9,10) y(-6,7), and by the
    # frame's move, as above)
    ('GUARD_TRAMP', (-29, 35, -41, 22)),
    ('GUARD_BTRAMP', (-47, 56, -52, 29)),
    # the health powerup's baked box (-6..6, 4..14) grown the same way
    ('GUARD_PW',    (-27, 25, -39, 26)),
    ('GUARD_BPW',   (-45, 46, -50, 33)),
    # the mask, the mummy and the red snake: written at run time (logic.s body_hit) from
    # the two frames drawn, so its values here are only its room.  (Last: the two quads
    # it replaced leave every guard band's offset where its pairing needs it.)
    ('BODY',        (0, 0, 0, 0)),
]
RQ = {n: 4 * i for i, (n, q) in enumerate(RNGTAB_QUADS)}
RNGTAB = bytes(v + RQ_BIAS for n, q in RNGTAB_QUADS for v in q)
assert all(RQ['GUARD_B' + g] == RQ['GUARD_' + g] + RQ_BOOMOFF for g in ('STAR', 'TRAMP', 'PW'))
assert len(RNGTAB) <= RNGTAB_LEN, 'RNGTAB has outgrown its memory (logic.s RNGTAB)'
def pack_level(lv, sub):
    """Write the level's file (L<lv*2+sub>) and return its statistics: the tiles (convert.py
    pack_tiles), the header's game fields, the objects with their extras filled in (box ids,
    reachability, star phases, disturbability), the tile tables, the sprite list bound
    (MAXSPR, BINMAX), the sprites' placement and the directory, through levelfile."""
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
    # HDR_SPECIAL's 12: the vanish run, then the flower run
    specials = [m.special['VANISH0'] + i for i in range(8)] + [m.special['FLOWER0'] + i for i in range(4)]

    # ---- tables: the header's game fields (the rest is the engine's: levelfile), as
    # logic.s level_init reads them (byte 7: always 1, no reader; kept so the files do not
    # change)
    ghdr = {HDR_STARTX: L['start'][0], HDR_STARTY: L['start'][1], HDR_EXITX: L['exit'][0],
            HDR_EXITY: L['exit'][1], 7: 1}
    for i, cid in enumerate(specials):
        ghdr[HDR_SPECIAL + i] = local.get(cid, 255)
    objs = []
    reach = m.enemy_reach(L['objs'])
    # a powerup's box is opaque: whatever can be drawn over it must be listed after it (the
    # walk's first cell, then each cell's chain, the later object first -- convert.py
    # parse_level puts the powerups last)
    for pi, (t, x, y, ex) in enumerate(L['objs']):
        if t != OT['POWERUP']:
            continue
        b0, b1, c0, c1 = 8 * x + PW_RECT[0], 8 * x + PW_RECT[1], 8 * y + PW_RECT[2], 8 * y + PW_RECT[3]
        pc = cellbox(OT['POWERUP'], x, y, [0, 0, 0])
        for qi, o in enumerate(L['objs']):
            if o[0] in (OT['STAR'], OT['POWERUP']) or not any(x0 < b1 and b0 < x1 and y0 < c1 and c0 < y1 for (x0, x1, y0, y1) in m.enemy_reach([o])):
                continue
            qc = cellbox(o[0], o[1], o[2], (list(o[3]) + [0, 0, 0])[:3])
            assert (qc[2], qc[0]) > (pc[2], pc[0]) or ((qc[2], qc[0]) == (pc[2], pc[0]) and qi < pi), \
                ('%s: an object listed before the powerup it can be drawn over' % name, o, (x, y))
    _tr, _st, _by, _at = level_bakes(lv, sub)
    # a red snake knocked flying sends its pot off sideways, up to a screen and more either
    # way (logic.s ob_rsnake @knocked): a trampoline at the pot's height within a screen
    # width of it is crossed, so it is disturbable too, as one on a walker's track is
    pb = m._SPRBOX[SPR['BASKET']]
    pot_reach = [(8 * x + pb[0] - WINPX, 8 * x + pb[1] + WINPX, 8 * y + pb[2], 8 * y + pb[3])
                 for (t, x, y, ex) in L['objs'] if t == OT['RSNAKE']]
    # the objects' extras: e0 a star's first box id (the sky's six, the black's, or its own
    # baked six; 0 for masked frames), a powerup's baked box id (logic.s ob_powerup), a
    # trampoline's rest box id (0: none); e1 whether an enemy's reach covers it
    for oi, (t, x, y, ex) in enumerate(L['objs']):
        e = (list(ex) + [0, 0, 0])[:3]
        if t == OT['STAR']:
            e[0] = m.star_class(cm, x, y)
            e[0] = {0: 0, 1: BOXID0, 2: BOXID0 + NSTARF}[e[0]]
            if oi in _st:
                e[0] = BOXID0 + NBOXART + TRMAX + NSTARF * _st[oi]
            e[1] = 1 if m.star_reachable(x, y, reach) else 0
        elif t == OT['POWERUP']:
            e[0] = BOXID0 + NBOXART + TRMAX + NSTARF * NSTAR + PWOF[(lv, sub)][oi]
            b = m.TYPE_BOX[OT['POWERUP']]
            selfbox = (8 * x + b[0], 8 * x + b[1], 8 * y + b[2], 8 * y + b[3])
            e[1] = 1 if m.box_reachable(PW_RECT, x, y, reach, skip=selfbox) else 0
        elif t == OT['TRAMP']:
            e[0] = BOXID0 + NBOXART + _tr[oi] if oi in _tr else 0
            b = m.TYPE_BOX[OT['TRAMP']]
            selfbox = (8 * x + b[0], 8 * x + b[1], 8 * y + b[2], 8 * y + b[3])
            e[1] = 1 if m.box_reachable(b, x, y, reach + pot_reach, skip=selfbox) else 0
        objs.append([t, x, y] + e)
    # The stars' phases (e2): a star's spin step is the level's star clock plus its phase
    # (logic.s ob_star), so the stars a screen shows at once can be spread across the spin
    # -- its frames run from 7 byte columns wide to 1 (edge on) -- and their drawing kept
    # level rather than all wide together.  Greedy, in map order: each star takes the phase
    # that makes the widest moment of it and the stars already placed within a screen's
    # reach narrowest (then the steadiest).
    def star_cols(x):
        """A star at tile x's byte columns at each of the spin's 12 steps (two a frame)."""
        cs = []
        for a_ in range(12):
            im_, rx_, ry_ = m.crops[SPR['STAR0'] + (a_ >> 1)]
            cs.append((((8 * x - rx_) & 1) + im_.shape[1] + 1) // 2)
        return cs
    # (x px, y px, cols, phase)
    placed = []
    for i in sorted((i for i, o in enumerate(objs) if o[0] == OT['STAR']), key=lambda i: (objs[i][1], objs[i][2])):
        x, y = objs[i][1], objs[i][2]
        cs = star_cols(x)
        near = [p_ for p_ in placed if abs(p_[0] - 8 * x) < 160 and abs(p_[1] - 8 * y) < 120]
        best = None
        for ph in range(12):
            tot = [cs[(t + ph) % 12] + sum(q[2][(t + q[3]) % 12] for q in near) for t in range(12)]
            score = (max(tot), sum(v * v for v in tot), ph)
            if best is None or score < best[0]:
                best = (score, ph)
        objs[i][5] = best[1]
        placed.append((8 * x, 8 * y, cs, best[1]))
    # a kept box must not be drawn over: any box-drawn object (a star or trampoline with a
    # box id) whose drawn area meets another static object's -- over every frame either can
    # show, a star's sparkle too -- is marked disturbable (e1), so it is redrawn every frame
    # (still a copy, never erased) rather than kept
    def area(t, x, y):
        """The pixel rectangle a static object of type t at tile (x, y) can draw over all its
        frames: the powerup its box; a star its spin and sparkle frames and its box field; a
        trampoline (standing at 8x + 4) its bounce frames and its rest box."""
        if t == OT['POWERUP']:
            return (8 * x + PW_RECT[0], 8 * x + PW_RECT[1], 8 * y + PW_RECT[2], 8 * y + PW_RECT[3])
        ids = range(SPR['STAR0'], SPR['TRAMP0']) if t == OT['STAR'] else range(SPR['TRAMP0'], SPR['TRAMP0'] + SPR_N['TRAMP0'])
        bs = [m._SPRBOX[i] for i in ids if i in m._SPRBOX]
        ox = 8 * x + (4 if t == OT['TRAMP'] else 0)
        r = (ox + min(b[0] for b in bs), ox + max(b[1] for b in bs), 8 * y + min(b[2] for b in bs), 8 * y + max(b[3] for b in bs))
        if t == OT['TRAMP']:
            bx = ox - m.TRAMP_HOT + 2 * m.TRAMP_REST_LO
            r = (min(r[0], bx), max(r[1], bx + 2 * m.TRAMP_REST_WC), min(r[2], 8 * y + 8), max(r[3], 8 * y + 8 + m.TRAMP_H))
        else:
            r = (min(r[0], 8 * x - 6), max(r[1], 8 * x + 8), min(r[2], 8 * y - 8), max(r[3], 8 * y + 4))
        return r
    stat = [(i, area(o[0], o[1], o[2])) for i, o in enumerate(objs) if o[0] in (OT['STAR'], OT['TRAMP'], OT['POWERUP'])]
    meet = lambda p, q: p[0] < q[1] and q[0] < p[1] and p[2] < q[3] and q[2] < p[3]
    for i, ri in stat:
        if objs[i][3] and any(j != i and meet(ri, rj) for j, rj in stat):
            objs[i][4] = 1
    objs = b''.join(bytes(o) for o in objs)
    # the tile tables by level id: the attribute (LV_ATTR0) and the altitude class
    # (LV_ALTCLS, 0 for a solid)
    attr = bytearray(256)
    acls = bytearray(256)
    for c in sorted(local):
        t = local[c]
        attr[t] = m.attr_of(c)
        acls[t] = 0 if c in m.tile_solid else m.alt_class[c]

    # ---- the sprite list's bounds: the objects whose cells the walk rectangle can cover
    # from any camera position
    boxes = []
    for (t, x, y, ex) in L['objs']:
        e = (list(ex) + [0, 0, 0])[:3]
        boxes.append((t, cellbox(t, x, y, e)))
    # (both machines' windows: one bound, so the tables it sizes lie alike on both)
    rects = set()
    for vl in VISLINES_ALL:
        maxwx, maxwy = w * 8 - WINPX, h * 8 - vl // 2
        for wx in range(0, maxwx + 1, 2):
            for wy in range(0, maxwy + 1):
                rects.add((wx // BINPX, (wx + WINPX - 1) // BINPX, wy // BINPX, (wy + vl // 2 - 1) // BINPX))
    MAXSPR, BINMAX = 0, 0
    for (rx0, rx1, ry0, ry1) in rects:
        hit = [t for (t, (gx0, gx1, gy, gy1)) in boxes if gx0 <= rx1 and gx1 >= rx0 and gy <= ry1 and gy1 >= ry0]
        # (+ Cleo and the boomerang)
        MAXSPR = max(MAXSPR, sum(SPRITES_OF[t] for t in hit) + 2)
        BINMAX = max(BINMAX, sum(1 for t in hit if t == OT['STAR']), sum(1 for t in hit if t != OT['STAR']))

    # ---- sprites: which images, and where each goes (place_sprites), then where in each
    # region: the order and padding that cost the sprite loops least (sprpack)
    fill, img_addr, img_bank, items0, regions, imgs = place_sprites(lv, sub)
    img_addr, cost0, cost1 = settle_level(lv * 2 + sub, img_addr, img_bank, regions)
    # a baked item's tile (x, y) rides in its placement entry's extra field (ldprog.s bake)
    BAKEAT[(lv, sub)] = {k: (img_bank[k], img_addr[k]) for k in _by}
    placement = lf.placement([(item_index(kind, j), img_bank[(kind, j)], a,
                               _at[(kind, j)][0] | _at[(kind, j)][1] << 8 if kind in BAKED else 0)
                              for (kind, j), a in sorted(img_addr.items(), key=lambda kv: item_index(*kv[0]))])
    # (the resident block, for the directory)
    for j in COMMON:
        img_addr[('img', j)] = common_addr[j]; img_bank[('img', j)] = common_bank[j]
    # the directory's level part: each id's placed image, its address and bank (the geometry
    # is the game's, sprgeom.inc, below)
    byitem = {item_index(*k): k for k in img_addr}
    entries = []
    for i in range(NDIR):
        t = sprdir[i * 8:i * 8 + 8]
        k = byitem.get(t[0]) if t[0] != 0xFF else None
        entries.append(None if k is None else (img_addr[k], img_bank[k]))
    directory = lf.directory(entries)

    # ---- the file (beebgame's levelfile: the engine's format)
    data = lf.encode(lf.Level(lw=L['lw'], lh=L['lh'], game_header=ghdr, shape=lf.Shape(**T['B']['shape']),
                              objects=bytes(objs), tile_tables=(bytes(attr), bytes(acls)),
                              tiles=T['B']['tiles'], placement=placement, map=mapb, flat=T['flat'],
                              halves=T['halves'], hpair=T['hpair'], mir=T['B']['mir'],
                              directory=directory, page0=T['B']['page0'], header_tail=RNGTAB,
                              boxid0=BOXID0, boxn=BOXN))
    back = lf.decode(data, BOXID0, BOXN)
    assert back['map'] == mapb and back['objs'] == bytes(objs) and back['dir'] == directory
    # (for the report)
    maprle = lf.rle(mapb)
    out('L%d' % (lv * 2 + sub), data)
    stats = dict(name=name, ntiles=T['ntiles'], nflat=T['nflat'], nhalf=T['nhalf'], w=w, h=h, nobj=len(L['objs']),
                 nimg=len(imgs), r4=fill['r4'], r6=fill['r6'],
                 maxspr=MAXSPR, binmax=BINMAX, maprle=len(maprle), size=len(data), cost0=cost0, cost1=cost1)
    return stats

# ---- the resident block, placed for the loops too: it may pad into the room the fullest
# level leaves in each bank (the levels' first fit, before it moves)
RESIDENT = set(('img', j) for j in COMMON)
if STARPLAN:
    # Which stars: the ones that save the most vsyncs a byte of bank.  The plan has every
    # frame that missed its peg (3 vsyncs of V usable cycles) with a masked star in it; a
    # frame's vsyncs are ceil(work / V), no fewer than the peg's, so a star saves something
    # only where taking its cycles out crosses a multiple of V -- summed over every frame it
    # is drawn in, a bonus level's (a small map: 32 x 32 tiles or less, played far less
    # often) at a quarter.  Greedy: the best star a byte of bank, its frames updated, the
    # next; each within its level's slots and its banks (the placement must still fit).
    # (The loader bakes them: nothing on the disc.)
    played = lambda lv, sub: 0.25 if m.maps[(lv, sub)].size <= 32 * 32 else 1.0
    # (lv, sub) -> (V, [[work, {(x, y): the star's cycles}] a frame])
    frames = {}
    for lv in range(8):
        for sub in (0, 1):
            P = STARPLAN.get(str(lv * 2 + sub))
            if P:
                frames[(lv, sub)] = (P['V'], [[w, {(x, y): c for x, y, c in st}] for w, st in P['frames']])
    vs = lambda w, V: max(3, -(-w // V))
    def gain(key, xy):
        """The vsyncs baking star xy of level key saves over the plan's frames, weighted by
        how often the level is played."""
        V, fl = frames[key]
        return sum(vs(w, V) - vs(w - st[xy], V) for w, st in fl if xy in st) * played(*key)
    cand = {(key, xy) for key, (V, fl) in frames.items() for w, st in fl for xy in st
            if m.star_class(m.maps[key], *xy) == 0 and m.bake_star(m.maps[key], *xy) is not None}
    size = lambda key, xy: sum(len(b) for b in m.bake_star(m.maps[key], *xy))
    SAVED = [0.0]
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
        SAVED[0] += gain(key, xy) / played(*key)
        for f in fl:
            if xy in f[1]:
                f[0] -= f[1].pop(xy)
    print('stars chosen (the plan\'s frames: %d vsyncs SAVED): %s' % (SAVED[0], ', '.join('L%d: %d' % (k[0] * 2 + k[1], len(v)) for k, v in sorted(CHOSEN.items()) if v)))
# the room the fullest level leaves in each bank's region
_spare4 = _spare5 = 0x10000
for lv in range(8):
    for sub in (0, 1):
        fill, *_rest, regions, _i = place_sprites(lv, sub)
        _spare4 = min(_spare4, regions['r4'][1] - regions['r4'][0] - fill['r4'])
        _spare5 = min(_spare5, regions['r6'][1] - regions['r6'][0] - fill['r6'])
_wr = weights(None)
def _resident(keys_i, lo, budget):
    """Place the resident items keys_i from lo with up to budget bytes of padding, by
    sprpack with the mean weights: ({sprpack key: address}, the block's bytes, the loops'
    cost before and after)."""
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
        print('%-4s %3d tiles +%2d half +%d flat map %3dx%2d rle %5d  %3d obj %2d img  '
              'b4 %5d  b5 %5d  spr %2d bin %2d  file %5d  loops %.1f -> %.1f'
              % (s['name'], s['ntiles'], s['nhalf'], s['nflat'], s['w'], s['h'], s['maprle'], s['nobj'], s['nimg'],
                 s['r4'], s['r6'], s['maxspr'], s['binmax'], s['size'], s['cost0'], s['cost1']))
sprpack.save_cache(_cache, SPRPACK_CACHE)

MAXSPR = max(s['maxspr'] for s in allstats)
BINMAX = max(s['binmax'] for s in allstats)
with open(os.path.join(OUT, 'assets.inc'), 'w') as f:
    f.write('; generated by tools/assets.py: the bounds every level fits\n')
    f.write('FLAT0 = %d\nNFLAT = %d\n' % (m.FLAT0, m.NFLAT))
    f.write('BOXID0 = %d\nBOXN = %d\n' % (BOXID0, BOXN))
    # the geometry carries flags by shape (frame.s .ifdef SPRGFL)
    f.write('SPRGFL = 1\n')
    # the items the loader bakes (ldprog.s bake)
    f.write('BAKEITEM0 = %d\n' % BAKEITEM0)
    f.write('SPRC_BASE = $%04X\nSPRC_LEN = %d\nSPRC5_BASE = $%04X\nSPRC5_LEN = %d\nSPRX_LEN = %d\n'
            % (B4_DATA[0], len(sprc4), C5_BASE, len(sprc5), len(sprx)))
    # id k's tile slot is k + TOFF (convert.py)
    f.write('TOFF = %d\n' % m.TOFF)
    # MIRTAB's length (TILEMIRROR: the most mirrored tiles a level has, convert.py)
    f.write('MAXMIR = %d\n' % m.MAXMIR)
    # the title pieces (convert.py pieces, in order)
    f.write('TP_LOGO = 0\nTP_YOU = 1\nTP_WIN = 2\nTP_LOSE = 3\nTP_CLEO0 = 4\n')
    # the largest piece, unpacked (menu.s)
    f.write('TBUF_LEN = %d\n' % max(len(p[3]) for p in m.title_pieces))
    f.write('MAXSPRDEF = %d\nBINMAXDEF = %d\n' % (MAXSPR, BINMAX))
    f.write('MAP5 = $%04X\n' % MAP5)
    f.write('B4_CODE_END = $%04X\nB5_CODE_END = $%04X\n' % (B4_CODE_END, B5_CODE_END))
    # the expansion tables (defs.inc L0TAB); bank 6's tiles (convert.py B_TILES)
    f.write('B4_DATA_END = $%04X\n' % B4_DATA_END)
    f.write('TILES = $%04X\n' % TILES_BASE)
    f.write('IMGTAB_LEN = %d\n' % IMGTAB_LEN)
    f.write('%s\n' % '\n'.join('BG_%s = %d' % kv for kv in (('WC', BG_WC), ('LINES', BG_LINES), ('DX', BG_DX),
                                                          ('DTY', BG_DTY), ('OV', BG_OV), ('SKIP', BG_SKIP), ('LEN', BG_LEN))))
    # the game's: its header fields, in_range's quads, the object types, the sprite ids
    f.write('HDR_STARTX = %d\nHDR_STARTY = %d\nHDR_EXITX = %d\nHDR_EXITY = %d\nHDR_SPECIAL = %d\n'
            % (HDR_STARTX, HDR_STARTY, HDR_EXITX, HDR_EXITY, HDR_SPECIAL))
    f.write('RNGTAB_LEN = %d\nRQ_BIAS = %d\nRQ_BOOMOFF = %d\n' % (RNGTAB_LEN, RQ_BIAS, RQ_BOOMOFF))
    f.write('%s\n' % '\n'.join('RQ_%s = %d' % (n, o) for n, o in RQ.items()))
    # the star guard's x limits (logic.s po_star)
    f.write('STARBAND_LO = %d\nSTARBAND_HI = %d\n' % dict(RNGTAB_QUADS)['GUARD_STAR'][:2])
    f.write('%s\n' % '\n'.join('OT_%s = %d' % kv for kv in OT.items()))
    f.write('%s\n' % '\n'.join('SPR_%s = %d' % (n, a) for n, a, c in m.SPR_IDS))
    # SPR_<name>_N: an animation's frame count, for the names ending in 0 with more than one
    f.write('%s\n' % '\n'.join('SPR_%s_N = %d' % (n[:-1], c) for n, a, c in m.SPR_IDS if c > 1 and n.endswith('0')))
    # the collision grid's cell (logic.s)
    f.write('BINPX = %d\n' % BINPX)
    # the HUD (convert.py: the bar's icons sit by them) and its digits (_digits above); the
    # menus' run-length code (convert.py title_rle); the font's glyphs (convert.py font)
    f.write('HUD_X_LIVES = %d\nHUD_X_HEALTH = %d\nHUD_X_STARS = %d\nHUD_X_SCORE = %d\n'
            % (m.HUD_X_LIVES, m.HUD_X_HEALTH, m.HUD_X_STARS, m.HUD_X_SCORE))
    f.write('DIGIT_W = 8\nDIGIT_PACKED = 16\n')
    f.write('RLE_RUN = $%02X\nRLE_RUNBIAS = $%02X\nRLE_END = $%02X\n' % (m.RLE_RUN, m.RLE_RUNBIAS, m.RLE_END))
    f.write('GLYPHW = 8\nGLYPHH = 8\n')
print('MAXSPR %d BINMAX %d; img_tab %d entries' % (MAXSPR, BINMAX, len(img_tab) // 5))
# the engine's L0TAB, L1TAB, NMASK (banks.s)
out('nibtab.bin', m.NIBTAB)
# the baker's tables (ldprog.s)
out('bake_geom.bin', bytes(bake_geom))
out('bake_kind.bin', bake_kind)
# test/bakecheck.mjs: what the loader must make, per level file: [kind, slot, tile, (bank,
# address), bytes]
json.dump({'%d' % (lv * 2 + sub): [[k[0], k[1], list(_bk[3][k]), list(BAKEAT[(lv, sub)][k]), list(_bk[2][k])] for k in sorted(_bk[2])]
           for lv in range(8) for sub in (0, 1) for _bk in [level_bakes(lv, sub)]},
          open(os.path.join(OUT, 'bakes.json'), 'w'))
print('baked by the loader: trampolines %d, stars %d' % (
      sum(len(level_bakes(lv, sub)[0]) for lv in range(8) for sub in (0, 1)),
      sum(len(level_bakes(lv, sub)[1]) for lv in range(8) for sub in (0, 1))))
# the geometry every level shares, by shape (the directory's game part: sprgeom.inc, read by
# frame.s draw_sprite): sprg_ix maps an id to its shape, the sprg_* tables a shape to W,
# refx, refy, lines and flags
shapes, six = [], []
for i in range(NDIR):
    t = sprdir[i * 8:i * 8 + 8]
    g = (t[2], t[4], t[5], t[7], t[6]) if t[0] != 0xFF else None
    if g is None:
        six.append(0); continue
    if g not in shapes:
        shapes.append(g)
    six.append(shapes.index(g))
assert len(shapes) <= 256
with open(os.path.join(OUT, 'sprgeom.inc'), 'w') as f:
    f.write('; generated by tools/assets.py: the sprites\' geometry by shape\n')
    f.write('sprg_ix: .byte %s\n' % ', '.join(map(str, six)))
    for name, k in (('sprg_w', 0), ('sprg_rx', 1), ('sprg_ry', 2), ('sprg_ln', 3), ('sprg_fl', 4)):
        f.write('%s: .byte %s\n' % (name, ', '.join(str(sh[k]) for sh in shapes)))
print('sprite geometry: %d ids, %d shapes: %d bytes of geometry' % (NDIR, len(shapes), NDIR + 5 * len(shapes)))
