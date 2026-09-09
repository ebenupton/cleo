#!/usr/bin/env python3
"""Convert the Cleo J2ME assets into BBC Master MODE 2 data files.

Outputs (in build/):
  SPR      bank 4 image: sprite table, font, bar, digits, sprite data, sfx
  TIL0     bank 5 image: compact tiles 0..255
  TIL1     bank 6 image: compact tiles 256..
  ALT      altitude classes + table (bank 7 @ &A900)
  L<n>A/B  level packs (bank 7 @ &8000): map, page tables, rowpage, header, objects
  TITLE    title pack (bank 7 @ &8000): logo, you/win/lose, big cleo frames
  preview PNGs for eyeballing the dither
"""
import struct, sys, os, json
from PIL import Image
import numpy as np

SRC = os.path.join(os.path.dirname(__file__), '..', '..', 'v500')
OUT = os.path.join(os.path.dirname(__file__), '..', 'build')
os.makedirs(OUT, exist_ok=True)

BAYER = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]], dtype=np.float32)
GAMMA = 1.35   # compromise: pure sRGB thresholding is too bright, linear too dark

BEEB_RGB = np.array([[0, 0, 0], [255, 0, 0], [0, 255, 0], [255, 255, 0],
                     [0, 0, 255], [255, 0, 255], [0, 255, 255], [255, 255, 255]], dtype=np.uint8)


def load_indexed(name):
    im = Image.open(os.path.join(SRC, name))
    pal = im.getpalette()
    tr = im.info.get('transparency', None)
    idx = np.array(im)
    rgb = np.array(pal, dtype=np.uint8).reshape(-1, 3)
    return idx, rgb, tr


def dither(rgb_img, alpha, x0=0, y0=0, full=True):
    """rgb_img: (h,w,3) uint8 ; alpha: (h,w) bool.
    Returns MODE 2 colour indices (h2, w) with h2 = 2h if full else h.
    Transparent -> 0, opaque black -> 8.  Ordered 4x4 Bayer dither per channel."""
    h, w, _ = rgb_img.shape
    v = (rgb_img.astype(np.float32) / 255.0) ** GAMMA
    if full:
        v = np.repeat(v, 2, axis=0)
        alpha = np.repeat(alpha, 2, axis=0)
    hh = v.shape[0]
    yy = (np.arange(hh) + y0) % 4
    xx = (np.arange(w) + x0) % 4
    thr = (BAYER[yy][:, xx] + 0.5) / 16.0
    bits = (v > thr[:, :, None]).astype(np.uint8)
    col = bits[:, :, 0] | (bits[:, :, 1] << 1) | (bits[:, :, 2] << 2)
    col = np.where(col == 0, 8, col).astype(np.uint8)
    col = np.where(alpha, col, 0).astype(np.uint8)
    return col


def pack_mode2(col):
    """col: (lines, w) colour indices (w even). Returns (lines, w//2) bytes."""
    lines, w = col.shape
    assert w % 2 == 0
    l = col[:, 0::2].astype(np.uint16)
    r = col[:, 1::2].astype(np.uint16)

    def spread(c, shift):
        # bit k of c -> bit (2k+shift)
        return (((c & 1) << shift) | (((c >> 1) & 1) << (2 + shift)) |
                (((c >> 2) & 1) << (4 + shift)) | (((c >> 3) & 1) << (6 + shift)))
    return (spread(l, 1) | spread(r, 0)).astype(np.uint8)


def col_to_rgb(col):
    rgb = BEEB_RGB[np.clip(col & 7, 0, 7)]
    rgb[col == 0] = [40, 40, 40]
    return rgb


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


levels = {}
used = set()
for lv in range(8):
    for sub in (0, 1):
        L = parse_level(lv, sub)
        levels[(lv, sub)] = L
        used |= set(int(t) for t in np.unique(L['map']))
used |= set(range(366, 374))   # vanishing block animation
used |= set(range(426, 430))   # random flower variants
used.discard(-1)
compact = sorted(used)
orig2compact = {t: i for i, t in enumerate(compact)}
print('compact tiles:', len(compact))

til_idx, til_rgb, _ = load_indexed('til.png')
tiles_mode2 = []
tile_preview = []
for cid, orig in enumerate(compact):
    img = til_rgb[til_idx[orig * 8:orig * 8 + 8, :]]
    col = dither(img, np.ones((8, 8), bool), full=True)   # (16, 8)
    tile_preview.append(col)
    b = pack_mode2(col)   # (16, 4)
    # Beeb layout: char row 0 (lines 0-7): chars 0..3 each 8 bytes ; then char row 1
    data = bytearray()
    for crow in range(2):
        for cx in range(4):
            for ra in range(8):
                data.append(int(b[crow * 8 + ra, cx]))
    assert len(data) == 64
    tiles_mode2.append(bytes(data))

