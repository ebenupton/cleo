#!/usr/bin/env python3
"""Preview only (no game data touched): render every level with the 'dark dithery' tiles
forced to solid black.  A tile counts as dark when, after dithering, at least DARK of its
pixels are black and it is not already solid.  Output: build/preview_dark/L<n><A|B>.png
(after) and build/preview_dark/orig/...png (before).   python3 tools/preview_dark.py [DARK]
"""
import io, contextlib, os, sys
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
DARK = float(sys.argv[1]) if len(sys.argv) > 1 else 0.8
g = {'__file__': os.path.join(HERE, 'convert.py'), '__name__': 'convert_state'}
with contextlib.redirect_stdout(io.StringIO()):
    exec(compile(open(g['__file__']).read(), g['__file__'], 'exec'), g)
tile_preview, levels, orig2compact, compact = g['tile_preview'], g['levels'], g['orig2compact'], g['compact']
BEEB_RGB = g['BEEB_RGB']
col_to_rgb = lambda col: BEEB_RGB[col & 7]        # true black for colour 0/8

# background mask per tile from the altitude data: alt[tile*8+col] high nibble = surface
# row (0 solid from the top .. 7, 8 = no ground in this column); pixels above the surface
# are background.  A tile's background is blackened when it is mostly black already.
altd = open(os.path.join(HERE, '..', '..', 'v500', 'alt'), 'rb').read()
def bg_mask(orig):
    m = np.zeros((16, 8), bool)
    for c in range(8):
        hi = altd[orig * 8 + c] >> 4
        m[:min(hi, 8) * 2, c] = True          # rows above the surface (all 16 lines if 8)
    return m
# 'wall-ish' source colours: near-black, or dark and desaturated (the indoor backdrops are
# (17,17,0)/(34,34,34)/greys/one dull brown; trunks and foliage are saturated browns, greens
# and blues, so they are left alone whatever their dithered darkness)
til_idx, til_rgb0 = g['til_idx'], g['til_rgb0']
def wallish(rgb):
    r, gg, b = (int(v) for v in rgb)
    mx, mn = max(r, gg, b), min(r, gg, b)
    sat = 0 if mx == 0 else (mx - mn) / mx
    return mx <= 40 or (sat <= 0.4 and mx <= 140)
wall_pal = np.array([wallish(c) for c in til_rgb0])
# the speckle families with bright highlight dots (wall 70/71, the band around the EXIT
# sign 102) are wall too: their source colours join the wall set
for orig in (70, 71, 102):
    for v in np.unique(til_idx[orig * 8:orig * 8 + 8, :]):
        wall_pal[int(v)] = True
# tiles whose background is cleaned pixel by pixel (art on a wall backdrop): the EXIT
# letters and the flower (2x2 tiles: 402/403 head, 434/435 stem and leaves; the animated
# run 426..429 is not it)
PIXEL_TILES = {32, 33, 402, 403, 434, 435}
# the one speckle variant the colour rule misses (a lone floating block in the tombs):
# forced black outright.  Its relatives (223/255/191 = wooden trusses, 183/212/179/180/211
# = the lattice beside the pillars) are foreground art and must NOT be listed here.
WALL_TILES = {297}
# the potted plant's box: its background tiles are cleaned with the box's own speckle
# colours (taken from the plant-free tiles) so only the plant is left; the solid top row
# (245..251) is a platform and stays visible
# the bush in the stone box (277..379) is NOT the flower and is left alone (its cleaning
# is backed out: PLANT_TILES empty; the machinery below stays for when the right tiles
# are identified)
PLANT_BG = set()
PLANT_ART = set()
PLANT_TILES = set()
plant_pal = np.zeros(len(til_rgb0), bool)
for orig in PLANT_BG:
    for v in np.unique(til_idx[orig * 8:orig * 8 + 8, :]):
        plant_pal[int(v)] = True
