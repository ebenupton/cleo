#!/bin/sh
# Cleo: one disc (build/cleo.ssd) for the BBC Model B (64K of sideways RAM) and the
# Master 128.  The sources (src/) are assembled twice against one sector table: BHW=1
# for the Model B's hardware into build/modelb/, BHW=0 for the Master's into
# build/master/ -- the same structure, each level gathered into the banks by the
# game's own loader.  The boot loader picks the machine's bank images (BANKSB,
# BANKSM); each machine's LDPROG and bank 7 images (IMG7: MENU, GAME) are its own;
# everything else, the levels included, is on the disc once.
set -e
cd "$(dirname "$0")"
# TILEMIRROR=1 builds the tile blitter's mirrored tiles (src/cpu.inc; off by default,
# no level needs them), which move the tiles up a page: the converter, the packer
# (tools/convert.py, assets.py) and the linker areas follow it
if [ "$TILEMIRROR" = 1 ]; then MIRDEF="-D TILEMIRROR=1"; else TILEMIRROR=0; MIRDEF=""; fi
export TILEMIRROR
settarget() {                       # $1: modelb or master
    TARGET=$1
    if [ "$TARGET" = master ]; then
        BD=build/master; CPU=65C02; DEFS="-D BHW=0 $MIRDEF"; CFG=cfg/master.cfg; BARADDR='$2B00'
    else
        BD=build/modelb; CPU=6502; DEFS="$MIRDEF"; CFG=cfg/modelb.cfg; BARADDR='$0300'
    fi
    export BD TARGET
}
[ -n "$SKIP_ASSETS" ] || python3 tools/midi2snd.py
for t in modelb master; do
    settarget $t
    mkdir -p $BD
    [ -n "$SKIP_ASSETS" ] || python3 tools/assets.py      # (assets.py runs tools/convert.py)
    sed "s#\"build/#\"$BD/#g" $CFG > $BD/game.cfg
    [ "$TILEMIRROR" = 1 ] && sed -i.bak 's#start = \$8000, size = \$0700#start = $8000, size = $0800#; s#start = \$8000, size = \$0300#start = $8000, size = $0340#' $BD/game.cfg
    for f in BANKS MENU GAME IMG7 LDPROG; do [ -f $BD/$f ] || : > $BD/$f; done
done
# what both machines read goes on the disc once (the Model B's copy): the packs agree
for f in SPRX SPRC BAR L0 L1 L2 L3 L4 L5 L6 L7 L8 L9 L10 L11 L12 L13 L14 L15; do
    cmp -s build/modelb/$f build/master/$f || { echo "build/modelb/$f and build/master/$f differ: the level layout is not one"; exit 1; }
done

# the disc's file list, in disc order: the boot files, each machine's pieces, the
# shared files together, the levels after them.  A game's start reads LDPROG, the
# game's image (IMG7) and BAR in turn, so they are neighbours: the Model B's in that
# order, the Master's around them
B=build/modelb M=build/master
DISC="!BOOT:build/BOOT LOADER:build/LOADER BANKSB:$B/BANKS BANKSM:$M/BANKS"
DISC="$DISC IMG7M:$M/IMG7 LDPROGM:$M/LDPROG LDPROGB:$B/LDPROG IMG7B:$B/IMG7 BAR:$B/BAR"
DISC="$DISC SPRX:$B/SPRX SPRC:$B/SPRC TILES0:build/TILES0 TILES1:build/TILES1"
for l in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do DISC="$DISC L$l:$B/L$l"; done
DISC="$DISC TILES2:build/TILES2"
[ -f build/LOADER ] || : > build/LOADER
printf '*RUN LOADER\r' > build/BOOT

