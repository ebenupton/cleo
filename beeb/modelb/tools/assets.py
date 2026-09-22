#!/usr/bin/env python3
"""Pack every level for the Model B target, in the Master's own formats.

   python3 tools/assets.py            (all sixteen levels; prints a fit report)

The Master's convert.py is imported for its tables (MODE=1).  The shared files (SPR,
SPRAND, BOX, TILESO, TILESI, TITLE, MUSIC) go on the disc as convert.py wrote them;
the game's own loader (ldprog.s) stages one at a time in display RAM and copies the
pieces a level needs into the banks, where the packer here decided they go.  What
this writes to build/:

   L0..L15        per level: header, objects, attr/altcls, the level's tile list
                  (set-local id per level-local id), the sprite placement list,
                  the RLE map.  A small table of section offsets at the top.
   sprdir.bin     the 118-entry directory template: (image, kind) in place of the
                  pointer; the loader fills the pointer and the bank flag in
   imgtab.bin     per image, box and trampoline: which shared file holds it and
                  where, and the same for its mask
   digits.bin     the HUD's digits (bank 7); font.bin (the menu image); alt.bin
   BAR            the bar template, 1280 bytes, loaded to $0300 at every level
   assets.inc     the bounds every level fits: MAXSPR, BINMAX, the biggest map,
                  the solid ids, the file sizes the bank images incbin
"""
import os, sys, io, contextlib, importlib.util
import numpy as np

os.environ['MODE'] = '1'
HERE = os.path.dirname(os.path.abspath(__file__))
BEEB = os.path.dirname(os.path.dirname(HERE))
os.chdir(BEEB)
spec = importlib.util.spec_from_file_location('conv', 'tools/convert.py')
m = importlib.util.module_from_spec(spec)
with contextlib.redirect_stdout(io.StringIO()):
    spec.loader.exec_module(m)
OUT = os.path.join(BEEB, 'modelb', 'build')
os.makedirs(OUT, exist_ok=True)

def out(name, data):
    open(os.path.join(OUT, name), 'wb').write(bytes(data))

SOLID_CYAN, SOLID_BLACK = 254, 255
NFLAT = 14                                  # flat tiles a level may have: ids FLAT0..253
FLAT0 = SOLID_CYAN - NFLAT                  # 240; the solids are the table's last two
VISLINES = 160                              # 20 rows (engine.s, MODELB)

# ---------------------------------------------------------------- the banks' fixed shape
# Code sits at the top of banks 4 and 6 and the data below it can be any size; the
# level image of bank 5 is its code and BSS from $8100 and the tiles above them, page
# aligned.  These are the bounds the linker config (cleo_b.cfg) and defs.inc share.
B4_DATA = (0x8800, 0xBBE0)                  # bank 4: images and masks
B4_HOLE = (0x8040, 0x8300)                  #   masks on their own below the tables
B6_HOLE = (0x8180, 0x8300)                  # bank 6: below the tables, above the low image
B6_SWAP = (0x8300, 0x8400)                  #   the page SWAPTAB would take: data here
B6_TOP = 0xBD60                             #   the row loop and copy blitter above this
MAP6 = 0x8800                               #   the map, then the directory, then images
TILES_BASE = 0x8100                         # bank 5: the tiles from here (page aligned)
B5X = 0xBB40                                #   up to the row loop's region (cleo_b.cfg)
TILE_ROOM = (B5X - TILES_BASE) // 64        # 233: the Master's largest level (L4B) exactly

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
out('sprdir.bin', sprdir)

out('digits.bin', m.digits)
out('font.bin', m.font)
out('alt.bin', m.altfile)
out('BAR', m.barbytes)
MUS = os.path.join(BEEB, 'build', 'MUSIC')
if not os.path.exists(MUS):
    os.system('python3 ' + os.path.join(BEEB, 'tools', 'midi2snd.py'))
out('music.bin', open(MUS, 'rb').read())

# ---------------------------------------------------------------- per-level helpers
def _bits(a, b):
    return sum(bin(x ^ y).count('1') for x, y in zip(a, b))
