#!/usr/bin/env python3
"""Convert Cleo's J2ME assets (assets/v500: CleoV500.jar's contents) into BBC MODE 1 data.

Not run on its own: tools/assets.py imports it (build.sh runs that from beeb/, once per
machine) and tools/tileids.py, tools/hotmap.py and tools/tile_editor.py import it for its
tables.  Importing runs the whole conversion.  From the jar's files -- the level files 0..7,
til.png and alt (the tiles and their collision data), spr.png and dim (the sprites and their
frames), bar.png (the status bar and digits), tit.png (the title art and the font) -- it
builds, as module globals:

  levels, maps          the 16 maps parsed (parse_level) and as compact tile ids
  compact, tiles_bytes, tile_preview, tile_solid, alt_class, attr_of, TSET, pack_tiles
                        the tile set, each tile's 64 bank bytes, and a level's tile layout
  images, entry, img_bytes, img_wbytes, img_shift, crops, _SPRBOX, TYPE_BOX, enemy_reach,
  star_reachable, box_reachable
                        the sprites as 4-bit images, each id's image and reference point,
                        and the reach tests the packer decides the box sprites by
  box_bytes, box_geom, BAKE_KINDS, bake_box, bake_tramp_rest, bake_star, bake_powerup
                        the box stars on sky and black, and the baked boxes
  NIBTAB                the 4-bit sprites' expansion tables (L0TAB, L1TAB, NMASK)
  barbytes, digits, font, HUD_X_*, title_pieces, title_streams, RLE_*
                        the bar template, the HUD digits, the font, the title pieces
  OT, SPR, SPR_N, SPR_IDS, altfile, special, FLAT0, NFLAT, TOFF, B_TILES, B_TILES_END ...
                        the constants the packer writes into assets.inc

It writes, in build/: TILES0-2, the tile set as three files (outdoor, shared, indoor), and
preview_*.png and meta.json for looking at the dither.  NFLAT in the environment sets the
flat tiles a level may have (build.sh).  tile_edits.json beside tools/, if present, holds
hand-painted tiles (tools/tile_editor.py) that replace the dither.
"""
import struct, sys, os, json
from PIL import Image
import numpy as np

SRC = os.path.join(os.path.dirname(__file__), '..', 'assets', 'v500')
OUT = os.path.join(os.path.dirname(__file__), '..', 'build')
os.makedirs(OUT, exist_ok=True)

# the BBC's eight colours by logical number: bit 0 red, bit 1 green, bit 2 blue
BEEB_RGB = np.array([[0, 0, 0], [255, 0, 0], [0, 255, 0], [255, 255, 0],
                     [0, 0, 255], [255, 0, 255], [0, 255, 255], [255, 255, 255]], dtype=np.uint8)


def load_indexed(name):
    """A palette PNG from the jar: (the index array, the palette as (n, 3) uint8, the
    transparent index or None)."""
    im = Image.open(os.path.join(SRC, name))
    pal = im.getpalette()
    tr = im.info.get('transparency', None)
    idx = np.array(im)
    rgb = np.array(pal, dtype=np.uint8).reshape(-1, 3)
    return idx, rgb, tr

# ---------------------------------------------------------------------------
# The dither.
# a compromise: thresholding in sRGB is too bright, in linear light too dark
GAMMA = 1.35

# MODE 1: 80 bytes a row, four dots a byte in four colours, so a byte is 2 game pixels and a
# game pixel is a 2x2 block of dots, each one of C, M, Y or K (logical colours 1, 2, 3, 0 --
# the palette the game sets).  The 2x2 kernel IS the pixel: per pixel the mix of inks nearest
# its colour is chosen, then laid in kernel order.  A "col" entry is one game pixel on one
# scanline: (left dot << 2) | right dot, so 0 is black.  A sprite's transparency is its own
# (the 4-bit sprites' nibble 0, below); the box stars and trampolines are opaque boxes,
# drawn by the copy blitter.
# the inks' colours in K C M Y order
_CMYK_RGB = np.array([[0, 0, 0], [0, 1, 1], [1, 0, 1], [1, 1, 0]], np.float32)
def _cmyk_tables():
    """For n = 4 and n = 2 dots: every mix (k, c, m, y) summing to n, as (its mean colour,
    (count, 3) float, and its dots in kernel order, (count, n) uint8: the C dots, then M,
    then Y, then K)."""
    res = {}
    for n in (4, 2):
        cs = [(k, c, m, n - k - c - m) for k in range(n + 1) for c in range(n + 1 - k)
              for m in range(n + 1 - k - c)]
        rgb = np.array([(m + y, c + y, c + m) for k, c, m, y in cs], np.float32) / n
        seq = np.array([[1] * c + [2] * m + [3] * y + [0] * k for k, c, m, y in cs], np.uint8)
        res[n] = (rgb, seq)
    return res
_CMYK = _cmyk_tables()


def dither(rgb_img, alpha, x0=0, y0=0, full=True):
    """Dither an (h, w, 3) uint8 image to col entries: (2h, w) with full (both scanlines of
    every game pixel), else (h, w) -- one scanline a pixel, row y showing the top or bottom
    half of its pattern by the parity of y + y0.  Transparent pixels (alpha False) come out
    0.  x0 is unused.  Always the 4-dot mixes: a 2-dot pick would send skin to M+Y (pink) on
    the bar's Cleo and the title pieces."""
    h, w, _ = rgb_img.shape
    v = (rgb_img.astype(np.float32) / 255.0) ** GAMMA
    crgb, seq = _CMYK[4]
    d = ((v[:, :, None, :] - crgb[None, None, :, :]) ** 2).sum(axis=3)
    dots = seq[d.argmin(axis=2)]
    # kernel positions 0 top left, 1 bottom right, 2 top right, 3 bottom left: two inks of
    # two make a checker, not stripes
    l0 = (dots[:, :, 0] << 2) | dots[:, :, 2]
    l1 = (dots[:, :, 3] << 2) | dots[:, :, 1]
    if full:
        col = np.empty((2 * h, w), np.uint8)
        col[0::2] = l0
        col[1::2] = l1
        alpha = np.repeat(alpha, 2, axis=0)
    else:
        yy = ((np.arange(h) + y0) & 1)[:, None]
        col = np.where(yy == 0, l0, l1).astype(np.uint8)
    return np.where(alpha, col, 0).astype(np.uint8)


def packcol(col):
    """col: (lines, w) col entries, w even.  Returns (lines, w // 2) MODE 1 screen bytes:
    dot i of the four has its colour's bit 1 in bit 7 - i and bit 0 in bit 3 - i."""
    lines, w = col.shape
    assert w % 2 == 0
    a = col[:, 0::2].astype(np.uint16)
    b = col[:, 1::2].astype(np.uint16)
    dots = (a >> 2, a & 3, b >> 2, b & 3)
    out = np.zeros(a.shape, np.uint16)
    for i, d in enumerate(dots):
        out |= (((d >> 1) & 1) << (7 - i)) | ((d & 1) << (3 - i))
    return out.astype(np.uint8)


# a col entry of two cyan dots
CYAN_COL = 5
# a col entry of forced black
OPAQUE_BLACK = 0



def encode_sprite(col, packed, blanks=True):
    """The sprite bytes as the blitters want them: every bit is a pixel, so the packed bytes
    go as they are.  col and blanks are unused (the signature is the old tagged encoding's;
    the blank_runs and cells counters below stay 0)."""
    return packed


encode_sprite.blank_runs = 0
encode_sprite.cells = 0


def col_to_rgb(col):
    """Col entries as RGB for the previews: the mean of the entry's two dots."""
    c = _CMYK_RGB[col >> 2] + _CMYK_RGB[col & 3]
    return (c * 127.5).astype(np.uint8)


# ----------------------------------------------------------------------------
# Tiles
# ----------------------------------------------------------------------------
# where each level file's main map (sub 0) starts; its bonus map (sub 1) is at the start
LEVELSKIP = [2115, 2119, 2108, 2129, 2104, 2128, 2118, 2134]


def parse_level(lv, sub):
    """One map from level file lv (0..7): sub 1 the bonus map at the file's start, sub 0 the
    main map at LEVELSKIP[lv].  The map is log2 width, log2 height, then big-endian int16
    tile ids row major (-1 empty); then the start and exit tiles, the object count and the
    objects: type, x, y and the type's extra bytes (one for types 2, 5, 6: the patrol
    range; two for 4, the bat's hover box; three for 12, the switch).  Returns dict(lw, lh,
    w, h, map, start, exit, objs), objs a list of (type, x, y, [extra])."""
    d = open(os.path.join(SRC, str(lv)), 'rb').read()
    p = 0 if sub == 1 else LEVELSKIP[lv]
    lw, lh = d[p], d[p + 1]; p += 2
    w, h = 1 << lw, 1 << lh
    n = w * h
    m = np.array(struct.unpack('>%dh' % n, d[p:p + 2 * n]), dtype=np.int32).reshape(h, w); p += 2 * n
    sx, sy, ex, ey = d[p:p + 4]; p += 4
    nobj = d[p]; p += 1
    objs = []
    for i in range(nobj):
        t, x, y = d[p:p + 3]; p += 3
        extra = []
        if t in (2, 5, 6):
            extra = [d[p]]; p += 1
        elif t == 4:
            extra = list(d[p:p + 2]); p += 2
        elif t == 12:
            extra = list(d[p:p + 3]); p += 3
        objs.append((t, x, y, extra))
    # the health powerups (type 10) last: level_init chains each grid cell's objects head
    # first, so they are walked, and drawn, first in their cell -- under anything that
    # passes, as their opaque baked boxes must be (assets.py checks it).  They draw no
    # random number in level_init, so the rest keep theirs.
    objs = [o for o in objs if o[0] != 10] + [o for o in objs if o[0] == 10]
    return dict(lw=lw, lh=lh, w=w, h=h, map=m, start=(sx, sy), exit=(ex, ey), objs=objs)


# The game's order of the original's maps: (level, sub) -> the source level it takes.
# Levels 1 and 5, the first and third large indoor maps, are swapped (their bonus maps, the
# subs 1, stay); menu.s's level names and starbake.json's plans follow the maps.
LEVEL_SOURCE = {(1, 0): 5, (5, 0): 1}
levels = {}
used = set()
for lv in range(8):
    for sub in (0, 1):
        L = parse_level(LEVEL_SOURCE.get((lv, sub), lv), sub)
        levels[(lv, sub)] = L
        used |= set(int(t) for t in np.unique(L['map']))
# the vanishing block's animation, and the flower's random variants: drawn though no map
# names them all
used |= set(range(366, 374))
used |= set(range(426, 430))
used.discard(-1)
# the compact ids: the original tile ids in use, in order
compact = sorted(used)
orig2compact = {t: i for i, t in enumerate(compact)}
print('compact tiles:', len(compact))

til_idx, til_rgb0, _ = load_indexed('til.png')