# Passes: the sector table (files.inc) needs the files' sizes, and bank 7 and LDPROG
# carry entries from it.  No size depends on a sector number, so the second pass is
# stable (the third checks that).
for pass in 1 2 3; do
    [ $pass = 3 ] && cp $B/files.inc $B/files.prev
    python3 tools/mkdfs.py table $B/files.inc $DISC
    cp $B/files.inc $M/files.inc
    [ $pass = 3 ] && { cmp -s $B/files.inc $B/files.prev || { echo "files.inc did not settle"; exit 1; }; break; }
    for t in modelb master; do
        settarget $t
        ca65 -g --cpu $CPU $DEFS -I $BD -I src --bin-include-dir $BD \
             -o $BD/main.o src/main.s -l $BD/main.lst
        # bank 7's game image ends at the kernel: the game's data and code, then the
        # engine's, from the Model B's sizes (od65: the object's segments, before any
        # link); the Master's, pinned to the Model B's, fall short of the kernel
        if [ $TARGET = modelb ]; then
            B7N=$(od65 --dump-segsize $BD/main.o | awk '/^ +(LGCDATA|LGCCODE|ENGCODE):/ {s += $2} END {print s}')
            B7S=$(printf '%04X' $(( 0x$(grep -o 'B7K: *start = \$[0-9A-F]*' $CFG | sed 's/.*\$//') - B7N )))
            B7N=$(printf '%04X' $B7N)
        fi
        sed -i.b7 "s#^\( *B7: *start = [$]\)[0-9A-F]*, size = [$][0-9A-F]*#\1$B7S, size = \$$B7N#" $BD/game.cfg
        # the Master's segments at the Model B's addresses (linked just before): its
        # shorter 65C02 code leaves gaps, and the data lies alike on both
        LCFG=$BD/game.cfg
        [ $TARGET = master ] && { python3 tools/pincfg.py $BD/game.cfg $B/cleo.dbg > $BD/pinned.cfg; LCFG=$BD/pinned.cfg; }
        ld65 -C $LCFG -o $BD/unused.bin $BD/main.o -m $BD/map.txt -Ln $BD/labels.txt --dbgfile $BD/cleo.dbg
        # what the loaders need from the game: its addresses
        python3 - <<'EOF'
import re
want = ['boot','dsk_type','dsk_drv','read_sectors','ld_sec','ld_n','ld_dst',
        'LV_HDR','LV_OBJS','LV_ATTR0','LV_ALTCLS','TILES','SPRMASK','SPR_TABLE','mapshr','MAPSTRIDE','FLATTAB',
        'half0','half1','half2','halfhi','halfhi5','halfsub','mir0','MIRTAB','sprc_ok','sprx_ok','HPAIR0','HPAIR1',
        'MAP5','LDZP','BARADDR','STAGE','STAGE_LVL','LDPROG','PBANK','PBOARD','dsk_banks','dsk_board']
addr = {}
import os
BD = os.environ['BD']
for l in open(BD + '/labels.txt'):
    p = l.split()
    if len(p) >= 3 and p[0] == 'al':
        addr[p[2].lstrip('.')] = int(p[1], 16)
# drawrect's @s0f (a cheap label: in the debug info, not labels.txt): the solid's
# lda #fill, whose operand the loader patches
dbg = open(BD + '/cleo.dbg').read()
did = re.search(r'^sym\tid=(\d+),name="drawrect",', dbg, re.M).group(1)
s0f = re.search(r'^sym\tid=\d+,name="@s0f",[^\n]*parent=%s,[^\n]*val=0x([0-9A-F]+)' % did, dbg, re.M)
addr['SOLIDF'] = int(s0f.group(1), 16) + 1
want.append('SOLIDF')
# bank 7's images (ldprog.s image_load): the game's, the linker's b7.bin (its code,
# from LGCDATA; its variables are not in the file), and the menus', MENU
# (one file on the disc, IMG7: the menus' image to a whole sector, then the game's,
# which ldprog.s reads as two)
import shutil
shutil.copy(BD + '/b7.bin', BD + '/GAME')
menu = open(BD + '/MENU', 'rb').read()
open(BD + '/IMG7', 'wb').write(menu + bytes(-len(menu) % 256) + open(BD + '/GAME', 'rb').read())
img = {'GAME': (addr['__LGCDATA_RUN__'], os.path.getsize(BD + '/GAME')),
       'MENU': (addr['__MNUCODE_RUN__'], os.path.getsize(BD + '/MENU'))}