def _art(c):
    o = m.compact[c]; return m.til_idx[o * 8:o * 8 + 8, :]
def _flatmask(a):
    f = np.zeros((8, 8), bool)
    f[:, 1:] |= a[:, 1:] == a[:, :-1]; f[:, :-1] |= a[:, :-1] == a[:, 1:]
    f[1:, :] |= a[1:, :] == a[:-1, :]; f[:-1, :] |= a[:-1, :] == a[1:, :]
    f[0, :] = f[-1, :] = f[:, 0] = f[:, -1] = True
    return f
def _flatdiff(c, k):
    a = m.strip(np.asarray(m.tile_preview[c])); b = m.strip(np.asarray(m.tile_preview[k]))
    d = (a != b); d = d[0::2] | d[1::2]
    return int((d & _flatmask(_art(c))).sum())

def level_fold(cm, live_reps, usage, room):
    """The level image holds `room` tiles.  A level that needs more folds its cheapest
    pairs by convert.py's own damage metric (cells using the tile x flat pixels whose
    rendering changes), the same order the set fold uses.  Returns {rep: rep} extra."""
    extra = {}
    if len(live_reps) <= room:
        return extra, 0
    cand = []
    ids = sorted(live_reps)
    for i, c in enumerate(ids):
        if c in m._nomerge:
            continue
        for k in ids[:i]:
            if k in m._nomerge or m.alt_class[k] != m.alt_class[c]:
                continue
            d = _bits(m.tiles_mode2[c], m.tiles_mode2[k])
            if d <= 96:
                cand.append((usage.get(c, 0) * _flatdiff(c, k), d, c, k))
    cand.sort()
    live, target, dmg = len(ids), set(), 0
    for damage, d, c, k in cand:
        if live <= room:
            break
        if c in extra or c in target or k in extra:
            continue
        extra[c] = k; target.add(k); live -= 1; dmg += damage
    assert live <= room, 'level will not fold into the tile room'
    return extra, dmg

def rle(data):
    """PackBits-like: c < 128 = c+1 literal bytes follow; c >= 128 = the next byte
    repeated c-126 times (2..129).  ldprog.s decodes it."""
    out_, i, n = bytearray(), 0, len(data)
    while i < n:
        j = i
        while j + 1 < n and data[j + 1] == data[i] and j - i < 128:
            j += 1
        run = j - i + 1
        if run >= 2:
            out_ += bytes([126 + run, data[i]]); i += run; continue
        j = i
        while j < n and j - i < 128 and not (j + 2 < n and data[j] == data[j + 1] == data[j + 2]):
            j += 1
        out_ += bytes([j - i - 1]) + data[i:j]; i = j
    return out_