# tiles are ordered by original id; but put the 'special' animation tiles in known places:
# we just record their compact ids for the game code
special = {name: orig2compact[t] for name, t in [('VANISH0', 366), ('FLOWER0', 426)]}
# ensure vanish anim 366..373 and flower 426..429 are contiguous in compact numbering
assert all(orig2compact[366 + i] == special['VANISH0'] + i for i in range(8))
assert all(orig2compact[426 + i] == special['FLOWER0'] + i for i in range(4))

bank5 = b''.join(tiles_mode2[:256])
bank6 = b''.join(tiles_mode2[256:])
open(os.path.join(OUT, 'TIL0'), 'wb').write(bank5.ljust(16384, b'\0'))
open(os.path.join(OUT, 'TIL1'), 'wb').write(bank6)
print('bank5 %d bank6 %d' % (len(bank5), len(bank6)))

# push-tiles (conveyor) and kill tiles: getPush / lava
push_tiles = {}
for t, v in [(412, -1), (413, -1), (414, 1), (415, 1), (423, -2), (424, 2), (439, 0), (440, 0), (441, 0), (442, 0)]:
    if t in orig2compact:
        push_tiles[orig2compact[t]] = v
kill_tiles = [orig2compact[t] for t in (101, 336) if t in orig2compact]

# alt
alt = open(os.path.join(SRC, 'alt'), 'rb').read()
classes = {}
alt_class = []
for orig in compact:
    row = alt[orig * 8:orig * 8 + 8]
    if row not in classes:
        classes[row] = len(classes)
    alt_class.append(classes[row])
print('alt classes:', len(classes))
altfile = bytes(alt_class).ljust(512, b'\0') + b''.join(sorted(classes, key=lambda r: classes[r]))
open(os.path.join(OUT, 'ALT'), 'wb').write(altfile)

# ----------------------------------------------------------------------------
# Level packs
# ----------------------------------------------------------------------------
def partition_rows(m, maxpages=2, extra=set()):
    """assign each map row to a page such that each page's tile set <= 256."""
    h = m.shape[0]
    rowsets = [set(int(t) for t in np.unique(m[r])) | extra for r in range(h)]
    pages = [set() for _ in range(maxpages)]
    rowpage = [0] * h
    # greedy: rows in order, choose the page with the largest overlap that still fits
    for r in range(h):
        best = None
        for p in range(maxpages):
            u = pages[p] | rowsets[r]
            if len(u) <= 256:
                score = len(pages[p] & rowsets[r]) - 0.001 * len(u)
                if best is None or score > best[0]:
                    best = (score, p)
        if best is None:
            return None
        rowpage[r] = best[1]
        pages[best[1]] |= rowsets[r]
    return rowpage, pages


