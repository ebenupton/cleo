#!/usr/bin/env python3
"""Convert the Cleo J2ME assets into BBC MODE 1 data files.

Outputs (in build/):
  SPR      bank 4 image: sprite table, font, bar, digits, sprite data, sfx
  TIL0     bank 5 image: compact tiles 0..255
  TIL1     bank 6 image: compact tiles 256..
  ALT      altitude classes + table (bank 7 @ &A900)
  L<n>A/B  level packs: map (bank 6), then header, objects, attr and alt class
           by tile id (bank 7 @ &8000)
  TITLE    title pack (bank 6 @ &8900, over the map): logo, you/win/lose, big cleo
  preview PNGs for eyeballing the dither
"""
import struct, sys, os, json
from PIL import Image
import numpy as np

SRC = os.path.join(os.path.dirname(__file__), '..', '..', 'v500')
OUT = os.path.join(os.path.dirname(__file__), '..', 'build')
os.makedirs(OUT, exist_ok=True)

BEEB_RGB = np.array([[0, 0, 0], [255, 0, 0], [0, 255, 0], [255, 255, 0],
                     [0, 0, 255], [255, 0, 255], [0, 255, 255], [255, 255, 255]], dtype=np.uint8)


def load_indexed(name):
    im = Image.open(os.path.join(SRC, name))
    pal = im.getpalette()
    tr = im.info.get('transparency', None)
    idx = np.array(im)
    rgb = np.array(pal, dtype=np.uint8).reshape(-1, 3)
    return idx, rgb, tr

# ---------------------------------------------------------------------------
# The dither.
GAMMA = 1.35   # compromise: pure sRGB thresholding is too bright, linear too dark

# MODE 1: 80 bytes a row, a byte = 2 game px, 4 colours and 4 dots a byte, so a game
# pixel is a 2x2 block of dots, each one of C, M, Y or K (logical 1, 2, 3, 0).  The 2x2
# kernel IS the pixel: per pixel the ink counts nearest its colour are chosen, then laid
# in kernel order.  A col entry is one game px on one scanline: (left dot << 2) | right
# dot, so 0 is black -- and also transparent, which is why the sprites are opaque boxes
# drawn by the copy blitters, and why no tile or sprite byte may carry a tag: every bit
# is a pixel.
_CMYK_RGB = np.array([[0, 0, 0], [0, 1, 1], [1, 0, 1], [1, 1, 0]], np.float32)   # K C M Y
def _cmyk_tables():
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
    h, w, _ = rgb_img.shape
    v = (rgb_img.astype(np.float32) / 255.0) ** GAMMA
    crgb, seq = _CMYK[4]                               # always the 4-dot combinations:
    d = ((v[:, :, None, :] - crgb[None, None, :, :]) ** 2).sum(axis=3)   # a 2-dot pick
    dots = seq[d.argmin(axis=2)]                       # sent skin to M+Y (pink) on the
    # kernel positions 0 (top left) 1 (bottom right) 2 (top right) 3 (bottom left):
    # two inks of two make a checker, not stripes
    l0 = (dots[:, :, 0] << 2) | dots[:, :, 2]          # bar's Cleo and the title pieces
    l1 = (dots[:, :, 3] << 2) | dots[:, :, 1]
    if full:
        col = np.empty((2 * h, w), np.uint8)
        col[0::2] = l0
        col[1::2] = l1
        alpha = np.repeat(alpha, 2, axis=0)
    else:                                              # one line a pixel: a row shows the
        yy = ((np.arange(h) + y0) & 1)[:, None]        # top or bottom half of its pattern
        col = np.where(yy == 0, l0, l1).astype(np.uint8)
    return np.where(alpha, col, 0).astype(np.uint8)


def packcol(col):
    """col: (lines, w) dot pairs (w even). Returns (lines, w//2) screen bytes: dot i's
    colour bit 1 in bit 7-i, bit 0 in bit 3-i."""
    lines, w = col.shape
    assert w % 2 == 0
    a = col[:, 0::2].astype(np.uint16)
    b = col[:, 1::2].astype(np.uint16)
    dots = (a >> 2, a & 3, b >> 2, b & 3)
    out = np.zeros(a.shape, np.uint16)
    for i, d in enumerate(dots):
        out |= (((d >> 1) & 1) << (7 - i)) | ((d & 1) << (3 - i))
    return out.astype(np.uint8)


CYAN_COL = 5                      # a col entry that is all cyan
OPAQUE_BLACK = 0                  # a col entry of forced black



def encode_sprite(col, packed, blanks=True):
    """The sprite bytes as the blitters want them: every bit is a pixel, so the packed
    bytes go as they are (col: (lines, 2W) indices, 0 = transparent)."""
    return packed


encode_sprite.blank_runs = 0
encode_sprite.cells = 0


def col_to_rgb(col):
    c = _CMYK_RGB[col >> 2] + _CMYK_RGB[col & 3]      # the mean of the two dots
    return (c * 127.5).astype(np.uint8)


# ----------------------------------------------------------------------------
# Tiles
# ----------------------------------------------------------------------------
LEVELSKIP = [2115, 2119, 2108, 2129, 2104, 2128, 2118, 2134]


def parse_level(lv, sub):
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
    return dict(lw=lw, lh=lh, w=w, h=h, map=m, start=(sx, sy), exit=(ex, ey), objs=objs)


# PARALLAX=1: level 0's sand dunes become sky, for the parallax experiments (the engine
# draws its own background into the sky under -D PARALLAX).  A dune is a region of
# sand-only tiles (the two faces and the sky-edge silhouettes) that the sky can reach
# in the rows above the ground band; the row bound keeps the flood out of the pits,
# whose sand walls are the same tiles.
PARALLAX = os.environ.get('PARALLAX', '0') == '1'
_DUNE_SKY = (136, 238, 255)
_DUNE_SAND = {(255, 204, 85), (187, 119, 51), (221, 170, 85)}
_DUNE_MAXROW = 22
_DUNE_SKYTILE = 4                    # a pure-sky tile
def strip_dunes(m):
    from collections import deque
    tidx, trgb, _ = load_indexed('til.png')
    def kind(t):
        c = {tuple(int(v) for v in trgb[i]) for i in np.unique(tidx[t * 8:t * 8 + 8])}
        return 'sky' if c == {_DUNE_SKY} else 'sand' if c <= _DUNE_SAND | {_DUNE_SKY} else 'other'
    kinds = {int(t): kind(int(t)) for t in np.unique(m) if t >= 0}
    h, w = m.shape
    seen = np.zeros((h, w), bool)
    q = deque()
    for y in range(h):
        for x in range(w):
            if m[y, x] >= 0 and kinds[int(m[y, x])] == 'sky':
                seen[y, x] = True
                q.append((y, x))
    m = m.copy()
    n = 0
    while q:
        y, x = q.popleft()
        for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
            if (0 <= ny <= min(h - 1, _DUNE_MAXROW) and 0 <= nx < w and not seen[ny, nx]
                    and m[ny, nx] >= 0 and kinds[int(m[ny, nx])] == 'sand'):
                seen[ny, nx] = True
                m[ny, nx] = _DUNE_SKYTILE
                n += 1
                q.append((ny, nx))
    print('PARALLAX: %d dune cells -> sky' % n)
    return m

levels = {}
used = set()
for lv in range(8):
    for sub in (0, 1):
        L = parse_level(lv, sub)
        if PARALLAX and lv == 0:
            L['map'] = strip_dunes(L['map'])
        levels[(lv, sub)] = L
        used |= set(int(t) for t in np.unique(L['map']))
used |= set(range(366, 374))   # vanishing block animation
used |= set(range(426, 430))   # random flower variants
used.discard(-1)
compact = sorted(used)
orig2compact = {t: i for i, t in enumerate(compact)}
print('compact tiles:', len(compact))

til_idx, til_rgb0, _ = load_indexed('til.png')

# ----------------------------------------------------------------------------
# Tile source-colour overrides.  Keyed by the source RGB in til.png:
#   TIL_SOLID   source colour -> a solid colour, no dither  (0 blk 1 red
#               2 grn 3 yel 4 blu 5 mag 6 cyn 7 wht)
#   TIL_NOBLACK source colour -> the colour that replaces BLACK in its dither
#               (kills black speckle in wall/ground textures; 3 yellow, 7 white)
# Edit these tables to tune the look.
# ----------------------------------------------------------------------------
TIL_SOLID = {
    (136, 238, 255): 6,          # sky -> cyan
}
TIL_NOBLACK = {
    # (85, 68, 68): 3,   # example: this wall brown's black dither -> yellow
}
#   TIL_RECOLOR source colour -> a new source colour (still dithered normally): a
#               hand-tune of the palette before the dither picks its inks
TIL_RECOLOR = {
    (187, 119, 51): (221, 162, 68),   # dark (left) dune sand: halfway up to the light
                                      # (255,204,85) face, so the shadow side is brighter
}
til_rgb = til_rgb0.copy()
# hand-painted tile overrides from the tile editor (tools/tile_editor.py):
#   { original_tile_id: 16x8 colour array }.  These replace the auto dither.
TILE_EDITS = {}
_edits_path = os.path.join(os.path.dirname(__file__), '..', 'tile_edits.json')
if os.path.exists(_edits_path):
    TILE_EDITS = {int(k): np.array(v, np.uint8) for k, v in json.load(open(_edits_path)).items()}
