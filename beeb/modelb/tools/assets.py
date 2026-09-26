#!/usr/bin/env python3
"""Pack every level for the Model B target, in the Master's own formats.

   python3 tools/assets.py            (all sixteen levels; prints a fit report)

The Master's convert.py is imported for its tables.  The shared files (SPR,
SPRAND, BOX, TILESO, TILESI, TITLE, MUSIC) go on the disc as convert.py wrote them;
the game's own loader (ldprog.s) stages one at a time in display RAM and copies the
pieces a level needs into the banks, where the packer here decided they go.  What
this writes to build/:

   L0..L15        per level: header, objects, attr/altcls, the level's tile lists
                  (convert.py pack_tiles), the sprite placement list, the RLE map,
                  the finished sprite directory and SPRMASK.  A small table of
                  section offsets at the top.
   imgtab.bin     per image, box and trampoline: which shared file holds it and
                  where, and the same for its mask
   digits.bin     the HUD's digits (bank 7); font.bin (the menu image); alt.bin
   BAR            the bar template, 1280 bytes, loaded to $0300 at every level
   assets.inc     the bounds every level fits: MAXSPR, BINMAX, the biggest map,
                  the solid ids, the file sizes the bank images incbin
"""
import os, sys, io, contextlib, importlib.util
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
BEEB = os.path.dirname(os.path.dirname(HERE))
os.chdir(BEEB)
spec = importlib.util.spec_from_file_location('conv', 'tools/convert.py')
m = importlib.util.module_from_spec(spec)
with contextlib.redirect_stdout(io.StringIO()):
    spec.loader.exec_module(m)
TARGET = os.environ.get('TARGET', 'modelb')     # 'master': the converged Master (build.sh)
OUT = os.path.join(BEEB, 'modelb', os.environ.get('BD', 'build'))
os.makedirs(OUT, exist_ok=True)

def out(name, data):
    open(os.path.join(OUT, name), 'wb').write(bytes(data))

SOLID_CYAN, SOLID_BLACK = 254, 255
VISLINES = 240 if TARGET == 'master' else 160   # the window's lines: 30 rows / 20 (engine.s)

# ---------------------------------------------------------------- the banks' fixed shape
# Code sits at the top of banks 4 and 6 and the data below it can be any size; the
# level image of bank 5 is its code and BSS from $8100 and the tiles above them, page
# aligned.  These are the bounds the linker config (cleo_b.cfg) and defs.inc share.
B4_DATA = (0x8800, 0xBC40)                  # bank 4: images and masks
B4_HOLE = (0x8040, 0x8300)                  #   masks on their own below the tables
B6_HOLE = (0x8180, 0x8300)                  # bank 6: below the tables, above the low image
B6_SWAP = (0x8300, 0x8400)                  #   the page SWAPTAB would take: data here
B6_TOP = 0xBDA0                             #   the row loop and copy blitter above this
MAP6 = 0x8800                               #   the map, then the directory, then images
TILES_BASE, B5X = m.B_TILES, m.B_TILES_END  # bank 5: the tiles from here (page aligned)
                                            #   up to the row loop's region (cleo_b.cfg)

SPRFILE_SPR, SPRFILE_AND, SPRFILE_BOX = 0, 1, 2   # the loader's source file ids

# ---------------------------------------------------------------- the shared files
# convert.py's bank-4 image, ANDY overflow and box-star file carry every image, mask,
# box and trampoline: this table says where in which file each one is.  The loader
# stages a file and copies from these offsets to the addresses placed below.
def img_src(j):
    base, region = m.img_addr[j]
    if region == 0:
        return (SPRFILE_SPR, base - 0x8000)
    if region == 1:
        return (SPRFILE_AND, base - m.SPR_ANDY)
    return (SPRFILE_BOX, base - m.BOX_BASE)
def mask_src(j):
    base, region = m.img_addr[j]
    a = m.mask_addr[j]
    if region == 2:
        return (SPRFILE_BOX, a - m.BOX_BASE)
    return (SPRFILE_SPR, a - 0x8000)