rng = np.random.RandomState(1234)
for (lv, sub), L in levels.items():
    m = L['map'].copy()
    # flower variants: the original randomises tile 427 at level start; do it here
    fl = (m == 427)
    m[fl] = 426 + rng.randint(0, 4, size=int(fl.sum()))
    # levels with vanishing blocks need the animation tiles in every page
    if any(o[0] == 11 for o in L['objs']):
        m[0, :8] = [366 + i for i in range(8)] if False else m[0, :8]
    cm = np.vectorize(lambda t: orig2compact[t])(m)
    extra = set(special['VANISH0'] + i for i in range(8)) if any(o[0] == 11 for o in L['objs']) else set()
    res = partition_rows(cm, extra=extra)
    if res is None:
        res = partition_rows(cm, 4, extra=extra)
        assert res is not None, 'cannot partition level %d/%d' % (lv, sub)
    rowpage, pages = res
    npages = max(rowpage) + 1
    # per page: byte -> compact id
    tables = []
    mapbytes = np.zeros_like(cm, dtype=np.uint8)
    for p in range(npages):
        ids = sorted(pages[p])
        # put the vanish/flower animation tiles at fixed byte codes if present so the game
        # can write them: we handle this by giving the game code a per-page code table
        code = {cid: i for i, cid in enumerate(ids)}
        tables.append((ids, code))
    for r in range(cm.shape[0]):
        code = tables[rowpage[r]][1]
        for c in range(cm.shape[1]):
            mapbytes[r, c] = code[int(cm[r, c])]
    # game needs to know: byte codes for VANISH0..7 and FLOWER0..3 in each page (255 = absent)
    # pack layout (bank 7): $8000 page tables (2 x 512), $8400 rowpage, $8480 header,
    # $8500 objects, $8900 attr page0, $8A00 attr page1, $8B00 map (row-major)
    pack = bytearray()
    for p in range(2):
        lo = bytearray(256); bank = bytearray(256)
        if p < npages:
            for i, cid in enumerate(tables[p][0]):
                lo[i] = cid & 255
                bank[i] = 5 + (cid >> 8)
        pack += lo + bank
    pack += bytes(rowpage).ljust(128, b'\0')      # $8400
    hdr = bytearray()
    hdr += bytes([L['lw'], L['lh'], L['start'][0], L['start'][1], L['exit'][0], L['exit'][1], len(L['objs']), npages])
    for p in range(2):
        for cid in [special['VANISH0'] + i for i in range(8)] + [special['FLOWER0'] + i for i in range(4)]:
            hdr.append(tables[p][1].get(cid, 255) if p < npages else 255)
    pack += hdr.ljust(0x80, b'\0')                 # $8480
    objs = bytearray()
    for (t, x, y, extra) in L['objs']:
        e = (extra + [0, 0, 0])[:3]
        objs += bytes([t, x, y] + e)
    pack += objs.ljust(0x400, b'\0')              # $8500..$88FF
    for p in range(2):
        attr = bytearray(256)
        if p < npages:
            for i, cid in enumerate(tables[p][0]):
                a = 3
                if cid in push_tiles:
                    a = push_tiles[cid] + 3
                if cid in kill_tiles:
                    a |= 0x80
                attr[i] = a
        pack += attr                               # $8900 page0 attr, $8A00 page1 attr
    assert len(pack) == 0xB00
    pack += mapbytes.tobytes()                     # $8B00
    name = 'L%d%s' % (lv, 'B' if sub == 0 else 'A')
    open(os.path.join(OUT, name), 'wb').write(pack)
    print(name, 'pages', npages, [len(t[0]) for t in tables], 'objs', len(L['objs']), 'size', len(pack))

# ----------------------------------------------------------------------------
# Sprites
# ----------------------------------------------------------------------------
spr_idx, spr_rgb, spr_tr = load_indexed('spr.png')
dim = open(os.path.join(SRC, 'dim'), 'rb').read()
DIM = [struct.unpack('BBBBbb', dim[i * 6:i * 6 + 6]) for i in range(103)]
FULLRES = set(range(0, 27))        # player frames keep 2-line dither
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

sprite_data = bytearray()
img_off = []
img_wbytes = []
preview = []
for (im, full, src) in images:
    h, w = im.shape
    W = (w + 1) // 2
    padded = np.full((h, W * 2), spr_tr, dtype=im.dtype)
    padded[:, :w] = im
    alpha = padded != spr_tr
    rgb = spr_rgb[padded]
    col = dither(rgb, alpha, full=full)
    preview.append(col)
    packed = pack_mode2(col)            # (lines, W)
    img_off.append(len(sprite_data))
    img_wbytes.append(W)
    # column major
    for c in range(W):
        sprite_data += packed[:, c].tobytes()
print('sprite images', len(images), 'data bytes', len(sprite_data))

# sprite table: 8 bytes each: ptr lo, ptr hi, W, H(game px), refx, refy, flags, colbytes(lines per column)
SPR_TABLE = 0x8000
SPR_FONT = 0x8340
SPR_BAR = 0x8480
SPR_DIGITS = 0x8980
SPR_DATA = 0x8C00
SPR_SFX = 0xBE00
table = bytearray()
for i in range(103):
    e = entry[i]
    if e is None:
        table += bytes(8); continue
    j, mirror, rx, ry = e
    im, full, src = images[j]
    h, w = im.shape
    W = img_wbytes[j]
    if mirror:
        rx = (2 * W - 1) - rx
    ptr = SPR_DATA + img_off[j]
    flags = (1 if mirror else 0) | (2 if full else 0)
    lines = 2 * h if full else h
    table += bytes([ptr & 255, ptr >> 8, W, h, rx & 255, ry & 255, flags, lines])
assert len(table) <= SPR_FONT - SPR_TABLE

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

# bar: compose 160x8 game px: background pattern col 0..7 tiled, icons squashed 2:1 vertically
bar_idx, bar_rgb, _ = load_indexed('bar.png')
bar = np.zeros((16, 160), dtype=np.int32)
for x in range(0, 160, 8):
    bar[:, x:x + 8] = bar_idx[:, 0:8]
bar[:, 152:160] = bar_idx[:, 15:23]
def blit_icon(dstx, sx):
    icon = bar_idx[:, sx:sx + 13]
    bar[:, dstx:dstx + 13] = icon