assert img['MENU'][0] + img['MENU'][1] <= addr['__KRNDATA_RUN__'] and img['GAME'][0] + img['GAME'][1] <= addr['__KRNDATA_RUN__']
with open(BD + '/defs_ld.inc', 'w') as f:
    f.write('; generated by build.sh from build/labels.txt\n')
    for n in want:
        if n in addr:
            f.write('%s = $%04X\n' % (n, addr[n]))
        else:
            f.write('; %s: not in labels.txt (a constant?)\n' % n)
    for k, (a, n) in img.items():
        f.write('%s_ADDR = $%04X\n%s_LEN = %d\n' % (k, a, k, n))
    # the image's variables (LGCBSS then ENGBSS, page aligned), zeroed as it comes in:
    # below its code
    bss, bssn = addr['__LGCBSS_RUN__'], addr['__ENGBSS_RUN__'] + addr['__ENGBSS_SIZE__'] - addr['__LGCBSS_RUN__']
    assert bss & 255 == 0 and bss + ((bssn + 255) & ~255) <= addr['__LGCDATA_RUN__'], 'the game image\'s variables run into its code'
    f.write('GAME_BSS = $%04X\nGAME_BSS_PAGES = %d\n' % (bss, (bssn + 255) // 256))
# each image's own patch lists (bank 7 entries of the linker's, cpu.inc BANKREF and
# wrsel, that fall in it): image_load applies them after every read, as the boot
# loader does BANKS's
fix, wr = open(BD + '/bankfix.bin', 'rb').read(), open(BD + '/wrfix.bin', 'rb').read()
fixe = [(fix[i], fix[i + 1] | fix[i + 2] << 8) for i in range(0, len(fix), 3)]
wre = [(wr[i], wr[i + 1] | wr[i + 2] << 8, wr[i + 3]) for i in range(0, len(wr), 4)]
# The two images share their addresses, so a list entry (bank, address) cannot say
# which it is in: the menus' carry none (they read PBANK: cpu.inc ldpbank), and the
# debug info's site labels (@bf_, @wr_) are checked for it.  Every bank 7 entry below
# the kernel is the game's.
for mm in re.finditer(r'^sym\tid=\d+,name="@(bf|wr)_\w+",[^\n]*seg=(\d+)', dbg, re.M):
    sg = re.search(r'^seg\tid=%s,name="(\w+)"' % mm.group(2), dbg, re.M).group(1)
    assert not sg.startswith('MNU'), 'a bank-number or write-bank site in the menus\' image (%s): use ldpbank' % sg
def inimg(k, bank, a):
    return k == 'GAME' and bank == 7 and img[k][0] <= a < img[k][0] + img[k][1]
with open(BD + '/img7fix.inc', 'w') as f:
    f.write('; generated by build.sh: bank 7 images\' bank numbers and write-bank stores\n')
    for k, lab in (('GAME', 'game'), ('MENU', 'menu')):
        bf = [a for b, a in fixe if inimg(k, b, a)]
        ws = [(a, kd) for b, a, kd in wre if inimg(k, b, a)]
        f.write('bf_%s: %s.byte 0, 0\n' % (lab, ''.join('.word $%04X\n        ' % a for a in bf)))
        f.write('wr_%s: %s.byte 0, 0\n' % (lab, ''.join('.word $%04X\n        .byte $%02X\n        ' % (a, kd) for a, kd in ws)))
EOF
        # the constants ld65 does not list: assembled with the game's own flags, so the
        # hardware conditionals in defs.inc resolve as they do in the game (src/ldconst.s)
        ca65 --cpu $CPU $DEFS -I $BD -I src -o /dev/null src/ldconst.s > $BD/ldconst.out
        grep ' = ' $BD/ldconst.out >> $BD/defs_ld.inc
        echo "BARADDR = $BARADDR" >> $BD/defs_ld.inc
        ca65 --cpu 6502 $DEFS -I $BD -I src --bin-include-dir $BD -o $BD/ldprog.o src/ldprog.s -l $BD/ldprog.lst
        ld65 -C cfg/ldprog.cfg -o $BD/LDPROG $BD/ldprog.o
        # BANKS: the fixed pieces with their table, then the bank-number patch list (every
        # byte of the pieces that holds a bank number, cpu.inc BANKREF) ending in $FF: the
        # boot loader rewrites those bytes to the banks it found RAM in.  Each entry is
        # checked against the pieces here: a wrong bank on a bankimm would land outside
        # them or on a byte that is no bank number.  Then the write-bank store list (cpu.inc
        # wrsel: bank, address, kind; every entry must sit on a `sta $FE30`), ending in $FF.
        python3 - <<'EOF'
import os
BD = os.environ['BD']
lab = {}
for l in open(BD + '/labels.txt'):
    p = l.split()
    if len(p) >= 3 and p[0] == 'al':
        lab[p[2].lstrip('.')] = int(p[1], 16)
pieces = [(4, 0x8000, 'b4x.bin'), (4, 0xBB00, 'b4t.bin'),
          (5, 0x8000, 'b5x.bin'), (5, 0xBC00, 'b5t.bin'),
          (6, 0x8000, 'b6x.bin'),                                 # (B6X in the cfg)
          (7, 0x7000, 'boot.bin'),        # main RAM (BOOTRAM): start-up and the low-RAM image
          (7, lab['__KRNDATA_RUN__'], 'b7k.bin')]   # the kernel: resident, the top of bank 7
if os.environ.get('TARGET') == 'master':
    pieces.append((7, 0x0600, 'mcode.bin'))         # main RAM: the Master's handler, chain, keys, sound
tab, body, img = bytearray([len(pieces)]), bytearray(), {}
for bank, addr, fn in pieces:
    d = open(os.path.join(BD, fn), 'rb').read()
    tab += bytes([bank, addr & 255, addr >> 8, len(d) & 255, len(d) >> 8])
    body += d
    img[(bank, addr)] = d
def piece_bytes(bank, addr, n):
    hit = [d[addr - a:addr - a + n] for (b, a), d in img.items() if b == bank and a <= addr and addr + n <= a + len(d)]
    assert len(hit) == 1, 'patch %d:$%04X is in no piece' % (bank, addr)
    return hit[0]
# bank 7's images are not BANKS's: ldprog.s image_load patches them (img7fix.inc)
imgs = [(lab['__LGCDATA_RUN__'], os.path.getsize(BD + '/GAME')), (lab['__MNUCODE_RUN__'], os.path.getsize(BD + '/MENU'))]
ingame = lambda bank, a: bank == 7 and any(b <= a < b + n for b, n in imgs)
fix0 = open(BD + '/bankfix.bin', 'rb').read()
assert len(fix0) % 3 == 0, 'bankfix.bin is not whole entries'
fix = b''.join(fix0[i:i + 3] for i in range(0, len(fix0), 3) if not ingame(fix0[i], fix0[i + 1] | fix0[i + 2] << 8))
for i in range(0, len(fix), 3):
    bank, addr = fix[i], fix[i + 1] | (fix[i + 2] << 8)
    v = piece_bytes(bank, addr, 1)[0]
    assert 4 <= (v & 15) <= 7, 'bank patch %d:$%04X names byte $%02X, no bank number' % (bank, addr, v)
wr0 = open(BD + '/wrfix.bin', 'rb').read()
assert len(wr0) % 4 == 0, 'wrfix.bin is not whole entries'
wr = b''.join(wr0[i:i + 4] for i in range(0, len(wr0), 4) if not ingame(wr0[i], wr0[i + 1] | wr0[i + 2] << 8))
for i in range(0, len(wr), 4):
    bank, addr, kind = wr[i], wr[i + 1] | (wr[i + 2] << 8), wr[i + 3]
    assert piece_bytes(bank, addr, 3) == b'\x8d\x30\xfe', 'write-bank store %d:$%04X is not sta $FE30' % (bank, addr)
    assert kind in (4, 5, 6, 7, 0xFE), 'write-bank store %d:$%04X: kind $%02X' % (bank, addr, kind)
banks = tab + body + fix + b'\xff' + wr + b'\xff'
assert 0x2000 + len(banks) <= 0x7000, 'BANKS (read to $2000) would run into the start-up piece at $7000'
open(BD + '/BANKS', 'wb').write(banks)
print('BANKS: %d pieces, %d bytes, %d bank patches, %d write-bank stores' % (len(pieces), len(tab) + len(body), len(fix) // 3, len(wr) // 4))
EOF
    done
    # the boot loader, one for both machines: the start-up header it writes and the
    # entry it jumps to are at the same addresses on both (init.s)
    for n in boot dsk_type dsk_drv dsk_banks dsk_board; do
        [ "$(grep "^$n = " $B/defs_ld.inc)" = "$(grep "^$n = " $M/defs_ld.inc)" ] || { echo "$n differs between the machines"; exit 1; }
    done
    ca65 --cpu 6502 -I $B -I src -o build/loader.o src/loader.s
    ld65 -C cfg/loader.cfg -o build/LOADER build/loader.o
done
python3 tools/mkdfs.py build build/cleo.ssd CLEO \
    "!BOOT:build/BOOT:0000:FFFF" "LOADER:build/LOADER:1900:1900" \
    $(echo $DISC | tr ' ' '\n' | grep -v '^!BOOT\|^LOADER' | tr '\n' ' ')
cmp -s $B/assets.inc $M/assets.inc || { echo "the machines' assets.inc differ"; exit 1; }
python3 test/layoutcheck.py $B $M
ls -l $B/BANKS $M/BANKS build/cleo.ssd