# ----------------------------------------------------------------------------
# Tile source-colour overrides, keyed by the source RGB in til.png:
#   TIL_SOLID   source colour -> a BBC colour (0 blk 1 red 2 grn 3 yel 4 blu 5 mag 6 cyn
#               7 wht): the colour is replaced before the dither, which then lays it solid
#   TIL_NOBLACK source colour -> the colour that replaces 8 in its dither (meant to kill
#               black speckle in wall and ground textures; the table is empty)
#   TIL_RECOLOR source colour -> a new source colour, still dithered: a hand-tune of the
#               palette before the dither picks its inks
#   TIL_PATTERN source colour -> fn(x, line): a hand-laid pattern in place of the dither
#               (the table is empty)
# Edit these tables to tune the look.
# ----------------------------------------------------------------------------
TIL_SOLID = {
    # sky -> cyan
    (136, 238, 255): 6,
}
TIL_NOBLACK = {
    # example: (85, 68, 68): 3 -- this wall brown's black dither -> yellow
}
TIL_RECOLOR = {
    # dark (left) dune sand: halfway up to the light (255, 204, 85) face, so the shadow side
    # is brighter
    (187, 119, 51): (221, 162, 68),
}
til_rgb = til_rgb0.copy()
# hand-painted tiles from tools/tile_editor.py: {original tile id: (16, 8) col array}, in
# place of the automatic dither
TILE_EDITS = {}
_edits_path = os.path.join(os.path.dirname(__file__), '..', 'tile_edits.json')
if os.path.exists(_edits_path):
    TILE_EDITS = {int(k): np.array(v, np.uint8) for k, v in json.load(open(_edits_path)).items()}
TIL_PATTERN = {}
# palette index -> replacement colour (TIL_NOBLACK), and -> pattern function (TIL_PATTERN)
noblack_idx = {}
pattern_idx = {}
for _i, _c in enumerate(til_rgb0):
    _t = tuple(int(v) for v in _c)
    if _t in TIL_SOLID:
        til_rgb[_i] = BEEB_RGB[TIL_SOLID[_t]]
    elif _t in TIL_RECOLOR:
        til_rgb[_i] = np.array(TIL_RECOLOR[_t], np.uint8)
    if _t in TIL_NOBLACK:
        noblack_idx[_i] = TIL_NOBLACK[_t]
    if _t in TIL_PATTERN:
        pattern_idx[_i] = TIL_PATTERN[_t]

# each compact tile dithered: (16, 8) col entries (the source tile is 8 x 8 game pixels, a
# strip of til.png)
tile_preview = []
for cid, orig in enumerate(compact):
    sidx = til_idx[orig * 8:orig * 8 + 8, :]
    img = til_rgb[sidx]
    col = dither(img, np.ones((8, 8), bool), full=True)
    if noblack_idx:
        # col entries equal to 8 under a flagged source colour take its replacement (8 is a
        # magenta/black pair, not black, which is 0: the table being empty, this is unused)
        nb = np.full(sidx.shape, -1, np.int32)
        for _pi, _rc in noblack_idx.items():
            nb[sidx == _pi] = _rc
        nb16 = np.repeat(nb, 2, axis=0)
        col = np.where((col == 8) & (nb16 >= 0), nb16.astype(col.dtype), col)
    for _pi, _fn in pattern_idx.items():
        for yy, xx in zip(*np.nonzero(sidx == _pi)):
            col[2 * yy, xx] = _fn(int(xx), 2 * int(yy))
            col[2 * yy + 1, xx] = _fn(int(xx), 2 * int(yy) + 1)
    if orig in TILE_EDITS:
        col = TILE_EDITS[orig]
    tile_preview.append(col)

# ----------------------------------------------------------------------------
# Background blackening.  The dark dithery backdrops of the tombs (and a few outdoor walls)
# become solid black: it looks better than the noise, it makes most of those tiles the one
# solid black (a fill, no bytes in the bank), and it lets the star boxes be composited on
# black.
#
# What counts as background comes from the collision data, not from taste:
# alt[tile*8 + col] >> 4 is the surface row of that pixel column (8 = no ground), so
# everything above the surface is backdrop.  A tile's backdrop is blackened when at least
# DARK_BG of its backdrop pixels come from 'wall-ish' source colours (near-black, or dark
# and desaturated); palm trunks, foliage and the like are saturated and survive.
# PIXEL_TILES are art on a wall backdrop (the EXIT letters, the flower) and are cleaned
# pixel by pixel instead; WALL_TILES are blackened whatever the fraction.
# ----------------------------------------------------------------------------
DARK_BG = 0.8
alt = open(os.path.join(SRC, 'alt'), 'rb').read()

def bg_mask(orig):
    """The backdrop of original tile orig as a (16, 8) bool mask: each column's scanlines
    above its surface row (alt's high nibble, 8 = none, so the whole column)."""
    m = np.zeros((16, 8), bool)
    for c in range(8):
        hi = alt[orig * 8 + c] >> 4
        m[:min(hi, 8) * 2, c] = True
    return m

def _wallish(rgb):
    """True for a near-black colour (max channel <= 40) or a dark desaturated one (saturation
    <= 0.4 and max channel <= 140)."""
    r, g, b = (int(v) for v in rgb)
    mx, mn = max(r, g, b), min(r, g, b)
    sat = 0 if mx == 0 else (mx - mn) / mx
    return mx <= 40 or (sat <= 0.4 and mx <= 140)

wall_pal = np.array([_wallish(c) for c in til_rgb0])
# speckle families with bright highlight dots: every colour in these tiles counts as wall
for _o in (70, 71, 102):
    for _v in np.unique(til_idx[_o * 8:_o * 8 + 8, :]):
        wall_pal[int(_v)] = True
# the EXIT letters; the flower's head and stem; the scaffold braces' tips (6 brown px on
# near-black)
PIXEL_TILES = {32, 33, 402, 403, 434, 435,
               239, 374}
# a lone floating block the colour rule misses
WALL_TILES = {297}

# compact id -> the tile's image with its backdrop black
blackened = {}
for cid, orig in enumerate(compact):
    col = tile_preview[cid]
    bg = bg_mask(orig)
    if not bg.any() or np.all(col == 0):
        continue
    src = til_idx[orig * 8:orig * 8 + 8, :]
    frac = float(np.mean(wall_pal[src][bg[::2]]))
    rep = col.copy()
    if orig in PIXEL_TILES:
        rep[bg & np.repeat(wall_pal[src], 2, axis=0)] = OPAQUE_BLACK
    elif frac >= DARK_BG or orig in WALL_TILES:
        rep[bg] = OPAQUE_BLACK
    else:
        continue
    blackened[cid] = rep

# A ramp's foot: the original filled the cell under a ramp's last step, boxed in by solid
# tiles, with backdrop speckle.  It showed the backdrop through there as everywhere; with
# the backdrops black that cell would be a black notch in the ramp, and its own speckle,
# brighter than the ramp's body, dithers magenta-heavy (the palette has no neutral or brown
# pairs) beside the body's black-and-yellow.  So the cell takes a rock image: a plain-rock
# tile beside it (RAMP_ROCK: left, right, then above); else what the original puts where
# the same eight neighbours occur elsewhere (a slope tile beside it would bring the slope's
# edge); else an adjacent foot's.  It goes in a twin compact tile with the foot's own
# collision -- nothing about the level changes but the look.  Only cells that blacken to
# all black count: a scaffold brace's tip keeps its pixels (PIXEL_TILES) and is not a foot.
# (Small enclosed black patches -- a frame's inside, a bracket's triangle -- are not given
# their speckle back: they are backdrop, and black.)
# the ramp body's plain rock (498 and 503 carry the slope's edge)
RAMP_ROCK = {497, 504}
def _solid(orig):
    """True if any column of original tile orig has a surface (alt's high nibble below 8)."""
    return any((alt[orig * 8 + c] >> 4) < 8 for c in range(8))

_NB8 = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
def _same_place(m, y, x, feet):
    """The tile the original puts, in any map, at a cell whose eight neighbours are this
    one's (its fellow feet match anything); the most used if several, None if nowhere."""
    pat = [None if (y + dy, x + dx) in feet else int(m[y + dy, x + dx]) for dy, dx in _NB8]
    found = {}
    for L2 in levels.values():
        mm = L2['map']; h2, w2 = mm.shape
        for yy in range(1, h2 - 1):
            for xx in range(1, w2 - 1):
                if all(p is None or int(mm[yy + dy, xx + dx]) == p for p, (dy, dx) in zip(pat, _NB8)):
                    t = int(mm[yy, xx])
                    # a real tile, not another foot
                    if orig2compact[t] not in blackened:
                        found[t] = found.get(t, 0) + 1
    return max(sorted(found), key=lambda t: found[t]) if found else None

# (lv, sub) -> {(y, x): (the cell's original tile, its donor's)}
foot_cells = {}
# (orig, donor) -> the compact id of the twin
twin_of = {}
for (lv, sub), L in levels.items():
    m = L['map']
    h, w = m.shape
    # a foot is a patch of up to four such cells (a ramp's last steps can leave two or
    # three), each with solid tiles or the patch below, left and right of it
    cand = set()
    for y in range(1, h - 1):
        for x in range(1, w - 1):
            o = int(m[y, x])
            if o >= 0 and orig2compact[o] in blackened and not _solid(o) \
                    and o not in PIXEL_TILES and np.all(blackened[orig2compact[o]] == 0):
                cand.add((y, x))
    feet, seen = [], set()
    for c in sorted(cand):
        if c in seen:
            continue
        comp, stack = [], [c]; seen.add(c)
        while stack:
            cy, cx = stack.pop(); comp.append((cy, cx))
            for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
                n = (cy + dy, cx + dx)
                if n in cand and n not in seen:
                    seen.add(n); stack.append(n)
        if len(comp) <= 4 and all(
                all((ny, nx) in comp or (int(m[ny, nx]) >= 0 and _solid(int(m[ny, nx])))
                    for ny, nx in ((cy + 1, cx), (cy, cx - 1), (cy, cx + 1)))
                for cy, cx in comp):
            feet += comp
    donor = {}
    # plain rock beside it
    for (y, x) in feet:
        for dy, dx in ((0, -1), (0, 1), (-1, 0)):
            if int(m[y + dy, x + dx]) in RAMP_ROCK:
                donor[(y, x)] = int(m[y + dy, x + dx]); break
    # what the original does in the same place
    for (y, x) in feet:
        if (y, x) not in donor:
            t = _same_place(m, y, x, set(feet))
            if t is not None:
                donor[(y, x)] = t
    # a foot beside feet takes theirs (four passes: a patch is four cells at most)
    for _ in range(4):
        for (y, x) in feet:
            for dy, dx in ((0, -1), (0, 1), (-1, 0)):
                if (y, x) not in donor and (y + dy, x + dx) in donor:
                    donor[(y, x)] = donor[(y + dy, x + dx)]
    for c in feet:
        assert c in donor, 'level %d.%d: ramp foot at %s has no ramp-body tile beside it' % (lv, sub, c[::-1])
    if feet:
        foot_cells[(lv, sub)] = {c: (int(m[c]), donor[c]) for c in feet}
        for v in foot_cells[(lv, sub)].values():
            twin_of.setdefault(v, None)