TIL_PATTERN = {}                 # source colour -> fn(x, line): a hand-laid pattern in place of the dither
noblack_idx = {}                 # palette index -> replacement colour
pattern_idx = {}                 # palette index -> pattern function
for _i, _c in enumerate(til_rgb0):
    _t = tuple(int(v) for v in _c)
    if _t in TIL_SOLID:
        til_rgb[_i] = BEEB_RGB[TIL_SOLID[_t]]      # dithers to that solid colour
    elif _t in TIL_RECOLOR:
        til_rgb[_i] = np.array(TIL_RECOLOR[_t], np.uint8)
    if _t in TIL_NOBLACK:
        noblack_idx[_i] = TIL_NOBLACK[_t]
    if _t in TIL_PATTERN:
        pattern_idx[_i] = TIL_PATTERN[_t]

tile_preview = []
for cid, orig in enumerate(compact):
    sidx = til_idx[orig * 8:orig * 8 + 8, :]
    img = til_rgb[sidx]
    col = dither(img, np.ones((8, 8), bool), full=True)   # (16, 8)
    if noblack_idx:                                # replace black for flagged colours
        nb = np.full(sidx.shape, -1, np.int32)
        for _pi, _rc in noblack_idx.items():
            nb[sidx == _pi] = _rc
        nb16 = np.repeat(nb, 2, axis=0)
        col = np.where((col == 8) & (nb16 >= 0), nb16.astype(col.dtype), col)
    for _pi, _fn in pattern_idx.items():           # hand-laid pattern per source colour
        for yy, xx in zip(*np.nonzero(sidx == _pi)):
            col[2 * yy, xx] = _fn(int(xx), 2 * int(yy))
            col[2 * yy + 1, xx] = _fn(int(xx), 2 * int(yy) + 1)
    if orig in TILE_EDITS:
        col = TILE_EDITS[orig]                     # hand-painted override
    tile_preview.append(col)

# ----------------------------------------------------------------------------
# Background blackening.  The dark dithery backdrops of the tombs (and a few
# outdoor walls) become solid black: it looks better than the noise, it makes
# most of those tiles constant-fill for drawrow, and it lets the star boxes be
# composited on black.
#
# What counts as background comes from the collision data, not from taste:
# alt[tile*8+col] >> 4 is the surface row of that pixel column (8 = no ground),
# so everything above the surface is backdrop.  A tile's backdrop is blackened
# when at least DARK_BG of its backdrop pixels come from 'wall-ish' source
# colours (near-black, or dark and desaturated); palm trunks, foliage and the
# like are saturated and survive.  PIXEL_TILES are art on a wall backdrop (the
# EXIT letters, the flower) and are cleaned pixel by pixel instead.
# ----------------------------------------------------------------------------
DARK_BG = 0.8
alt = open(os.path.join(SRC, 'alt'), 'rb').read()

def bg_mask(orig):
    m = np.zeros((16, 8), bool)
    for c in range(8):
        hi = alt[orig * 8 + c] >> 4
        m[:min(hi, 8) * 2, c] = True
    return m

def _wallish(rgb):
    r, g, b = (int(v) for v in rgb)
    mx, mn = max(r, g, b), min(r, g, b)
    sat = 0 if mx == 0 else (mx - mn) / mx
    return mx <= 40 or (sat <= 0.4 and mx <= 140)

wall_pal = np.array([_wallish(c) for c in til_rgb0])
for _o in (70, 71, 102):        # speckle families with bright highlight dots
    for _v in np.unique(til_idx[_o * 8:_o * 8 + 8, :]):
        wall_pal[int(_v)] = True
PIXEL_TILES = {32, 33, 402, 403, 434, 435}   # EXIT letters; flower head and stem
WALL_TILES = {297}                           # lone floating block the colour rule misses

blackened = {}                  # compact id -> tile image with its backdrop black
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

# Wall texture is occasionally used as foreground filler (the feet of ramps):
# blackening those cells would punch a hole in the level.  They are found by
# their neighbourhood (a non-solid backdrop tile boxed in by solid ones) and
# given a twin compact tile that keeps its texture -- same image as before,
# same collision, so nothing about the level changes but the look.
def _solid(orig):
    return any((alt[orig * 8 + c] >> 4) < 8 for c in range(8))

hole_cells = {}                 # (lv, sub) -> {(y, x): orig}
twin_of = {}                    # orig -> compact id of the texture-keeping twin
for (lv, sub), L in levels.items():
    m = L['map']
    h, w = m.shape
    cells = {}
    for y in range(1, h - 1):
        for x in range(1, w - 1):
            o = int(m[y, x])
            if o < 0 or orig2compact[o] not in blackened or _solid(o) \
                    or o in PIXEL_TILES:
                continue
            nb = [int(m[y + 1, x]), int(m[y, x - 1]), int(m[y, x + 1])]
            if sum(_solid(n) for n in nb if n >= 0) >= 3 - 0 and \
                    sum(_solid(n) for n in nb if n >= 0) >= 3:
                cells[(y, x)] = o
    if cells:
        hole_cells[(lv, sub)] = cells
        for o in set(cells.values()):
            twin_of.setdefault(o, None)
for o in sorted(twin_of):
    twin_of[o] = len(compact)
    compact.append(o)                       # same original id: same alt class
    tile_preview.append(tile_preview[orig2compact[o]].copy())   # unblackened
for cid, rep in blackened.items():
    tile_preview[cid] = rep
print('blackened %d tiles; %d texture-keeping twins for %d filler cells'
      % (len(blackened), len(twin_of),
         sum(len(c) for c in hole_cells.values())))

tiles_bytes = []
for cid in range(len(compact)):
    b = packcol(tile_preview[cid])   # (16, 4)
    # Beeb layout: char row 0 (lines 0-7): chars 0..3 each 8 bytes ; then char row 1
    data = bytearray()
    for crow in range(2):
        for cx in range(4):
            for ra in range(8):
                data.append(int(b[crow * 8 + ra, cx]))
    assert len(data) == 64
    tiles_bytes.append(bytes(data))

# star backgrounds: a star whose 2x2 tile neighbourhood is all sky (solid cyan) or all
# 'dark' (mostly black: noisy low-intensity indoor backgrounds count) is drawn as a
# pre-composited box sprite that needs neither masking nor erasing (see the sprite section)
tile_class = []
# solid tiles (the sky, and pure black) are filled by drawrow with a constant instead of
# being copied: flagged in the page-table entry (hi bit 6 = solid, lo bit 4 = cyan)
tile_solid = {}
for cid, col in enumerate(tile_preview):
    if np.all(col == CYAN_COL):
        tile_solid[cid] = 1
    elif np.all(col == 0):
        tile_solid[cid] = 2
# a star is drawn as a pre-composited box only where its whole 2x2 tile
# neighbourhood is exactly one colour, so the box's background matches the map
# byte for byte: solid cyan (sky) or solid black (a blackened tomb backdrop)
for cid in range(len(tile_preview)):
    tile_class.append(tile_solid.get(cid, 0))
BOX_BLACK = True                   # blackened backdrops make star-on-black exact
def star_class(cm, x, y):
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
star_stats = {}

# ---------------------------------------------------------------------------
# A box star is drawn as an opaque rectangle with its background baked in, so
# anything that passes through it gets painted over.  Stars an enemy can reach
# therefore keep the ordinary masked sprite -- which is also what leaves the
# rest of them safe to skip redrawing between frames.
#
# The margin is each type's own drawn rectangle, taken from the art, plus the
# distance it can travel.  Motion, from level_init's per-type setup and the ob_*
# handlers (all in pixels; the object's x,y are tiles):
#   1 trampoline   static          2 snake    patrols x .. x+8*e0
#   3 cobra        rises 4 tiles   5,6 walker patrols x .. x+8*e0
#   4 bat          hovers in x .. x+8*e0, y .. y+8*e1.  It steers towards Cleo, but
#                  its position is never stored back: process_object re-reads the home
#                  position every frame and ob_bat draws at ox + fc/2, oy + fd/2 with
#                  fc clamped to [0, e0*16] and fd to [0, e1*16].  So it stays in its
#                  own rectangle however far the player runs.  Plus the batoff wobble.
#   7,9,10,12      static;  11 vanish animates as tiles, not a sprite
TYPE_IDS = {1: (43, 45), 2: (46, 53), 3: (54, 60), 4: (61, 66), 5: (67, 75),
            6: (76, 84), 7: (85, 92), 9: (93, 96), 10: (97, 97), 12: (100, 102)}