def unrle(data):
    o, i = bytearray(), 0
    while i < len(data):
        c = data[i]; i += 1
        if c < 128:
            o += data[i:i + c + 1]; i += c + 1
        else:
            o += bytes([data[i]]) * (c - 126); i += 1
    return o

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
    rep = m.folded[gset]
    def rep_of(c): return rep.get(c, c)
    specials = [m.special['VANISH0'] + i for i in range(8)] + [m.special['FLOWER0'] + i for i in range(4)]
    inset = set(m.remap[gset])
    live = set(int(c) for c in np.unique(cm)) | (set(specials) & inset)
    vals, cnt = np.unique(cm, return_counts=True)
    usage = {}
    for v, n in zip(vals, cnt):
        r = rep_of(int(v)); usage[r] = usage.get(r, 0) + int(n)
    reps = set(rep_of(c) for c in live if c not in m.tile_solid)
    extra, dmg = level_fold(cm, reps, usage, TILE_ROOM)
    def rep2(c):
        r = rep_of(c); return extra.get(r, r)
    local = {}                              # compact id -> level tile id
    for c in sorted(live):
        if c in m.tile_solid:
            local[c] = SOLID_CYAN if m.tile_solid[c] == 1 else SOLID_BLACK
    # a flat tile -- every char the same two bytes alternating down its lines (one
    # colour's dither) -- is two bytes in FLATTAB and an id from FLAT0, as the two
    # solids are (the last two entries); the blitter fills it (drawrect's @solid)
    def flat_pair_row(row):                 # a char row (4 chars) of one 2-byte dither
        cs = [bytes(row[k * 8:k * 8 + 8]) for k in range(4)]
        if all(c == cs[0] for c in cs) and all(cs[0][i] == cs[0][i & 1] for i in range(8)):
            return cs[0][:2]
        return None
    def flat_pair(t):
        a, b = flat_pair_row(t[:32]), flat_pair_row(t[32:])
        return a if a is not None and a == b else None
    # A half tile has one char row that is a fill (flat_pair of its four chars) or
    # equal to the other: only the other row is stored, 32 bytes, in a region above
    # the full tiles, with the fill's pair in HALFPAIR.  Ids: full tiles from 0,
    # halves from half0 in three runs (top row fills, bottom row fills, both rows the
    # same), flats from FLAT0.  Byte-identical tiles (the set fold only merges near
    # ones) share an id.
    def half_of(t):
        top, bot = flat_pair_row(t[:32]), flat_pair_row(t[32:])
        if top is not None and bot is None:
            return ('top', t[32:], top)      # the top row is the fill: the bottom stored
        if bot is not None and top is None:
            return ('bot', t[:32], bot)
        if t[:32] == t[32:]:
            return ('pair', t[:32], b'\0\0')
        return None
    reps = sorted(set(rep2(c) for c in sorted(live) if c not in m.tile_solid))
    # identical tiles share one representative -- identical to the game too: the logic
    # reads a tile's attribute and altitude class by id, so those are in the key
    def attr_of(c):
        a = 3
        if c in m.push_tiles:
            a = m.push_tiles[c] + 3
        if c in m.kill_tiles:
            a |= 0x80
        return a
    def ident(r):
        return (bytes(m.tiles_mode2[r]), attr_of(r), m.alt_class[r])
    bybytes = {}
    for r in reps:
        bybytes.setdefault(ident(r), r)
    canon = {r: bybytes[ident(r)] for r in reps}
    ureps = sorted(set(canon.values()))
    flats, halves, fulls = [], {'top': [], 'bot': [], 'pair': []}, []
    for r in ureps:
        t = m.tiles_mode2[r]
        fp = flat_pair(t)
        if fp is not None:
            flats.append((r, fp)); continue
        h = half_of(t)
        if h is not None:
            halves[h[0]].append((r, h[1], h[2])); continue
        fulls.append(r)
    byrep = {}
    for i, r in enumerate(fulls):
        byrep[r] = i
    half0 = len(fulls)
    hlist = halves['top'] + halves['bot'] + halves['pair']
    half1 = half0 + len(halves['top'])
    half2 = half1 + len(halves['bot'])
    for i, (r, stored, pr) in enumerate(hlist):
        byrep[r] = half0 + i
    for i, (r, fp) in enumerate(flats):
        byrep[r] = FLAT0 + i
    assert half0 + len(hlist) <= FLAT0, (name, half0, len(hlist))
    for c in sorted(live):
        if c not in m.tile_solid:
            local[c] = byrep[canon[rep2(c)]]
    NTILES = len(fulls)
    NHALF = len(hlist)
    assert NTILES <= TILE_ROOM, (name, NTILES)
    assert len(flats) <= NFLAT, (name, len(flats))
    flattab = bytearray()
    for r, fp in flats:
        flattab += fp
    flattab = flattab.ljust(2 * NFLAT, b'\0')
    flattab += bytes([0x0F, 0x0F, 0x00, 0x00])          # cyan, black: ids 254, 255
    halfpair = bytearray()
    for r, stored, pr in hlist:
        halfpair += pr
    # the room: full tiles, the halves from the next page, their pairs after them
    HALFBASE = TILES_BASE + ((NTILES * 64 + 255) & ~255)
    assert HALFBASE + NHALF * 32 + len(halfpair) <= B5X, (name, NTILES, NHALF)
    # the tile list: for each level id, the tile's index in the set's file (TILESO/I)
    setidx = {c: i for i, c in enumerate(m.tileset[gset])}
    tilelist = bytearray()
    for r in fulls:
        tilelist.append(setidx[r])
    halflist = bytearray()                  # per half: the set index and the stored row
    for r, stored, pr in hlist:
        halflist += bytes([setidx[r], 0 if stored == bytes(m.tiles_mode2[r][:32]) else 1])
    lut = np.zeros(len(m.compact), dtype=np.uint8)
    for c, t in local.items():
        lut[c] = t
    mapb = lut[cm].tobytes()
    h, w = cm.shape

    # ---- tables
    hdr = bytearray([L['lw'], L['lh'], L['start'][0], L['start'][1], L['exit'][0], L['exit'][1],
                     len(L['objs']), 1])
    for cid in specials:
        hdr.append(local.get(cid, 255))
    assert len(hdr) == 20
    hdr.append(gset)
    hdr.append(NTILES)
    hdr.append(8 - L['lw'])                 # maprow's shift: row * 2^lw = (row << 8) >> (8 - lw)
    hdr += bytes([NHALF, half0, half1, half2, HALFBASE >> 8])   # +23..+27: the halves
    hdr = hdr.ljust(32, b'\0')
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
    for c in sorted(live):
        t = local[c]
        a = 3
        if c in m.push_tiles:
            a = m.push_tiles[c] + 3
        if c in m.kill_tiles:
            a |= 0x80
        attr[t] = a
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
    ids = set(range(42))                    # Cleo, the boomerang (27..33), the common ones
    for t in types:
        if t in m.TYPE_IDS:
            lo, hi = m.TYPE_IDS[t]
            ids |= set(range(lo, hi + 1))
    imgs = sorted(set(m.entry[i][0] for i in ids if m.entry[i] is not None))
    bxs = list(range(6, 12)) if gset == 1 else list(range(0, 6))
    tramps = [0, 1, 2] if 1 in types else []
    R6BASE = MAP6 + len(mapb) + 118 * 8
    regions = {'r4': [B4_DATA[0], B4_DATA[1]], 'h4': [B4_HOLE[0], B4_HOLE[1]],
               'r6': [R6BASE, B6_TOP], 's6': [B6_SWAP[0], B6_SWAP[1]], 'h6': [B6_HOLE[0], B6_HOLE[1]]}
    fill = {r: 0 for r in regions}
    mirrored = set(m.entry[i][0] for i in ids if m.entry[i] is not None and m.entry[i][1])
    def place(region, n):
        base = regions[region][0] + fill[region]; fill[region] += n; return base
    def room(region):
        return regions[region][1] - regions[region][0] - fill[region]
    img_addr, mask_addr, img_bank = {}, {}, {}
    items = [('img', j, len(m.img_bytes[j]), len(m.img_mask[j])) for j in imgs]
    items += [('box', k, len(m.box_bytes[k]), 0) for k in bxs]
    items += [('tramp', f, len(m.tramp_bytes[f]), 0) for f in tramps]
    def canmirror(it):
        return it[0] == 'img' and it[1] in mirrored
    items.sort(key=lambda it: (0 if it[0] != 'img' else (1 if canmirror(it) else 2), -(it[2] + it[3])))
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
            assert try4(key, nd, nm), '%s: mirrored sprite does not fit bank 4: %s %d' % (name, kind, j)
        elif kind != 'img':                 # the copy blitter is bank 6's alone
            assert try6(key, nd, nm), '%s: box stars do not fit bank 6: %s %d' % (name, kind, j)
        else:
            if not (try6(key, nd, nm) or try4(key, nd, nm)):
                raise SystemExit('%s: sprites do not fit: %s %d (%d+%d); room r4=%d h4=%d r6=%d h6=%d s6=%d'
                                 % (name, kind, j, nd, nm, room('r4'), room('h4'), room('r6'), room('h6'), room('s6')))
    placement = bytearray()
    for (kind, j), a in sorted(img_addr.items(), key=lambda kv: item_index(*kv[0])):
        ma = mask_addr.get((kind, j), 0)
        placement += bytes([item_index(kind, j), img_bank[(kind, j)], a & 255, a >> 8, ma & 255, ma >> 8])
    placement += b'\xff'

    # ---- the file: a table of section offsets, then the sections
    maprle = rle(mapb)
    assert unrle(maprle) == mapb
    secs = [('hdr', hdr), ('objs', objs), ('attr', attr), ('altcls', acls),
            ('tiles', tilelist), ('place', placement), ('map', maprle), ('flat', flattab),
            ('halves', halflist), ('hpair', halfpair)]
    off = 2 * len(secs)
    table = bytearray()
    body = bytearray()
    for nm_, data in secs:
        o = off + len(body)
        table += bytes([o & 255, o >> 8])
        body += data
    assert off + len(body) <= 0x7800 - 0x5C00, (name, off + len(body))   # STAGE_LVL..LV_OBJS (defs.inc)
    out('L%d' % (lv * 2 + sub), table + body)
    stats = dict(name=name, ntiles=NTILES, nflat=len(flats), nhalf=NHALF, folded=len(extra), damage=dmg, w=w, h=h, nobj=len(L['objs']),
                 nimg=len(imgs), r4=fill['r4'], h4=fill['h4'], r6=fill['r6'], h6=fill['h6'], s6=fill['s6'],
                 maxspr=MAXSPR, binmax=BINMAX, maprle=len(maprle), size=off + len(body))
    return stats