for (o, d) in sorted(twin_of):
    twin_of[(o, d)] = len(compact)
    # the twin: the foot's own original id (its collision and alt class), the body's image
    compact.append(o)
    tile_preview.append(tile_preview[orig2compact[d]].copy())
for cid, rep in blackened.items():
    tile_preview[cid] = rep
print('blackened %d tiles; %d ramp-foot twins for %d cells'
      % (len(blackened), len(twin_of), sum(len(c) for c in foot_cells.values())))

# each tile's 64 bank bytes in the screen's layout: char row 0 (lines 0-7), its four
# characters of eight bytes each; then char row 1
tiles_bytes = []
for cid in range(len(compact)):
    b = packcol(tile_preview[cid])
    data = bytearray()
    for crow in range(2):
        for cx in range(4):
            for ra in range(8):
                data.append(int(b[crow * 8 + ra, cx]))
    assert len(data) == 64
    tiles_bytes.append(bytes(data))

# The solid tiles: 1 all cyan (the sky), 2 all black.  Each becomes id 254 or 255 in a level
# (pack_tiles), a fill from FLATTAB, never copied.  tile_class is the same by compact id,
# 0 for a tile with pixels: a star whose 2x2 tile neighbourhood is one class other than 0
# is drawn as a pre-composited box over that colour, matching the map byte for byte
# (the sprite section).
tile_class = []
tile_solid = {}
for cid, col in enumerate(tile_preview):
    if np.all(col == CYAN_COL):
        tile_solid[cid] = 1
    elif np.all(col == 0):
        tile_solid[cid] = 2
for cid in range(len(tile_preview)):
    tile_class.append(tile_solid.get(cid, 0))
# boxes on black are allowed (the blackened backdrops make them exact)
BOX_BLACK = True
def star_class(cm, x, y):
    """The class of the star at tile (x, y) of compact map cm: 1 if its four tiles (x-1..x,
    y-1..y) are all cyan, 2 if all black, else 0 (mixed, with pixels, or off the map)."""
    h, w = cm.shape
    cls = set()
    for ty in (y - 1, y):
        for tx in (x - 1, x):
            if 0 <= tx < w and 0 <= ty < h:
                cls.add(tile_class[int(cm[ty, tx])])
            else:
                cls.add(0)
    c = cls.pop() if len(cls) == 1 else 0
    return 0 if (c == 2 and not BOX_BLACK) else c

# ---------------------------------------------------------------------------
# A box star is drawn as an opaque rectangle with its background baked in, so anything
# that passes through it gets painted over.  Stars an enemy can reach therefore keep the
# ordinary masked sprite -- which is also what leaves the rest of them safe to skip
# redrawing between frames.
#
# The margin is each type's own drawn rectangle, taken from the art, plus the distance it
# can travel.  Motion, from level_init's per-type setup and the ob_* handlers (logic.s;
# all in pixels, the object's x, y in tiles):
#   1 trampoline   static          2 snake    patrols x .. x + 8 e0
#   3 cobra        rises 4 tiles   5,6 walker patrols x .. x + 8 e0
#   4 bat          hovers in x .. x + 8 e0, y .. y + 8 e1: it steers towards Cleo, but its
#                  home position is never changed -- ob_bat draws at home + C/2, D/2 with
#                  its velocity C kept in 0..A and D in 0..B, level_init's A = 16 e0 and
#                  B = 16 e1.  So it stays in its own rectangle however far the player runs.
#                  Plus the bat_off wobble.
#   7,9,10,12      static;  11 vanish animates as tiles, not a sprite
# The object types (an object's first byte; logic.s process_object's dispatch) and the
# sprite ids (the original's dim order: each animation's first frame and its frame count;
# the pairs are right then left where a frame has a facing).  assets.py writes both into
# assets.inc (OT_*, SPR_*, SPR_*_N) for logic.s.
OT = dict(STAR=0, TRAMP=1, SNAKE=2, RSNAKE=3, BAT=4, MASK=5, MUMMY=6, SPIKE=7, NONE=8,
          FLAME=9, POWERUP=10, VANISH=11, SWITCH=12)
# the original's sprites: dim's entries
NSPRITE = 103
SPR_IDS = [('CLEO_RUN0', 0, 8), ('CLEO_STAND', 8, 2), ('CLEO_IDLE1', 10, 2), ('CLEO_IDLE2', 12, 2),
           ('CLEO_THROW0', 14, 6), ('CLEO_JUMP', 20, 2), ('CLEO_MID', 22, 2), ('CLEO_FALL', 24, 2),
           ('CLEO_DEAD', 26, 1), ('BOOM0', 27, 7), ('STAR0', 34, 6), ('SPARKLE0', 40, 3),
           ('TRAMP0', 43, 3), ('SNAKE0', 46, 8), ('RSNAKE0', 54, 6), ('BASKET', 60, 1),
           ('BAT0', 61, 6), ('MASK0', 67, 9), ('MUMMY0', 76, 9), ('SPIKE0', 85, 8),
           ('FLAME0', 93, 4), ('POWERUP', 97, 1), ('PICKUP0', 98, 2), ('SWITCH0', 100, 3)]
SPR = {n: a for n, a, c in SPR_IDS}
SPR_N = {n: c for n, a, c in SPR_IDS}
assert all(a + c <= NSPRITE for n, a, c in SPR_IDS)
_span = lambda n: (SPR[n], SPR[n] + SPR_N[n] - 1)
# object type -> (first, last) sprite id it draws (the rising snake draws its basket too)
TYPE_IDS = {OT['TRAMP']: _span('TRAMP0'), OT['SNAKE']: _span('SNAKE0'), OT['RSNAKE']: (SPR['RSNAKE0'], SPR['BASKET']),
            OT['BAT']: _span('BAT0'), OT['MASK']: _span('MASK0'), OT['MUMMY']: _span('MUMMY0'),
            OT['SPIKE']: _span('SPIKE0'), OT['FLAME']: _span('FLAME0'), OT['POWERUP']: _span('POWERUP'),
            OT['SWITCH']: _span('SWITCH0')}

def _sprite_boxes():
    """id -> (dx0, dx1, dy0, dy1): the drawn rectangle about the reference point, from the
    opaque pixels of each frame in spr.png (dim: x, y, w, h, refx, refy per id); ids with no
    opaque pixel are left out."""
    idx, _rgb, tr = load_indexed('spr.png')
    dim = open(os.path.join(SRC, 'dim'), 'rb').read()
    out = {}
    for i in range(NSPRITE):
        x, y, w, h, rx, ry = struct.unpack('BBBBbb', dim[i * 6:i * 6 + 6])
        im = idx[y:y + h, x:x + w]
        ys, xs = np.where(im != tr)
        if not len(xs):
            continue
        x0, y0 = int(xs.min()), int(ys.min())
        cw, ch = int(xs.max()) - x0 + 1, int(ys.max()) - y0 + 1
        out[i] = (-(rx - x0), -(rx - x0) + cw, -(ry - y0), -(ry - y0) + ch)
    return out

_SPRBOX = _sprite_boxes()
# object type -> the union of its frames' rectangles about the reference point
TYPE_BOX = {}
for _t, (_lo, _hi) in TYPE_IDS.items():
    _b = [_SPRBOX[i] for i in range(_lo, _hi + 1) if i in _SPRBOX]
    TYPE_BOX[_t] = (min(b[0] for b in _b), max(b[1] for b in _b),
                    min(b[2] for b in _b), max(b[3] for b in _b)) if _b else (0, 0, 0, 0)
# the box star's rectangle about (8x, 8y): the field's 14 px with the hotspot at 6, BOX_H
# tall from ry = 8 (the box star section asserts both)
STAR_BOX = (-6, 8, -8, 4)
print('enemy margins about the reference point (px):',
      ' '.join('t%d=%d..%d,%d..%d' % ((t,) + TYPE_BOX[t]) for t in sorted(TYPE_BOX)))

def enemy_reach(objs):
    """The rectangles (x0, x1, y0, y1), in pixels, that the level's moving or drawn objects
    can cover: each type's TYPE_BOX at 8x, 8y grown by its motion (the patrol or hover range
    8 e0 / 8 e1, the cobra's 32 up, the bat's 2 of wobble each way).  Types not in TYPE_BOX
    (stars, the vanishing block, none) are skipped."""
    boxes = []
    for (t, x, y, extra) in objs:
        if t not in TYPE_BOX:
            continue
        e = (list(extra) + [0, 0, 0])[:3]
        dx0, dx1, dy0, dy1 = TYPE_BOX[t]
        mx = 8 * e[0] if t in (2, 4, 5, 6) else 0
        my = 8 * e[1] if t == 4 else 0
        up = 32 if t == 3 else 0
        wob = 2 if t == 4 else 0
        boxes.append((8 * x + dx0 - wob, 8 * x + dx1 + mx + wob,
                      8 * y + dy0 - up - wob, 8 * y + dy1 + my + wob))
    return boxes

def star_reachable(x, y, reach):
    """True if the star at tile (x, y)'s STAR_BOX overlaps any rectangle in reach
    (enemy_reach's)."""
    sx0, sx1, sy0, sy1 = (8 * x + STAR_BOX[0], 8 * x + STAR_BOX[1],
                          8 * y + STAR_BOX[2], 8 * y + STAR_BOX[3])
    for (x0, x1, y0, y1) in reach:
        if x0 < sx1 and sx0 < x1 and y0 < sy1 and sy0 < y1:
            return True
    return False

def box_reachable(box, x, y, reach, skip=None):
    """True if box (dx0, dx1, dy0, dy1 about tile (x, y)) overlaps any rectangle in reach
    other than skip (the object's own).  Used for the trampoline's rest box and the
    powerup's, which are drawn like a star box: opaque, no mask, no erase."""
    sx0, sx1, sy0, sy1 = 8 * x + box[0], 8 * x + box[1], 8 * y + box[2], 8 * y + box[3]
    for r in reach:
        if skip is not None and r == skip:
            continue
        x0, x1, y0, y1 = r
        if x0 < sx1 and sx0 < x1 and y0 < sy1 and sy0 < y1:
            return True
    return False

# ---------------------------------------------------------------------------
# Renumber so that every tile carrying pixel data comes first: a solid tile is a fill and
# its 64 bytes are never read.  The sort is stable within each group, so runs like the
# vanish animation stay contiguous -- and a solid frame inside the vanish or flower run
# keeps its place in the data group, wasting its 64 bytes, so the run stays contiguous.
# ---------------------------------------------------------------------------
_keep = {orig2compact[o] for o in list(range(366, 374)) + list(range(426, 430))
         if o in orig2compact}
