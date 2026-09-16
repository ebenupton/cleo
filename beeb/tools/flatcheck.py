"""Every pixel that belongs to a flat region -- same source colour as an orthogonal
neighbour, within its tile or across into the adjacent tile of the level bitmap --
must render as that colour's own dither at that phase.  Ordered dithering gives this
by construction; anything that edits pixels afterwards can break it.  Reports each
level's violations by cause.   MODE=2 python3 tools/flatcheck.py"""
import os, io, contextlib, importlib.util, numpy as np
spec = importlib.util.spec_from_file_location('c', os.path.join(os.path.dirname(__file__), 'convert.py'))
m = importlib.util.module_from_spec(spec)
with contextlib.redirect_stdout(io.StringIO()):
    spec.loader.exec_module(m)
strip = m.strip
flat_col = {}
def expect(pi):                      # palette index -> the flat dither (16, 8), stripped
    if pi not in flat_col:
        c = m.til_rgb[pi]
        col = m.dither(np.tile(c, (8, 8, 1)).astype(np.uint8), np.ones((8, 8), bool), full=True)
        fn = m.pattern_idx.get(pi) if hasattr(m, 'pattern_idx') else None
        if fn:
            for yy in range(8):
                for xx in range(8):
                    col[2 * yy, xx] = fn(xx, 2 * yy); col[2 * yy + 1, xx] = fn(xx, 2 * yy + 1)
        flat_col[pi] = strip(col)
    return flat_col[pi]
total = {}
for (lv, sub), cm in sorted(m.maps.items()):
    g = m.tileset_of(lv, sub); rm = m.remap[g]; fo = m.folded[g]
    raw = m.levels[(lv, sub)]['map']; h, w = cm.shape
    src = np.full((h * 8, w * 8), -1, int)          # source palette index per game pixel
    for y in range(h):
        for x in range(w):
            o = m.compact[int(cm[y, x])]
            src[y*8:y*8+8, x*8:x*8+8] = m.til_idx[o*8:o*8+8, :]
    flat = np.zeros_like(src, bool)                   # has a same-colour orthogonal neighbour
    flat[:, 1:] |= src[:, 1:] == src[:, :-1]; flat[:, :-1] |= src[:, :-1] == src[:, 1:]
    flat[1:, :] |= src[1:, :] == src[:-1, :]; flat[:-1, :] |= src[:-1, :] == src[1:, :]
    counts = {}
    for y in range(h):
        for x in range(w):
            c = int(cm[y, x]); r = rm.get(c)
            if r == m.SOLID_CYAN:   got = np.full((16, 8), m.CYAN_COL & 7, np.uint8)
            elif r == m.SOLID_BLACK: got = np.zeros((16, 8), np.uint8)
            else:                    got = strip(np.asarray(m.tile_preview[fo.get(c, c)]))
            f = flat[y*8:y*8+8, x*8:x*8+8]
            if not f.any():
                continue
            s = src[y*8:y*8+8, x*8:x*8+8]
            bad = 0
            for yy in range(8):
                for xx in range(8):
                    if not f[yy, xx]: continue
                    e = expect(int(s[yy, xx]))
                    if got[2*yy, xx] != e[2*yy, xx] or got[2*yy+1, xx] != e[2*yy+1, xx]:
                        bad += 1
            if bad:
                orig = m.compact[c]
                cause = ('fold' if c in fo else 'solid' if r in (m.SOLID_CYAN, m.SOLID_BLACK)
                         else 'fill' if int(cm[y, x]) != m.orig2compact[int(raw[y, x])]
                         else 'edit' if orig in m.TILE_EDITS else 'blackened' if c in m.blackened else 'other')
                counts[cause] = counts.get(cause, 0) + bad
    if counts:
        print('%s: flat pixels rendered off-pattern: %s' % (m.name_of(lv, sub), counts))
    for k, v in counts.items(): total[k] = total.get(k, 0) + v
print('TOTAL', total if total else 'none: every flat pixel is its colour\'s own dither')