def _sprite_boxes():
    """id -> (dx0, dx1, dy0, dy1): the drawn rectangle about the reference point."""
    idx, _rgb, tr = load_indexed('spr.png')
    dim = open(os.path.join(SRC, 'dim'), 'rb').read()
    out = {}
    for i in range(103):
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
TYPE_BOX = {}
for _t, (_lo, _hi) in TYPE_IDS.items():
    _b = [_SPRBOX[i] for i in range(_lo, _hi + 1) if i in _SPRBOX]
    TYPE_BOX[_t] = (min(b[0] for b in _b), max(b[1] for b in _b),
                    min(b[2] for b in _b), max(b[3] for b in _b)) if _b else (0, 0, 0, 0)
STAR_BOX = (-6, 8, -8, 4)          # the box star's rectangle, from box_geom/BOX_H
print('enemy margins about the reference point (px):',
      ' '.join('t%d=%d..%d,%d..%d' % ((t,) + TYPE_BOX[t]) for t in sorted(TYPE_BOX)))

def enemy_reach(objs):
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
    sx0, sx1, sy0, sy1 = (8 * x + STAR_BOX[0], 8 * x + STAR_BOX[1],
                          8 * y + STAR_BOX[2], 8 * y + STAR_BOX[3])
    for (x0, x1, y0, y1) in reach:
        if x0 < sx1 and sx0 < x1 and y0 < sy1 and sy0 < y1:
            return True
    return False

# A trampoline whose whole drawn rectangle sits on solid black can be drawn the same
# way a star box is: opaque, its black background baked in, no mask and no erase.
def box_reachable(box, x, y, reach, skip=None):
    sx0, sx1, sy0, sy1 = 8 * x + box[0], 8 * x + box[1], 8 * y + box[2], 8 * y + box[3]
    for r in reach:
        if skip is not None and r == skip:
            continue
        x0, x1, y0, y1 = r
        if x0 < sx1 and sx0 < x1 and y0 < sy1 and sy0 < y1:
            return True
    return False

