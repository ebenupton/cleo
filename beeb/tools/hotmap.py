#!/usr/bin/env python3
"""Draw test/hotmap.mjs's result over the level's map.

The picture: the map, its tiles as convert.py renders them, a game pixel a pixel; every
object's first sprite frame at its place; a heat layer by cell -- blue where frames had
their window centred and none missed the vsync peg, yellow to red by the share that did --
each miss dotted, its colour by how far over the peg it ran; and the sweep's paths faint.
A long map is cut into strips, stacked, with a key at the top.

Input: the JSON hotmap.mjs writes (machine, level, vis, V, starts, frames: each frame
[px, py, wx, wy, work], work the frame's cycles).  Output: a PNG.

Usage (from beeb/):
    python3 tools/hotmap.py <hotmap.json> <out.png> [cell=16] [strip=512] [scale=2]
"""
import io, contextlib, json, os, sys
import numpy as np
from PIL import Image, ImageDraw
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
src, out = sys.argv[1:3]
CELL = int(sys.argv[3]) if len(sys.argv) > 3 else 16
STRIP = int(sys.argv[4]) if len(sys.argv) > 4 else 512
SC = int(sys.argv[5]) if len(sys.argv) > 5 else 2
with contextlib.redirect_stdout(io.StringIO()):
    import convert as m
d = json.load(open(src))
lv = d['level']
L = m.levels[(lv // 2, lv % 2)]
h, w = L['map'].shape
# ---- the map, a game pixel a pixel (every other scanline of the tiles' 16)
col = m.render_map(L, 0, 0, w, h)[0::2]
img = Image.fromarray(m.col_to_rgb(col)).convert('RGBA')
# ---- the objects: each type's first frame at its reference point (the engine's: x*8, y*8;
# a trampoline 4 px in).  The rising snake shows its basket (60)
FIRST = {0: 34, 1: 43, 2: 46, 3: 60, 4: 61, 5: 67, 6: 76, 7: 85, 9: 93, 10: 97, 12: 100}
for (t, x, y, e) in L['objs']:
    sid = FIRST.get(t)
    if sid is None:
        continue
    im, rx, ry = m.crops[sid]
    rgba = np.zeros(im.shape + (4,), np.uint8)
    rgba[..., :3] = m.spr_rgb[im]
    rgba[..., 3] = np.where(im != m.spr_tr, 255, 0)
    ox = 8 * x + (4 if t == 1 else 0) - rx
    oy = 8 * y - ry
    img.alpha_composite(Image.fromarray(rgba), (int(ox), int(oy))) if 0 <= ox < w * 8 and 0 <= oy < h * 8 else None
W, H = img.size
# ---- the heat: visits and misses by the cell the window's centre falls in; a miss is a
# frame over three vsyncs' worth of V
V, vis = d['V'], d['vis']
cw, ch = (W + CELL - 1) // CELL, (H + CELL - 1) // CELL
visits = np.zeros((ch, cw)); misses = np.zeros((ch, cw))
pts = []
for (px, py, wx, wy, work) in d['frames']:
    cx, cy = wx + 80, wy + vis // 2
    i, j = min(ch - 1, max(0, cy // CELL)), min(cw - 1, max(0, cx // CELL))
    visits[i, j] += 1
    if work > 3 * V:
        misses[i, j] += 1
        pts.append((cx, cy, (work - 3 * V) / V))
heat = Image.new('RGBA', (W, H), (0, 0, 0, 0))
hd = ImageDraw.Draw(heat)
for i in range(ch):
    for j in range(cw):
        if visits[i, j]:
            f = misses[i, j] / visits[i, j]
            if f > 0:
                hd.rectangle([j * CELL, i * CELL, (j + 1) * CELL - 1, (i + 1) * CELL - 1],
                             fill=(255, int(200 * (1 - f)), 0, int(70 + 140 * f)))
            else:
                hd.rectangle([j * CELL, i * CELL, (j + 1) * CELL - 1, (i + 1) * CELL - 1], fill=(0, 160, 255, 40))
img.alpha_composite(heat)
# ---- the sweep's paths (the windows' centres), faint; a jump between runs is not drawn
pd = ImageDraw.Draw(img)
fr = d['frames']
for k in range(1, len(fr)):
    a, b = fr[k - 1], fr[k]
    if abs(b[2] - a[2]) < 20 and abs(b[3] - a[3]) < 20:
        pd.line([(a[2] + 80, a[3] + vis // 2), (b[2] + 80, b[3] + vis // 2)], fill=(255, 255, 255, 70))
for (x, y, o) in pts:
    c = (255, 255, 255) if o < 0.1 else (255, 230, 0) if o < 0.3 else (255, 0, 255)
    pd.ellipse([x - 2, y - 2, x + 2, y + 2], outline=(0, 0, 0, 255), fill=c + (255,))
# ---- strips, scaled, with a key
nstrip = (W + STRIP - 1) // STRIP
GAP, HEAD = 10, 40
sheet = Image.new('RGBA', (STRIP * SC, HEAD + nstrip * (H * SC + GAP)), (24, 24, 28, 255))
for k in range(nstrip):
    part = img.crop((k * STRIP, 0, min(W, (k + 1) * STRIP), H)).resize((min(STRIP, W - k * STRIP) * SC, H * SC), Image.NEAREST)
    sheet.paste(part, (0, HEAD + k * (H * SC + GAP)))
    ImageDraw.Draw(sheet).text((4, HEAD + k * (H * SC + GAP) + 2), 'x %d-%d' % (k * STRIP, min(W, (k + 1) * STRIP)), fill=(255, 255, 255, 255))
n, nm = len(fr), len(pts)
ImageDraw.Draw(sheet).text((6, 6), '%s level file %d: %d diagonal runs (45 deg up-right, 6 px a frame), %d frames, %d miss the peg (%.1f%%).  '
                           'Cells by the window centre: blue = visited, no miss; yellow->red = share of frames that missed.  '
                           'Dots = misses: white <10%% over, yellow <30%%, magenta more.' % (d['machine'], lv, len(d['starts']), n, nm, 100 * nm / max(1, n)),
                           fill=(230, 230, 230, 255))
sheet.convert('RGB').save(out)
print('%s: %dx%d, %d strips' % (out, sheet.size[0], sheet.size[1], nstrip))