box_off = []
_o = 0
for b in m.allbox_bytes:                    # 12 boxes then 3 trampolines, in the BOX file
    box_off.append(_o); _o += len(b)
NIMG = len(m.images)
# item keys: ('img', j) | ('box', k) | ('tramp', f) -> a small integer the placement
# lists and the directory template use
def item_index(kind, j):
    return {'img': 0, 'box': NIMG, 'tramp': NIMG + 12}[kind] + j
def item_bytes(kind, j):
    return m.img_bytes[j] if kind == 'img' else (m.box_bytes[j] if kind == 'box' else m.tramp_bytes[j])
imgtab = bytearray()
for j in range(NIMG):
    f, o = img_src(j); mf, mo = mask_src(j)
    n, mn = len(m.img_bytes[j]), len(m.img_mask[j])
    imgtab += bytes([f, o & 255, o >> 8, n & 255, n >> 8, mf, mo & 255, mo >> 8, mn & 255, mn >> 8])
for k in range(15):
    o, n = box_off[k], len(m.allbox_bytes[k])
    imgtab += bytes([SPRFILE_BOX, o & 255, o >> 8, n & 255, n >> 8, 0, 0, 0, 0, 0])
out('imgtab.bin', imgtab)

# the directory template: the Master's entry less its pointer, which becomes the item
# index and its kind; the loader writes the pointer and the bank-6 flag
sprdir = bytearray()
for i in range(103):
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
    sprdir += bytes([item_index('img', j), 0, W, hh, rx & 255, ry & 255, (1 if mirror else 0) | 2, 2 * hh])
for k in range(12):
    lo, wc = m.box_geom[k % 6]
    sprdir += bytes([item_index('box', k), 1, wc, m.BOX_H, (6 - 2 * lo) & 255, 8, 2 | 8, m.BOX_H * 2])
for f in range(3):
    lo, wc = m.tramp_geom[f]
    sprdir += bytes([item_index('tramp', f), 2, wc, m.TRAMP_H, (m.TRAMP_HOT - 2 * lo) & 255, (-8) & 255, 2 | 8, m.TRAMP_H * 2])
assert len(sprdir) == 118 * 8

out('digits.bin', m.digits)
out('font.bin', m.font)
out('alt.bin', m.altfile)
out('BAR', m.barbytes)
MUS = os.path.join(BEEB, 'build', 'MUSIC')
if not os.path.exists(MUS):
    os.system('python3 ' + os.path.join(BEEB, 'tools', 'midi2snd.py'))
out('music.bin', open(MUS, 'rb').read())

# ---------------------------------------------------------------- per-level helpers
rle, unrle = m.rle, m.unrle

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