def tramp_class(cm, x, y):           # 1 = its rectangle is all solid black (bakeable)
    h, w = cm.shape
    dx0, dx1, dy0, dy1 = TYPE_BOX[1]
    for ty in range((8 * y + dy0) // 8, (8 * y + dy1 - 1) // 8 + 1):
        for tx in range((8 * x + dx0) // 8, (8 * x + dx1 - 1) // 8 + 1):
            if not (0 <= tx < w and 0 <= ty < h) or tile_class[int(cm[ty, tx])] != 2:
                return 0
    return 1

# ---------------------------------------------------------------------------
# Renumber so that every tile carrying pixel data comes first.  A solid tile is
# filled by drawrow from a constant and its 64 bytes are never read, so it needs
# no room in a tile bank: giving those tiles ids above 255 puts the whole game's
# tile data in bank 5 alone, and bank 6 keeps only the box stars.  Sorting is
# stable within each group, so runs like the vanish animation stay contiguous.
# ---------------------------------------------------------------------------
# the vanish and flower animations must stay contiguous, so a solid frame inside
# one of those runs keeps its place in the data group and wastes its 64 bytes
_keep = {orig2compact[o] for o in list(range(366, 374)) + list(range(426, 430))
         if o in orig2compact}
_order = sorted(range(len(compact)), key=lambda c: (c in tile_solid and c not in _keep, c))
_newid = [0] * len(compact)
for _new, _old in enumerate(_order):
    _newid[_old] = _new
NDATA = sum(1 for c in range(len(compact)) if c not in tile_solid or c in _keep)
assert NDATA <= 512, 'tiles with data (%d) no longer fit two banks' % NDATA
compact = [compact[o] for o in _order]
tile_preview = [tile_preview[o] for o in _order]
tiles_bytes = [tiles_bytes[o] for o in _order]
tile_class = [tile_class[o] for o in _order]
tile_solid = {_newid[c]: v for c, v in tile_solid.items()}
orig2compact = {t: _newid[c] for t, c in orig2compact.items()}
twin_of = {t: _newid[c] for t, c in twin_of.items()}
print('tiles: %d with data, %d solid' % (NDATA, len(compact) - NDATA))
# tiles are ordered by original id; but put the 'special' animation tiles in known places:
# we just record their compact ids for the game code
special = {name: orig2compact[t] for name, t in [('VANISH0', 366), ('FLOWER0', 426)]}
# ensure vanish anim 366..373 and flower 426..429 are contiguous in compact numbering
assert all(orig2compact[366 + i] == special['VANISH0'] + i for i in range(8))
assert all(orig2compact[426 + i] == special['FLOWER0'] + i for i in range(4))

# only the tiles with data are emitted: the solid ones sort above them and their
# page-table entries address bytes that are never read
# push-tiles (conveyor) and kill tiles: getPush / lava
push_tiles = {}
for t, v in [(412, -1), (413, -1), (414, 1), (415, 1), (423, -2), (424, 2), (439, 0), (440, 0), (441, 0), (442, 0)]:
    if t in orig2compact:
        push_tiles[orig2compact[t]] = v
kill_tiles = [orig2compact[t] for t in (101, 336) if t in orig2compact]

# alt (read above, for the background masks)
classes = {}
alt_class = []
for orig in compact:
    row = alt[orig * 8:orig * 8 + 8]
    if row not in classes:
        classes[row] = len(classes)
    alt_class.append(classes[row])
print('alt classes:', len(classes))
# the class table is global; alt_class itself is indexed by tile id, which is now
# local to a level, so each level pack carries its own copy
altfile = b''.join(sorted(classes, key=lambda r: classes[r]))
open(os.path.join(OUT, 'ALT'), 'wb').write(altfile)

# ----------------------------------------------------------------------------
# Level packs
# ----------------------------------------------------------------------------
BANK_TILES = 5                       # every tile is in this bank now
rng = np.random.RandomState(1234)
level_tiles = []
level_split = {}                     # level -> sectors of map (the bank-6 piece)
def name_of(lv, sub):
    return 'L%d%s' % (lv, 'B' if sub == 0 else 'A')

# ----------------------------------------------------------------------------
# The maps, as compact tile ids.  A level's map bytes are its OWN tile ids (pack_tiles,
# below); 254 and 255 are the two solid fills (cyan sky, black), which own no bytes in
# the tile bank.  Every solid tile in the game reduces to one of those two -- they all
# have altitude class 0 and differ only in colour -- so the whole 47-tile solid set
# costs two ids.
# ----------------------------------------------------------------------------
SOLID_CYAN, SOLID_BLACK = 254, 255   # reserved ids, identical in both sets
maps = {}
for (lv, sub), L in levels.items():
    m = L['map'].copy()
    fl = (m == 427)                  # the original randomises tile 427 at level start
    m[fl] = 426 + rng.randint(0, 4, size=int(fl.sum()))
    cm = np.vectorize(lambda t: orig2compact[t])(m)
    for (hy, hx), ho in hole_cells.get((lv, sub), {}).items():
        cm[hy, hx] = twin_of[ho]     # keep the wall texture at ramp feet
    maps[(lv, sub)] = cm

SETNAME = ['O', 'I']                 # outdoors, indoors
def tileset_of(lv, sub):
    return lv & 1

_want = [set(), set()]
for (lv, sub), cm in maps.items():
    s = _want[tileset_of(lv, sub)]
    s.update(int(x) for x in np.unique(cm))
    if any(o[0] == 11 for o in levels[(lv, sub)]['objs']):
        s.update(special['VANISH0'] + i for i in range(8))

# Isolated black cells read as holes punched in the foreground.  A hole is black
# that is NOT part of the backdrop: a 4-connected component of solid-black cells of
# at most four cells (1x1 up to 2x2) that touches neither the map edge nor any other
# black -- so a black cell under the black sky beside a doorway is backdrop, not a
# hole, however textured its floor neighbours are.  Each hole is filled with the
# majority tile among the component's textured neighbours; on a tie, the neighbour
# whose art is nearest the hole's own (so a doorframe never wins over a wall).  Keyed
# on the solid-black set.
def _tile_mean(c):
    o = [oo for oo, cc in orig2compact.items() if cc == c]
    return til_rgb0[til_idx[o[0] * 8:o[0] * 8 + 8, :]].reshape(-1, 3).mean(0) if o else np.zeros(3)
for (lv, sub), cm in maps.items():
    h, w = cm.shape
    black = np.vectorize(lambda c: tile_solid.get(int(c)) == 2)(cm)
    tex = lambda c: int(c) not in tile_solid
    seen = np.zeros_like(black)
    fills = []
    for y in range(h):
        for x in range(w):
            if not black[y, x] or seen[y, x]:
                continue
            comp, stack, edge = [], [(y, x)], False
            seen[y, x] = True
            while stack and len(comp) <= 4:
                cy, cx = stack.pop(); comp.append((cy, cx))
                for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
                    ny, nx = cy + dy, cx + dx
                    if not (0 <= ny < h and 0 <= nx < w):
                        edge = True; continue
                    if black[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True; stack.append((ny, nx))
            if stack or len(comp) > 4 or edge:
                for cy, cx in stack: pass                  # (the rest is marked as visited on the way)
                while stack:
                    cy, cx = stack.pop()
                    for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
                        ny, nx = cy + dy, cx + dx
                        if 0 <= ny < h and 0 <= nx < w and black[ny, nx] and not seen[ny, nx]:
                            seen[ny, nx] = True; stack.append((ny, nx))
                continue
            nb = []
            for cy, cx in comp:
                for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
                    ny, nx = cy + dy, cx + dx
                    if (ny, nx) not in comp and tex(cm[ny, nx]):
                        nb.append(int(cm[ny, nx]))
            if not nb:
                continue
            top = max(nb.count(c) for c in set(nb))
            cands = [c for c in set(nb) if nb.count(c) == top]
            me = _tile_mean(int(cm[comp[0][0], comp[0][1]]))
            pick = min(cands, key=lambda c: float(np.sum((_tile_mean(c) - me) ** 2)))
            for cy, cx in comp:
                fills.append((cx, cy, pick))
    for (x, y, c) in fills:
        cm[y, x] = c
    if fills:
        print('%s: filled %d isolated black cells (%d holes)' % (name_of(lv, sub), len(fills), len(set((x, y) for x, y, _ in fills))))

# ----------------------------------------------------------------------------
# The tiles of a level, for both targets (modelb/tools/assets.py calls pack_tiles
# too).  A map byte is a LEVEL tile id; the level's tiles are gathered at load time
# from its set's files into the tile bank, 64 bytes a slot, so a tile's address is
# arithmetic (drawrect's gather).  Ids:
#   0 .. NTILES-1        full tiles, slot = id
#   half0 .. mir0-1      half tiles: one char row stored (32 bytes, from HALFPAGE),
#                        the other a fill or the same row again; three runs --
#                        top row fills (to half1), bottom row fills (to half2), both
#                        rows the stored one
#   mir0 .. mir0+NMIR-1  a full tile drawn mirrored left-right from the slot in
#                        MIRTAB: only as many as the bank needs, the least used first
#   FLAT0 .. 253         flat tiles: two bytes alternating down every char (FLATTAB)
#   254, 255             the solids, cyan and black (FLATTAB's last two pairs)
# The mirror is exact: the dither is per game pixel with no position term, so a
# game pixel's 2x2 dots move as a unit -- reverse the chars and swap the byte's
# two pixels, ((b & $33) << 2) | ((b & $CC) >> 2).
# ----------------------------------------------------------------------------
FLAT0 = 250
NFLAT = SOLID_CYAN - FLAT0          # 4 flats a level at most, then the two solids
MAXMIR = 24
TILE_CHUNK = 256                    # tiles in a set file: 16K, what either target stages
def mirror_byte(b):
    return ((b & 0x33) << 2) | ((b & 0xCC) >> 2)
def mirror_tile(t):
    t = bytes(t)
    return bytes(mirror_byte(t[cr * 32 + (3 - c) * 8 + l]) for cr in range(2) for c in range(4) for l in range(8))
# the set files: every distinct tile the set's levels use, those the most levels
# use first, so a level rarely needs a set's second file
_setpat = []                        # per set: pattern bytes -> (chunk, index)
_nlev = {}
for (lv, sub), cm in maps.items():
    g = tileset_of(lv, sub)
    for c in set(int(x) for x in np.unique(cm)):
        if c not in tile_solid:
            b = bytes(tiles_bytes[c])
            _nlev[(g, b)] = _nlev.get((g, b), 0) + 1
SETFILES = []
for g in (0, 1):
    pats = {}
    for c in sorted(_want[g]):
        if c not in tile_solid:
            pats.setdefault(bytes(tiles_bytes[c]), c)
    order = sorted(pats, key=lambda b: (-_nlev.get((g, b), 0), pats[b]))
    _setpat.append({b: (i // TILE_CHUNK, i % TILE_CHUNK) for i, b in enumerate(order)})
    nch = (len(order) + TILE_CHUNK - 1) // TILE_CHUNK
    assert nch <= 2
    for k in range(2):
        data = b''.join(order[k * TILE_CHUNK:(k + 1) * TILE_CHUNK])
        open(os.path.join(OUT, 'TILES%s%d' % (SETNAME[g], k)), 'wb').write(data or bytes(64))
    SETFILES.append(nch)
    print('tile set %s: %d distinct tiles, %d file(s)' % (SETNAME[g], len(order), nch))

def attr_of(c):
    a = 3
    if c in push_tiles:
        a = push_tiles[c] + 3
    if c in kill_tiles:
        a |= 0x80
    return a
def _flat_pair_row(row):            # a char row (4 chars) of one 2-byte dither
    cs = [bytes(row[k * 8:k * 8 + 8]) for k in range(4)]
    if all(x == cs[0] for x in cs) and all(cs[0][i] == cs[0][i & 1] for i in range(8)):
        return cs[0][:2]
    return None

# The ids are the same on both targets, so the two run the same logic on the same
# level: they are laid out for the Model B's tile bank, the smaller.  The Master's is
# big enough for every level as it stands, so it stores a mirrored id's tile as a full
# tile of its own, and its gather is a table (LV_PAGE0) its loader builds: per id, the
# pair the Model B's gather computes -- the same encoding, so the one row loop reads
# both.
B_TILES, B_TILES_END = 0x8100, 0xB620       # the Model B's bank 5: tiles to its row loop
M_TILES, M_TILES_END = 0x8000, 0xC000       # the Master's: all of bank 5
def _layout(stored, hlist, halfpair, base, end, loc):
    slot = {k: i for i, k in enumerate(stored)}
    NT, NHALF = len(stored), len(hlist)
    HALFPAGE = base + ((NT * 64) & ~255)
    HALFOFF = ((NT * 64) & 255) // 32
    assert HALFPAGE + (HALFOFF + NHALF) * 32 + len(halfpair) <= end, ('tiles do not fit', NT, NHALF)
    chunks = [loc(k)[0] for k in stored]
    nfiles = max(chunks + [loc(h[0])[0] for h in hlist] + [0]) + 1     # the files to stage
    return dict(slot=slot, NT=NT, HALFPAGE=HALFPAGE, HALFOFF=HALFOFF,
                tiles=bytes([nfiles] + [chunks.count(j) for j in range(nfiles)]) + bytes(loc(k)[1] for k in stored))

def pack_tiles(lv, sub):
    """The level's tile ids, and for each target the lists that gather its tiles."""
    cm = maps[(lv, sub)]
    g = tileset_of(lv, sub)
    specials = [special['VANISH0'] + i for i in range(8)] + [special['FLOWER0'] + i for i in range(4)]
    vals, cnt = np.unique(cm, return_counts=True)
    usage = {int(v): int(n) for v, n in zip(vals, cnt)}
    live = set(usage) | (set(specials) & _want[g])
    local = {}
    for c in live:
        if c in tile_solid:
            local[c] = SOLID_CYAN if tile_solid[c] == 1 else SOLID_BLACK
    # identical tiles share an id -- identical to the logic too, which reads a tile's
    # attribute and altitude class by id
    keyof = lambda c: (bytes(tiles_bytes[c]), attr_of(c), alt_class[c])
    groups = {}
    for c in sorted(live):
        if c not in tile_solid:
            groups.setdefault(keyof(c), []).append(c)
    use = {k: sum(usage.get(c, 0) for c in cs) for k, cs in groups.items()}
    flats, halves, fulls = [], {'top': [], 'bot': [], 'pair': []}, []
    for k in groups:
        t = k[0]
        a, b = _flat_pair_row(t[:32]), _flat_pair_row(t[32:])
        if a is not None and a == b:
            flats.append((k, a))
        elif a is not None and b is None:
            halves['top'].append((k, 1, a))         # the top row fills: the bottom stored
        elif b is not None and a is None:
            halves['bot'].append((k, 0, b))
        elif t[:32] == t[32:]:
            halves['pair'].append((k, 0, b'\0\0'))
        else:
            fulls.append(k)
    pat = _setpat[g]
    loc = lambda k: pat[k[0]]
    for v in halves.values():
        v.sort(key=lambda h: loc(h[0]))
    hlist = halves['top'] + halves['bot'] + halves['pair']
    halfpair = b''.join(h[2] for h in hlist)
    assert len(flats) <= NFLAT, (lv, sub, len(flats))
    # mirrors: only while the Model B's bank is short, the least used first; a
    # mirror's source stays a stored tile
    need = lambda nt: B_TILES + nt * 64 + len(hlist) * 32 + len(halfpair) > B_TILES_END
    bypat = {}
    for k in fulls:
        bypat.setdefault(k[0], []).append(k)
    mirrored = {}                   # key -> its source key
    cand = sorted((k for k in fulls if mirror_tile(k[0]) != k[0] and mirror_tile(k[0]) in bypat),
                  key=lambda k: (use[k], loc(k)))
    for k in cand:
        if not need(len(fulls) - len(mirrored)):
            break
        if k in mirrored.values():
            continue
        srcs = [x for x in bypat[mirror_tile(k[0])] if x not in mirrored]
        if srcs:
            mirrored[k] = srcs[0]
    assert len(mirrored) <= MAXMIR
    stored = sorted((k for k in fulls if k not in mirrored), key=loc)
    mirs = sorted(mirrored, key=lambda k: loc(mirrored[k]))
    NT, NHALF, NMIR = len(stored), len(hlist), len(mirs)
    idof = {k: i for i, k in enumerate(stored)}
    half0 = NT
    half1 = half0 + len(halves['top'])
    half2 = half1 + len(halves['bot'])
    for i, h in enumerate(hlist):
        idof[h[0]] = half0 + i
    mir0 = half0 + NHALF
    for i, k in enumerate(mirs):
        idof[k] = mir0 + i
    assert mir0 + NMIR <= FLAT0, (lv, sub, mir0 + NMIR)
    for i, (k, fp) in enumerate(flats):
        idof[k] = FLAT0 + i
    for k, cs in groups.items():
        for c in cs:
            local[c] = idof[k]
    flattab = b''.join(fp for k, fp in flats).ljust(2 * NFLAT, b'\0') + bytes([0x0F, 0x0F, 0x00, 0x00])
    halflist = b''.join(bytes([loc(h[0])[1], h[1] | loc(h[0])[0] << 1]) for h in hlist)
    lw = 8 - levels[(lv, sub)]['lw']
    # the Model B: the stored tiles at slot = id, a mirror by its source's slot
    B = _layout(stored, hlist, halfpair, B_TILES, B_TILES_END, loc)
    assert all(B['slot'][k] == idof[k] for k in stored)
    B['hdr'] = bytes([g, NT, lw, NHALF, half0, half1, half2, B['HALFPAGE'] >> 8, B['HALFOFF'], mir0, NMIR, 0])
    B['mir'] = bytes(B['slot'][mirrored[k]] for k in mirs)
    # the Master: the same slots, then a copy of each mirrored tile as a full tile of
    # its own (by a list of its own: file index, file); load_tiles builds LV_PAGE0
    NS = NT + NMIR
    M = dict(NT=NS, HALFPAGE=M_TILES + ((NS * 64) & ~255), HALFOFF=((NS * 64) & 255) // 32)
    assert M['HALFPAGE'] + (M['HALFOFF'] + NHALF) * 32 + len(halfpair) <= M_TILES_END
    chunks = [loc(k)[0] for k in stored]
    nfiles = max(chunks + [loc(k)[0] for k in mirs] + [loc(h[0])[0] for h in hlist] + [0]) + 1
    M['tiles'] = bytes([nfiles] + [chunks.count(j) for j in range(nfiles)]) + bytes(loc(k)[1] for k in stored)
    M['mirs'] = b''.join(bytes([loc(k)[1], loc(k)[0]]) for k in mirs)
    M['hdr'] = bytes([g, NT, lw, NHALF, half0, half1, half2, M['HALFPAGE'] >> 8, M['HALFOFF'], mir0, NMIR, 0])
    return dict(local=local, B=B, M=M, flat=flattab, halves=halflist, hpair=halfpair,
                ntiles=NT, nhalf=NHALF, nmir=NMIR, nflat=len(flats), usage=usage)

for (lv, sub), L in levels.items():
    cm = maps[(lv, sub)]
    gset = tileset_of(lv, sub)
    T = pack_tiles(lv, sub)
    local = T['local']               # compact id -> level tile id, solids included
    lut = np.zeros(len(compact), dtype=np.uint8)
    for _c, _t in local.items():
        lut[_c] = _t
    mapbytes = lut[cm]
    used = set(int(x) for x in np.unique(mapbytes))
    level_tiles.append((name_of(lv, sub), len(used), 0))
    # A level is loaded in two pieces: the game logic has bank 7 (inherited from the
    # Model B, which had no HAZEL), and the map is the only thing big enough to make
    # the room for it.
    #   bank 6, from $8700:  the tile list (256: the file count, each file's count,
    #                        each stored tile's index in its file), the half list, the
    #                        halves' fill pairs and the mirror copies' list (256), the
    #                        map at $8900 (row-major)
    #   bank 7, from $8000:  header (256: the fixed fields, FLATTAB at +32), objects
    #                        (1024), attr by tile id (256), alt class by tile id (256)
    name = name_of(lv, sub)
    assert len(T['M']['tiles']) <= 256 and len(T['halves']) + len(T['hpair']) + len(T['M']['mirs']) <= 256
    packm = (T['M']['tiles'].ljust(0x100, b'\0')
             + (T['halves'] + T['hpair'] + T['M']['mirs']).ljust(0x100, b'\0') + mapbytes.tobytes())
    pack = bytearray()
    hdr = bytearray()
    hdr += bytes([L['lw'], L['lh'], L['start'][0], L['start'][1], L['exit'][0], L['exit'][1], len(L['objs']), 1])
    for cid in [special['VANISH0'] + i for i in range(8)] + [special['FLOWER0'] + i for i in range(4)]:
        hdr.append(local.get(cid, 255))            # plain tile ids, so one table not two
    assert len(hdr) == 20
    hdr += T['M']['hdr']                           # +20..+31: the tiles' shape
    hdr += T['flat']                               # +32: FLATTAB
    pack += hdr.ljust(0x100, b'\0')                # bank 7 $8000
    objs = bytearray()
    reach = enemy_reach(L['objs'])
    for (t, x, y, extra) in L['objs']:
        e = (extra + [0, 0, 0])[:3]
        if t == 0:
            e[0] = star_class(cm, x, y)
            # e1 = "an enemy can reach me".  Draw order keeps the picture right either
            # way (box stars go down first, so anything sharing their space lands on
            # top), so this does not change the sprite -- it marks the stars whose
            # pixels can be disturbed, and so may not be left alone between frames.
            e[1] = 1 if star_reachable(x, y, reach) else 0
            star_stats.setdefault((lv, sub), [0, 0, 0, 0])[3] += e[1] if e[0] else 0
            star_stats.setdefault((lv, sub), [0, 0, 0, 0])[e[0]] += 1
        elif t == 1:                              # trampoline: same box treatment
            e[0] = tramp_class(cm, x, y)
            b = TYPE_BOX[1]
            selfbox = (8 * x + b[0], 8 * x + b[1], 8 * y + b[2], 8 * y + b[3])
            e[1] = 1 if box_reachable(b, x, y, reach, skip=selfbox) else 0
        objs += bytes([t, x, y] + e)
    pack += objs.ljust(0x400, b'\0')              # bank 7 $8100
    attr = bytearray(256)                          # bank 7 $8500: attr by tile id
    acls = bytearray(256)                          # bank 7 $8600: alt class by tile id
    for c in sorted(local):
        t = local[c]
        attr[t] = attr_of(c)
        acls[t] = 0 if c in tile_solid else alt_class[c]
    pack += attr
    pack += acls
    assert len(pack) == 0x700
    open(os.path.join(OUT, name), 'wb').write(packm + pack)
    level_split[name] = len(packm) // 256
    print(name, 'ids', len(used), 'tiles %d+%d half+%d mirror+%d flat' % (T['ntiles'], T['nhalf'], T['nmir'], T['nflat']),
          'objs', len(L['objs']), 'map', len(packm), 'tables', len(pack))

print('levels want at most %d tiles (%s)' % max((d, n) for n, d, s in level_tiles))

# ----------------------------------------------------------------------------
# Sprites
# ----------------------------------------------------------------------------
spr_idx, spr_rgb, spr_tr = load_indexed('spr.png')
dim = open(os.path.join(SRC, 'dim'), 'rb').read()
DIM = [struct.unpack('BBBBbb', dim[i * 6:i * 6 + 6]) for i in range(103)]
FULLRES = set(range(103))          # every sprite full-res (2 stored rows per game px)
SKIP = {102}                       # BONUS LEVEL banner is drawn as text instead
crops = []
for i, (x, y, w, h, rx, ry) in enumerate(DIM):
    im = spr_idx[y:y + h, x:x + w]
    mask = im != spr_tr
    ys, xs = np.where(mask)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    crops.append((im[y0:y1, x0:x1], rx - x0, ry - y0))

images = []   # list of (idx array, full)
entry = []    # per logical sprite: (image index, mirror, refx, refy)
for i in range(103):
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
for i in range(34, 40):
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

# Bank 4 layout (sprite table moved to main RAM; ANDY 4K holds the overflow):
#   FONT $8000 (320)  DIGITS $8140 (640)  BAR $83C0 (1280)  sprite data from $88C0..$C000
SPR_DIGITS = 0x8140
SPR_BAR    = 0x83C0
SPR_DATA   = 0x8000               # the mask planes need the room: the font, digits and
                                  # bar spans go to bank 6 behind the box stars (below)
SPR_ANDY   = 0x8000                     # ANDY 4K RAM, paged at $8000 with ROMSEL bit7
BANK4_END  = 0xC000
ANDY_END   = 0x9000

# pack each unique image (column-major bytes); assign to bank4 or ANDY
#
# An odd-width image leaves one transparent pixel of padding, and it can sit at either
# end: both give the same ceil(w/2) columns, but they pair art columns into bytes
# differently.  A byte with both pixels opaque is a straight store (and can join a RUN);
# a byte with one opaque pixel goes through MASKTAB/ORTAB -- read, mask, or, store.  So
# the phase that leaves fewer half-opaque bytes is strictly cheaper to blit, for nothing.
# x0 cancels the shift in the dither so every art pixel keeps the phase it had.
img_bytes = []
img_wbytes = []
img_shift = []
preview = []

def _pack(im, full, shift):
    h, w = im.shape
    W = (w + 1) // 2
    padded = np.full((h, W * 2), spr_tr, dtype=im.dtype)
    padded[:, shift:shift + w] = im
    col = dither(spr_rgb[padded], padded != spr_tr, x0=(-shift) & 1, full=full)
    return col, encode_sprite(col, packcol(col))  # (lines, W): see encode_sprite

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


def mask_plane(alpha):
    """A sprite mask: one bit per game pixel, 1 = opaque.  A data byte's two pixels
    are a 2-bit pair (left in bit 1), four horizontally adjacent columns pack into one
    byte (column 4g+j in bits 7-2j, 6-2j), and the plane is column-group-major: for
    group g, h consecutive bytes, one per pixel row -- the shape of the data itself, so
    the blitter's mask pointer walks exactly like its data pointer."""
    h, w2 = alpha.shape
    W = w2 // 2
    pair = (alpha[:, 0::2].astype(np.uint8) << 1) | alpha[:, 1::2].astype(np.uint8)   # (h, W)
    out = bytearray()
    for g in range((W + 3) // 4):
        for r in range(h):
            b = 0
            for j in range(4):
                c = 4 * g + j
                if c < W:
                    b |= int(pair[r, c]) << (6 - 2 * j)
            out.append(b)
    return bytes(out)

img_mask = []
for (im, full, src), shift in zip(images, img_shift):
    h, w = im.shape
    W = (w + 1) // 2
    padded = np.full((h, W * 2), spr_tr, dtype=im.dtype)
    padded[:, shift:shift + w] = im
    img_mask.append(mask_plane(padded != spr_tr))

# greedy assignment: fill bank4 data region first (largest sprites there), rest to ANDY
order = sorted(range(len(images)), key=lambda j: -len(img_bytes[j]))
img_addr = [None] * len(images)         # (base_addr, region: 0 bank 4, 1 ANDY, 2 bank 6)
b4 = SPR_DATA
an = SPR_ANDY
SPILL_BASE, SPILL_END = 0xBE00, 0xC000  # a few small images (with their
b6 = SPILL_BASE                          # masks) in bank 6 above the HUD blobs, flag bit 4
data_end = BANK4_END - sum(len(m) for m in img_mask)   # the masks take the top
for j in order:
    n = len(img_bytes[j])
    if b4 + n <= data_end:
        img_addr[j] = (b4, 0); b4 += n
    elif an + n <= ANDY_END:
        img_addr[j] = (an, 1); an += n
    elif b6 + n + len(img_mask[j]) <= SPILL_END:
        img_addr[j] = (b6, 2); b6 += n + len(img_mask[j])
    else:
        raise SystemExit('sprite data overflow: no room for image %d (%d bytes)' % (j, n))
n_andy = sum(1 for a in img_addr if a[1])
print('sprite images', len(images),
      'bank4 data %d/%d bytes' % (b4 - SPR_DATA, BANK4_END - SPR_DATA),
      'ANDY %d/%d bytes' % (an - SPR_ANDY, ANDY_END - SPR_ANDY),
      '(%d imgs in ANDY)' % n_andy)
mask_addr = [None] * len(images)
for j in range(len(images)):
    n = len(img_mask[j])
    if img_addr[j][1] == 2:                       # bank 6 spill: mask right after its data
        mask_addr[j] = img_addr[j][0] + len(img_bytes[j])
        continue
    if b4 + n > BANK4_END:
        raise SystemExit('mask plane overflow: no room for image %d (%d bytes, %d over)'
                         % (j, n, b4 + n - BANK4_END))
    assert not img_addr[j][1] or b4 >= 0x9000, j    # ANDY sprite: mask above ANDY's window
    mask_addr[j] = b4
    b4 += n
print('mask planes %d bytes; bank 4 %d/%d used; %d images (%d bytes) spilled to bank 6 $BE00'
      % (sum(len(m) for m in img_mask), b4 - 0x8000, 0x4000, sum(1 for a in img_addr if a[1] == 2), b6 - SPILL_BASE))

# box stars: each spin frame (34..39) composited over cyan and over black in a box just
# wide enough to cover its own art AND the previous frame's, so drawing frame N erases
# frame N-1 with no mask and no erase pass.  The frames are all 24 lines tall but the
# spin narrows to a sliver, so the narrow ones carry a narrower box.  Stored after the
# tiles in bank 6 (flag bit4), drawn with the copy blitter (flag bit3).
BOX_H = 12                      # game px (24 lines)
FIELD = 14                      # px: the widest frame, hotspot at px 6
box_art = []
box_alpha = []
for f in range(6):
    j, mirror, rx, ry = entry[34 + f]
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

# The mask is the art's alpha, not "col != 0": black star pixels -- the whole dark
# outline -- are part of the star.  The copy blitter copies the field verbatim, so
# black as colour 0 in it is simply black.
_boxmask = lambda f: box_alpha[f]
def _span(f):                   # opaque pixel range of one frame, in field px
    col, x0 = box_art[f]
    xs = np.where(_boxmask(f).any(axis=0))[0]
    return x0 + int(xs.min()), x0 + int(xs.max())

# Every box has to be able to erase whatever the record holds, and the record is the
# same buffer's previous draw, two renders back.  main.s runs exactly one logic step
# per render, fa advances every second step and the spin frame is fa >> 1, so two
# renders move the animation by at most one frame and a box need only cover its own
# art and its predecessor's.  If logic catch-up ever comes back this has to go back to
# the union of all six: catching up ran two or three steps per render, the animation
# could skip a frame, and the narrow boxes then left the previous one on screen.
def _boxgeom(f):
    p = (f - 1) % 6
    lo = min(_span(f)[0], _span(p)[0]) // 2
    hi = max(_span(f)[1], _span(p)[1]) // 2
    return lo, hi - lo + 1
box_geom = [_boxgeom(f) for f in range(6)]
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

# trampoline black boxes: the three bounce frames (43,44,45) composited over black,
# same scheme as the star boxes but one background.  8 px tall, ~24 px wide; the
# hotspot is TRAMP_HOT px in so every frame lines up, and each frame's box covers it
# and the frame that can precede it (the cycle is 43->44->45->43, or a static 43).
TRAMP_IDS = [43, 44, 45]
TRAMP_H = 8
TRAMP_FIELD = 26
TRAMP_HOT = 16
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

_tmask = lambda f: tramp_alpha[f]          # alpha, as the box stars (see there)
def _tspan(f):
    col, x0 = tramp_art[f]
    xs = np.where(_tmask(f).any(axis=0))[0]
    return x0 + int(xs.min()), x0 + int(xs.max())

def _tboxgeom(f):
    p = (f - 1) % 3
    lo = min(_tspan(f)[0], _tspan(p)[0]) // 2
    hi = max(_tspan(f)[1], _tspan(p)[1]) // 2
    return lo, hi - lo + 1

tramp_geom = [_tboxgeom(f) for f in range(3)]
tramp_bytes = []
for f in range(3):
    col, x0 = tramp_art[f]
    lo, Wc = tramp_geom[f]
    field = np.zeros((TRAMP_H * 2, TRAMP_FIELD), np.uint8)   # black background
    field[:, x0:x0 + col.shape[1]] = np.where(_tmask(f), col, field[:, x0:x0 + col.shape[1]])
    packed = packcol(field[:, 2 * lo:2 * (lo + Wc)])
    b = bytearray()
    for c in range(Wc):
        b += packed[:, c].tobytes()
    tramp_bytes.append(bytes(b))
print('trampoline black boxes: widths', [w for _l, w in tramp_geom],
      '= %d bytes' % sum(len(b) for b in tramp_bytes))

allbox_bytes = box_bytes + tramp_bytes
BOX_BASE = 0xB000                  # bank 6, above anything a level's tiles can reach
assert BOX_BASE + sum(len(b) for b in allbox_bytes) <= 0xC000
print('box stars at $%04X in bank 6; classes per level:' % BOX_BASE,
      ' '.join('L%d%s=%s' % (lv, 'B' if sub == 0 else 'A', '/'.join(map(str, v))) for (lv, sub), v in sorted(star_stats.items())),
      '(regular/cyan/black, and how many boxes an enemy can reach)')

# sprite table: 8 bytes each: ptr lo, ptr hi, W, H(game px), refx, refy, flags, lines
# flags: bit0 mirror, bit1 full (always set now), bit2 data in ANDY, bit3 copy blitter,
# bit4 data in bank 6 (box stars 103..114)
table = bytearray()
for i in range(103):
    e = entry[i]
    if e is None:
        table += bytes(8); continue
    j, mirror, rx, ry = e
    im, full, src = images[j]
    h, w = im.shape
    W = img_wbytes[j]
    rx += img_shift[j]              # refx is a field coordinate, and the art may be
    if mirror:                      # one pixel in from the left edge of the field
        rx = (2 * W - 1) - rx
    if i < 27:
        # Cleo anchors the camera, which is computed before she moves and rounded down
        # to an even pixel (clamp_window's `and #$FE`), so her column on screen is
        # floor((step + 80 + (px & 1) - refx) / 2).  That only stays put while she runs
        # at an odd number of pixels a step -- which is every speed except 2 -- if refx
        # is odd; with an even one she jitters a character left and right every step.
        # Mirroring flips the parity, which is why one direction looked smooth and the
        # other did not.  A one-pixel shift of the art is the price; rounding down keeps
        # the mirrored pairs closer to symmetric than rounding up (25 px against 43).
        if not rx & 1:
            rx -= 1
    ptr, region = img_addr[j]
    flags = (1 if mirror else 0) | 2 | (4 if region == 1 else 0) | (0x10 if region == 2 else 0)
    lines = 2 * h
    table += bytes([ptr & 255, ptr >> 8, W, h, rx & 255, ry & 255, flags, lines])
_off = 0
for k in range(12):                                # 103..108 cyan, 109..114 black
    _lo, _wc = box_geom[k % 6]
    ptr = BOX_BASE + _off
    _off += len(box_bytes[k])
    # refx: the hotspot sits at field px 6, the box starts at field px 2*lo
    table += bytes([ptr & 255, ptr >> 8, _wc, BOX_H, (6 - 2 * _lo) & 255, 8,
                    2 | 8 | 16, BOX_H * 2])
for f in range(3):                                 # 115..117: trampoline black boxes
    _lo, _wc = tramp_geom[f]
    ptr = BOX_BASE + _off
    _off += len(tramp_bytes[f])
    table += bytes([ptr & 255, ptr >> 8, _wc, TRAMP_H, (TRAMP_HOT - 2 * _lo) & 255,
                    (-8) & 255, 2 | 8 | 16, TRAMP_H * 2])

# font: 40 glyphs 8x8 at tit.png y=26.., 10 per row -> 1 bit per pixel
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

# bar: solid blue (8 game px tall), 1px cyan top border, 1px black bottom
# separator, icons keyed onto the blue.
bar_idx, bar_rgb, _ = load_indexed('bar.png')
BAR_BLUE = np.array([0, 0, 255], np.uint8)
BAR_CYAN = np.array([0, 255, 255], np.uint8)
BAR_BLACK = np.array([0, 0, 0], np.uint8)
BAR_BG = {0, 1, 5, 6, 7, 8, 9, 13}      # brick/blue/grey background indices in bar.png
# The bar is composited at native half-game-pixel (16-scanline) resolution so the
# ordered dither operates per scanline, exactly like the playfield.  Each icon is a
# game sprite region placed into bar16; icons that fit (<=8 game px) go in native
# (one game px = two scanlines) with an optional half-pixel (1-scanline) offset,
# taller ones are resampled onto the 16-line grid (LANCZOS) rather than to 8-then-doubled.
bar16 = np.zeros((16, 160, 3), np.uint8)
bar16[:] = BAR_BLACK
def bar_icon(dstx, spr_id, y0=0, crop_h=None, crop_w=None, sub_scan=0, fit=False):
    im = crops[spr_id][0][y0:]
    if crop_h:
        im = im[:crop_h]
    if crop_w:
        im = im[:, :crop_w]
    h, w = im.shape
    if fit:
        # resample the whole crop onto the 16-scanline grid (proper dithering, no
        # game-px doubling); width kept to true aspect (a game px is 1 line x 2 scanlines)
        tw = max(1, int(round(w * 16 / float(2 * h))))
        rgba = np.dstack([spr_rgb[im].astype(np.uint8), (im != spr_tr).astype(np.uint8) * 255]).astype(np.uint8)
        arr = np.array(Image.fromarray(rgba, 'RGBA').resize((tw, 16), Image.LANCZOS))
        for s in range(16):
            for xx in range(tw):
                if dstx + xx < 160 and arr[s, xx, 3] > 96:
                    bar16[s, dstx + xx] = arr[s, xx, :3]
    else:
        # native: one game px -> two scanlines, top-aligned, clipped to the 16 lines
        for k in range(min(h, 8)):
            rgb = spr_rgb[im[k]]; op = im[k] != spr_tr
            for s in (2 * k + sub_scan, 2 * k + sub_scan + 1):
                if 0 <= s < 16:
                    for xx in range(w):
                        if dstx + xx < 160 and op[xx]:
                            bar16[s, dstx + xx] = rgb[xx]
bar_icon(3, 0, y0=4, crop_h=8, crop_w=14)             # cleo head: native, two game px up
bar_icon(31, 97, fit=True)                            # heart: resampled onto the 16-line grid
bar_icon(59, 34, fit=True)                            # star: resampled onto the 16-line grid (full star fits)
barcol = dither(bar16, np.ones((16, 160), bool), full=False)   # 16 lines x 160
barpk = packcol(barcol)     # 16 x 80
barbytes = bytearray()
for crow in range(2):
    for cx in range(80):
        for ra in range(8):
            barbytes.append(int(barpk[crow * 8 + ra, cx]))
# digits 0..9 from bar.png at (63 + n%5*8, n//5*8), 8x8 -> 64-byte tiles
digits = bytearray()
for n in range(10):
    dx, dy = 63 + (n % 5) * 8, (n // 5) * 8
    idxblk = bar_idx[dy:dy + 8, dx:dx + 8]
    img = bar_rgb[idxblk].copy()
    for bg in BAR_BG:
        img[idxblk == bg] = BAR_BLACK        # drop the blue/brick surround -> black
    col = dither(img, np.ones((8, 8), bool), full=True)
    pk = packcol(col)
    for crow in range(2):
        for cx in range(4):
            for ra in range(8):
                digits.append(int(pk[crow * 8 + ra, cx]))

bank4 = bytearray(16384)
andy = bytearray(4096)
spill = bytearray(SPILL_END - SPILL_BASE)
# The bar is a black background (opaque black = $C0) with a few icon spans, so store it
# as span records (offset16, len, bytes...) ended by $FFFF, not the full 1280 bytes --
# bar_bg fills black and lays the spans, freeing the rest of the region for sprite code.
BARFILL = 0                       # what 'black' packs to
barspans = bytearray()
i = 0
while i < len(barbytes):
    if barbytes[i] != BARFILL:
        j = i
        while j < len(barbytes) and barbytes[j] != BARFILL:
            j += 1
        barspans += bytes([i & 0xFF, i >> 8, j - i]) + barbytes[i:j]
        i = j
    else:
        i += 1
barspans += bytes([0xFF, 0xFF])
print('bar: %d span bytes vs %d raw (%d free in bank 4)'
      % (len(barspans), len(barbytes), len(barbytes) - len(barspans)))

# bank 6, in the box-star file, behind the boxes: the HUD's digits and the bar.  The
# menus' font is a file of its own, FONT, assembled into bank 7 beside the menu code
# (menu.s font_art), so the text drawer reads it in place.
boxfile = b''.join(allbox_bytes)
open(os.path.join(OUT, 'FONT'), 'wb').write(font)
SPR_DIGITS = BOX_BASE + len(boxfile); boxfile += digits
SPR_BAR = BOX_BASE + len(boxfile); boxfile += barspans
HUD_BANK = 6
assert BOX_BASE + len(boxfile) <= SPILL_BASE, len(boxfile)
if b6 > SPILL_BASE:                           # spilled images at $BE00: pad up to them
    boxfile = boxfile.ljust(SPILL_BASE - BOX_BASE, b'\0') + bytes(spill[:b6 - SPILL_BASE])
open(os.path.join(OUT, 'BOX'), 'wb').write(boxfile)
for j in range(len(images)):
    base, region = img_addr[j]
    if region == 1:
        andy[base - SPR_ANDY:base - SPR_ANDY + len(img_bytes[j])] = img_bytes[j]
    elif region == 2:
        spill[base - SPILL_BASE:base - SPILL_BASE + len(img_bytes[j])] = img_bytes[j]
        spill[mask_addr[j] - SPILL_BASE:mask_addr[j] - SPILL_BASE + len(img_mask[j])] = img_mask[j]
    else:
        bank4[base - 0x8000:base - 0x8000 + len(img_bytes[j])] = img_bytes[j]
    if region != 2:
        m = mask_addr[j]
        bank4[m - 0x8000:m - 0x8000 + len(img_mask[j])] = img_mask[j]
sprmask = bytearray()
for i in range(103 + 15):                         # box ids draw by copy: no mask
    a = mask_addr[entry[i][0]] if i < 103 and entry[i] is not None else 0
    sprmask += bytes([a & 255, a >> 8])
open(os.path.join(OUT, 'SPRMASK'), 'wb').write(sprmask)
open(os.path.join(OUT, 'SPR'), 'wb').write(bank4)
# ANDY 4K sprite overflow (loaded with ROMSEL bit7 set)
an_used = max((b - SPR_ANDY + len(img_bytes[j]) for j,(b,a) in enumerate(img_addr) if a), default=0)
open(os.path.join(OUT, 'SPRAND'), 'wb').write(andy[:((an_used + 255)//256)*256] if an_used else b'')
# sprite table -> main RAM (incbin'd into the CLEO binary)
open(os.path.join(OUT, 'SPRTAB'), 'wb').write(table)
print('sprite table %d bytes -> main; SPRAND %d bytes' % (len(table), an_used))

# ----------------------------------------------------------------------------
# Title pack: logo (80x26 full-res), YOU (38x13), WIN (39x13), LOSE (45x13), big cleo 9 frames (26x31 half-res)
# ----------------------------------------------------------------------------
def rect_image(idx, rgb, tr, x, y, w, h, full, opaque=False):
    W = (w + 1) // 2
    im = np.full((h, W * 2), tr, dtype=idx.dtype)
    im[:, :w] = idx[y:y + h, x:x + w]
    alpha = np.ones(im.shape, bool) if opaque else (im != tr)
    src = rgb[im].copy()
    if opaque:
        src[im == tr] = 0          # transparent key -> black
    col = dither(src, alpha, full=full)
    pk = encode_sprite(col, packcol(col), blanks=False)   # no blank-run tags: the
                                                   # half-res blitter cannot decode them
    data = bytearray()
    for c in range(W):
        data += pk[:, c].tobytes()
    mask = mask_plane(alpha) if not opaque else b''
    return W, (2 * h if full else h), h, data, col, mask

TITLE_ADDR = 0x8900               # bank 6, where the map and the box stars go during a level
title = bytearray()
tdir = []
pieces = [('logo', 0, 0, 80, 26, True), ('you', 0, 58, 38, 13, True), ('win', 38, 58, 39, 13, True), ('lose', 0, 71, 45, 13, True)]
for f in range(9):                  # full-res like everything else: a half-res image
    pieces.append(('cleo%d' % f, (f % 3) * 26, 85 + (f // 3) * 32, 26, 31, True))   # dithers per line, and looked it
tpreview = []
TDIR = 0xA0                       # a mask-address table at +$80, 2 bytes a piece, then the directory
for (name, x, y, w, h, full) in pieces:
    opaque = name.startswith('cleo')
    W, lines, hpx, data, col, mask = rect_image(tit_idx, tit_rgb, tit_tr, x, y, w, h, full, opaque=opaque)
    ptr = TITLE_ADDR + TDIR + len(title)
    title += data
    mptr = TITLE_ADDR + TDIR + len(title) if mask else 0
    title += mask
    flags = (2 if full else 0) | (8 if opaque else 0)   # opaque pieces copy
    tdir.append((name, ptr, W, hpx, lines, flags, mptr))
    tpreview.append(col)
# directory at &8000: 8 bytes per piece: ptr lo, hi, W, h, refx, refy (0: the prologue
# is the sprite one), flags, lines.  Mask addresses at +$80, two bytes a piece.
tdirbytes = bytearray()
for (name, ptr, W, hpx, lines, flags, mptr) in tdir:
    tdirbytes += bytes([ptr & 255, ptr >> 8, W, hpx, 0, 0, flags, lines])
tdirbytes = tdirbytes.ljust(0x80, b'\0')
for (name, ptr, W, hpx, lines, flags, mptr) in tdir:
    tdirbytes += bytes([mptr & 255, mptr >> 8])
titlefile = tdirbytes.ljust(TDIR, b'\0') + title
TITLE_END = 0xB800                # the title pack may overwrite the box stars (reloaded at
assert len(titlefile) <= TITLE_END - TITLE_ADDR, len(titlefile)   # level start), not the music
open(os.path.join(OUT, 'TITLE'), 'wb').write(titlefile)
print('title pack', len(titlefile))
print('sprite blank runs: %d tagged bytes of %d' % (encode_sprite.blank_runs, encode_sprite.cells))

# ----------------------------------------------------------------------------
# constants for the assembler
# ----------------------------------------------------------------------------
with open(os.path.join(OUT, 'assets.inc'), 'w') as f:
    f.write('; generated by convert.py\n')
    f.write('NTILES = %d\n' % len(compact))
    f.write('FLAT0 = %d\nNFLAT = %d\nMAXMIR = %d\n' % (FLAT0, NFLAT, MAXMIR))
    f.write('BOX_BASE = $%04X\n' % BOX_BASE)
    # the box stars are the last sprite ids, so "is this an opaque pre-composited
    # rectangle?" is a single compare rather than a range test on two ends
    f.write('SOLID_CYAN = %d\nSOLID_BLACK = %d\n' % (SOLID_CYAN, SOLID_BLACK))
    f.write('BOXID0 = %d\n' % 103)
    f.write('BOXN = %d\n' % 15)        # 12 star boxes + 3 trampoline boxes; the skip
                                        # aliases sit BOXN above, same picture, the logic
                                        # having decided nothing can disturb them
    f.write('TITLE_ADDR = $%04X\n' % TITLE_ADDR)
    for _n, _m in sorted(level_split.items()):
        f.write('LM_%s = %d\n' % (_n, _m))
    f.write('SPR_BAR = $%04X\nSPR_DIGITS = $%04X\nSPR_DATA = $%04X\nSPR_ANDY = $%04X\n' %
            (SPR_BAR, SPR_DIGITS, SPR_DATA, SPR_ANDY))
    for i, (name, ptr, W, hpx, lines, flags, mptr) in enumerate(tdir):
        f.write('TP_%s = %d\n' % (name.upper(), i))
    f.write('HUD_BANK = %d\n' % HUD_BANK)

# ----------------------------------------------------------------------------
# previews
# ----------------------------------------------------------------------------
def save_preview(cols, path, cols_per_row=16, scale=2):
    # each col array (lines, w); a col entry is one game px on one scanline -> render it 2x1
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
# sprites: expand half-res to 2 lines for preview
save_preview([np.repeat(c, 2, axis=0) if not images[i][1] else c for i, c in enumerate(preview)],
             os.path.join(OUT, 'preview_sprites.png'), 12, 2)
save_preview([np.repeat(c, 2, axis=0) if not p[5] else c for c, p in zip(tpreview, pieces)],
             os.path.join(OUT, 'preview_title.png'), 4, 2)
save_preview([barcol], os.path.join(OUT, 'preview_bar.png'), 1, 3)

# a level preview: render level 0 main map region around start using compact tiles
def render_map(L, x0, y0, wt, ht):
    m = L['map']
    out = np.zeros((ht * 16, wt * 8), dtype=np.uint8)
    for ty in range(ht):
        for tx in range(wt):
            t = int(m[y0 + ty, x0 + tx])
            out[ty * 16:ty * 16 + 16, tx * 8:tx * 8 + 8] = tile_preview[orig2compact[t]]
    return out
L0 = levels[(0, 0)]
save_preview([render_map(L0, 0, 0, 40, 30)], os.path.join(OUT, 'preview_level0.png'), 1, 2)
L1 = levels[(1, 0)]
save_preview([render_map(L1, 0, 0, 40, 30)], os.path.join(OUT, 'preview_level1.png'), 1, 2)
json.dump({'special': special, 'compact': compact}, open(os.path.join(OUT, 'meta.json'), 'w'))
print('done')