_order = sorted(range(len(compact)), key=lambda c: (c in tile_solid and c not in _keep, c))
_newid = [0] * len(compact)
for _new, _old in enumerate(_order):
    _newid[_old] = _new
NDATA = sum(1 for c in range(len(compact)) if c not in tile_solid or c in _keep)
# a bound on the tiles with data (the set files below hold TILE_CHUNK each)
assert NDATA <= 512, 'tiles with data (%d) no longer fit two banks' % NDATA
compact = [compact[o] for o in _order]
tile_preview = [tile_preview[o] for o in _order]
tiles_bytes = [tiles_bytes[o] for o in _order]
tile_class = [tile_class[o] for o in _order]
tile_solid = {_newid[c]: v for c, v in tile_solid.items()}
orig2compact = {t: _newid[c] for t, c in orig2compact.items()}
twin_of = {t: _newid[c] for t, c in twin_of.items()}
print('tiles: %d with data, %d solid' % (NDATA, len(compact) - NDATA))
# the animated tiles' first compact ids, for the game (the level header's HDR_SPECIAL):
# the vanish run 366..373 and the flower run 426..429 must be contiguous
special = {name: orig2compact[t] for name, t in [('VANISH0', 366), ('FLOWER0', 426)]}
assert all(orig2compact[366 + i] == special['VANISH0'] + i for i in range(8))
assert all(orig2compact[426 + i] == special['FLOWER0'] + i for i in range(4))

# the conveyor tiles (the original's getPush: -2..2) and the kill tiles (lava), by compact id
push_tiles = {}
for t, v in [(412, -1), (413, -1), (414, 1), (415, 1), (423, -2), (424, 2), (439, 0), (440, 0), (441, 0), (442, 0)]:
    if t in orig2compact:
        push_tiles[orig2compact[t]] = v
kill_tiles = [orig2compact[t] for t in (101, 336) if t in orig2compact]

# the altitude classes: each distinct 8-byte alt row gets a class number; alt_class by
# compact id.  The class table is global (alt.bin, the game's alt_tab); a map's tile ids
# are the level's own, so each level file carries its own id -> class table (assets.py)
classes = {}
alt_class = []
for orig in compact:
    row = alt[orig * 8:orig * 8 + 8]
    if row not in classes:
        classes[row] = len(classes)
    alt_class.append(classes[row])
print('alt classes:', len(classes))
altfile = b''.join(sorted(classes, key=lambda r: classes[r]))

# ----------------------------------------------------------------------------
# Level packs
# ----------------------------------------------------------------------------
rng = np.random.RandomState(1234)
def name_of(lv, sub):
    """The level's name in the reports: L<lv>B for the main map (sub 0), L<lv>A for the
    bonus map (sub 1)."""
    return 'L%d%s' % (lv, 'B' if sub == 0 else 'A')

# ----------------------------------------------------------------------------
# The maps, as compact tile ids.  A level's map bytes are its OWN tile ids (pack_tiles,
# below); 254 and 255 are the two solid fills (cyan sky, black), which own no bytes in the
# tile bank.  Every solid tile in the game reduces to one of those two -- they all have
# altitude class 0 and differ only in colour -- so the whole solid set costs two ids.
# ----------------------------------------------------------------------------
# the reserved ids, the same in every level
SOLID_CYAN, SOLID_BLACK = 254, 255
maps = {}
# One stream of random sand for all the maps, taken in the ORIGINAL's order of the maps
# (LEVEL_SOURCE), not the game's: a map's sand is then the map's own, whichever level it is
# played as, and reordering levels leaves every other map's bytes alone.
_src = lambda k: (LEVEL_SOURCE.get(k, k[0]), k[1])
for (lv, sub) in sorted(levels, key=_src):
    L = levels[(lv, sub)]
    m = L['map'].copy()
    # the original randomises tile 427 at level start: one of the four flower variants
    fl = (m == 427)
    m[fl] = 426 + rng.randint(0, 4, size=int(fl.sum()))
    cm = np.vectorize(lambda t: orig2compact[t])(m)
    # a ramp's foot: the body's image, its own collision
    for (hy, hx), od in foot_cells.get((lv, sub), {}).items():
        cm[hy, hx] = twin_of[od]
    maps[(lv, sub)] = cm
# the game's order again (the stream's was the original's)
maps = {k: maps[k] for k in levels}

def tileset_of(lv, sub):
    """The level's side of the tile set: 0 outdoor (even levels), 1 indoor (odd)."""
    return lv & 1

# the compact ids each side draws: its maps' tiles, and the vanish run where a level has a
# vanishing block
_want = [set(), set()]
for (lv, sub), cm in maps.items():
    s = _want[tileset_of(lv, sub)]
    s.update(int(x) for x in np.unique(cm))
    if any(o[0] == 11 for o in levels[(lv, sub)]['objs']):
        s.update(special['VANISH0'] + i for i in range(8))

# ----------------------------------------------------------------------------
# The tiles of a level, for both machines (tools/assets.py calls pack_tiles).  A map byte is
# a LEVEL tile id; the level's tiles are gathered at load time from the tile set's files
# into bank 6, 64 bytes a slot, so a tile's address is arithmetic (the Model B's gather5)
# or a table of the same pairs (the Master's LV_PAGE0).  Ids:
#   0                    the level's solid (the colour it uses more: cyan outdoors, black
#                        indoors), a one-byte fill the row loop tests for by the zero (its
#                        fill byte is the header's solidfill, which the loader patches
#                        in); it has no slot
#   1 .. NTILES          full tiles, slot = id + TOFF (the first slot clear of the code)
#   half0 .. half0+NHALF-1  half tiles: one char row stored (32 bytes, from HALFPAGE), the
#                        other a fill or the same row again; three runs -- top row fills
#                        (to half1), bottom row fills (to half2), both rows the stored one
#   FLAT0 .. 253         flat tiles, NFLAT of them: two bytes alternating down every char
#                        (FLATTAB)
#   254, 255             the solids, cyan and black (FLATTAB's last two pairs): the level's
#                        other solid, where it has both
# So NFLAT + 3 ids are fills (id 0, the flats, the two solids) and cost no bank 6 room; the
# rest are the tiles.
# ----------------------------------------------------------------------------
# NFLAT, the flat tiles a level may have, is a build parameter (NFLAT=n sh build.sh; 4 by
# default): each is two bytes of FLATTAB in bank 6 in place of 64 in the tile run, but takes
# an id from the tiles'.  A level with more flat tiles than that stores the rest, the least
# used, as full tiles (they draw the same).  The engine reads FLAT0 and NFLAT from
# assets.inc.
NFLAT = int(os.environ.get('NFLAT', '4'))
# the flats, then the two solids at the top
FLAT0 = SOLID_CYAN - NFLAT
assert 0 < NFLAT < 64, NFLAT
# tiles in a set file: 16K, what either machine stages at a time
TILE_CHUNK = 256
# ONE tile set: every distinct tile any level uses, once, in files of at most TILE_CHUNK cut
# by who uses a tile -- outdoor levels only, both, indoor levels only -- so a level stages
# only its side's file and the shared one: TILES0 outdoor, TILES1 shared, TILES2 indoor.
# Within a file the tiles the most levels use come first.
# tile bytes -> the levels using it; -> its sides (1 outdoor, 2 indoor, 3 both)
_nlev, _side = {}, {}
for (lv, sub), cm in maps.items():
    for c in set(int(x) for x in np.unique(cm)):
        if c not in tile_solid:
            b = bytes(tiles_bytes[c])
            _nlev[b] = _nlev.get(b, 0) + 1
for g in (0, 1):
    for c in _want[g]:
        if c not in tile_solid:
            b = bytes(tiles_bytes[c])
            _side[b] = _side.get(b, 0) | (1 << g)
# tile bytes -> (file, index in it)
TSET = {}
NTFILES = 0
for side in (1, 3, 2):
    order = sorted((b for b in _side if _side[b] == side), key=lambda b: (-_nlev.get(b, 0), b))
    for k in range(0, len(order), TILE_CHUNK):
        part = order[k:k + TILE_CHUNK]
        for i, b in enumerate(part):
            TSET[b] = (NTFILES, i)
        open(os.path.join(OUT, 'TILES%d' % NTFILES), 'wb').write(b''.join(part))
        print('tile file %d: %d tiles (%s)' % (NTFILES, len(part), {1: 'outdoor', 2: 'indoor', 3: 'shared'}[side]))
        NTFILES += 1
# the loaders' file tables name three
assert NTFILES == 3

def attr_of(c):
    """Compact tile c's attribute byte for the game (LV_ATTR0): 3 + its push (0..6 for
    -3..3; 3 for none), bit 7 set for a kill tile."""
    a = 3
    if c in push_tiles:
        a = push_tiles[c] + 3
    if c in kill_tiles:
        a |= 0x80
    return a
def _flat_pair_row(row):
    """A char row's 32 bank bytes (4 chars of 8): its 2-byte dither pair if the row is one
    pair repeated down every char, else None."""
    cs = [bytes(row[k * 8:k * 8 + 8]) for k in range(4)]
    if all(x == cs[0] for x in cs) and all(cs[0][i] == cs[0][i & 1] for i in range(8)):
        return cs[0][:2]
    return None

# One layout serves both machines (the level files are shared): bank 6's tiles above its
# code, at the same slots on both.  The Model B's gather computes a tile's address pair
# from its id; the Master's is a table (LV_PAGE0, B['page0'], the file's last two sectors)
# of the same pairs, so the one row loop reads both.
# bank 6: the tiles' page origin (assets.inc TILES, for the engine), to the end of the bank
B_TILES, B_TILES_END = 0x8600, 0xC000
# id k's slot is k + TOFF, the first slots clear of bank 6's code and variables (init.s and
# defs.inc assert it, from assets.inc)
TOFF = 2
def _layout(stored, hlist, halfpair, base, end, loc, name='', demoted=0):
    """The bank 6 layout of a level's stored tiles: slot[k] = i + 1 + TOFF for the i-th (id
    0, the solid, has none); NT the slot count; the halves from HALFPAGE, the first page
    after the full tiles, at HALFOFF (the half slots the last full page's tail takes).
    Asserts that the halves and the fill palette fit below end."""
    slot = {k: i + 1 + TOFF for i, k in enumerate(stored)}
    NT, NHALF = len(stored) + 1 + TOFF, len(hlist)
    HALFPAGE = base + ((NT * 64) & ~255)
    HALFOFF = ((NT * 64) & 255) // 32
    assert HALFPAGE + (HALFOFF + NHALF) * 32 + len(halfpair) <= end, \
        '%s: its tiles do not fit bank 6 (%d full, %d half%s)' % (
            name, NT - 1 - TOFF, NHALF, ', %d of them flat tiles past NFLAT = %d: raise NFLAT' % (demoted, NFLAT) if demoted else '')
    return dict(slot=slot, NT=NT, HALFPAGE=HALFPAGE, HALFOFF=HALFOFF)
