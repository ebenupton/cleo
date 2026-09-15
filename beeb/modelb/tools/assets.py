#!/usr/bin/env python3
"""Pack one level's data for the Model B target, in the Master's own formats.

   python3 tools/assets.py [lv] [sub]     (default 1 0 = L1B, the first large indoor level)

The Master's convert.py is imported for its tables (MODE=1) and the files are laid
out exactly as it lays them out for the Master's loader, only cut down to what one
level needs and split between the banks the Model B has room in:

   tiles.bin    the tiles this level can show, 64 bytes each, by tile id (0..253);
                the two solid fills are ids 254/255 and own no bytes, as on the Master
   map.bin      row major tile ids
   hdr.bin      the level header (256), objs.bin (768), attr.bin, altcls.bin (256 each),
                alt.bin -- the pieces of the Master's L?? file, bank-7 half
   spr4.bin     sprite images and masks for bank 4 ($8800 on), spr4h.bin (bank 4,
                $8100-$82FF) and spr6.bin (bank 6, $8800 on): the level's sprites do
                not fit one bank beside the blitter, so the directory's $10 flag
                names the second bank, the way the Master's does
   sprtab.bin   the 118-entry, 8-byte sprite directory; sprmask.bin the mask addresses
   digits.bin, bar.bin, music.bin, assets.inc
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

lv = int(sys.argv[1]) if len(sys.argv) > 1 else 1
sub = int(sys.argv[2]) if len(sys.argv) > 2 else 0
L = m.levels[(lv, sub)]
name = m.name_of(lv, sub)
cm = m.maps[(lv, sub)]                      # the compact map, as the Master packs it
assert cm.min() >= 0
gset = m.tileset_of(lv, sub)
SOLID_CYAN, SOLID_BLACK = 254, 255

# ---------------------------------------------------------------- tiles
specials = [m.special['VANISH0'] + i for i in range(8)] + [m.special['FLOWER0'] + i for i in range(4)]
inset = set(m.remap[gset])                  # the compact ids the level's tile set has
live = set(int(c) for c in np.unique(cm)) | (set(specials) & inset)
# The Master folds a set's near-duplicate tiles into one another to fit 254 ids
# (convert.py: folded[g] maps a compact id to the one that stands in for it), so the
# tile drawn for c is the representative's; the same here, or the pixels differ.
rep = m.folded[gset]
def rep_of(c): return rep.get(c, c)
local = {}                                  # compact id -> tile id
for c in sorted(live):
    if c in m.tile_solid:
        local[c] = SOLID_CYAN if m.tile_solid[c] == 1 else SOLID_BLACK
byrep = {}                                  # representative -> tile id
for c in sorted(live):
    if c not in m.tile_solid:
        r = rep_of(c)
        if r not in byrep:
            byrep[r] = len(byrep)
        local[c] = byrep[r]
NTILES = len(byrep)
assert NTILES <= 254, NTILES
tiles = bytearray()
for r, t in sorted(byrep.items(), key=lambda kv: kv[1]):
    tiles += m.tiles_mode2[r]
assert len(tiles) == 64 * NTILES
out('tiles.bin', tiles)

lut = np.zeros(len(m.compact), dtype=np.uint8)
for c, t in local.items():
    lut[c] = t
mapb = lut[cm].tobytes()
h, w = cm.shape
out('map.bin', mapb)

# ---------------------------------------------------------------- level tables
hdr = bytearray([L['lw'], L['lh'], L['start'][0], L['start'][1], L['exit'][0], L['exit'][1],
                 len(L['objs']), 1])
for cid in specials:
    hdr.append(local.get(cid, 255))
assert len(hdr) == 20
hdr.append(gset)
out('hdr.bin', hdr.ljust(32, b'\0'))

objs = bytearray()
reach = m.enemy_reach(L['objs'])
for (t, x, y, extra) in L['objs']:
    e = (list(extra) + [0, 0, 0])[:3]
    if t == 0:
        e[0] = m.star_class(cm, x, y)
        e[1] = 1 if m.star_reachable(x, y, reach) else 0
    elif t == 1:
        e[0] = m.tramp_class(cm, x, y)
        b = m.TYPE_BOX[1]
        selfbox = (8 * x + b[0], 8 * x + b[1], 8 * y + b[2], 8 * y + b[3])
        e[1] = 1 if m.box_reachable(b, x, y, reach, skip=selfbox) else 0
    objs += bytes([t, x, y] + e)
assert len(objs) <= 768, len(objs)
out('objs.bin', objs.ljust(768, b'\0'))

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
out('attr.bin', attr)
out('altcls.bin', acls)
out('alt.bin', m.altfile)
out('digits.bin', m.digits)
out('BAR', m.barbytes)                      # the bar, 1280 bytes: the loader puts it at $0300

MUS = os.path.join(BEEB, 'build', 'MUSIC')
if not os.path.exists(MUS):
    os.system('python3 ' + os.path.join(BEEB, 'tools', 'midi2snd.py'))
out('music.bin', open(MUS, 'rb').read())

# ---------------------------------------------------------------- sprites
# The ids the level can draw: Cleo and the common ones, the object types' frames,
# and the box stars of its tile set (black indoors, cyan out) with the trampolines.
types = sorted(set(t for (t, x, y, e) in L['objs']))
ids = set(range(42))                     # Cleo, the boomerang (27..33), the common ones
for t in types:
    if t in m.TYPE_IDS:
        lo, hi = m.TYPE_IDS[t]
        ids |= set(range(lo, hi + 1))
imgs = sorted(set(m.entry[i][0] for i in ids if m.entry[i] is not None))
boxes = list(range(6, 12)) if gset == 1 else list(range(0, 6))    # box_bytes indices
tramps = [0, 1, 2] if 1 in types else []

# Three regions, in the two banks that have room, filled largest first.  An image's
# mask must sit in the same bank as its pixels (the row loop reads both), but not
# beside them: bank 4's hole takes masks on their own.
B4CODE = 1410                               # bank 4: the row loop and inner blocks
B6CODE = 660                                # bank 6: the row loop without the mirrored blitter
R6BASE = 0x8800 + len(mapb) + 118 * 8                   # the map, the directory
regions = {'r4': [0x8800, 0xC000 - B4CODE], 'h4': [0x8020, 0x8300],
           'r6': [R6BASE, 0xC000 - B6CODE], 's6': [0x8300, 0x8400], 'h6': [0x8150, 0x8300]}
blobs = {'r4': bytearray(), 'h4': bytearray(), 'r6': bytearray(), 's6': bytearray(), 'h6': bytearray()}
# an image some entry draws mirrored needs SWAPTAB and the mirrored blitter, which
# only bank 4 carries: bank 6 takes the never-mirrored ones (and the boxes)
mirrored = set(m.entry[i][0] for i in ids if m.entry[i] is not None and m.entry[i][1])
def place(region, data):
    base = regions[region][0] + len(blobs[region])
    blobs[region] += data
    return base
def room(region):
    return regions[region][1] - regions[region][0] - len(blobs[region])
img_addr, mask_addr, img_bank = {}, {}, {}
items = [('img', j, len(m.img_bytes[j]), len(m.img_mask[j])) for j in imgs]
items += [('box', k, len(m.box_bytes[k]), 0) for k in boxes]
items += [('tramp', f, len(m.tramp_bytes[f]), 0) for f in tramps]
def canmirror(it):
    return it[0] == 'img' and it[1] in mirrored
items.sort(key=lambda it: (0 if it[0] != 'img' else (1 if canmirror(it) else 2), -(it[2] + it[3])))   # boxes to bank 6 first, mirrored to bank 4, then the rest
def try4(key, data, nm, j):
    nd = len(data)
    if room('r4') >= nd + nm:
        img_addr[key] = place('r4', data); img_bank[key] = 4
        if nm:
            mask_addr[key] = place('h4' if room('h4') >= nm else 'r4', m.img_mask[j])
    elif room('r4') >= nd and room('h4') >= nm:
        img_addr[key] = place('r4', data); img_bank[key] = 4
        if nm:
            mask_addr[key] = place('h4', m.img_mask[j])
    elif room('h4') >= nd + nm:
        img_addr[key] = place('h4', data); img_bank[key] = 4
        if nm:
            mask_addr[key] = place('h4', m.img_mask[j])
    else:
        return False
    return True
def try6(key, data, nm, j):
    nd = len(data)
    for r in ('r6', 'h6', 's6'):
        if room(r) >= nd + nm:
            img_addr[key] = place(r, data); img_bank[key] = 6
            if nm:
                mask_addr[key] = place(r, m.img_mask[j])
            return True
    for r in ('r6', 'h6'):
        for rm in ('s6', 'h6', 'r6'):
            if rm != r and room(r) >= nd and room(rm) >= nm:
                img_addr[key] = place(r, data); img_bank[key] = 6
                if nm:
                    mask_addr[key] = place(rm, m.img_mask[j])
                return True
    return False
for kind, j, nd, nm in items:
    data = m.img_bytes[j] if kind == 'img' else (m.box_bytes[j] if kind == 'box' else m.tramp_bytes[j])
    key = (kind, j)
    if canmirror((kind, j, nd, nm)):
        assert try4(key, data, nm, j), 'mirrored sprites do not fit bank 4: %s %d' % (kind, j)
    elif kind != 'img':                        # the copy blitter is bank 6's alone
        assert try6(key, data, nm, j), 'box stars do not fit bank 6: %s %d' % (kind, j)
    else:
        if not (try6(key, data, nm, j) or try4(key, data, nm, j)):
            left = sum(it[2] + it[3] for it in items[items.index((kind, j, nd, nm)):])
            raise SystemExit('sprites do not fit: %s %d (%d+%d); room r4=%d h4=%d r6=%d h6=%d s6=%d; %d bytes still to place'
                             % (kind, j, nd, nm, room('r4'), room('h4'), room('r6'), room('h6'), room('s6'), left))
out('spr4.bin', blobs['r4'])
out('spr4h.bin', blobs['h4'])
out('spr6.bin', blobs['r6'])
out('spr6s.bin', blobs['s6'].ljust(256, b'\0'))
out('spr6h.bin', blobs['h6'])

# the directory, exactly as convert.py builds the Master's (its comments explain the
# refx parity rule for Cleo's frames)
table = bytearray()
for i in range(103):
    e = m.entry[i]
    if e is None or ('img', e[0]) not in img_addr:
        table += bytes(8); continue
    j, mirror, rx, ry = e
    im, full, src = m.images[j]
    hh, ww = im.shape
    W = m.img_wbytes[j]
    rx += m.img_shift[j]
    if mirror:
        rx = (2 * W - 1) - rx
    if i < 27:
        if not rx & 1:
            rx -= 1
    ptr = img_addr[('img', j)]
    flags = (1 if mirror else 0) | 2 | (0x10 if img_bank[('img', j)] == 6 else 0)
    table += bytes([ptr & 255, ptr >> 8, W, hh, rx & 255, ry & 255, flags, 2 * hh])
for k in range(12):                                # 103..108 cyan, 109..114 black
    if ('box', k) not in img_addr:
        table += bytes(8); continue
    lo, wc = m.box_geom[k % 6]
    ptr = img_addr[('box', k)]
    flags = 2 | 8 | (0x10 if img_bank[('box', k)] == 6 else 0)
    table += bytes([ptr & 255, ptr >> 8, wc, m.BOX_H, (6 - 2 * lo) & 255, 8, flags, m.BOX_H * 2])
for f in range(3):                                 # 115..117: trampoline black boxes
    if ('tramp', f) not in img_addr:
        table += bytes(8); continue
    lo, wc = m.tramp_geom[f]
    ptr = img_addr[('tramp', f)]
    flags = 2 | 8 | (0x10 if img_bank[('tramp', f)] == 6 else 0)
    table += bytes([ptr & 255, ptr >> 8, wc, m.TRAMP_H, (m.TRAMP_HOT - 2 * lo) & 255,
                    (-8) & 255, flags, m.TRAMP_H * 2])
assert len(table) == 118 * 8
out('sprtab.bin', table)
sprmask = bytearray()
for i in range(118):
    a = 0
    if i < 103 and m.entry[i] is not None and ('img', m.entry[i][0]) in mask_addr:
        a = mask_addr[('img', m.entry[i][0])]
    sprmask += bytes([a & 255, a >> 8])
out('sprmask.bin', sprmask)

with open(os.path.join(OUT, 'assets.inc'), 'w') as f:
    f.write('; generated by modelb/tools/assets.py from %s\n' % name)
    f.write('NTILES = %d\n' % NTILES)
    f.write('MAPW = %d\nMAPH = %d\nMAPLW = %d\nMAPLH = %d\n' % (w, h, L['lw'], L['lh']))
    f.write('SOLID_CYAN = %d\nSOLID_BLACK = %d\n' % (SOLID_CYAN, SOLID_BLACK))
    f.write('BOXID0 = 103\nBOXN = 15\n')
    f.write('TITLE_ADDR = $8900\n')     # (the title pieces: never drawn on this target)
    f.write('HUD_BANK = 6\n')
    f.write('SPR_BAR = 0\nSPR_DIGITS = digits_art\n')   # (no bar art: the loader puts the bar in place)
    f.write('NOBJS = %d\n' % len(L['objs']))
    f.write('LEVEL_IDX = %d\n' % (lv * 2 + sub))   # game.s: file = FI_L0A + (i eor 1) * 2
    f.write('SPR6_MIRROR = 0\n')      # bank 6 holds no image that is drawn mirrored
    f.write('SPR4_COPY = 0\n')        # and bank 4 nothing the copy blitter draws
    f.write('STARTX = %d\nSTARTY = %d\n' % L['start'])
print('%s: %d tiles (%d B), map %dx%d, %d objects, sprites %d images: bank 4 %d+%d B, bank 6 %d+%d+%d B'
      % (name, NTILES, len(tiles), w, h, len(L['objs']), len(imgs),
         len(blobs['r4']), len(blobs['h4']), len(blobs['r6']), len(blobs['h6']), len(blobs['s6'])))