dark = {}          # compact id -> (fraction, replacement tile)
for cid, orig in enumerate(compact):
    col = tile_preview[cid]
    c = col & 7
    bg = bg_mask(orig)
    if not bg.any() or np.all(c[bg] == 0):
        continue
    src = til_idx[orig * 8:orig * 8 + 8, :]
    wall_px = wall_pal[src]                       # (8, 8) source pixels that are wall colour
    frac = float(np.mean(wall_px[bg[::2]]))
    if orig in PIXEL_TILES or orig in PLANT_TILES:
        pal = plant_pal if orig in PLANT_TILES else wall_pal
        rep = c.copy(); rep[bg & np.repeat(pal[src], 2, axis=0)] = 0
        dark[cid] = (frac, rep)
    elif frac >= DARK or orig in WALL_TILES:
        rep = c.copy(); rep[bg] = 0
        dark[cid] = (frac, rep)
nfull = sum(1 for cid in dark if bg_mask(compact[cid]).all())
print('threshold %.2f: %d tiles get their background blackened (%d whole, %d partial)' % (DARK, len(dark), nfull, len(dark) - nfull))

out = os.path.join(HERE, '..', 'build', sys.argv[2] if len(sys.argv) > 2 else 'preview_dark')
os.makedirs(os.path.join(out, 'orig'), exist_ok=True)
solid = lambda t: any((altd[t * 8 + c] >> 4) < 8 for c in range(8))
def fill_holes(m):
    # a blackened background cell boxed in by solid tiles (3+ of its 4 neighbours) is wall
    # texture used as foreground filler (ramp feet): continue the block below it instead
    m = m.copy(); h, w = m.shape; subs = []
    for y in range(1, h - 1):
        for x in range(1, w - 1):
            t = int(m[y, x])
            if orig2compact[t] not in dark or solid(t) or t in PIXEL_TILES or t in PLANT_TILES:
                continue
            nb = [int(m[y + 1, x]), int(m[y, x - 1]), int(m[y, x + 1]), int(m[y - 1, x])]
            if sum(solid(n) for n in nb) >= 3:
                for n in nb[:3]:
                    if solid(n) and orig2compact[n] not in dark:
                        m[y, x] = n; subs.append((x, y, t, n)); break
    return m, subs
def near_plant(m, tx, ty):
    # the plant box tiles double as the plain stone-block bases outdoors: only clean them
    # when the plant itself is within two cells
    h, w = m.shape
    win = m[max(ty - 2, 0):ty + 3, max(tx - 2, 0):tx + 3]
    return bool(np.isin(win, list(PLANT_ART)).any())
def render(m, force):
    h, w = m.shape
    img = np.zeros((h * 16, w * 8, 3), np.uint8)
    n = 0
    if force:
        m, subs = fill_holes(m)
        if subs: print('   holes filled:', subs)
    for ty in range(h):
        for tx in range(w):
            orig = int(m[ty, tx])
            cid = orig2compact[orig]
            col = tile_preview[cid]
            if force and cid in dark and (orig not in PLANT_TILES or near_plant(m, tx, ty)):
                col = dark[cid][1]; n += 1
            img[ty * 16:ty * 16 + 16, tx * 8:tx * 8 + 8] = col_to_rgb(col)
    return img, n
for (lv, sub), L in sorted(levels.items()):
    name = 'L%d%s' % (lv, 'B' if sub == 0 else 'A')
    m = L['map']
    for force, sub_dir in ((True, ''), (False, 'orig')):
        img, n = render(m, force)
        im = Image.fromarray(img)
        im = im.resize((im.width * 2, im.height), Image.NEAREST)     # MODE 2 pixels are 2:1
        im.save(os.path.join(out, sub_dir, name + '.png'))
        if force:
            print('%s: %dx%d tiles, %d (%.0f%%) forced black' % (name, m.shape[1], m.shape[0], n, 100 * n / m.size))
