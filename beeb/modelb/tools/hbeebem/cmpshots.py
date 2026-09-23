# Compare BeebEm's rendering (PPM, 800x312, one scanline per row, the display from x = 0)
# with jsbeeb's screenshot (PNG, 1024x625) of the same frame: both are reduced to a grid of
# BBC colours, one cell per 2-MHz pixel and scanline, aligned on the status bar's top-left,
# and the mismatching cells are reported as boxes.
#   python3 cmpshots.py beebem.ppm jsbeeb.png [diff.png]
import sys
from PIL import Image
def quant(px):
    r, g, b = px[:3]; return (1 if r > 127 else 0) | (2 if g > 127 else 0) | (4 if b > 127 else 0)
def grid(img, x0, y0, cw, ch, cols, rows):
    g = []
    for r in range(rows):
        row = []
        for c in range(cols):
            x = x0 + c * cw + cw / 2; y = y0 + r * ch + ch / 2
            row.append(quant(img.getpixel((min(int(x), img.width - 1), min(int(y), img.height - 1)))))
        g.append(row)
    return g
def bbox(img):
    px = img.load(); xs = []; ys = []
    for y in range(0, img.height, 2):
        for x in range(0, img.width, 2):
            if quant(px[x, y]): xs.append(x); ys.append(y); 
    return min(xs), min(ys), max(xs), max(ys)
hb = Image.open(sys.argv[1]).convert('RGB'); jb = Image.open(sys.argv[2]).convert('RGB')
hx0, hy0, hx1, hy1 = bbox(hb); jx0, jy0, jx1, jy1 = bbox(jb)
# BeebEm: 1 px per 2-MHz pixel, 1 row per scanline.  jsbeeb: 1024 px across for 128 chars = 8 px
# per char = 1 px per 2-MHz pixel too, 2 rows per scanline (625 for 312.5).
rows = (hy1 - hy0) + 1; cols = (hx1 - hx0) + 1
# the scale from the WIDTH alone (the pictures' geometry is fixed: a scanline is one row in a
# 1:1 image, two in jsbeeb's doubled canvas); a stray line in one picture must not stretch the other
# known geometries: a 1:1 picture (BeebEm's buffer, the ideal render) is one pixel per 2-MHz pixel
# and one row per scanline; jsbeeb's canvas is two by four
cw = 2.0 if jb.width > 1000 else 1.0; ch = 4.0 if jb.width > 1000 else 1.0
gh = grid(hb, hx0, hy0, 1, 1, cols, rows)
gj = grid(jb, jx0, jy0, cw, ch, cols, rows)
bad = [(c, r) for r in range(rows) for c in range(cols) if gh[r][c] != gj[r][c]]
print('%s: display %dx%d lines; beebem box %s jsbeeb box %s; mismatching cells: %d' % (sys.argv[1].split('/')[-1], cols, rows, (hx0, hy0, hx1, hy1), (jx0, jy0, jx1, jy1), len(bad)))
if bad:
    cs = [c for c, r in bad]; rs = [r for c, r in bad]
    print('  box: cols %d-%d (chars %d-%d), lines %d-%d (rows %d-%d)' % (min(cs), max(cs), min(cs) // 8, max(cs) // 8, min(rs), max(rs), min(rs) // 8, max(rs) // 8))
    # per row-of-8 histogram
    hist = {}
    for c, r in bad: hist[r // 8] = hist.get(r // 8, 0) + 1
    print('  by char row: ' + ' '.join('%d:%d' % kv for kv in sorted(hist.items())))
    if len(sys.argv) > 3:
        out = Image.new('RGB', (cols, rows))
        pal = [(0,0,0),(255,0,0),(0,255,0),(255,255,0),(0,0,255),(255,0,255),(0,255,255),(255,255,255)]
        for r in range(rows):
            for c in range(cols): out.putpixel((c, r), pal[gh[r][c]] if gh[r][c] == gj[r][c] else (255, 255, 255) if gh[r][c] else (128, 0, 0))
        out.resize((cols, rows * 2)).save(sys.argv[3])