def _tilelist(files, stored, loc):
    """The level's files (the set's numbers) with the full tiles each gives, then each
    full tile's index in its file: [n, file, count, ..., index, ...]."""
    chunks = [loc(k)[0] for k in stored]
    return (bytes([len(files)]) + b''.join(bytes([f, chunks.count(f)]) for f in files)
            + bytes(loc(k)[1] for k in stored))

def pack_tiles(lv, sub):
    """The level's tile ids, and the lists that gather its tiles: B, the layout both
    machines load.  Returns dict(local: compact id -> level id, B: dict(slot, NT, HALFPAGE,
    HALFOFF, tiles, shape, mir, page0), flat: FLATTAB's bytes, halves: the half list,
    hpair: the fill palette section, ntiles, nhalf, nflat, usage)."""
    cm = maps[(lv, sub)]
    g = tileset_of(lv, sub)
    specials = [special['VANISH0'] + i for i in range(8)] + [special['FLOWER0'] + i for i in range(4)]
    vals, cnt = np.unique(cm, return_counts=True)
    usage = {int(v): int(n) for v, n in zip(vals, cnt)}
    live = set(usage) | (set(specials) & _want[g])
    local = {}
    # the solid the level uses more is id 0 (ties: cyan); the other keeps its fill id
    nsol = [sum(usage.get(c, 0) for c in live if tile_solid.get(c) == v) for v in (1, 2)]
    sol0 = 1 if nsol[0] >= nsol[1] else 2
    for c in live:
        if c in tile_solid:
            local[c] = 0 if tile_solid[c] == sol0 else SOLID_CYAN if tile_solid[c] == 1 else SOLID_BLACK
    # identical tiles share an id -- identical to the logic too, which reads a tile's
    # attribute and altitude class by id
    keyof = lambda c: (bytes(tiles_bytes[c]), attr_of(c), alt_class[c])
    groups = {}
    for c in sorted(live):
        if c not in tile_solid:
            groups.setdefault(keyof(c), []).append(c)
    use = {k: sum(usage.get(c, 0) for c in cs) for k, cs in groups.items()}
    # a group is flat (both char rows one pair), a half (one row a pair: the other stored;
    # or both rows the same bytes: one stored), or a full tile
    flats, halves, fulls = [], {'top': [], 'bot': [], 'pair': []}, []
    for k in groups:
        t = k[0]
        a, b = _flat_pair_row(t[:32]), _flat_pair_row(t[32:])
        if a is not None and a == b:
            flats.append((k, a))
        elif a is not None and b is None:
            # the top row fills: the bottom is stored (row 1)
            halves['top'].append((k, 1, a))
        elif b is not None and a is None:
            halves['bot'].append((k, 0, b))
        elif t[:32] == t[32:]:
            halves['pair'].append((k, 0, b'\0\0'))
        else:
            fulls.append(k)
    demoted = max(0, len(flats) - NFLAT)
    if demoted:
        # more flats than ids: the most used stay flats, the rest are stored as full tiles
        keep = set(k for k, fp in sorted(flats, key=lambda f: -use[f[0]])[:NFLAT])
        fulls += [k for k, fp in flats if k not in keep]
        flats = [f for f in flats if f[0] in keep]
    loc = lambda k: TSET[k[0]]
    for v in halves.values():
        v.sort(key=lambda h: loc(h[0]))
    hlist = halves['top'] + halves['bot'] + halves['pair']
    # A half's fill is one of a few pairs (5 at most a level): a palette of 8, each half's
    # low bits the fill's row (bit 3 the top, bit 4 the bottom, neither for a pair of stored
    # rows) and its colour in the palette (bits 0-2).  The section: the palette's first
    # bytes, its second bytes, then each half's low bits.
    pal = sorted(set(h[2] for h in hlist if h in halves['top'] or h in halves['bot']))
    assert len(pal) <= 8, (lv, sub, 'more than 8 half fill pairs', len(pal))
    hlow = bytes((8 if h in halves['top'] else 16 if h in halves['bot'] else 0) |
                 (pal.index(h[2]) if h[2] in pal and h not in halves['pair'] else 0) for h in hlist)
    pal8 = pal + [b'\0\0'] * (8 - len(pal))
    # bank 6's 16 bytes (HPAIR0, HPAIR1)
    halfpair = bytes(p[0] for p in pal8) + bytes(p[1] for p in pal8)
    hpairsec = halfpair + hlow
    assert len(flats) <= NFLAT, (lv, sub, len(flats))
    # (every stored tile must fit the bank: _layout asserts it)
    stored = sorted(fulls, key=loc)
    NT, NHALF = len(stored), len(hlist)
    idof = {k: i + 1 for i, k in enumerate(stored)}
    half0 = NT + 1
    half1 = half0 + len(halves['top'])
    half2 = half1 + len(halves['bot'])
    for i, h in enumerate(hlist):
        idof[h[0]] = half0 + i
    assert half0 + NHALF <= FLAT0, (lv, sub, half0 + NHALF)
    for i, (k, fp) in enumerate(flats):
        idof[k] = FLAT0 + i
    for k, cs in groups.items():
        for c in cs:
            local[c] = idof[k]
    # FLATTAB: the flats' pairs, zero to NFLAT pairs, then the solids' (cyan $0F $0F, black
    # $00 $00)
    flattab = b''.join(fp for k, fp in flats).ljust(2 * NFLAT, b'\0') + bytes([0x0F, 0x0F, 0x00, 0x00])
    # the files to stage, and each tile's by its place in that list
    files = sorted(set(loc(k)[0] for k in list(fulls) + [h[0] for h in hlist]))
    pos = lambda k: files.index(loc(k)[0])
    halflist = b''.join(bytes([loc(h[0])[1], h[1] | pos(h[0]) << 1]) for h in hlist)
    lw = 8 - levels[(lv, sub)]['lw']
    # the layout: the stored tiles at slot = id + TOFF
    B = _layout(stored, hlist, halfpair, B_TILES, B_TILES_END, loc, name_of(lv, sub), demoted)
    assert all(B['slot'][k] == idof[k] + TOFF for k in stored)
    B['tiles'] = _tilelist(files, stored, loc)
    # the header's shape (beebgame levelfile.Shape): mir0 and nmir are the format's, kept
    # from the removed mirrored tiles (the first id past the halves, and 0)
    B['shape'] = dict(ntiles=NT, map_shr=lw, nhalf=NHALF, half0=half0, half1=half1, half2=half2,
                      halfpage=B['HALFPAGE'] >> 8, halfoff=B['HALFOFF'],
                      mir0=half0 + NHALF, nmir=0,
                      solidfill=0x0F if sol0 == 1 else 0x00)
    # the format's mirrored-tile section, empty
    B['mir'] = b''
    assert B['HALFOFF'] + NHALF <= 64, (lv, sub, 'the halves outgrow HLOW (gather.s)')
    # The Master's LV_PAGE0 for these slots: per id, the pair the Model B's gather computes
    # (256 low bytes, then 256 high).  An id no tile has -- the rows past the map's end are
    # read too, whatever lies there -- is a black fill: low byte 2 (NFLAT + 1), FLATTAB's
    # last pair, high byte $40; a high byte with bit 7 clear is a fill (the row loop's bpl),
    # id 0's zero high byte the solid (its beq).
    blo, bhi = bytearray([2 * (NFLAT + 1)] * 256), bytearray([0x40] * 256)
    bhi[0] = 0
    for k in stored:
        s_, a_ = idof[k], B['slot'][k]
        blo[s_], bhi[s_] = (a_ & 3) << 6, (B_TILES >> 8) + (a_ >> 2)
    for i, h in enumerate(hlist):
        t, kk = half0 + i, B['HALFOFF'] + i
        # a half's page less $80 marks it a half; its low byte the slot in the page and hlow
        bhi[t] = ((B['HALFPAGE'] >> 8) + (kk >> 3)) & 0x7F
        blo[t] = ((kk & 7) << 5) | hlow[i]
    for j in range(NFLAT + 2):
        blo[FLAT0 + j], bhi[FLAT0 + j] = 2 * j, 0x40
    B['page0'] = bytes(blo + bhi)
    return dict(local=local, B=B, flat=flattab, halves=halflist, hpair=hpairsec,
                ntiles=NT, nhalf=NHALF, nflat=len(flats), usage=usage)

# ----------------------------------------------------------------------------
# Sprites
# ----------------------------------------------------------------------------
spr_idx, spr_rgb, spr_tr = load_indexed('spr.png')
dim = open(os.path.join(SRC, 'dim'), 'rb').read()
# per id: x, y, w, h in spr.png and the signed reference point refx, refy
DIM = [struct.unpack('BBBBbb', dim[i * 6:i * 6 + 6]) for i in range(NSPRITE)]
# every sprite full-res: two stored scanlines a game px
FULLRES = set(range(NSPRITE))
# the BONUS LEVEL banner is drawn as text instead
SKIP = {102}
# per id: (the frame cropped to its opaque pixels, refx and refy within the crop)
crops = []
for i, (x, y, w, h, rx, ry) in enumerate(DIM):
    im = spr_idx[y:y + h, x:x + w]
    mask = im != spr_tr
    ys, xs = np.where(mask)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    crops.append((im[y0:y1, x0:x1], rx - x0, ry - y0))

# The health powerup (97) and the red snake (54..59): their reds turned 30% of the way
# round to magenta (hue 0 -> 342, saturation and value kept), in new palette entries -- the
# crops themselves, so the HUD's heart (bar_icon) turns with the powerup.  The 4-bit
# sprites' fifteen patterns had turned those reds pale and dark; with the powerup's box
# (below) this undoes it.  Only reds (within 15 degrees of hue 0): the snake's browns and the
# highlights keep theirs.
PW_ID, RED_HUE = SPR['POWERUP'], 0.3 * -60
RED_IDS = [PW_ID] + list(range(SPR['RSNAKE0'], SPR['RSNAKE0'] + SPR_N['RSNAKE0']))
spr_rgb = spr_rgb.copy()
# the palette entries no sprite uses, for the rotated colours; source index -> new index
_red_free = [k for k in range(len(spr_rgb)) if k != spr_tr and k not in set(np.unique(spr_idx).tolist())]
_red_map = {}
def _hue_rotated(im):
    """im (an index crop) with each red palette entry replaced by a new entry of the hue
    rotated by RED_HUE, made on first sight (_red_map); other colours and the transparent
    index are kept."""
    import colorsys
    out = im.copy()
    for k in sorted(set(np.unique(im).tolist()) - {spr_tr}):
        if k not in _red_map:
            r, g, b = (spr_rgb[k] / 255.0).tolist()
            h, s, v = colorsys.rgb_to_hsv(r, g, b)
            if s == 0 or 15 / 360 <= h <= 345 / 360:
                # not a red: kept
                _red_map[k] = k
            else:
                n = _red_free.pop(0)
                spr_rgb[n] = np.round(np.array(colorsys.hsv_to_rgb((h + RED_HUE / 360) % 1.0, s, v)) * 255).astype(np.uint8)
                _red_map[k] = n
        out[im == k] = _red_map[k]
    return out