# ---------------------------------------------------------------- one level
def pack_level(lv, sub):
    L = m.levels[(lv, sub)]
    name = m.name_of(lv, sub)
    cm = m.maps[(lv, sub)]
    assert cm.min() >= 0
    gset = m.tileset_of(lv, sub)
    # the level's tiles: convert.py pack_tiles, the ids the Master's too
    T = m.pack_tiles(lv, sub)
    local = T['local']
    lut = np.zeros(len(m.compact), dtype=np.uint8)
    for c, t in local.items():
        lut[c] = t
    mapb = lut[cm].tobytes()
    h, w = cm.shape
    specials = [m.special['VANISH0'] + i for i in range(8)] + [m.special['FLOWER0'] + i for i in range(4)]

    # ---- tables
    hdr = bytearray([L['lw'], L['lh'], L['start'][0], L['start'][1], L['exit'][0], L['exit'][1],
                     len(L['objs']), 1])
    for cid in specials:
        hdr.append(local.get(cid, 255))
    assert len(hdr) == 20
    hdr += T['B']['hdr']                    # +20..+31: the tiles' shape (pack_tiles)
    assert len(hdr) == 32
    objs = bytearray()
    reach = m.enemy_reach(L['objs'])
    for (t, x, y, ex) in L['objs']:
        e = (list(ex) + [0, 0, 0])[:3]
        if t == 0:
            e[0] = m.star_class(cm, x, y)
            e[1] = 1 if m.star_reachable(x, y, reach) else 0
        elif t == 1:
            e[0] = m.tramp_class(cm, x, y)
            b = m.TYPE_BOX[1]
            selfbox = (8 * x + b[0], 8 * x + b[1], 8 * y + b[2], 8 * y + b[3])
            e[1] = 1 if m.box_reachable(b, x, y, reach, skip=selfbox) else 0
        objs += bytes([t, x, y] + e)
    assert len(L['objs']) <= 149
    attr = bytearray(256)
    acls = bytearray(256)
    for c in sorted(local):
        t = local[c]
        attr[t] = m.attr_of(c)
        acls[t] = 0 if c in m.tile_solid else m.alt_class[c]

    # ---- the sprite list's bounds (see the old packer: the objects whose cells the
    # walk rectangle can cover from any camera position)
    boxes = []
    for (t, x, y, ex) in L['objs']:
        e = (list(ex) + [0, 0, 0])[:3]
        boxes.append((t, cellbox(t, x, y, e)))
    maxwx, maxwy = w * 8 - 160, h * 8 - VISLINES // 2
    rects = set()
    for wx in range(0, maxwx + 1, 2):
        for wy in range(0, maxwy + 1):
            rects.add((wx >> 6, (wx + 159) >> 6, wy >> 6, (wy + VISLINES // 2 - 1) >> 6))
    MAXSPR, BINMAX = 0, 0
    for (rx0, rx1, ry0, ry1) in rects:
        hit = [t for (t, (gx0, gx1, gy, gy1)) in boxes if gx0 <= rx1 and gx1 >= rx0 and gy <= ry1 and gy1 >= ry0]
        MAXSPR = max(MAXSPR, sum(SPRITES_OF[t] for t in hit) + 2)
        BINMAX = max(BINMAX, sum(1 for t in hit if t == 0), sum(1 for t in hit if t != 0))

    # ---- sprites: which images, and where each goes
    types = sorted(set(t for (t, x, y, e) in L['objs']))
    ids = set(range(43))                    # Cleo, the boomerang (27..33), the common ones:
                                            # through 42, the star's collect animation's end
    for t in types:
        if t in m.TYPE_IDS:
            lo, hi = m.TYPE_IDS[t]
            ids |= set(range(lo, hi + 1))
    imgs = sorted(set(m.entry[i][0] for i in ids if m.entry[i] is not None))
    # the box stars' art by each star's class (convert.py star_class: 1 on sky, the
    # first six boxes; 2 on black, the second six -- logic.s boxbase), not by the set
    classes = set(m.star_class(cm, x, y) for (t, x, y, e) in L['objs'] if t == 0)
    bxs = (list(range(0, 6)) if 1 in classes else []) + (list(range(6, 12)) if 2 in classes else [])
    tramps = [0, 1, 2] if 1 in types else []
    R6BASE = MAP6 + len(mapb) + 118 * 8
    regions = {'r4': [B4_DATA[0], B4_DATA[1]], 'h4': [B4_HOLE[0], B4_HOLE[1]],
               'r6': [R6BASE, B6_TOP], 's6': [B6_SWAP[0], B6_SWAP[1]], 'h6': [B6_HOLE[0], B6_HOLE[1]]}
    mirrored = set(m.entry[i][0] for i in ids if m.entry[i] is not None and m.entry[i][1])
    items0 = [('img', j, len(m.img_bytes[j]), len(m.img_mask[j])) for j in imgs]
    items0 += [('box', k, len(m.box_bytes[k]), 0) for k in bxs]
    items0 += [('tramp', f, len(m.tramp_bytes[f]), 0) for f in tramps]
    def canmirror(it):
        return it[0] == 'img' and it[1] in mirrored
    def attempt(items, prefer4):
        """One greedy placement in this order; None if something does not fit."""
        fill = {r: 0 for r in regions}
        img_addr, mask_addr, img_bank = {}, {}, {}
        def place(region, n):
            base = regions[region][0] + fill[region]; fill[region] += n; return base
        def room(region):
            return regions[region][1] - regions[region][0] - fill[region]
        def try4(key, nd, nm):
            if room('r4') >= nd + nm:
                img_addr[key] = place('r4', nd); img_bank[key] = 4
                if nm: mask_addr[key] = place('h4' if room('h4') >= nm else 'r4', nm)
            elif room('r4') >= nd and room('h4') >= nm:
                img_addr[key] = place('r4', nd); img_bank[key] = 4
                if nm: mask_addr[key] = place('h4', nm)
            elif room('h4') >= nd + nm:
                img_addr[key] = place('h4', nd); img_bank[key] = 4
                if nm: mask_addr[key] = place('h4', nm)
            else:
                return False
            return True
        def try6(key, nd, nm):
            for r in ('r6', 'h6', 's6'):
                if room(r) >= nd + nm:
                    img_addr[key] = place(r, nd); img_bank[key] = 6
                    if nm: mask_addr[key] = place(r, nm)
                    return True
            for r in ('r6', 'h6'):
                for rm in ('s6', 'h6', 'r6'):
                    if rm != r and room(r) >= nd and room(rm) >= nm:
                        img_addr[key] = place(r, nd); img_bank[key] = 6
                        if nm: mask_addr[key] = place(rm, nm)
                        return True
            return False
        for kind, j, nd, nm in items:
            key = (kind, j)
            if canmirror((kind, j, nd, nm)):
                ok = try4(key, nd, nm)
            elif kind != 'img':                 # the copy blitter is bank 6's alone
                ok = try6(key, nd, nm)
            else:
                ok = (try4(key, nd, nm) or try6(key, nd, nm)) if prefer4 else (try6(key, nd, nm) or try4(key, nd, nm))
            if not ok:
                return None
        return fill, img_addr, mask_addr, img_bank
    # the fixed pieces first (the box stars, the mirrored images: each has one bank),
    # then the rest largest first; when that greedy order leaves a hole too small,
    # other orders of the rest, deterministically, until one fits
    base_order = sorted(items0, key=lambda it: (0 if it[0] != 'img' else (1 if canmirror(it) else 2), -(it[2] + it[3])))
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
    fill, img_addr, mask_addr, img_bank = got
    placement = bytearray()
    for (kind, j), a in sorted(img_addr.items(), key=lambda kv: item_index(*kv[0])):
        ma = mask_addr.get((kind, j), 0)
        placement += bytes([item_index(kind, j), img_bank[(kind, j)], a & 255, a >> 8, ma & 255, ma >> 8])
    placement += b'\xff'
    # the directory and SPRMASK as the game reads them: the template's entries with each
    # placed item's address (and bank 6's flag), and each sprite id's mask address
    byitem = {item_index(*k): k for k in img_addr}
    directory, smask = bytearray(), bytearray()
    for i in range(118):
        t = sprdir[i * 8:i * 8 + 8]
        k = byitem.get(t[0]) if t[0] != 0xFF else None
        if k is None:
            directory += bytes(8); ma = 0
        else:
            a = img_addr[k]
            e = bytearray([a & 255, a >> 8]) + t[2:8]
            if img_bank[k] == 6:
                e[6] |= 0x10
            directory += e; ma = mask_addr.get(k, 0)
        if i < 118 - 15:                    # the box ids (the last 15) have no entry
            smask += bytes([ma & 255, ma >> 8])
    assert len(smask) == 2 * 103

    # ---- the file: a table of section offsets, then the sections
    maprle = rle(mapb)
    assert unrle(maprle) == mapb
    secs = [('hdr', hdr), ('objs', objs), ('attr', attr), ('altcls', acls),
            ('tiles', T['B']['tiles']), ('place', placement), ('map', maprle), ('flat', T['flat']),
            ('halves', T['halves']), ('hpair', T['hpair']), ('mir', T['B']['mir']),
            ('dir', directory), ('smask', smask)]
    if TARGET == 'master':                  # the gather's table (LV_PAGE0), for main RAM
        secs.append(('page0', T['B']['page0']))
    off = 2 * len(secs)
    table = bytearray()
    body = bytearray()
    for nm_, data in secs:
        o = off + len(body)
        table += bytes([o & 255, o >> 8])
        body += data
    room = 0x8000 - 0x3000 if TARGET == 'master' else 0x7C00 - 0x5C00   # STAGE_LVL's (defs.inc)
    assert off + len(body) <= room, (name, off + len(body))
    out('L%d' % (lv * 2 + sub), table + body)
    stats = dict(name=name, ntiles=T['ntiles'], nflat=T['nflat'], nhalf=T['nhalf'], nmir=T['nmir'], w=w, h=h, nobj=len(L['objs']),
                 nimg=len(imgs), r4=fill['r4'], h4=fill['h4'], r6=fill['r6'], h6=fill['h6'], s6=fill['s6'],
                 maxspr=MAXSPR, binmax=BINMAX, maprle=len(maprle), size=off + len(body))
    return stats

allstats = []
for lv in range(8):
    for sub in (0, 1):
        s = pack_level(lv, sub)
        allstats.append(s)
        print('%-4s %3d tiles +%2d half +%2d mirror +%d flat map %3dx%2d rle %5d  %3d obj %2d img  '
              'b4 %5d+%3d  b6 %5d+%3d+%3d  spr %2d bin %2d  file %5d'
              % (s['name'], s['ntiles'], s['nhalf'], s['nmir'], s['nflat'], s['w'], s['h'], s['maprle'], s['nobj'], s['nimg'],
                 s['r4'], s['h4'], s['r6'], s['h6'], s['s6'], s['maxspr'], s['binmax'], s['size']))

MAXSPR = max(s['maxspr'] for s in allstats)
BINMAX = max(s['binmax'] for s in allstats)
with open(os.path.join(OUT, 'assets.inc'), 'w') as f:
    f.write('; generated by modelb/tools/assets.py: the bounds every level fits\n')
    f.write('SOLID_CYAN = %d\nSOLID_BLACK = %d\nFLAT0 = %d\nNFLAT = %d\nMAXMIR = %d\n' % (SOLID_CYAN, SOLID_BLACK, m.FLAT0, m.NFLAT, m.MAXMIR))
    f.write('BOXID0 = 103\nBOXN = 15\n')
    f.write('TITLE_ADDR = $8900\n')         # bank 6, as the Master: over the map
    f.write('TP_LOGO = 0\nTP_YOU = 1\nTP_WIN = 2\nTP_LOSE = 3\nTP_CLEO0 = 4\n')   # the title pack's pieces
    f.write('HUD_BANK = 7\n')
    f.write('SPR_BAR = 0\nSPR_DIGITS = digits_art\nSPR_FONT = font_art\n')
    f.write('MAXSPRDEF = %d\nBINMAXDEF = %d\n' % (MAXSPR, BINMAX))
    f.write('SPR6_MIRROR = 0\n')            # bank 6 holds no image that is drawn mirrored
    f.write('SPR4_COPY = 0\n')              # and bank 4 nothing the copy blitter draws
    f.write('B4_DATA_END = $%04X\nB6_TOP = $%04X\nMAP6 = $%04X\n' % (B4_DATA[1], B6_TOP, MAP6))
    f.write('NIMGTAB = %d\n' % (NIMG + 15))
print('MAXSPR %d BINMAX %d; imgtab %d entries' % (MAXSPR, BINMAX, NIMG + 15))