allstats = []
for lv in range(8):
    for sub in (0, 1):
        s = pack_level(lv, sub)
        allstats.append(s)
        print('%-4s %3d tiles +%2d half +%d flat (%2d folded, damage %4d) map %3dx%2d rle %5d  %3d obj %2d img  '
              'b4 %5d+%3d  b6 %5d+%3d+%3d  spr %2d bin %2d  file %5d'
              % (s['name'], s['ntiles'], s['nhalf'], s['nflat'], s['folded'], s['damage'], s['w'], s['h'], s['maprle'], s['nobj'], s['nimg'],
                 s['r4'], s['h4'], s['r6'], s['h6'], s['s6'], s['maxspr'], s['binmax'], s['size']))

MAXSPR = max(s['maxspr'] for s in allstats)
BINMAX = max(s['binmax'] for s in allstats)
with open(os.path.join(OUT, 'assets.inc'), 'w') as f:
    f.write('; generated by modelb/tools/assets.py: the bounds every level fits\n')
    f.write('SOLID_CYAN = %d\nSOLID_BLACK = %d\nFLAT0 = %d\n' % (SOLID_CYAN, SOLID_BLACK, FLAT0))
    f.write('BOXID0 = 103\nBOXN = 15\n')
    f.write('TITLE_ADDR = $8900\n')         # bank 6, as the Master: over the map
    f.write('TP_LOGO = 0\nTP_YOU = 1\nTP_WIN = 2\nTP_LOSE = 3\nTP_CLEO0 = 4\n')   # the title pack's pieces
    f.write('HUD_BANK = 7\n')
    f.write('SPR_BAR = 0\nSPR_DIGITS = digits_art\nSPR_FONT = font_art\n')
    f.write('MAXSPRDEF = %d\nBINMAXDEF = %d\n' % (MAXSPR, BINMAX))
    f.write('SPR6_MIRROR = 0\n')            # bank 6 holds no image that is drawn mirrored
    f.write('SPR4_COPY = 0\n')              # and bank 4 nothing the copy blitter draws
    f.write('TILE_ROOM = %d\n' % TILE_ROOM)
    f.write('B4_DATA_END = $%04X\nB6_TOP = $%04X\nMAP6 = $%04X\n' % (B4_DATA[1], B6_TOP, MAP6))
    f.write('NIMGTAB = %d\n' % (NIMG + 15))
print('MAXSPR %d BINMAX %d; tile room %d; imgtab %d entries' % (MAXSPR, BINMAX, TILE_ROOM, NIMG + 15))