for _i in RED_IDS:
    crops[_i] = (_hue_rotated(crops[_i][0]),) + tuple(crops[_i][1:])
# the distinct images: (index array, full-res, the first id that uses it); an id whose crop
# is another's, or another's mirror, shares the image
images = []
# per id: (image index, mirrored, refx, refy), or None (SKIP)
entry = []
for i in range(NSPRITE):
    if i in SKIP:
        entry.append(None); continue
    im, rx, ry = crops[i]
    found = None
    for j, (jm, jfull, jsrc) in enumerate(images):
        if jm.shape != im.shape or jfull != (i in FULLRES):
            continue
        if np.array_equal(jm, im):
            found = (j, 0); break
        if np.array_equal(jm[:, ::-1], im):
            found = (j, 1); break
    if found is None:
        images.append((im, i in FULLRES, i))
        found = (len(images) - 1, 0)
    entry.append((found[0], found[1], rx, ry))

# Object sprites are drawn at tile-aligned y (object y = ty*8), so their top scanline sits
# 2*refy below a char-row boundary whatever the camera does (the wy/wfine terms cancel
# mod 8).  Snap refy to a multiple of 4 game px wherever that saves a whole char row of
# blit + erase: the image moves by at most 2 px (nearest multiple; ties move it up).
# Only the stars (34..39) qualify: they are static.  Cleo, the boomerang, the rising
# cobra (54..59, y follows a parabola) and the bats (61..66, flying) are not tile-aligned,
# so shifting them would move the art for no saving.
snapped = []
for i in range(SPR['STAR0'], SPR['STAR0'] + SPR_N['STAR0']):
    e = entry[i]
    if e is None:
        continue
    j, mirror, rx, ry = e
    lines = images[j][0].shape[0] * 2
    rows = lambda r: (((-2 * r) % 8) + lines + 7) // 8
    if ry % 4 == 0:
        continue
    down, up = ry - ry % 4, ry + (4 - ry % 4)
    cand = up if (up - ry) <= (ry - down) else down
    if rows(cand) < rows(ry):
        entry[i] = (j, mirror, rx, cand)
        snapped.append((i, ry, cand))
print('refy snapped:', snapped)

# Pack each unique image (column-major bytes).
#
# An odd-width image leaves one transparent pixel of padding, and it can sit at either
# end: both give the same ceil(w/2) columns, but they pair art columns into bytes
# differently.  A byte with both pixels opaque is a straight store; a byte with one goes
# through the mask -- read, mask, or, store.  So the phase that leaves fewer half-opaque
# bytes is cheaper to blit, for nothing.  The count is made on the MODE 1 screen bytes of
# the dithered image, as when sprites were stored that way (_masked: a byte with bit 7
# clear that is not $41 -- a proxy from that encoding, kept so the choice stays as it
# was); the 4-bit bytes below are built from the same padded images.
img_bytes = []
img_wbytes = []
img_shift = []
preview = []

def _pack(im, full, shift):
    """Image im (an index array) padded to an even width with the art shift (0 or 1) pixels
    in, dithered: (its col entries, its MODE 1 screen bytes, (lines, W))."""
    h, w = im.shape
    W = (w + 1) // 2
    padded = np.full((h, W * 2), spr_tr, dtype=im.dtype)
    padded[:, shift:shift + w] = im
    col = dither(spr_rgb[padded], padded != spr_tr, x0=(-shift) & 1, full=full)
    return col, encode_sprite(col, packcol(col))

_masked = lambda e: int((((e & 0x80) == 0) & (e != 0x41)).sum())
_saved = 0
for (im, full, src) in images:
    h, w = im.shape
    W = (w + 1) // 2
    col, packed = _pack(im, full, 0)
    shift = 0
    if w & 1:
        col1, packed1 = _pack(im, full, 1)
        if _masked(packed1) < _masked(packed):
            _saved += _masked(packed) - _masked(packed1)
            shift, col, packed = 1, col1, packed1
    preview.append(col)
    b = bytearray()
    for c in range(W):
        b += packed[:, c].tobytes()
    img_bytes.append(bytes(b))
    img_wbytes.append(W)
    img_shift.append(shift)
print('sprite padding phase: %d of %d images pad on the left, %d fewer masked bytes'
      % (sum(img_shift), len(images), _saved))


# ---- 4-bit sprites: every game pixel one of fifteen 2x2 patterns, nibble 0 transparent --
# a byte a game-pixel row for each column (the left pixel in the high nibble), no mask.
# The fifteen are the dither's patterns that lose least: each colour keeps its pattern if it
# is one of them, else takes the one nearest in Lab (as a linear mix of its dots).  (The
# boxes are not 4-bit: their screen bytes, backdrop and all, are copied -- below.)  NIBTAB
# is the expansion the engine draws through (banks.s nibtab.bin): L0TAB and L1TAB, a stored
# byte's two scanlines, and NMASK, the AND mask for its transparent pixels.
# (MMYK in place of CMMY, 2 Oct 2026: the heart's red, so the red snake's rotated red
# matches the powerup's box instead of taking a cyan dot; CMMY's other user, a lavender on
# the bats and walkers, takes MMYK too.)
NIB_PATTERNS = 'CCCM CCKK CKKK CMKK CMYY CYYK CYYY KKKK MMYK MYKK MYYK MYYY YKKK YYKK YYYY'.split()
_crgb, _seq = _CMYK[4]
_code = [''.join('KCMY'[d] for d in s_) for s_ in _seq]
# nibble n + 1 -> the index of its pattern in _CMYK[4]
NIB_PAT = [_code.index(c) for c in NIB_PATTERNS]
def _lab(lin):
    """Linear-light RGB rows (n, 3) to CIE Lab (n, 3), D65 white."""
    M = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = lin @ M.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[:, 1] - 16, 500 * (f[:, 0] - f[:, 1]), 200 * (f[:, 1] - f[:, 2])], axis=1)
_PL = _lab(_crgb.astype(np.float64))
# each palette colour's pattern: the dither's own choice first, else the nearest of the
# fifteen in Lab
_v = (spr_rgb.astype(np.float32) / 255.0) ** GAMMA
_today = ((_v[:, None, :] - _crgb[None, :, :]) ** 2).sum(axis=2).argmin(axis=1)
# palette index -> nibble
NIB_OF = np.zeros(len(spr_rgb), np.uint8)
for _c in range(len(spr_rgb)):
    _p = _today[_c]
    if _p not in NIB_PAT:
        _p = min(NIB_PAT, key=lambda q: ((_PL[_p] - _PL[q]) ** 2).sum())
    NIB_OF[_c] = 1 + NIB_PAT.index(_p)
NIB_OF[spr_tr] = 0
# a nibble's col entry on scanline 0 (kernel dots TL, TR) or 1 (BL, BR); 0 for nibble 0
_entry = lambda n, line: 0 if n == 0 else (
    (_seq[NIB_PAT[n - 1]][0] << 2) | _seq[NIB_PAT[n - 1]][2] if line == 0
    else (_seq[NIB_PAT[n - 1]][3] << 2) | _seq[NIB_PAT[n - 1]][1])
# L0TAB (0..255), L1TAB (256..511): a stored byte's two screen bytes; NMASK (512..767): $FF
# for two transparent pixels, else $CC for a transparent left pixel | $33 for a right
NIBTAB = bytearray(768)
for _b in range(256):
    _hi, _lo = _b >> 4, _b & 15
    for _line in (0, 1):
        NIBTAB[256 * _line + _b] = int(packcol(np.array([[_entry(_hi, _line), _entry(_lo, _line)]], np.uint8))[0, 0])
    NIBTAB[512 + _b] = 0xFF if _b == 0 else (0xCC if _hi == 0 else 0) | (0x33 if _lo == 0 else 0)
# the image bytes, replaced: per column, a byte a game-pixel row (column-major)
for _j, ((im, full, src), shift) in enumerate(zip(images, img_shift)):
    h, w = im.shape
    W = (w + 1) // 2
    padded = np.full((h, W * 2), spr_tr, dtype=im.dtype)
    padded[:, shift:shift + w] = im
    n = NIB_OF[padded]
    img_bytes[_j] = bytes(((n[:, 0::2] << 4) | n[:, 1::2]).T.astype(np.uint8).tobytes())
print('4-bit sprites: %d bytes' % sum(len(b) for b in img_bytes))

# Box stars: each spin frame (34..39) composited over cyan and over black in a box just
# wide enough to cover its own art AND the previous frame's, so drawing frame N erases
# frame N-1 with no mask and no erase pass.  The frames are all BOX_H tall but the spin
# narrows to a sliver, so the narrow ones carry a narrower box.  The engine draws them with
# the copy blitter (SPF_COPY) from bank 5.
# game px (24 lines)
BOX_H = 12
# the field in px: the widest frame, its hotspot at px 6
FIELD = 14
# per frame: (its col entries, the field column its art starts at), and its alpha (lines, w)
box_art = []
box_alpha = []
for f in range(6):
    j, mirror, rx, ry = entry[SPR['STAR0'] + f]
    im = images[j][0]
    h, w = im.shape
    W = (w + 1) // 2
    padded = np.full((h, W * 2), spr_tr, dtype=im.dtype)
    padded[:, :w] = im
    if mirror:
        padded = padded[:, ::-1]
        rx = (2 * W - 1) - rx
    col = dither(spr_rgb[padded], padded != spr_tr, full=True)
    assert h == BOX_H and ry == 8, (f, ry, h)
    x0 = 6 - rx
    assert 0 <= x0 and x0 + 2 * W <= FIELD, (f, x0, W)
    box_art.append((col, x0))
    box_alpha.append(np.repeat(padded != spr_tr, 2, axis=0))

# The mask is the art's alpha, not "col != 0": black star pixels -- the whole dark outline
# -- are part of the star.  The copy blitter copies the field verbatim, so black as colour
# 0 in it is simply black.
_boxmask = lambda f: box_alpha[f]
def _span(f):
    """The opaque pixel range of spin frame f, in field px: (first, last)."""
    col, x0 = box_art[f]
    xs = np.where(_boxmask(f).any(axis=0))[0]
    return x0 + int(xs.min()), x0 + int(xs.max())

# Every box has to be able to erase whatever the record holds, and the record is the same
# buffer's previous draw, two renders back.  The logic runs once a rendered frame with no
# catch-up (game.s frame_loop), the stars' clock advances one step a frame, and a star's
# spin frame is (clock + phase) >> 1 (logic.s ob_star), so two renders move the animation
# by at most one frame and a box need only cover its own art and its predecessor's.  If
# logic catch-up ever comes in this has to go back to the union of all six: more steps per
# render let the animation skip a frame, and the narrow boxes then leave the previous one
# on screen.
def _boxgeom(f):
    """Frame f's box: (its first byte column in the field, its width in byte columns),
    covering frame f and frame f - 1."""
    p = (f - 1) % 6
    lo = min(_span(f)[0], _span(p)[0]) // 2
    hi = max(_span(f)[1], _span(p)[1]) // 2
    return lo, hi - lo + 1