blit_icon(3, 24)     # cleo head
blit_icon(31, 37)    # heart
blit_icon(59, 50)    # star
# squash 16 -> 8 rows (take every other row) then dither full-res
bar8 = bar[::2, :]
barcol = dither(bar_rgb[bar8], np.ones(bar8.shape, bool), full=True)   # 16 lines x 160
barcol[0, :] = 0    # top scanline black: it is also shown as the first line of the blank section
barpk = pack_mode2(barcol)     # 16 x 80
barbytes = bytearray()
for crow in range(2):
    for cx in range(80):
        for ra in range(8):
            barbytes.append(int(barpk[crow * 8 + ra, cx]))
# digits 0..9 from bar.png at (63 + n%5*8, n//5*8), 8x8 -> 64-byte tiles
digits = bytearray()
for n in range(10):
    dx, dy = 63 + (n % 5) * 8, (n // 5) * 8
    img = bar_rgb[bar_idx[dy:dy + 8, dx:dx + 8]]
    col = dither(img, np.ones((8, 8), bool), full=True)
    pk = pack_mode2(col)
    for crow in range(2):
        for cx in range(4):
            for ra in range(8):
                digits.append(int(pk[crow * 8 + ra, cx]))

bank4 = bytearray(16384)
bank4[0:len(table)] = table
bank4[SPR_FONT - 0x8000:SPR_FONT - 0x8000 + len(font)] = font
bank4[SPR_BAR - 0x8000:SPR_BAR - 0x8000 + len(barbytes)] = barbytes
bank4[SPR_DIGITS - 0x8000:SPR_DIGITS - 0x8000 + len(digits)] = digits
assert SPR_DATA + len(sprite_data) <= SPR_SFX, 'sprite data overflow: %d' % (SPR_DATA + len(sprite_data))
bank4[SPR_DATA - 0x8000:SPR_DATA - 0x8000 + len(sprite_data)] = sprite_data
open(os.path.join(OUT, 'SPR'), 'wb').write(bank4)
print('sprite data ends at %04X' % (SPR_DATA + len(sprite_data)))

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
    pk = pack_mode2(col)
    data = bytearray()
    for c in range(W):
        data += pk[:, c].tobytes()
    return W, (2 * h if full else h), h, data, col

title = bytearray()
tdir = []
pieces = [('logo', 0, 0, 80, 26, True), ('you', 0, 58, 38, 13, True), ('win', 38, 58, 39, 13, True), ('lose', 0, 71, 45, 13, True)]
for f in range(9):
    pieces.append(('cleo%d' % f, (f % 3) * 26, 85 + (f // 3) * 32, 26, 31, False))
tpreview = []
for (name, x, y, w, h, full) in pieces:
    W, lines, hpx, data, col = rect_image(tit_idx, tit_rgb, tit_tr, x, y, w, h, full, opaque=name.startswith('cleo'))
    tdir.append((name, 0x8000 + 0x80 + len(title), W, hpx, lines, full))
    title += data
    tpreview.append(col)
# directory at &8000: 8 bytes per piece: ptr lo, hi, W, h, flags(2=full), lines, 0, 0
tdirbytes = bytearray()
for (name, ptr, W, hpx, lines, full) in tdir:
    tdirbytes += bytes([ptr & 255, ptr >> 8, W, hpx, 0, 0, 2 if full else 0, lines])
titlefile = tdirbytes.ljust(0x80, b'\0') + title
open(os.path.join(OUT, 'TITLE'), 'wb').write(titlefile)
print('title pack', len(titlefile))

# ----------------------------------------------------------------------------
# constants for the assembler
# ----------------------------------------------------------------------------
with open(os.path.join(OUT, 'assets.inc'), 'w') as f:
    f.write('; generated by convert.py\n')
    f.write('NTILES = %d\n' % len(compact))
    f.write('SPR_TABLE = $%04X\nSPR_FONT = $%04X\nSPR_BAR = $%04X\nSPR_DIGITS = $%04X\nSPR_DATA = $%04X\nSPR_SFX = $%04X\n' %
            (SPR_TABLE, SPR_FONT, SPR_BAR, SPR_DIGITS, SPR_DATA, SPR_SFX))
    for i, (name, ptr, W, hpx, lines, full) in enumerate(tdir):
        f.write('TP_%s = %d\n' % (name.upper(), i))

# ----------------------------------------------------------------------------
# previews
# ----------------------------------------------------------------------------
def save_preview(cols, path, cols_per_row=16, scale=2):
    # each col array (lines, w); lines are MODE2 scanlines (aspect 2:1 wide) -> render each byte pixel as 2x1
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