box_geom = [_boxgeom(f) for f in range(6)]
# the twelve boxes' screen bytes, column-major: the six frames on cyan, then on black
box_bytes = []
for bg in (CYAN_COL, 0):
    for f in range(6):
        col, x0 = box_art[f]
        lo, Wc = box_geom[f]
        field = np.full((BOX_H * 2, FIELD), bg, np.uint8)
        sub = field[:, x0:x0 + col.shape[1]]
        field[:, x0:x0 + col.shape[1]] = np.where(_boxmask(f), col, sub)
        packed = packcol(field[:, 2 * lo:2 * (lo + Wc)])
        b = bytearray()
        for c in range(Wc):
            b += packed[:, c].tobytes()
        box_bytes.append(bytes(b))
print('box stars: widths (chars) per frame', [w for _l, w in box_geom],
      '= %d bytes for 12 boxes (was %d)' % (sum(len(b) for b in box_bytes), 12 * 7 * 24))

# The trampoline's art: its three bounce frames (43, 44, 45), TRAMP_H px tall, lined up on
# a hotspot TRAMP_HOT px into a TRAMP_FIELD px field.  Its rest frame is baked over each
# level's backdrop (below); the bounce frames are drawn as ordinary 4-bit sprites.
TRAMP_IDS = [43, 44, 45]
TRAMP_H = 8
TRAMP_FIELD = 26
TRAMP_HOT = 16
# per frame: (its col entries, the field column its art starts at), and its alpha
tramp_art = []
tramp_alpha = []
for _i in TRAMP_IDS:
    _j, _mir, _rx, _ry = entry[_i]
    _im = images[_j][0]
    _h, _w = _im.shape
    assert _h == TRAMP_H and not _mir and _ry == -8, (_i, _h, _mir, _ry)
    _W = (_w + 1) // 2
    _pad = np.full((_h, _W * 2), spr_tr, dtype=_im.dtype)
    _pad[:, :_w] = _im
    _col = dither(spr_rgb[_pad], _pad != spr_tr, full=True)
    _x0 = TRAMP_HOT - _rx
    assert 0 <= _x0 and _x0 + 2 * _W <= TRAMP_FIELD, (_i, _x0, _W)
    tramp_art.append((_col, _x0))
    tramp_alpha.append(np.repeat(_pad != spr_tr, 2, axis=0))

# the mask is the art's alpha, as for the box stars (see there)
_tmask = lambda f: tramp_alpha[f]
def _tspan(f):
    """The opaque pixel range of trampoline frame f, in field px: (first, last)."""
    col, x0 = tramp_art[f]
    xs = np.where(_tmask(f).any(axis=0))[0]
    return x0 + int(xs.min()), x0 + int(xs.max())


# ---- Baked boxes: a sprite's frame composited over the level's own tiles where it stands,
# its screen bytes column by column (every scanline: the copy blitter's), for the
# trampolines at rest, the health powerups and the stars the packer chooses (assets.py).
# A box at map game pixel (X0, Y0), wc bytes by h rows; the art's col lines and alpha at
# field column fx0 of the box.  None where the box would show an animated tile (the
# vanishing blocks, the flowers) or leave the map: those keep their masked frames.
_ANIMATED = set(special['VANISH0'] + i for i in range(8)) | set(special['FLOWER0'] + i for i in range(4))
def bake_box(cm, X0, Y0, wc, h, col, alpha, fx0):
    """The box's screen bytes, column-major (2h lines a column), from compact map cm: the
    tiles' pixels under it, the art's opaque pixels over them; None if any pixel is off the
    map or on an animated tile."""
    mh, mw = cm.shape
    fld = np.zeros((2 * h, 2 * wc), np.uint8)
    for line in range(2 * h):
        my = 2 * Y0 + line
        ty = my // 16
        for gx in range(2 * wc):
            X = X0 + gx
            tx = X // 8
            if not (0 <= ty < mh and 0 <= tx < mw) or X < 0 or my < 0:
                return None
            c = int(cm[ty, tx])
            if c in _ANIMATED:
                return None
            fld[line, gx] = tile_preview[c][my % 16, X % 8]
    ah, aw = col.shape
    for line in range(ah):
        for ax in range(aw):
            gx = fx0 + ax
            if 0 <= gx < 2 * wc and alpha[line, ax]:
                fld[line, gx] = col[line, ax]
    packed = packcol(fld)
    return bytes(packed.T.astype(np.uint8).tobytes())
# the trampoline's rest state (frame 0 alone: its box need cover no other frame): its first
# byte column in the field and its width in byte columns
_r0 = _tspan(0)
TRAMP_REST_LO, TRAMP_REST_WC = _r0[0] // 2, _r0[1] // 2 - _r0[0] // 2 + 1
def bake_tramp_rest(cm, x, y):
    """The rest box of the trampoline at tile (x, y): it stands at 8x + 4 (logic.s
    level_init @t1), its art TRAMP_H px tall from 8y + 8.  bake_box's result."""
    col, x0 = tramp_art[0]
    return bake_box(cm, 8 * x + 4 - TRAMP_HOT + 2 * TRAMP_REST_LO, 8 * y + 8, TRAMP_REST_WC, TRAMP_H,
                    col, _tmask(0), x0 - 2 * TRAMP_REST_LO)
# The loader's baker (beebgame ldprog.s bake) makes the same bytes on the Beeb from an
# overlay a kind: each column's pixels (2h lines) then its mask (1s where the backdrop
# shows), (backdrop AND mask) OR pixels.  BAKE_KINDS: kind 0 the trampoline at rest, 1..6
# the star's frames, 7 the powerup: (bytes wide, lines, dx from 8x in game pixels, dty from
# y in tile rows, the overlay[, skip: start at the tile row's bottom char row]).
def bake_overlay(wc, h, col, alpha, fx0):
    """The overlay for a kind: per byte column, its 2h pixel bytes then its 2h mask bytes
    ($F for a transparent game pixel, 0 under the art), the art at field column fx0."""
    dat = np.zeros((2 * h, 2 * wc), np.uint8)
    msk = np.full((2 * h, 2 * wc), 15, np.uint8)
    ah, aw = col.shape
    for line in range(ah):
        for ax in range(aw):
            gx = fx0 + ax
            if 0 <= gx < 2 * wc and alpha[line, ax]:
                dat[line, gx], msk[line, gx] = col[line, ax], 0
    d, k = packcol(dat), packcol(msk)
    return b''.join(d[:, c].tobytes() + k[:, c].tobytes() for c in range(wc))
BAKE_KINDS = [(TRAMP_REST_WC, 2 * TRAMP_H, 4 - TRAMP_HOT + 2 * TRAMP_REST_LO, 1,
               bake_overlay(TRAMP_REST_WC, TRAMP_H, tramp_art[0][0], _tmask(0), tramp_art[0][1] - 2 * TRAMP_REST_LO))]
for _f in range(6):
    _lo, _wc = box_geom[_f]
    BAKE_KINDS.append((_wc, 2 * BOX_H, -6 + 2 * _lo, -1,
                       bake_overlay(_wc, BOX_H, box_art[_f][0], _boxmask(_f), box_art[_f][1] - 2 * _lo)))
# The health powerup at rest (97): always a baked box -- the full dither, not the fifteen
# patterns.  It draws at (8x, 8y) with its art 4 px down, the tile row's bottom char row:
# the box starts there (the baker's skip: its first tile row from that row), on an even game
# px, as tall and wide as the art -- the char rows the sprite covered, no more.
_pj, _pmir, _prx, _pry = entry[PW_ID]
_pim = images[_pj][0]
assert not _pmir and _pry == -4
_ph, _pw = _pim.shape
# game px from 8y to the art's top: a char row
PW_TOP = -_pry
# game px from the box's left to 8x (even)
PW_LEFT = _prx + (_prx & 1)
# the art's first column in the box
PW_FX0 = PW_LEFT - _prx
PW_WC = (PW_FX0 + _pw + 1) // 2
PW_H = _ph
pw_col = dither(spr_rgb[_pim], _pim != spr_tr, full=True)
pw_alpha = np.repeat(_pim != spr_tr, 2, axis=0)
def bake_powerup(cm, x, y):
    """The box of the health powerup at tile (x, y): bake_box's result."""
    return bake_box(cm, 8 * x - PW_LEFT, 8 * y + PW_TOP, PW_WC, PW_H, pw_col, pw_alpha, PW_FX0)
BAKE_KINDS.append((PW_WC, 2 * PW_H, -PW_LEFT, 0, bake_overlay(PW_WC, PW_H, pw_col, pw_alpha, PW_FX0), 1))
PW_KIND = len(BAKE_KINDS) - 1

def bake_star(cm, x, y):
    """The six baked boxes of the star at tile (x, y), each spin frame's box over the tiles
    (bake_box, STAR_BOX's origin 8x - 6, 8y - 8), or None if any cannot be made."""
    out = []
    for f in range(6):
        col, x0 = box_art[f]
        lo, wc = box_geom[f]
        b = bake_box(cm, 8 * x - 6 + 2 * lo, 8 * y - 8, wc, BOX_H, col, _boxmask(f), x0 - 2 * lo)
        if b is None:
            return None
        out.append(b)
    return out

# the font: 40 glyphs of 8 x 8 from tit.png at y = 26 on, 10 a row, a bit a pixel (bit 7 the
# left), 8 bytes a glyph
tit_idx, tit_rgb, tit_tr = load_indexed('tit.png')
font = bytearray()
for g in range(40):
    gx, gy = (g % 10) * 8, 26 + (g // 10) * 8
    for r in range(8):
        b = 0
        for c in range(8):
            if tit_idx[gy + r, gx + c] != tit_tr:
                b |= 0x80 >> c
        font.append(b)

# The bar: 160 game px wide, 16 scanlines (two char rows), its icons from the sprites on
# black; the digits from bar.png.
bar_idx, bar_rgb, _ = load_indexed('bar.png')
BAR_BLUE = np.array([0, 0, 255], np.uint8)
BAR_CYAN = np.array([0, 255, 255], np.uint8)
BAR_BLACK = np.array([0, 0, 0], np.uint8)
# the brick, blue and grey background indices in bar.png
BAR_BG = {0, 1, 5, 6, 7, 8, 9, 13}
# The bar is composed at scanline resolution (16 lines) so the dither runs per scanline,
# exactly like the playfield.  Each icon is a sprite crop placed into bar16: icons that fit
# (<= 8 game px tall) go in native (one game px = two scanlines) with an optional
# one-scanline offset; taller ones are resampled onto the 16-line grid (LANCZOS) rather
# than to 8 then doubled.
bar16 = np.zeros((16, 160, 3), np.uint8)
bar16[:] = BAR_BLACK
def bar_icon(dstx, spr_id, y0=0, crop_h=None, crop_w=None, sub_scan=0, fit=False):
    """Paint sprite spr_id's crop (from row y0, cut to crop_h rows and crop_w columns) into
    bar16 at game px column dstx: with fit, resampled to 16 scanlines at true aspect (a game
    px is 2 scanlines) with alpha over 96 opaque; else native, each game px two scanlines
    from 2k + sub_scan, at most 8 rows, clipped to the 16 lines."""
    im = crops[spr_id][0][y0:]
    if crop_h:
        im = im[:crop_h]
    if crop_w:
        im = im[:, :crop_w]
    h, w = im.shape
    if fit:
        tw = max(1, int(round(w * 16 / float(2 * h))))
        rgba = np.dstack([spr_rgb[im].astype(np.uint8), (im != spr_tr).astype(np.uint8) * 255]).astype(np.uint8)
        arr = np.array(Image.fromarray(rgba, 'RGBA').resize((tw, 16), Image.LANCZOS))
        for s in range(16):
            for xx in range(tw):
                if dstx + xx < 160 and arr[s, xx, 3] > 96:
                    bar16[s, dstx + xx] = arr[s, xx, :3]
    else:
        for k in range(min(h, 8)):
            rgb = spr_rgb[im[k]]; op = im[k] != spr_tr
            for s in (2 * k + sub_scan, 2 * k + sub_scan + 1):
                if 0 <= s < 16:
                    for xx in range(w):
                        if dstx + xx < 160 and op[xx]:
                            bar16[s, dstx + xx] = rgb[xx]
# the HUD's digit columns, in game px (logic.s redraw_hud and bar_digit; assets.inc HUD_X_*):
# each count's icon sits HUD_ICON_DX game px left of its first digit
HUD_X_LIVES, HUD_X_HEALTH, HUD_X_STARS, HUD_X_SCORE = 18, 46, 74, 108
HUD_ICON_DX = 15
# Cleo's head, native, from two game px down her first run frame
bar_icon(HUD_X_LIVES - HUD_ICON_DX, SPR['CLEO_RUN0'], y0=4, crop_h=8, crop_w=14)
# the heart and the star, resampled onto the 16-line grid
bar_icon(HUD_X_HEALTH - HUD_ICON_DX, SPR['POWERUP'], fit=True)
bar_icon(HUD_X_STARS - HUD_ICON_DX, SPR['STAR0'], fit=True)
# 16 lines x 160 col entries; 16 x 80 screen bytes; 1280 bytes in the screen's order
barcol = dither(bar16, np.ones((16, 160), bool), full=False)
barpk = packcol(barcol)
barbytes = bytearray()
for crow in range(2):
    for cx in range(80):
        for ra in range(8):
            barbytes.append(int(barpk[crow * 8 + ra, cx]))
# the digits 0..9 from bar.png at (63 + (n % 5) * 8, (n // 5) * 8), 8 x 8 each, their
# surround black: 64-byte tiles in the screen's order (assets.py packs them further)
digits = bytearray()
for n in range(10):
    dx, dy = 63 + (n % 5) * 8, (n // 5) * 8
    idxblk = bar_idx[dy:dy + 8, dx:dx + 8]
    img = bar_rgb[idxblk].copy()
    for bg in BAR_BG:
        img[idxblk == bg] = BAR_BLACK
    col = dither(img, np.ones((8, 8), bool), full=True)
    pk = packcol(col)
    for crow in range(2):
        for cx in range(4):
            for ra in range(8):
                digits.append(int(pk[crow * 8 + ra, cx]))

# ----------------------------------------------------------------------------
# The title pack from tit.png: the logo (80 x 26), YOU (38 x 13), WIN (39 x 13), LOSE
# (45 x 13) and eight frames of the big Cleo (26 x 31), every piece full-res.
# ----------------------------------------------------------------------------
def rect_image(idx, rgb, tr, x, y, w, h, full, opaque=False):
    """A w x h rectangle of an indexed image dithered and packed, padded to an even width:
    (W byte columns, lines, h, the bytes column-major, the col entries).  With opaque the
    transparent key is black and every pixel is drawn."""
    W = (w + 1) // 2
    im = np.full((h, W * 2), tr, dtype=idx.dtype)
    im[:, :w] = idx[y:y + h, x:x + w]
    alpha = np.ones(im.shape, bool) if opaque else (im != tr)
    src = rgb[im].copy()
    if opaque:
        src[im == tr] = 0
    col = dither(src, alpha, full=full)
    pk = encode_sprite(col, packcol(col), blanks=False)
    data = bytearray()
    for c in range(W):
        data += pk[:, c].tobytes()
    return W, (2 * h if full else h), h, data, col

# (name, W, char rows, the bytes in the screen's order)
title_pieces = []
pieces = [('logo', 0, 0, 80, 26, True), ('you', 0, 58, 38, 13, True), ('win', 38, 58, 39, 13, True), ('lose', 0, 71, 45, 13, True)]
# the big Cleo's frames: 3 a row from (0, 85), 26 x 31 each; full-res like everything else
# (a half-res image dithers per line, and looked it).  The sheet's ninth frame is never
# shown: not built
for f in range(8):
    pieces.append(('cleo%d' % f, (f % 3) * 26, 85 + (f // 3) * 32, 26, 31, True))
tpreview = []
for (name, x, y, w, h, full) in pieces:
    # every piece is drawn opaque: the menus draw on black, and a transparent pixel is black
    # already (rect_image's col is 0 there), so no mask is built
    W, lines, hpx, data, col = rect_image(tit_idx, tit_rgb, tit_tr, x, y, w, h, full, opaque=True)
    # char rows: the last one's lines past the piece are 0
    rows = (lines + 7) // 8
    scr = bytearray()
    # the screen's order: a char row, each column's eight lines in turn
    for r in range(rows):
        for c in range(W):
            for l in range(8):
                ln = r * 8 + l
                scr.append(data[c * lines + ln] if ln < lines else 0)
    title_pieces.append((name, W, rows, bytes(scr)))
    tpreview.append(col)


# the menus' run-length stream (menu.s unpack; assets.inc RLE_*): a byte n < RLE_RUN is n+1
# literals; RLE_RUN..RLE_END-1 a run of n - RLE_RUNBIAS copies of the next byte (3..129);
# RLE_END the end
RLE_RUN, RLE_RUNBIAS, RLE_END = 0x80, 0x7D, 0xFF


def title_rle(b):
    """Run-length encode bytes b for menu.s unpack: runs of 3..129 as (RLE_RUNBIAS + run,
    byte), literals in blocks of up to RLE_RUN, RLE_END last."""
    out, lit, i = bytearray(), bytearray(), 0
    def flush():
        """Write the pending literals, RLE_RUN a block at most."""
        while lit:
            k = lit[:RLE_RUN]
            out.append(len(k) - 1)
            out.extend(k)
            del lit[:RLE_RUN]
    while i < len(b):
        j = i
        while j < len(b) and b[j] == b[i] and j - i < RLE_END - RLE_RUNBIAS - 1:
            j += 1
        if j - i >= RLE_RUN - RLE_RUNBIAS:
            flush()
            out += bytes([j - i + RLE_RUNBIAS, b[i]])
            i = j
        else:
            lit.append(b[i])
            i += 1
    flush()
    out.append(RLE_END)
    return bytes(out)


def title_unrle(s):
    """Decode title_rle's stream (a check of the encoder)."""
    out, i = bytearray(), 0
    while s[i] != RLE_END:
        n = s[i]
        if n < RLE_RUN:
            out += s[i + 1:i + 2 + n]
            i += n + 2
        else:
            out += bytes([s[i + 1]]) * (n - RLE_RUNBIAS)
            i += 2
    return bytes(out)


title_streams = [title_rle(p[3]) for p in title_pieces]
for p, t in zip(title_pieces, title_streams):
    assert title_unrle(t) == p[3], p[0]
print('title pieces: %d bytes as %d' % (sum(len(p[3]) for p in title_pieces), sum(len(t) for t in title_streams)))
# (always 0 of 0: encode_sprite tags nothing)
print('sprite blank runs: %d tagged bytes of %d' % (encode_sprite.blank_runs, encode_sprite.cells))

# ----------------------------------------------------------------------------
# previews
# ----------------------------------------------------------------------------
def save_preview(cols, path, cols_per_row=16, scale=2):
    """Save a sheet of col arrays ((lines, w) each) as a PNG: cells of the largest size in
    rows of cols_per_row on grey, a col entry rendered 2 x 1 (a game px is twice as wide as
    a scanline is tall), the whole scaled."""
    cellw = max(c.shape[1] for c in cols)
    cellh = max(c.shape[0] for c in cols)
    rows = (len(cols) + cols_per_row - 1) // cols_per_row
    canvas = np.zeros((rows * (cellh + 2), cols_per_row * (cellw + 1), 3), dtype=np.uint8) + 60
    for i, c in enumerate(cols):
        r, cc = divmod(i, cols_per_row)
        rgb = col_to_rgb(c)
        canvas[r * (cellh + 2):r * (cellh + 2) + c.shape[0], cc * (cellw + 1):cc * (cellw + 1) + c.shape[1]] = rgb
    img = Image.fromarray(canvas)
    img = img.resize((img.width * 2 * scale, img.height * scale), Image.NEAREST)
    img.save(path)

save_preview(tile_preview, os.path.join(OUT, 'preview_tiles.png'), 32, 2)
# a half-res image (none, FULLRES being every sprite) would be doubled to two lines
save_preview([np.repeat(c, 2, axis=0) if not images[i][1] else c for i, c in enumerate(preview)],
             os.path.join(OUT, 'preview_sprites.png'), 12, 2)
save_preview([np.repeat(c, 2, axis=0) if not p[5] else c for c, p in zip(tpreview, pieces)],
             os.path.join(OUT, 'preview_title.png'), 4, 2)
save_preview([barcol], os.path.join(OUT, 'preview_bar.png'), 1, 3)

def render_map(L, x0, y0, wt, ht):
    """A parsed level's map from tile (x0, y0), wt by ht tiles, as col entries (16 ht lines
    by 8 wt), each tile's compact image."""
    m = L['map']
    out = np.zeros((ht * 16, wt * 8), dtype=np.uint8)
    for ty in range(ht):
        for tx in range(wt):
            t = int(m[y0 + ty, x0 + tx])
            out[ty * 16:ty * 16 + 16, tx * 8:tx * 8 + 8] = tile_preview[orig2compact[t]]
    return out
# the top left 40 x 30 tiles of the first two main maps
L0 = levels[(0, 0)]
save_preview([render_map(L0, 0, 0, 40, 30)], os.path.join(OUT, 'preview_level0.png'), 1, 2)
L1 = levels[(1, 0)]
save_preview([render_map(L1, 0, 0, 40, 30)], os.path.join(OUT, 'preview_level1.png'), 1, 2)
json.dump({'special': special, 'compact': compact}, open(os.path.join(OUT, 'meta.json'), 'w'))
print('done')
